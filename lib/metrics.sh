#!/usr/bin/env bash
# Telemetry is kept separately from operational metadata. Readers never need
# agents, and collection does not modify the worktree or user configuration.
# ISSUE and S are supplied by load_issue (or the sampler's isolated scope).
# shellcheck disable=SC2153
metrics_key() { printf '%s' "$1" | cksum | awk '{print $1 "-" $2}'; }
metrics_job_dir() { printf '%s/metrics/%s\n' "$DV_HOME" "$(metrics_key "$1:$2")"; }
metrics_store() (
  local dir=$1 record=$2 key tmp
  key=$(metrics_key "$(printf '%s\n' "$record" | jq -er .id)") || return 1
  mkdir -p "$dir/records" || return 1
  tmp=$(mktemp "$dir/.record.XXXXXX") || return 1
  trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$record" > "$tmp" || return 1
  # Publish immutable records with an atomic no-replace link. This also works
  # for worker subshells sharing the watcher's $$, without stale PID locks.
  if ln "$tmp" "$dir/records/$key.json" 2>/dev/null; then return 0; fi
  # First success wins on replay. Refuse checksum/identity collisions.
  jq -e --argjson record "$record" '.id==$record.id and .host==$record.host and .issue==$record.issue' \
    "$dir/records/$key.json" >/dev/null
)
metrics_note() {
  local kind=$1 head=${2:-} at=${3:-$(now)} record
  record=$(jq -cn --arg kind "$kind" --arg head "$head" --arg host "$(jq -r .host "$S/meta")" \
    --arg issue "$ISSUE" --arg id "$kind:$at:$$:$RANDOM" --argjson at "$at" \
    '{id:$id,host:$host,issue:$issue,kind:$kind,head:$head,at:$at}') &&
    metrics_store "$S/metrics" "$record" || printf 'dv: could not record %s metric for %s\n' "$kind" "$ISSUE" >&2
}
metrics_event() {
  local event=$1 kind=$2 at=${3:-$(now)} record host issue
  record=$(printf '%s\n' "$event" | jq -c --arg kind "$kind" --argjson at "$at" \
    '{id:($kind+":"+.id),host:.host,issue:.issue,kind:$kind,at:$at,event_at:.time,event_id:.id,
      latency:([$at-(.time // $at),0]|max)}') || return 1
  host=$(printf '%s\n' "$record" | jq -er .host) || return 1
  issue=$(printf '%s\n' "$record" | jq -er .issue) || return 1
  metrics_store "$(metrics_job_dir "$host" "$issue")" "$record" ||
    printf 'dv: could not record %s metric for %s\n' "$kind" "$issue" >&2
}
metrics_handled() { metrics_event "$1" handled; }
metrics_manager_resumes() {
  local event
  # One manager resume serves the whole batch. Attribute one attempt per job,
  # while successful completion below still acknowledges every original event.
  while IFS= read -r event; do metrics_event "$event" manager_resume; done < <(
    jq -c 'group_by([.event.host,.event.issue]) | .[] | last | .event' "$1")
}
metrics_records() {
  local file
  for file in "$1"/records/*.json; do [ ! -f "$file" ] || cat "$file"; done
}
metrics_fingerprint() (
  local wt=$1 state=$2 file
  {
    if [ -d "$wt" ]; then
    cd "$wt" || return 1
    git rev-parse HEAD || return 1
    # Include tracked and untracked, nonignored files, even same-size edits.
    # NUL paths handle whitespace/newlines; symlinks are never followed.
    while IFS= read -r -d '' file; do
      printf '%s\0' "$file"
      if [ -L "$file" ]; then readlink "$file"
      elif [ -f "$file" ]; then
        stat -c '%Y:%Z:%s:%a' "$file" 2>/dev/null || stat -f '%m:%c:%z:%Lp' "$file" || return 1
        cksum < "$file" || return 1
      elif [ -d "$file" ]; then git -C "$file" rev-parse HEAD || return 1
      else printf 'missing\n'; fi
    done < <(git ls-files -c -o --exclude-standard -z)
    else printf 'worktree missing\n'; fi
    [ ! -f "$state/events.log" ] || cksum < "$state/events.log"
    [ ! -f "$state/agent.jsonl" ] || cksum < "$state/agent.jsonl"
    cksum < "$state/meta"
    metrics_records "$state/metrics"
  } | cksum
)
metrics_sample_issue() (
  local meta=$1 events=${2:-[]} state dir wt status at fingerprint old snapshot records merged pr reply head
  state=$(dirname "$meta"); dir="$state/metrics"
  mkdir -p "$dir" || return 1
  owned_lock "$dir/.sample-lock" "$$" || return 1
  trap 'owned_unlock "$dir/.sample-lock" "$$"' EXIT
  wt=$(jq -er .worktree "$meta") || return 1
  status=$(jq -r .status "$meta"); at=$(now)
  if jq -e '.cleaned_at!=null' "$meta" >/dev/null; then status=cleaned; fi
  records=$(metrics_records "$dir" | jq -s .) || return 1
  # Also observe merges performed outside dv land, using the server timestamp.
  if [ -f "$state/pr.json" ] && [ "$status" != landed ] && [ "$status" != cancelled ] && [ "$status" != cleaned ] &&
    ! printf '%s\n' "$records" | jq -e 'any(.[]; .kind=="merged")' >/dev/null; then
    pr=$(jq -er .url "$state/pr.json") || return 1
    if reply=$(cd "$(jq -r .repo "$meta")" && gh pr view "$pr" --json state,headRefOid,mergedAt 2>/dev/null) &&
      merged=$(printf '%s\n' "$reply" | jq -er 'select(.state=="MERGED") | .mergedAt | fromdateiso8601' 2>/dev/null); then
      head=$(printf '%s\n' "$reply" | jq -er .headRefOid) || return 1
      S=$state ISSUE=$(jq -r .issue "$meta") metrics_note merged "$head" "$merged"
      records=$(metrics_records "$dir" | jq -s .)
    fi
  fi
  merged=$(printf '%s\n' "$records" | jq '[.[]|select(.kind=="merged")|.at]|max // empty')
  if [ -n "$merged" ]; then status=landed; at=$merged; fi
  old='null'; [ ! -f "$dir/activity.json" ] || old=$(cat "$dir/activity.json")
  case "$status" in
    landed|cancelled|cleaned)
      fingerprint=$(printf '%s\n' "$old" | jq -r '.fingerprint // ""') ;;
    *)
      # A missing worktree can still be a stalled job. Read errors remain
      # unknown rather than producing a false observation.
      fingerprint=$(metrics_fingerprint "$wt" "$state") || return 1 ;;
  esac
  snapshot=$(jq -cn --argjson meta "$(cat "$meta")" --argjson old "$old" --argjson at "$at" \
    --arg fingerprint "$fingerprint" --arg status "$status" --argjson records "$records" --argjson events "$events" '
    ($status=="landed" or $status=="cancelled" or $status=="cleaned") as $terminal |
    (if $old.started==$meta.started then $old else null end) as $previous |
    (if $previous==null then $at else [$previous.observed_at,$at]|max end) as $end |
    ([$events[] | select(.host==$meta.host and .issue==$meta.issue)]|max_by(.time)) as $event |
    (if $event==null or ($event.time < ($previous.queue_event.time // 0)) then $previous.queue_event else $event end) as $queue_event |
    ($previous!=null and $previous.fingerprint==$fingerprint and $previous.queue_event==$queue_event) as $same |
    (if $same then $previous.idle_since else $end end) as $since |
    ($previous.idle_periods // []) as $periods |
    {host:$meta.host,issue:$meta.issue,started:$meta.started,head:($meta.head // $meta.start_head // ""),
     token:($meta.award_token // ""),status:$status,observed_at:$end,fingerprint:$fingerprint,
     queue_event:$queue_event,idle_since:$since,idle_seconds:(if $terminal then 0 else $end-$since end),
     idle_periods:(if $same and $end>$previous.observed_at and
        ($previous.status!="landed" and $previous.status!="cancelled" and $previous.status!="cleaned") then
        if ($periods|length)>0 and $periods[-1][1]==$previous.observed_at then
          $periods[0:-1]+[[$periods[-1][0],$end]]
        else $periods+[[$previous.observed_at,$end]] end
       else $periods end | if $terminal then map([.[0],([.[1],$at]|min)] | select(.[1]>.[0])) else . end),records:$records}') || return 1
  local tmp
  tmp=$(mktemp "$dir/.activity.XXXXXX") || return 1
  printf '%s\n' "$snapshot" > "$tmp" && mv "$tmp" "$dir/activity.json" || return 1
  printf '%s\n' "$snapshot"
)
cmd__metrics_sample() {
  local meta events='[]'
  if [ "$#" = 2 ] && [ "$1" = --events ]; then events=$2
  elif [ "$#" != 0 ]; then fail 'usage: dv _metrics-sample [--events JSON]'
  elif [ -f "$DV_HOME/kick.q" ]; then events=$(metrics_queue_events); fi
  {
    for meta in "$DV_STATE"/*/meta; do
      [ -f "$meta" ] || continue
      metrics_sample_issue "$meta" "$events" || printf 'dv: metrics sample unavailable: %s\n' "$meta" >&2
    done
  } | jq -s .
}
metrics_queue_events() {
  # Alert delivery/handling is observation, not progress. Do not let our own
  # alerts end the episode they describe. Preserve original event timestamps.
  jq -Rsc '[split("\n")[] | fromjson? | select(type=="object" and .kind!="idle" and (.time|type)=="number")|{host,issue,id,time}] |
    group_by([.host,.issue]) | map(max_by(.time))' "$DV_HOME/kick.q"
}
metrics_collector_alive() {
  metrics_pid=$(cat "$DV_HOME/metrics.pid" 2>/dev/null) || return 1
  [[ "$metrics_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$metrics_pid" 2>/dev/null &&
    ps -o args= -p "$metrics_pid" 2>/dev/null | grep -q '[ /]dv _metrics-collect'
}
metrics_start() {
  # A collector may survive a killed watcher. Reuse that live handle instead
  # of creating another sampler on restart or on the next sampling interval.
  if metrics_collector_alive; then return 0; fi
  [ -z "${metrics_pid:-}" ] || wait "$metrics_pid" 2>/dev/null || true
  "$DV_ROOT/bin/dv" _metrics-collect >> "$DV_HOME/metrics.log" 2>&1 &
  metrics_pid=$!; printf '%s\n' "$metrics_pid" > "$DV_HOME/metrics.pid"
}
metrics_stop() {
  # Only the recorded collector and its descendants belong to this lifecycle.
  # Cancel SSH, timeout helpers and local scans without waiting for host timeouts.
  if metrics_collector_alive; then
    bid_stop_tree "$metrics_pid"
    wait "$metrics_pid" 2>/dev/null || true
  fi
  rm -f "$DV_HOME/metrics.pid"
}
cmd__metrics_collect() {
  [ "$#" = 0 ] || fail 'usage: dv _metrics-collect'
  owned_lock "$DV_HOME/.metrics-collect" "$$" || return 1
  trap 'owned_unlock "$DV_HOME/.metrics-collect" "$$"' EXIT
  metrics_collect
}
metrics_collect() {
  local host rows row dir tmp issue idle id head token events
  events=$(metrics_queue_events) || return 1
  for host in $DV_HOSTS; do
    if [ "$host" = "$DV_HOST" ]; then
      rows=$(bid_limit "$DV_BID_TIMEOUT" "$DV_ROOT/bin/dv" _metrics-sample --events "$events") || continue
    else
      rows=$(bid_limit "$DV_BID_TIMEOUT" ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$host" "$(shell_join dv _metrics-sample --events "$events")") || continue
    fi
    printf '%s\n' "$rows" | jq -e 'type=="array"' >/dev/null 2>&1 || continue
    while IFS= read -r row; do
      issue=$(printf '%s\n' "$row" | jq -r .issue)
      dir=$(metrics_job_dir "$(printf '%s\n' "$row" | jq -r .host)" "$issue")
      mkdir -p "$dir"
      # Persist host observations atomically; offline hosts retain their last
      # observation, whose timestamp remains visible in metrics --json.
      tmp=$(mktemp "$dir/.snapshot.XXXXXX") || continue
      printf '%s\n' "$row" > "$tmp"; mv "$tmp" "$dir/snapshot.json"
      idle=$(printf '%s\n' "$row" | jq -r .idle_seconds)
      [ "$idle" -gt "$DV_STALL_AFTER" ] || continue
      id=$(printf '%s\n' "$row" | jq -r '[.host,.issue,"idle",(.started|tostring),(.idle_since|tostring)]|join(":")')
      # Generated alerts do not reset activity. Replays/restarts retain one ID
      # per episode, even after the corresponding worker has finished.
      if jq -se --arg id "$id" 'any(.[]; .id==$id)' "$DV_HOME/kick.q" >/dev/null 2>&1; then continue; fi
      head=$(printf '%s\n' "$row" | jq -r .head); token=$(printf '%s\n' "$row" | jq -r .token)
      "$DV_ROOT/bin/dv-kick" idle "$issue" "No file or event change for ${idle}s" \
        "$(printf '%s\n' "$row" | jq -r .host)" "$head" "$id" "$token"
    done < <(printf '%s\n' "$rows" | jq -c '.[] | select(
      (.host|type)=="string" and (.issue|type)=="string" and
      (.observed_at|type)=="number" and (.idle_seconds|type)=="number" and (.records|type)=="array")')
  done
}
metrics_inputs() {
  local meta dir snapshot records
  for meta in "$DV_STATE"/*/meta; do
    [ -f "$meta" ] || continue
    dir="$(dirname "$meta")/metrics"
    snapshot=null; [ ! -f "$dir/activity.json" ] || snapshot=$(cat "$dir/activity.json")
    records=$(metrics_records "$dir" | jq -s .)
    jq -c --argjson snapshot "$snapshot" --argjson records "$records" \
      '{host,issue,snapshot:$snapshot,records:$records}' "$meta"
  done
  for dir in "$DV_HOME"/metrics/*; do
    [ -d "$dir" ] || continue
    snapshot=null; [ ! -f "$dir/snapshot.json" ] || snapshot=$(cat "$dir/snapshot.json")
    records=$(metrics_records "$dir" | jq -s .)
    jq -cn --argjson snapshot "$snapshot" --argjson records "$records" '
      ($records+($snapshot.records // [])) as $all |
      {host:($snapshot.host // $all[0].host),issue:($snapshot.issue // $all[0].issue),snapshot:$snapshot,records:$all}'
  done
}
cmd_metrics() {
  local since=0 json=0 duration amount factor
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --since)
        [ "$#" -ge 2 ] || fail 'usage: dv metrics [--since 6h] [--json]'
        duration=$2; shift 2
        [[ "$duration" =~ ^([1-9][0-9]{0,8})([smhd])$ ]] || fail '--since requires a positive duration such as 30m, 6h or 7d'
        amount=${BASH_REMATCH[1]}
        case "${BASH_REMATCH[2]}" in s) factor=1 ;; m) factor=60 ;; h) factor=3600 ;; d) factor=86400 ;; esac
        since=$(( $(now) - amount * factor )); [ "$since" -ge 0 ] || since=0 ;;
      *) fail 'usage: dv metrics [--since 6h] [--json]' ;;
    esac
  done
  metrics_inputs | jq -s --argjson since "$since" '
    group_by([.host,.issue]) | map(
      . as $inputs | ([.[].records[]] | unique_by(.id)) as $all |
      ([$inputs[].snapshot | select(.!=null)] | max_by(.observed_at)) as $sample |
      ([$all[] | select(.at >= $since)]) as $recent |
      ([$recent[]|select(.kind=="handled")]) as $handled |
      ([$recent[]|select(.kind=="merged")]|max_by(.at)) as $merged |
      ([$all[]|select(.kind=="done" and .head==$merged.head and .at<=$merged.at)]|max_by(.at)) as $done |
      select($since==0 or ($recent|length)>0 or ($sample.observed_at // 0)>=$since) |
      {host:.[0].host,issue:.[0].issue,observed_at:$sample.observed_at,
       idle_minutes:(if $sample==null then null else
         ([$sample.idle_periods[] | ([.[1]-([.[0],$since]|max),0]|max)]|add // 0)/60 end),
       current_idle_seconds:$sample.idle_seconds,handled_count:($handled|length),
       event_to_handled_seconds:(if ($handled|length)==0 then null else ([$handled[].latency]|add)/($handled|length) end),
       event_to_handled_max_seconds:([$handled[].latency]|max),
       done_to_merged_seconds:(if $done!=null and $merged!=null then $merged.at-$done.at else null end),
       revive_count:([$recent[]|select(.kind=="revive")]|length),
       agent_resume_count:([$recent[]|select(.kind=="resume")]|length),
       manager_resume_count:([$recent[]|select(.kind=="manager_resume")]|length)} |
       .resume_count=(.agent_resume_count+.manager_resume_count)) | sort_by(.host,.issue)
  ' | if [ "$json" = 1 ]; then cat
  else
    printf 'HOST\tISSUE\tIDLE_MIN\tEVENT_HANDLED_S\tDONE_MERGED_S\tREVIVE\tRESUME\n'
    jq -r '.[] | [.host,.issue,(.idle_minutes // "-"),(.event_to_handled_seconds // "-"),
      (.done_to_merged_seconds // "-"),.revive_count,.resume_count] | @tsv'
  fi
}
