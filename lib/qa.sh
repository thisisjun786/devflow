#!/usr/bin/env bash
# Merge discovery on the scheduler and isolated QA runners awarded to hosts.
# Job metadata globals are deliberately scoped to each runner/CLI subshell.
# shellcheck disable=SC2016,SC2030,SC2031
qa_alive() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] && kill -0 "$1" 2>/dev/null &&
    [ "$(ps -p "$1" -o stat= 2>/dev/null | cut -c 1)" != Z ]
}
# A QA job owns a slot only while its runner or agent child lives. A reboot can
# leave status=running without agent.exit; the scratch checkout stays for
# inspection and dv clean releases it.
qa_job_alive() {
  local dir=$1 issue runner wrapper child
  issue=${dir##*/}
  wrapper=$(cat "$dir/agent.pid" 2>/dev/null) || wrapper=''
  runner=$(cat "$DV_STATE/.qa/$issue/runner.pid" 2>/dev/null) || runner=''
  child=$(cat "$DV_STATE/.qa/$issue/child.pid" 2>/dev/null) || child=''
  qa_alive "$wrapper" || qa_alive "$runner" || qa_alive "$child"
}
qa_job_id() {
  local repository=$1 head=$2 slug key
  slug=$(printf '%s' "$repository" | tr -c 'A-Za-z0-9_-' '-')
  key=$(printf '%s' "$repository" | cksum | awk '{print $1}')
  printf 'QA-%s-%s-%s\n' "$slug" "$key" "${head:0:12}"
}
# Discovery runs only on the scheduler. A landed event merely asks it to poll
# operator-enabled repositories; event fields never authorize a repository.
qa_enabled_repos() {
  local meta repo identity settings base remote
  for meta in "$DV_HOME"/managers/*/meta.json; do
    [ -f "$meta" ] || continue
    jq -e '.enabled==true' "$meta" >/dev/null || continue
    repo=$(jq -er .repo "$meta") || continue
    identity=$(manager_identity "$repo") || continue
    case "$identity" in github.com/*/*) ;; *) continue ;; esac
    jq -e --arg identity "$identity" '.identity==$identity' "$meta" >/dev/null || continue
    settings=$(qa_settings "$repo") || continue
    jq -e .enabled <<< "$settings" >/dev/null || continue
    base=$(jq -r .base <<< "$settings")
    if [ -z "$base" ]; then base=$(jq -r '.base // empty' "$meta"); fi
    if [ -z "$base" ] && [ "${1:-}" != events ]; then
      base=$(bid_limit "$DV_BID_TIMEOUT" git -C "$repo" ls-remote --symref origin HEAD |
        sed -n 's@^ref: refs/heads/\([^[:space:]]*\).*@\1@p') || continue
    fi
    if [ -n "$base" ] || [ "${1:-}" != events ]; then
      git check-ref-format "refs/heads/$base" >/dev/null || continue
    fi
    remote=$(git -C "$repo" config --get remote.origin.url) || continue
    jq -cn --arg repo "$repo" --arg repository "${identity#github.com/}" --arg base "$base" \
      --arg remote "$remote" --argjson settings "$settings" \
      '{repo:$repo,repository:$repository,base:$base,remote:$remote,agent:$settings.agent}'
  done
}
# GitHub is another input to the existing watcher loop, not a separate check
# timer. Authenticated conditional requests avoid re-reading unchanged feeds.
qa_github_events() {
  local record
  [ "$DV_HOST" = "$DV_MANAGER_HOST" ] || return 0
  while IFS= read -r record; do
    if ! qa_github_events_repo "$record"; then
      printf 'QA event input unavailable; retaining cursor: %s\n' "$(jq -r .repository <<< "$record")" >&2
    fi
  done < <(qa_enabled_repos events)
}
qa_github_events_repo() (
  local record=$1 repository base key dir response body code etag='' previous='' newest eligible tmp rc=0
  local headers=()
  repository=$(jq -r .repository <<< "$record"); base=$(jq -r .base <<< "$record")
  key=$(printf '%s' "$repository" | cksum | awk '{print $1 "-" $2}')
  dir="$DV_HOME/qa-events/$key"
  mkdir -p "$dir" || return 1
  if [ -f "$dir/cursor.json" ]; then
    jq -e --arg repository "$repository" '.repository==$repository' "$dir/cursor.json" >/dev/null || return 1
    etag=$(jq -r '.etag // empty' "$dir/cursor.json")
    previous=$(jq -r '.id // empty' "$dir/cursor.json")
  fi
  [ -z "$etag" ] || headers=(-H "If-None-Match: $etag")
  response=$(mktemp "$dir/.response.XXXXXX") || return 1
  body=$(mktemp "$dir/.body.XXXXXX") || { rm "$response"; return 1; }
  trap 'rm "$response" "$body"' EXIT
  bid_limit "$DV_BID_TIMEOUT" gh api --include "repos/$repository/events?per_page=100" \
    ${headers[@]+"${headers[@]}"} > "$response" || rc=$?
  code=$(awk '/^HTTP\// {code=$2} END {print code}' "$response")
  [ "$code" != 304 ] || return 0
  [ "$rc" = 0 ] && [ "$code" = 200 ] || return 1
  # gh --include puts one response header block before the JSON body.
  awk 'body {print; next} /^\r?$/ {body=1}' "$response" > "$body"
  jq -e 'type=="array" and all(.[]; (.id|type)=="string")' "$body" >/dev/null || return 1
  etag=$(awk 'tolower($1)=="etag:" {sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit}' "$response")
  newest=$(jq -r 'first.id // empty' "$body")
  eligible=$(jq -r --arg previous "$previous" --arg base "$base" '
    (map(.id)|index($previous)) as $index | (if $index==null then . else .[:$index] end) |
    map(select((.type=="PullRequestEvent" and .payload.action=="closed" and .payload.pull_request.merged==true and
      ($base=="" or .payload.pull_request.base.ref==$base)) or
      (.type=="PushEvent" and ($base=="" or .payload.ref==("refs/heads/"+$base))) or
      (.type=="IssuesEvent" and (.payload.action=="opened" or .payload.action=="closed")))) | first.id // empty' "$body") || return 1
  if [ -n "$eligible" ]; then
    # Only a repository already enabled by the operator reaches this point.
    # Public event content never supplies commands, paths or QA authorization.
    "$DV_ROOT/bin/dv-kick" qa-repository "QA-EVENTS-$key" 'GitHub repository event; verify merged base' \
      "$DV_HOST" '' "github:$repository:$eligible" || return 1
  fi
  # The queue write comes first: a crash replays a stable event ID, so the
  # watcher's existing deduplication preserves at-least-once delivery.
  tmp=$(mktemp "$dir/.cursor.XXXXXX") || return 1
  jq -n --arg repository "$repository" --arg id "$newest" --arg etag "$etag" \
    '{repository:$repository,id:$id,etag:$etag}' > "$tmp" || return 1
  mv "$tmp" "$dir/cursor.json"
)
qa_scan() {
  local record
  [ "$DV_HOST" = "$DV_MANAGER_HOST" ] || return 0
  while IFS= read -r record; do
    if ! qa_poll_repo "$(jq -r .repo <<< "$record")" "$(jq -r .repository <<< "$record")" \
      "$(jq -r .base <<< "$record")" "$(jq -r .agent <<< "$record")" "$(jq -r .remote <<< "$record")"; then
      printf 'QA merge scan failed; will retry: %s\n' "$(jq -r .repository <<< "$record")" >&2
    fi
  done < <(qa_enabled_repos)
}
qa_enqueue() { qa_scan; }
qa_dir() {
  local identity=$1 base=$2
  printf '%s/qa/%s\n' "$DV_HOME" "$(printf '%s\n%s' "$identity" "$base" | cksum | awk '{print $1 "-" $2}')"
}
qa_poll_repo() (
  local repo=$1 repository=$2 base=$3 agent=$4 remote=$5 dir encoded head page rows merges='[]'
  local cursor='{"merged_at":"","numbers":[]}' since result pr sha comparison tmp request old='{}' time
  dir=$(qa_dir "$repository" "$base")
  if [ -f "$dir/identity.json" ]; then
    jq -e --arg repository "$repository" --arg base "$base" \
      '.repository==$repository and .base==$base' "$dir/identity.json" >/dev/null || return 1
  fi
  encoded=$(jq -rn --arg base "$base" '$base|@uri')
  head=$(bid_limit "$DV_BID_TIMEOUT" gh api "repos/$repository/commits/$encoded" --jq .sha) || return 1
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
  if [ -f "$dir/observed.json" ]; then cursor=$(cat "$dir/observed.json"); fi
  since=$(jq -r .merged_at <<< "$cursor")
  # First startup also honors QA completed by the pre-polling runner. Its
  # merged PR supplies the timestamp, independently of local wall clocks.
  if [ ! -f "$dir/observed.json" ]; then
    for result in "$DV_STATE"/QA-*/meta; do
      [ -f "$result" ] || continue
      if jq -e --arg repository "$repository" --arg base "$base" \
        '.repository==$repository and .base==$base and .done_at!=null' "$result" >/dev/null; then
        pr=$(qa_merged_pr "$repository" "$(jq -r .head "$result")" "$base") || return 1
        cursor=$(jq -cn --argjson cursor "$cursor" --argjson pr "$pr" \
          'if $pr.merged_at>$cursor.merged_at then {merged_at:$pr.merged_at,numbers:[$pr.number]}
           elif $pr.merged_at==$cursor.merged_at then $cursor | .numbers+=[$pr.number] else $cursor end')
      fi
    done
    since=$(jq -r .merged_at <<< "$cursor")
  fi
  # Closed PRs are sorted by update time, so stop only after crossing the
  # durable merge watermark. Late comments on old PRs cannot hide new merges.
  page=1
  while :; do
    rows=$(bid_limit "$DV_BID_TIMEOUT" gh api "repos/$repository/pulls?state=closed&base=$encoded&sort=updated&direction=desc&per_page=100&page=$page") || return 1
    jq -e 'type=="array"' <<< "$rows" >/dev/null || return 1
    result=$(jq -c --arg base "$base" --argjson cursor "$cursor" '[.[] |
      select(.merged_at!=null and .base.ref==$base and
        (.merged_at>$cursor.merged_at or (.merged_at==$cursor.merged_at and
          (.number as $n | $cursor.numbers|index($n)|not)))) |
      {number,title,merged_at,merge_commit_sha,base:{ref:.base.ref},milestone:(if .milestone==null then null else (.milestone|{number,title}) end)}]' <<< "$rows") || return 1
    merges=$(jq -cn --argjson old "$merges" --argjson new "$result" '$old+$new|unique_by(.number)|sort_by(.merged_at,.number)')
    [ "$(jq length <<< "$rows")" = 100 ] || break
    if [ -n "$since" ] && jq -e --arg since "$since" 'last.updated_at < $since' <<< "$rows" >/dev/null; then break; fi
    page=$((page + 1))
  done
  if [ "$merges" = '[]' ]; then
    if [ ! -f "$dir/observed.json" ]; then
      mkdir -p "$dir"
      tmp=$(mktemp "$dir/.observed.XXXXXX") || return 1
      printf '%s\n' "$cursor" > "$tmp"; mv "$tmp" "$dir/observed.json"
    fi
    return 0
  fi
  # Verify every merge is in the configured base snapshot, even if a branch
  # was reset or a PR payload names a different base. Failed reads retry later.
  while IFS= read -r pr; do
    sha=$(jq -r .merge_commit_sha <<< "$pr")
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
    comparison=$(bid_limit "$DV_BID_TIMEOUT" gh api "repos/$repository/compare/$sha...$head") || return 1
    jq -e '.status=="ahead" or .status=="identical"' <<< "$comparison" >/dev/null || return 1
  done < <(jq -c '.[]' <<< "$merges")
  mkdir -p "$dir" || return 1
  if [ ! -f "$dir/identity.json" ]; then
    tmp=$(mktemp "$dir/.identity.XXXXXX") || return 1
    jq -n --arg repository "$repository" --arg base "$base" '{repository:$repository,base:$base}' > "$tmp" || return 1
    mv "$tmp" "$dir/identity.json" || return 1
  fi
  [ ! -f "$dir/pending.json" ] || old=$(cat "$dir/pending.json")
  time=$(now)
  request=$(jq -cn --arg repository "$repository" --arg repo "$repo" --arg remote "$remote" --arg base "$base" \
    --arg head "$head" --arg agent "$agent" --argjson prs "$merges" --argjson old "$old" \
    --argjson time "$time" --argjson delay "$DV_QA_COALESCE" \
    '{repository:$repository,repo:$repo,remote:$remote,base:$base,head:$head,agent:$agent,
      prs:(($old.prs // [])+$prs|unique_by(.number)|sort_by(.merged_at,.number)),due_at:($time+$delay)}')
  tmp=$(mktemp "$dir/.pending.XXXXXX") || return 1
  printf '%s\n' "$request" > "$tmp" && mv "$tmp" "$dir/pending.json" || return 1
  # Persist the pending request before acknowledging observations. A crash
  # between these writes replays into the same union instead of losing merges.
  tmp=$(mktemp "$dir/.observed.XXXXXX") || return 1
  jq -n --argjson cursor "$cursor" --argjson prs "$merges" \
    '($prs|last.merged_at) as $time | {merged_at:$time,
     numbers:((if $time==$cursor.merged_at then $cursor.numbers else [] end)+
       [$prs[]|select(.merged_at==$time)|.number]|unique)}' > "$tmp"
  mv "$tmp" "$dir/observed.json" || return 1
)
qa_recover() {
  # Legacy local runners remain reserved until exit during upgrades. Awarded
  # QA is accounted for by bid_active on its host, just like development jobs.
  local marker dir runner child
  for marker in "$DV_HOME"/qa/*/pid; do
    [ -f "$marker" ] || continue
    dir=$(dirname "$marker")
    runner=$(cat "$dir/runner.pid" 2>/dev/null) || runner=$(cat "$marker")
    child=$(cat "$dir/child.pid" 2>/dev/null || true)
    if qa_alive "$runner" || qa_alive "$child"; then
      case " ${pids:-} " in *" $runner "*) ;; *) active=$((${active:-0} + 1)) ;; esac
    fi
  done
}
qa_request_enabled() {
  local request=$1 meta repo settings base repository
  repository=$(jq -r .repository "$request")
  for meta in "$DV_HOME"/managers/*/meta.json; do
    [ -f "$meta" ] || continue
    jq -e --arg identity "github.com/$repository" '.enabled==true and .identity==$identity' "$meta" >/dev/null || continue
    repo=$(jq -r .repo "$meta")
    [ "$(manager_identity "$repo")" = "github.com/$repository" ] || continue
    settings=$(qa_settings "$repo") || continue
    jq -e .enabled <<< "$settings" >/dev/null || continue
    base=$(jq -r .base <<< "$settings")
    [ -n "$base" ] || base=$(jq -r '.base // empty' "$meta")
    # An implicit base is the remote default observed by the last event/sweep;
    # dispatch must not add a network poll to every local debounce tick.
    [ -z "$base" ] || [ "$base" = "$(jq -r .base "$request")" ] || continue
    return 0
  done
  return 1
}
qa_dispatch() {
  local request dir job task payload tmp pid child receipt
  [ "$DV_HOST" = "$DV_MANAGER_HOST" ] || return 0
  for request in "$DV_HOME"/qa/*/pending.json; do
    [ -f "$request" ] || continue
    dir=$(dirname "$request")
    [ "$(now)" -ge "$(jq -r '.due_at // 0' "$request")" ] || continue
    qa_request_enabled "$request" || continue
    if [ -f "$dir/running.json" ]; then
      job=$(jq -r '.issue // empty' "$dir/running.json")
      task="$DV_HOME/submissions/$job/task.json"
      if [ -n "$job" ] && [ -f "$task" ] && jq -e '.status=="submitted" or .status=="working" or .status=="input-required"' "$task" >/dev/null; then continue; fi
      if [ -n "$job" ] && [ -f "$task" ]; then
        receipt=$(bid_limit "$DV_BID_TIMEOUT" bid_rpc "$(jq -r .host "$task")" _receipt "$job" "$(jq -r .token "$task")" </dev/null) || continue
        jq -e '.exited==true' <<< "$receipt" >/dev/null || continue
      fi
      pid=$(cat "$dir/pid" 2>/dev/null || true); child=$(cat "$dir/child.pid" 2>/dev/null || true)
      if qa_alive "$pid" || qa_alive "$child"; then continue; fi
    fi
    job=$(qa_job_id "$(jq -r .repository "$request")" "$(jq -r .head "$request")")
    task="$DV_HOME/submissions/$job/task.json"
    if [ ! -f "$task" ]; then
      payload=$(jq --arg issue "$job" --rawfile brief "$DV_ROOT/templates/qa-prompt.md" \
        '{kind:"qa",issue:$issue,repo:.remote,slug:"qa",agent:.agent,
          mode:(if .agent=="codex" then "exec" else "goal" end),base,brief:$brief,qa:.}' "$request")
      printf '%s\n' "$payload" | "$DV_ROOT/bin/dv" _submit || return 1
    fi
    "$DV_ROOT/bin/dv-kick" submitted "$job" 'Awaiting QA bids' "$DV_HOST" || return 1
    tmp=$(mktemp "$dir/.running.XXXXXX") || return 1
    jq --arg issue "$job" '.+{issue:$issue}' "$request" > "$tmp"; mv "$tmp" "$dir/running.json"
    rm "$request"
  done
}
# Called under the ordinary host admission lock after a successful fresh bid.
qa_award() {
  local request=$1 receipt_dir=$2 issue token deadline dir pid status=input-required head owner tmp
  issue=$(jq -r .issue <<< "$request"); token=$(jq -r .token <<< "$request")
  deadline=$(jq -r .deadline <<< "$request")
  dir="$DV_STATE/.qa/$issue"
  mkdir -p "$dir"
  jq --arg token "$token" '.qa+{award_token:$token,agent:.agent}' <<< "$request" > "$dir/running.json"
  owner=$(sh -c 'echo "$PPID"')
  printf '%s\n' "$owner" > "$dir/pid"
  "$DV_ROOT/bin/dv" _qa-run "$dir" </dev/null >> "$dir/log" 2>&1 & pid=$!
  printf '%s\n' "$pid" > "$dir/runner.pid"
  while [ "$(now)" -lt "$deadline" ]; do
    if [ -f "$DV_STATE/$issue/agent.started" ]; then status=working; break; fi
    if ! qa_alive "$pid"; then
      wait "$pid" 2>/dev/null || true
      # Setup failures retain their diagnostics and scratch checkout. They
      # require inspection, never an unsafe second award on another host.
      break
    fi
    sleep 0.1
  done
  head=$(jq -r .qa.head <<< "$request")
  tmp=$(mktemp "$receipt_dir/.receipt.XXXXXX") || return 1
  jq -n --arg status "$status" --arg token "$token" --arg head "$head" \
    '{status:$status,token:$token,head:$head}' > "$tmp"
  mv "$tmp" "$receipt_dir/receipt.json"
  cat "$receipt_dir/receipt.json"
}
qa_settings() (
  local line key value
  cd "$1" || exit 1
  if [ -f .devflow ]; then
    # Opt-in discovery is data, not permission to execute repository code on
    # the watcher. Read only literal QA assignments; never source .devflow.
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?(DV_QA|DV_QA_AGENT|DV_QA_BASE)= ]]; then
        key=${BASH_REMATCH[2]}
        value=$(printf '%s' "${line#*=}" | sed 's/[[:space:]]*#.*$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$value" in \"*\") value=${value#\"}; value=${value%\"} ;; \'*\') value=${value#\'}; value=${value%\'} ;; esac
        case "$key" in DV_QA) DV_QA=$value ;; DV_QA_AGENT) DV_QA_AGENT=$value ;; DV_QA_BASE) DV_QA_BASE=$value ;; esac
      fi
    done < .devflow
  fi
  case "$DV_QA" in 0|1) ;; *) fail 'DV_QA must be 0 or 1' ;; esac
  case "$DV_QA_AGENT" in codex|claude) ;; *) fail 'DV_QA_AGENT must be codex or claude' ;; esac
  jq -cn --arg enabled "$DV_QA" --arg agent "${agent:-$DV_QA_AGENT}" --arg base "$DV_QA_BASE" \
    '{enabled:($enabled=="1"),agent:$agent,base:$base}'
)
qa_merged_pr() {
  local repository=$1 head=$2 base=${3:-} result attempt reason
  # GitHub can associate the merge commit with its PR after the landed event.
  # Keep the latest-base selection for coalesced jobs, but bound the wait.
  for attempt in 1 2 3 4 5 6; do
    if ! result=$(gh api "repos/$repository/commits/$head/pulls"); then
      reason='request failed'
    elif ! result=$(jq -cs --arg base "$base" '
      if length==1 and (.[0]|type)=="array" then .[0]
      else error("expected a PR array") end |
      [.[] | select(.merged_at!=null and ($base=="" or .base.ref==$base))] |
      sort_by(.merged_at) | last' <<< "$result"); then
      reason='invalid PR response'
    elif [ "$result" != null ]; then
      printf '%s\n' "$result"; return 0
    else
      reason='no merged PR'
    fi
    printf 'QA pr lookup: %s for %s at %s (attempt %s/6)\n' "$reason" "$repository" "$head" "$attempt" >&2
    [ "$attempt" = 6 ] || sleep 5
  done
  return 1
}
qa_milestone() {
  local repository=$1 pr=$2 result
  result=$(jq -c '.milestone // empty' <<< "$pr")
  if [ -n "$result" ]; then printf '%s\n' "$result"; return; fi
  # Closing issues carry the milestone when the PR itself has none. Refuse
  # ambiguity rather than silently attributing findings to a later milestone.
  # gh 2.46 does not expose closingIssuesReferences through pr view --json.
  result=$(gh api graphql --paginate -f owner="${repository%%/*}" -f name="${repository#*/}" \
    -F number="$(jq -r .number <<< "$pr")" -f query='
      query($owner:String!, $name:String!, $number:Int!, $endCursor:String) {
        repository(owner:$owner, name:$name) {
          pullRequest(number:$number) {
            closingIssuesReferences(first:100, after:$endCursor) {
              nodes { number milestone { number title } }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
      }') || return 1
  result=$(jq -sce 'if length==0 or any(.[]; (.errors | length)>0 or
      (.data.repository.pullRequest.closingIssuesReferences.nodes | type)!="array")
    then error("QA milestone: invalid closing issues response")
    else [.[].data.repository.pullRequest.closingIssuesReferences.nodes[].milestone // empty] | unique_by(.number) end' <<< "$result") || return 1
  case "$(jq length <<< "$result")" in
    0) printf 'null\n' ;;
    1) jq -c '.[0]' <<< "$result" ;;
    *) fail 'QA milestone: multiple distinct milestones on closing issues' ;;
  esac
}
qa_run_cleanup() {
  local rc=$? reason
  trap - EXIT INT TERM
  if [ -n "${qa_child:-}" ]; then bid_stop_tree "$qa_child"; wait "$qa_child" 2>/dev/null || true; fi
  reason=${qa_failure_reason:-"QA failed at $qa_step (exit $rc); inspect log before retrying"}
  if [ "$rc" != 0 ]; then
    printf '%s\n' "$reason" >&2
    if [ -z "${S:-}" ] || [ ! -f "$S/meta" ]; then
      jq -n --arg reason "$reason" '{status:"blocked",failure_reason:$reason}' > "$qa_dir/meta"
    fi
  fi
  if [ -n "${S:-}" ] && [ -f "$S/meta" ]; then
    printf '%s\n' "$rc" > "$S/agent.exit"
    if [ "$rc" != 0 ]; then
      meta_set --arg reason "$reason" '.status="blocked" | .failure_reason=$reason'
      [ -n "${qa_failure_reason:-}" ] || cmd_kick blocked "$ISSUE" "$reason"
    fi
  fi
  printf '%s\n' "$rc" > "$qa_dir/exit"
  rm -f "$qa_dir/child.pid"
  # Retain the reservation until the process really exits. The watcher checks
  # liveness, so a restart cannot overlap a finishing child.
  exit "$rc"
}
qa_reserve_job() {
  ISSUE=$(qa_job_id "$repository" "$head"); valid_issue "$ISSUE"
  S="$DV_STATE/$ISSUE"
  if [ -e "$S" ]; then
    printf 'QA head already reserved: %s\n' "$ISSUE"
    # No agent has touched this newly allocated scratch directory.
    rm -r "$scratch"; S=''; exit 0
  fi
  mkdir -p "$DV_STATE"
  mkdir "$S"
  WT="$scratch/source"
  jq -n --arg issue "$ISSUE" --arg repo "https://github.com/$repository.git" --arg repository "$repository" \
    --arg wt "$WT" --arg base "$base" --arg head "$head" --arg host "$DV_HOST" --arg agent "${agent:-$DV_QA_AGENT}" \
    --arg scratch "$scratch" --argjson started "$(now)" --slurpfile request "$qa_dir/running.json" \
    '{issue:$issue,kind:"qa",repo:$repo,repository:$repository,worktree:$wt,branch:$issue,base:$base,
      head:$head,start_head:$head,host:$host,agent:($request[0].agent // $agent),backend:"qa",status:"running",
      started:$started,scratch:$scratch,award_token:($request[0].award_token // ""),prs:($request[0].prs // [])}' > "$S/meta"
  printf '%s\n' "$$" > "$S/agent.pid"
}
cmd__qa_run() (
  [ "$#" = 1 ] || fail 'usage: dv _qa-run <qa-directory>'
  local qa_dir=$1 qa_child='' scratch repository remote base head settings agent pr milestone prompt
  local S='' ISSUE='' WT='' qa_step='request'
  local qa_failure_reason='' rc session='' new_session instruction attempt=0 output
  local args=()
  case "$(dirname "$qa_dir")" in
    "$DV_HOME/qa"|"$DV_STATE/.qa") ;;
    *) fail 'invalid QA directory' ;;
  esac
  [ "$(cat "$qa_dir/pid")" = "$PPID" ] || fail 'QA runner has no parent reservation'
  (set -C; printf '%s\n' "$$" > "$qa_dir/claim") 2>/dev/null || fail 'QA reservation already claimed'
  printf '%s\n' "$$" > "$qa_dir/pid"
  trap qa_run_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  repository=$(jq -er .repository "$qa_dir/running.json")
  remote=$(jq -er .remote "$qa_dir/running.json")
  base=$(jq -r .base "$qa_dir/running.json")
  if [ -z "$base" ]; then
    # A remote job may target dev while origin/HEAD names a release branch.
    head=$(jq -er .event.head "$qa_dir/running.json")
    qa_step='pr lookup'
    pr=$(qa_merged_pr "$repository" "$head")
    base=$(jq -er '.base.ref // empty' <<< "$pr")
  fi
  qa_step='checkout'
  tmp_make scratch dv-qa
  printf '%s\n' "$scratch" > "$qa_dir/scratch"
  head=$(jq -r '.head // empty' "$qa_dir/running.json")
  [ -z "$head" ] || qa_reserve_job
  git clone --quiet --no-hardlinks --no-checkout "$remote" "$scratch/source"
  git -C "$scratch/source" checkout --quiet --detach "refs/remotes/origin/$base"
  head=$(jq -r '.head // empty' "$qa_dir/running.json")
  if [ -n "$head" ]; then
    [[ "$head" =~ ^[0-9a-f]{40}$ ]] || fail 'invalid QA head'
    git -C "$scratch/source" merge-base --is-ancestor "$head" "refs/remotes/origin/$base" || fail 'QA head is not on configured base'
    git -C "$scratch/source" checkout --quiet --detach "$head"
  else head=$(git -C "$scratch/source" rev-parse HEAD); fi
  qa_step='settings'
  settings=$(qa_settings "$scratch/source")
  agent=$(jq -r .agent <<< "$settings")
  if ! jq -e .enabled <<< "$settings" >/dev/null && [ "$(jq -r '.award_token // ""' "$qa_dir/running.json")" = '' ]; then
    printf 'QA disabled: %s\n' "$repository"
    # This pristine clone is ours; no agent has run and no user work exists.
    rm -rf "$scratch"
    exit 0
  fi
  qa_step='job setup'
  [ -n "$S" ] || qa_reserve_job
  git -C "$WT" checkout --quiet -b "$ISSUE"
  qa_step='pr lookup'
  agent=$(jq -r .agent "$S/meta")
  pr=$(jq -c '.prs // [] | last // empty' "$qa_dir/running.json")
  if [ -z "$pr" ]; then
    pr=$(qa_merged_pr "$repository" "$head" "$base")
  fi
  meta_set --argjson pr "$pr" '.pr=$pr.number'
  qa_step='milestone'
  milestone=$(qa_milestone "$repository" "$pr")
  meta_set --argjson milestone "$milestone" '.milestone=$milestone'
  qa_step='agent setup'
  mkdir -m 700 "$scratch/home" "$scratch/state" "$scratch/out"
  prompt="$S/brief.md"
  cat "$DV_ROOT/templates/qa-prompt.md" > "$prompt"
  printf '\nJob: %s\nRepository: %s\nHead: %s\nMilestone: %s\nIsolated product home/state/output: %s/{home,state,out}\nReport: %s/report.md\n' \
    "$ISSUE" "$repository" "$head" "$(jq -r '.title // "none"' <<< "$milestone")" "$scratch" "$S" >> "$prompt"
  export DV_ISSUE="$ISSUE" DV_QA_SCRATCH="$scratch"
  jq -r ' .prs[]? | "Merged PR: #\(.number) — \(.title // "")"' "$S/meta" >> "$prompt"
  touch "$S/agent.started"
  instruction=$(cat "$prompt")
  while :; do
  attempt=$((attempt + 1)); output="$S/agent-$attempt.log"
  export DV_AGENT_INSTRUCTION="$instruction"
  if [ -n "$DV_QA_AGENT_CMD" ]; then
    (cd "$WT" && bash -c "$DV_QA_AGENT_CMD \"\$@\"" dv-qa "$prompt") > "$output" 2>&1 & qa_child=$!
  elif [ "$agent" = codex ]; then
    codex_environment || fail 'Codex environment unavailable'
    args=("$DV_CODEX_BIN" -m "$DV_CODEX_MODEL" -c "model_reasoning_effort=\"$DV_CODEX_EFFORT\""
      --disable hooks -c 'plugins."crw@crw".enabled=false' exec)
    if [ -n "$session" ]; then args+=(resume --json --dangerously-bypass-approvals-and-sandbox "$session")
    else args+=(--json --dangerously-bypass-approvals-and-sandbox); fi
    (cd "$WT" && "${args[@]}" "$instruction") > "$output" 2>&1 & qa_child=$!
  else
    # The QA workspace is isolated; preserve it and include the original brief
    # on continuation even when the CLI does not persist a provider session.
    (cd "$WT" && "$DV_CLAUDE_BIN" --model "$DV_CLAUDE_MODEL" --dangerously-skip-permissions \
      --no-session-persistence -p "$instruction") > "$output" 2>&1 & qa_child=$!
  fi
  printf '%s\n' "$qa_child" > "$qa_dir/child.pid"
  qa_step='agent'
  rc=0; wait "$qa_child" || rc=$?; qa_child=''
  rm -f "$qa_dir/child.pid"
  cat "$output" >> "$S/log"
  if capacity_output_error "$output" "$rc"; then
    new_session=$(jq -Rr 'fromjson? | select(.type=="thread.started") | .thread_id // empty' "$output" | tail -n 1)
    [ -z "$new_session" ] || session=$new_session
    if ! capacity_wait; then
      qa_failure_reason=$(jq -r .failure_reason "$S/meta")
      exit 1
    fi
    instruction="Continue the interrupted request in this worktree. Preserve existing changes and findings; do not start over.
$(cat "$prompt")"
    continue
  fi
  capacity_clear
  [ "$rc" = 0 ] || exit "$rc"
  break
  done
  [ -f "$S/done.json" ] || fail 'QA exited without dv done'
)
qa_load() {
  load_issue "$1"
  [ "$(jq -r '.kind // empty' "$S/meta")" = qa ] || fail 'not a QA job'
}
qa_clean() {
  # Mirror tmp_collect for one named job, including scratch from before owner
  # markers: only a stopped QA with a clean clone releases its scratch.
  local scratch owner dirty
  ! codex_exec_alive "$S" || fail 'QA is still running; scratch retained'
  scratch=$(jq -r '.scratch // empty' "$S/meta")
  if [ -z "$scratch" ] || { [ ! -e "$scratch" ] && [ ! -L "$scratch" ]; }; then return 0; fi
  case "${scratch##*/}" in dv-qa.*) ;; *) fail 'QA scratch is not a dv-qa directory; retained' ;; esac
  if [ ! -d "$scratch" ] || [ -L "$scratch" ] || [ ! -O "$scratch" ]; then
    fail 'QA scratch is not a directory owned by this user; retained'
  fi
  [ "$WT" = "$scratch/source" ] || fail 'QA worktree is outside its scratch; retained'
  owner=$(cat "$scratch/owner.pid" 2>/dev/null) || owner=''
  if [[ "$owner" =~ ^[1-9][0-9]*$ ]] && kill -0 "$owner" 2>/dev/null; then fail 'QA scratch is still in use; retained'; fi
  if [ -e "$WT" ]; then
    require_worktree
    dirty=$(git -C "$WT" status --porcelain --untracked-files=all) || fail "cannot read QA clone: $WT"
    [ -z "$dirty" ] || fail "uncommitted files: $WT"
  fi
  rm -rf -- "$scratch"
}
qa_open_issues() {
  local repository page=1 result count issues='[]'
  repository=$(jq -r .repository "$S/meta") || return 1
  # Fetch numbered pages ourselves: gh --paginate can silently stop after a
  # full page. Count PRs too, and check one more page when the last is full.
  while :; do
    result=$(gh api "repos/$repository/issues?state=open&per_page=100&page=$page") || return 1
    result=$(jq -sce 'if length==1 and (.[0]|type)=="array" then .[0]
      else error("QA issues: expected one array per page") end' <<< "$result") || return 1
    count=$(jq length <<< "$result") || return 1
    result=$(jq -c '[.[] | select(.pull_request==null) | {number,title}]' <<< "$result") || return 1
    issues="$issues
$result"
    [ "$count" -ge 100 ] || break
    page=$((page + 1))
  done
  # Publish the list only after every page succeeds. Keep large lists off argv.
  printf '%s\n' "$issues" | jq -sc 'add'
}
qa_finding() (
  [ "$#" = 2 ] || fail 'usage: dv qa finding ISSUE finding.json'
  qa_load "$1"; issue_lock
  local finding=$2 data title kind repository marker match issues body result milestone
  data=$(jq -ce 'select((.kind=="bug" or .kind=="feature") and
    ([.title,.steps,.expected,.actual,.evidence] | all(.[]; type=="string" and length>0)) and
    (.summary==null or (.summary|type=="string" and length>0)))' "$finding") || fail 'invalid QA finding'
  # Titles follow docs/issue-format.md; reject before any GitHub read or write.
  jq -e --arg types "$CHANGE_TYPES|research" '.title | capture("^(\($types))(\\([^()[:space:]]+\\))?: (?<phrase>.+)$") |
    .phrase | length<=72 and (test("^[[:space:]]|^[A-Z][a-z]")|not) and
      (test("#[0-9]|[0-9]{4}-[0-9]{2}-[0-9]{2}|\\bfollow[ -]?ups?\\b|\\bmisc\\b";"i")|not)' <<< "$data" >/dev/null ||
    fail "invalid QA finding title: use \"type(scope): lowercase imperative phrase\" with type one of ${CHANGE_TYPES//|/ } research, at most 72 characters after the colon, and no PR numbers, dates, \"follow up\" or \"misc\" (e.g. fix(tui): keep the progress card after restart)"
  title=$(jq -r .title <<< "$data"); kind=$(jq -r .kind <<< "$data")
  repository=$(jq -r .repository "$S/meta"); milestone=$(jq -r .milestone.number "$S/meta")
  marker="<!-- devflow-qa:$ISSUE:$(printf '%s' "$data" | cksum | awk '{print $1 "-" $2}') -->"
  if [ -f "$S/findings.jsonl" ] && jq -se --arg marker "$marker" 'any(.[]; .marker==$marker)' "$S/findings.jsonl" >/dev/null; then return; fi
  # Validate an explicit match directly; list membership is not authoritative.
  # Otherwise finish reading all open titles before any external write.
  if jq -e '.match!=null' <<< "$data" >/dev/null; then
    match=$(jq -er '.match | select(type=="number")' <<< "$data") || fail 'invalid matching issue number'
    [[ "$match" =~ ^[1-9][0-9]*$ ]] || fail 'invalid matching issue number'
    result=$(gh api "repos/$repository/issues/$match") || fail 'cannot look up matching issue'
    jq -se --argjson match "$match" 'length==1 and (.[0] | type=="object" and
      .number==$match and .state=="open" and .pull_request==null)' <<< "$result" >/dev/null ||
      fail 'matching issue must be open and not a pull request'
  else
    issues=$(qa_open_issues) || fail 'cannot list open QA issues'
    match=$(jq -r --arg title "$title" '[.[] | select(
      (.title|ascii_downcase)==($title|ascii_downcase))] | first | .number // empty' <<< "$issues") || return 1
  fi
  body=$(mktemp "$S/.finding.XXXXXX")
  jq -r --arg marker "$marker" --arg head "$(jq -r .head "$S/meta")" --arg milestone "$(jq -r '.milestone.title // "none"' "$S/meta")" '
    "## Summary\n"+(.summary // (if .kind=="bug" then "Real-use QA found that the steps below do not give the expected result."
      else "Real-use QA found that the behaviour expected below is missing." end))+
    "\n\n## Steps\n"+.steps+"\n\n## Expected\n"+.expected+"\n\n## Actual\n"+.actual+
    "\n\n## Done when\n- [ ] following the steps gives the expected result.\n- [ ] a test covers this case.\n\n"+
    "## Context\nSource: real-use QA at `"+$head+"`, milestone **"+$milestone+"**\nEvidence: "+.evidence+"\n\n"+$marker' <<< "$data" > "$body"
  # Create only missing labels; never overwrite a repository's existing label.
  gh label create qa -R "$repository" --color 7057ff --description 'Real-use QA finding' 2>/dev/null || gh label list -R "$repository" --json name --jq '.[].name' | grep -Fxq qa
  gh label create "$kind" -R "$repository" --color d73a4a --description 'QA finding type' 2>/dev/null || gh label list -R "$repository" --json name --jq '.[].name' | grep -Fxq "$kind"
  if [ -n "$match" ]; then
    local milestone_args=()
    if [ "$milestone" != null ]; then milestone_args=(--milestone "$(jq -r .milestone.title "$S/meta")"); fi
    gh issue edit "$match" -R "$repository" --add-label "qa,$kind" ${milestone_args[@]+"${milestone_args[@]}"}
    result=$(gh api --paginate "repos/$repository/issues/$match/comments?per_page=100" | jq -sc --arg marker "$marker" 'add | any(.[]; (.body // "")|contains($marker))')
    if [ "$result" != true ]; then gh issue comment "$match" -R "$repository" --body-file "$body"; fi
    result="https://github.com/$repository/issues/$match"
  else
    # API gives an unambiguous number and preserves the current milestone.
    result=$(jq -n --arg title "$title" --rawfile body "$body" --arg kind "$kind" --argjson milestone "$milestone" \
      '{title:$title,body:$body,labels:["qa",$kind]} + (if $milestone==null then {} else {milestone:$milestone} end)' |
      gh api --method POST "repos/$repository/issues" --input -)
    result=$(jq -er .html_url <<< "$result")
  fi
  jq -cn --arg marker "$marker" --arg url "$result" --arg match "$match" \
    '{marker:$marker,url:$url,action:(if $match=="" then "opened" else "commented" end)}' >> "$S/findings.jsonl"
  # Publish after GitHub and the finding receipt commit, before QA completion.
  # A matching issue's new qa label can also change scheduling priority.
  if [ -z "$match" ]; then cmd_kick issue-opened "$ISSUE" "$result"
  else cmd_kick issue-edited "$ISSUE" "$result"; fi
  rm "$body"
  printf '%s\n' "$result"
)
qa_done() (
  qa_load "$1"; issue_lock
  local repository pr marker comments body head
  [ -s "$S/report.md" ] || fail 'QA needs report.md with journeys and findings'
  head=$(jq -r .head "$S/meta")
  [ "$(git -C "$WT" rev-parse HEAD)" = "$head" ] || fail 'QA must not commit fixes'
  git -C "$WT" diff --quiet HEAD -- || fail 'QA must not change tracked product files'
  [ ! -f "$S/done.json" ] || return 0
  repository=$(jq -r .repository "$S/meta"); pr=$(jq -r .pr "$S/meta")
  marker="<!-- devflow-qa-summary:$ISSUE -->"
  body="$S/summary.md"
  { printf '%s\n\n' "$marker"; cat "$S/report.md"; printf '\nTested head: `%s`\n\n' "$head"
    jq -r --arg repository "$repository" '.prs[]? | "- Merged PR: https://github.com/\($repository)/pull/\(.number)"' "$S/meta"
    [ ! -f "$S/findings.jsonl" ] || jq -r '"- "+.action+": "+.url' "$S/findings.jsonl"
  } > "$body"
  comments=$(gh api --paginate "repos/$repository/issues/$pr/comments?per_page=100" | jq -sc --arg marker "$marker" 'add | any(.[]; (.body // "")|contains($marker))')
  if [ "$comments" != true ]; then gh pr comment "$pr" -R "$repository" --body-file "$body"; fi
  jq -n --arg head "$head" --arg report "$S/report.md" --argjson time "$(now)" '{head:$head,report:$report,done_at:$time}' > "$S/done.json"
  meta_set --argjson time "$(now)" '.status="done" | .done_at=$time'
  cmd_kick 'done' "$ISSUE" 'QA complete; findings enter the current milestone queue'
)
cmd_qa() {
  local action=${1:-}; [ "$#" = 0 ] || shift
  case "$action" in
    finding) qa_finding "$@" ;;
    status)
      local request dir pending running pid child job task
      [ "$#" = 0 ] || [ "$*" = --json ] || fail 'usage: dv qa status [--json]'
      {
        for request in "$DV_HOME"/qa/*/running.json "$DV_HOME"/qa/*/pending.json; do
          [ -f "$request" ] || continue
          dir=$(dirname "$request"); pending=false; running=false
          if [ -f "$dir/pending.json" ]; then
            [ "$request" = "$dir/pending.json" ] || continue
            pending=true
          fi
          pid=$(cat "$dir/pid" 2>/dev/null || true); child=$(cat "$dir/child.pid" 2>/dev/null || true)
          if qa_alive "$pid" || qa_alive "$child"; then running=true; fi
          job=$(jq -r '.issue // empty' "$dir/running.json" 2>/dev/null) || job=''
          task="$DV_HOME/submissions/$job/task.json"
          if [ -n "$job" ] && [ -f "$task" ]; then
            running=false
            if jq -e '.status=="submitted" or .status=="working" or .status=="input-required"' "$task" >/dev/null; then running=true; fi
          fi
          jq --argjson pending "$pending" --argjson running "$running" '{repository,base,pending:$pending,running:$running}' "$request"
        done
      } | jq -s . ;;
    search)
      [ "$#" = 2 ] || fail 'usage: dv qa search ISSUE keywords'
      qa_load "$1"
      gh issue list -R "$(jq -r .repository "$S/meta")" --state open --search "$2" --limit 100 --json number,title,url,milestone,labels ;;
    *) fail 'usage: dv qa status|search|finding' ;;
  esac
}
