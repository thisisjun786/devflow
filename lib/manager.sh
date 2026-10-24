#!/usr/bin/env bash
# jq filters and child-shell snippets use literal dollars.
# shellcheck disable=SC2016
manager_identity() {
  local repo=$1 origin
  if [ -d "$repo" ]; then
    repo=$(cd "$repo" && git rev-parse --show-toplevel) || return 1
    origin=$(git -C "$repo" config --get remote.origin.url 2>/dev/null || true)
    [ -z "$origin" ] || repo=$origin
  fi
  repo=${repo%/}; repo=${repo%.git}
  case "$repo" in
    https://github.com/*) repo="github.com/${repo#https://github.com/}" ;;
    http://github.com/*) repo="github.com/${repo#http://github.com/}" ;;
    git@github.com:*) repo="github.com/${repo#git@github.com:}" ;;
    ssh://git@github.com/*) repo="github.com/${repo#ssh://git@github.com/}" ;;
  esac
  case "$repo" in github.com/*) repo=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]') ;; esac
  printf '%s\n' "$repo"
}
manager_dir() {
  local key dir
  key=$(manager_identity "$1") || return 1
  dir="$DV_HOME/managers/$(printf '%s' "$key" | cksum | awk '{print $1 "-" $2}')"
  # Refuse a checksum collision instead of selecting another repo's session.
  if [ -f "$dir/meta.json" ]; then
    jq -e --arg key "$key" '.identity==$key' "$dir/meta.json" >/dev/null || return 1
  fi
  printf '%s\n' "$dir"
}
manager_set() {
  local dir=$1 tmp; shift
  tmp=$(mktemp "$dir/.meta.XXXXXX") || return 1
  if jq "$@" "$dir/meta.json" > "$tmp"; then mv "$tmp" "$dir/meta.json"
  else rm -f "$tmp"; return 1; fi
}
manager_lock() {
  local dir=$1
  mkdir -p "$dir/run.lock" || return 1
  # Bash noclobber uses exclusive file creation. Keep the parent directory:
  # removing it on release races the next acquirer creating its owner file.
  # Dispatch checks the recorded owner before recovering a stale reservation.
  # A runner can outlive its watcher, so the watcher's PID is not sufficient.
  (set -C; printf '%s\n' "$$" > "$dir/run.lock/pid") 2>/dev/null || return 1
  now > "$dir/run.lock/started"
}
manager_unlock() {
  local dir=$1 owner=${2:-$$}
  [ "$(cat "$dir/run.lock/pid" 2>/dev/null)" = "$owner" ] || return 0
  rm -f "$dir/run.lock/job" "$dir/run.lock/claim" "$dir/run.lock/started" \
    "$dir/run.lock/batch.json" "$dir/run.lock/notices.json"
  rm -f "$dir/run.lock/pid"
}
manager_log() {
  local dir=$1 kind=$2 old=$3 new=$4 rc=$5
  jq -cn --arg kind "$kind" --arg old "$old" --arg new "$new" --argjson rc "$rc" --argjson time "$(now)" \
    '{kind:$kind,previous_session:$old,session_id:$new,exit_code:$rc,time:$time}' >> "$dir/events.log"
}
manager_prompt() {
  local dir=$1
  cat "$DV_ROOT/templates/manager-prompt.md"
  printf '\n관리 저장소: %s\n저장소 식별자: %s\n관리 호스트(DV_HOST): %s\n\n' \
    "$(jq -r .repo "$dir/meta.json")" "$(jq -r .identity "$dir/meta.json")" "$DV_HOST"
  # The manager role references this file; include the exact current rules too.
  cat "$DV_ROOT/templates/worker-prompt.md"
}
manager_call() (
  local dir=$1 prompt=$2 session=$3 log=$4
  cd "$(jq -er .repo "$dir/meta.json")" || return 1
  if [ -n "$DV_WORKER_CMD" ]; then
    set -- "$prompt" --pass-session-id
    [ -z "$session" ] || set -- "$@" --resume "$session" --no-restore-cwd
    bash -c "$DV_WORKER_CMD \"\$@\"" dv-worker "$@" > "$log.out" 2> "$log.err"
  else
    set -- -p sion chat -Q --yolo -t terminal,connections -s devflow --pass-session-id
    [ -z "$session" ] || set -- "$@" --resume "$session" --no-restore-cwd
    "$DV_HERMES_BIN" "$@" --query-file "$prompt" > "$log.out" 2> "$log.err"
  fi
)
manager_session_id() {
  # -Q emits this machine-readable trailer on stderr, never trust answer text.
  sed -n 's/^session_id: \([A-Za-z0-9][A-Za-z0-9_-]*\)[[:space:]]*$/\1/p' "$1" | tail -n 1
}
manager_turn() {
  local dir=$1 prompt=$2 log=$3 session next='' rc=0 fresh
  session=$(jq -r '.session_id // empty' "$dir/meta.json")
  if [ -n "$session" ]; then
    [ -z "${METRICS_MANAGER_BATCH:-}" ] || metrics_manager_resumes "$METRICS_MANAGER_BATCH"
    manager_call "$dir" "$prompt" "$session" "$log.resume" || rc=$?
    next=$(manager_session_id "$log.resume.err")
    if [ "$rc" = 0 ] && [ -n "$next" ]; then
      manager_set "$dir" --arg id "$next" '.session_id=$id | del(.last_error)' || return 1
      manager_log "$dir" resumed "$session" "$next" 0
      manager_rotate "$dir" "$next"
      return 0
    fi
    manager_log "$dir" resume_failed "$session" "$next" "$rc"
    printf 'dv: manager resume failed; starting a fresh session (see %s.resume.err)\n' "$log" >&2
  fi
  fresh="$log.fresh.prompt.md"
  manager_prompt "$dir" > "$fresh" || return 1
  # Initialization has no event. Recovery sends the role once in the new session
  # followed by the original, unchanged event prompt.
  [ -z "$prompt" ] || cat "$prompt" >> "$fresh"
  rc=0
  manager_call "$dir" "$fresh" '' "$log.fresh" || rc=$?
  next=$(manager_session_id "$log.fresh.err")
  if [ "$rc" != 0 ] || [ -z "$next" ]; then
    manager_log "$dir" fresh_failed "$session" "$next" "$rc"
    manager_set "$dir" '.session_id=null | .last_error="fresh manager turn failed or returned no session_id"'
    return 1
  fi
  manager_set "$dir" --arg id "$next" '.session_id=$id | del(.last_error)' || return 1
  manager_log "$dir" fresh "$session" "$next" 0
  manager_rotate "$dir" "$next"
}
# The operator hook decides when a long-lived session has stopped compacting
# (token ceiling, repeated no-op compression). Exit 10 retires it; the next
# turn starts fresh with the role prompt. Any other result keeps the session.
manager_rotate() {
  local dir=$1 session=$2 rc=0
  [ -n "${DV_MANAGER_ROTATE_CHECK:-}" ] || return 0
  "$DV_MANAGER_ROTATE_CHECK" "$session" >> "$dir/rotate.log" 2>&1 || rc=$?
  [ "$rc" = 10 ] || return 0
  manager_set "$dir" --arg id "$session" '.session_id=null | .rotated_from=$id' || return 0
  manager_log "$dir" rotated "$session" '' 0
}
manager_start() (
  [ "$#" -ge 1 ] || fail 'usage: dv manager start <repo> [--agent hermes]'
  local repo=$1 agent=$DV_MANAGER_AGENT dir key tries=0 tmp
  shift
  if [ "$#" -gt 0 ]; then
    if [ "$#" != 2 ] || [ "$1" != --agent ]; then
      fail 'usage: dv manager start <repo> [--agent hermes]'
    fi
    agent=$2
  fi
  [ "$agent" = hermes ] || fail 'manager supports --agent hermes'
  repo=$(cd "$repo" && git rev-parse --show-toplevel) || fail 'manager needs an existing repository checkout'
  dir=$(manager_dir "$repo") || fail 'manager identity conflict'
  key=$(manager_identity "$repo")
  mkdir -p "$dir/pending" "$dir/failed"
  until manager_lock "$dir"; do
    tries=$((tries + 1)); [ "$tries" -lt 100 ] || fail 'manager is busy'
    sleep 0.1
  done
  trap 'manager_unlock "$dir"' EXIT
  if [ ! -f "$dir/meta.json" ]; then
    tmp=$(mktemp "$dir/.meta.XXXXXX")
    jq -cn --arg repo "$repo" --arg key "$key" --arg host "$DV_HOST" \
      '{repo:$repo,identity:$key,host:$host,agent:"hermes",enabled:false,session_id:null}' > "$tmp"
    mv "$tmp" "$dir/meta.json"
  fi
  # The remote identity survives a move; the validated checkout path does not.
  manager_set "$dir" --arg repo "$repo" '.repo=$repo'
  if ! jq -e '.session_id!=null' "$dir/meta.json" >/dev/null; then
    manager_turn "$dir" '' "$dir/start-$(now)-$$" || fail 'manager initialization failed; see manager logs'
  fi
  manager_set "$dir" '.enabled=true'
  cat "$dir/meta.json"
)
manager_status() {
  local repo='' json=0 arg path selected='' pid running
  for arg in "$@"; do case "$arg" in --json) json=1 ;; *) [ -z "$repo" ] || fail 'one repository only'; repo=$arg ;; esac; done
  if [ -n "$repo" ]; then selected=$(manager_dir "$repo") || fail 'manager identity conflict'; fi
  {
    for path in "$DV_HOME"/managers/*/meta.json; do
      [ -f "$path" ] || continue
      [ -z "$selected" ] || [ "$path" = "$selected/meta.json" ] || continue
      pid=$(cat "$(dirname "$path")/run.lock/pid" 2>/dev/null || true); running=false
      if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then running=true; fi
      jq --argjson active "$running" '.+{active:$active}' "$path"
    done
  } | jq -s . | if [ "$json" = 1 ]; then cat; else jq -r '.[] | [.repo,(.enabled|tostring),(.session_id//""),("active="+(.active|tostring))] | @tsv'; fi
}
manager_stop() (
  [ "$#" = 1 ] || fail 'usage: dv manager stop <repo>'
  local dir
  dir=$(manager_dir "$1") || fail 'manager identity conflict'
  [ -f "$dir/meta.json" ] || return 0
  manager_lock "$dir" || fail 'manager is busy; stop after its current turn finishes'
  trap 'manager_unlock "$dir"' EXIT
  manager_set "$dir" '.enabled=false'
)
manager_note() (
  [ "$#" = 2 ] || fail 'usage: dv manager note <repo> <file>'
  local dir tmp job
  dir=$(manager_dir "$1") || fail 'manager identity conflict'
  if [ ! -f "$dir/meta.json" ] || ! jq -e .enabled "$dir/meta.json" >/dev/null; then fail 'manager is not enabled'; fi
  if [ ! -f "$2" ] || [ ! -r "$2" ]; then fail 'manager note needs a readable file'; fi
  mkdir -p "$dir/notices"
  tmp=$(mktemp "$dir/notices/.note-XXXXXX") || return 1
  trap 'rm -f "$tmp"' EXIT
  job="$dir/notices/note-$(now)-$$-${tmp##*/.note-}.json"
  jq -cn --rawfile text "$2" --arg host "$DV_HOST" --argjson time "$(now)" \
    '{kind:"operator_note",text:$text,host:$host,time:$time}' > "$tmp" || return 1
  # Publish only a complete note; a busy manager picks it up next turn.
  ln "$tmp" "$job" || return 1
  printf '%s\n' "$job"
)
cmd_manager() {
  [ "$DV_HOST" = "$DV_MANAGER_HOST" ] || fail "run manager commands on $DV_MANAGER_HOST"
  local action=${1:-}; [ "$#" = 0 ] || shift
  case "$action" in start|status|stop|note) "manager_$action" "$@" ;; *) fail 'usage: dv manager start|status|stop|note' ;; esac
}
manager_event_repo() {
  local line=$1 issue host repo rows
  issue=$(printf '%s\n' "$line" | jq -er '.issue|select(type=="string" and test("^[A-Za-z0-9][A-Za-z0-9_-]*$"))') || return 1
  host=$(printf '%s\n' "$line" | jq -er .host) || return 1
  # Current event-side metadata takes precedence over a retained submission,
  # including a reused identifier on the same host with a different repo.
  if [ "$host" = "$DV_HOST" ] && [ -f "$DV_STATE/$issue/meta" ]; then
    jq -er --arg host "$host" 'select(.host==$host) | .repo' "$DV_STATE/$issue/meta"
  elif [ -f "$DV_HOME/submissions/$issue/task.json" ] &&
    repo=$(jq -er --arg host "$host" 'select(.host==$host) | .repo | select(type=="string" and length>0)' "$DV_HOME/submissions/$issue/task.json"); then
    printf '%s\n' "$repo"
  else
    case " $DV_HOSTS " in *" $host "*) ;; *) return 1 ;; esac
    rows=$(bid_limit "$DV_BID_TIMEOUT" bid_rpc "$host" status "$issue" --json < /dev/null) || return 1
    repo=$(printf '%s\n' "$rows" | jq -er --arg issue "$issue" --arg host "$host" '.[] | select(.issue==$issue and .host==$host) | .repo') || return 1
    # Resolve a remote checkout on its host; basename matching can cross repos.
    bid_limit "$DV_BID_TIMEOUT" ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$host" "$(shell_join git -C "$repo" config --get remote.origin.url)"
  fi
}
manager_conflict() {
  local dir=$1 path=$2 id=$3 saved reserved=false slot route=''
  # A running batch or durable fallback still refers to its original pathname.
  # Preserve an archival copy in that case; its owner must finish the receipt.
  if [ -f "$dir/run.lock/pid" ] && [ -f "$dir/run.lock/batch.json" ] &&
    jq -e --arg path "$path" 'any(.[]; .job==$path)' "$dir/run.lock/batch.json" >/dev/null; then reserved=true; fi
  slot=$(manager_fallback_slot "$dir" "$path")
  if [ -f "$slot.manager" ] && [ "$(cat "$slot.manager")" = "$path" ]; then reserved=true; fi
  mkdir -p "$dir/conflict" || return 2
  saved=$(mktemp -d "$dir/conflict/entry-XXXXXX") || return 2
  case "$path" in
    "$dir/pending/"*.json) route=pending ;;
    "$dir/fallback/"*.json) route=fallback ;;
  esac
  # Genuine undelivered events must remain executable. Persist the recovery
  # intent BEFORE the atomic move so a crash cannot strand the archived job.
  # Hand-written notes/malformed records and terminal receipts stay archived.
  if [ "$reserved" = false ] && [ -n "$route" ] && jq -e '.event |
    all(.id,.host,.kind; type=="string" and length>0) and
    (.issue | type=="string" and test("^[A-Za-z0-9][A-Za-z0-9_-]*$"))' "$path" >/dev/null; then
    printf '%s\n' "$route" > "$saved/requeue" || return 2
  fi
  saved="$saved/$(basename "$path")"
  if [ "$reserved" = true ]; then cp "$path" "$saved" || return 2
  else mv "$path" "$saved" || return 2; fi
  jq -cn --arg path "$path" --arg saved "$saved" --arg id "$id" --argjson reserved "$reserved" --argjson time "$(now)" \
    '{kind:"queue_conflict",path:$path,saved:$saved,event_id:$id,reserved:$reserved,time:$time}' >> "$dir/events.log" || return 2
  printf 'queue_conflict: %s preserved in %s (incoming %s)\n' "$path" "$saved" "$id" >&2
}
manager_conflict_recover() {
  local marker archive dir route saved name job previous found tmp
  for marker in "$DV_HOME"/managers/*/conflict/*/requeue; do
    [ -f "$marker" ] || continue
    archive=${marker%/requeue}; dir=${archive%/conflict/*}
    route=$(cat "$marker") || return 1
    case "$route" in pending|fallback) ;; *) return 1 ;; esac
    for saved in "$archive"/*.json; do
      [ -f "$saved" ] || continue
      # Sort recovered work before new arrivals when event timestamps tie.
      name="!recovered-$(basename "$archive")-$(jq -jr .event.id "$saved" | cksum | awk '{print $1 "-" $2}')"
      job="$dir/$route/$name.json"; found=false
      for previous in "$dir/pending/$name.json" "$dir/pending/$name.done" "$dir/failed/$name.json" \
        "$dir/fallback/$name.json" "$dir/fallback/$name.done"; do
        [ ! -f "$previous" ] || found=true
      done
      if [ "$found" = false ]; then
        tmp=$(mktemp "$dir/.recovered-XXXXXX") || return 1
        if ! cp "$saved" "$tmp" || ! ln "$tmp" "$job"; then rm -f "$tmp"; return 1; fi
        rm -f "$tmp"
      fi
      # A crash before this rename finds the queued job or terminal receipt.
      mv "$marker" "$archive/requeued" || return 1
    done
  done
}
manager_slot() {
  local dir=$1 name=$2 id=$3 previous occupied=1
  # Include legacy receipts so a restart during an upgrade cannot replay work.
  for previous in "$dir/pending/$name.json" "$dir/pending/$name.done" "$dir/failed/$name.json" \
    "$dir/fallback/$name.json" "$dir/fallback/$name.done"; do
    [ -f "$previous" ] || continue
    if jq -e --arg id "$id" '.event.id==$id' "$previous" >/dev/null; then return 0; fi
    manager_conflict "$dir" "$previous" "$id" || return 2
    [ ! -f "$previous" ] || occupied=3
  done
  return "$occupied"
}
manager_enqueue() {
  local line=$1 prompt=$2 sequence=$3 repo dir job tmp id legacy name suffix=0 rc previous
  [ -d "$DV_HOME/managers" ] || return 1
  repo=$(manager_event_repo "$line") || return 1
  dir=$(manager_dir "$repo") || return 1
  [ -f "$dir/meta.json" ] && jq -e .enabled "$dir/meta.json" >/dev/null || return 1
  id=$(jq -er '.id | select(type=="string")' <<< "$line") || return 2
  legacy=$(printf '%020d' "$sequence")
  name="$legacy-$(printf '%s' "$id" | cksum | awk '{print $1 "-" $2}')"
  # A crash between enqueue and cursor persistence must not overwrite a job
  # already running or replay one that has finished. Scan collision suffixes
  # too: the stranger may have finished and vacated the preferred name.
  for previous in "$dir/pending/$name"*.json "$dir/pending/$name"*.done "$dir/failed/$name"*.json \
    "$dir/fallback/$name"*.json "$dir/fallback/$name"*.done; do
    [ -f "$previous" ] || continue
    if jq -e --arg id "$id" '.event.id==$id' "$previous" >/dev/null; then return 0; fi
  done
  rc=0; manager_slot "$dir" "$legacy" "$id" || rc=$?
  case "$rc" in 0) return 0 ;; 2) return 2 ;; esac
  while :; do
    job=$name
    [ "$suffix" = 0 ] || job="$name-$suffix"
    rc=0; manager_slot "$dir" "$job" "$id" || rc=$?
    case "$rc" in 0) return 0 ;; 1) break ;; 2) return 2 ;; esac
    suffix=$((suffix + 1))
  done
  job="$dir/pending/$job.json"
  tmp=$(mktemp "$dir/.pending.XXXXXX") || return 2
  if ! jq -cn --argjson event "$line" --arg prompt "$prompt" --argjson queued_at "$(now)" \
    '{event:$event,prompt:$prompt,queued_at:$queued_at}' > "$tmp" || ! mv "$tmp" "$job"; then
    rm -f "$tmp"; return 2
  fi
}
# The watcher owns fallback routing; workers use its existing durable retry path.
manager_fallback_slot() {
  printf '%s/pending/manager-%s-%s\n' "$DV_HOME" "$(basename "$1")" "$(basename "${2%.json}")"
}
manager_fallback_recover() {
  local job dir slot
  for job in "$DV_HOME"/managers/*/fallback/*.json; do
    [ -f "$job" ] || continue
    dir=$(dirname "$(dirname "$job")")
    slot=$(manager_fallback_slot "$dir" "$job")
    [ ! -f "$slot.json" ] || continue
    printf '%s\n' "$job" > "$slot.manager"
    jq '.event' "$job" > "$slot.json.tmp" || return 1
    mv "$slot.json.tmp" "$slot.json"
  done
}
manager_event_result() {
  local item=$1 route=$2 rc=$3
  jq -cn --argjson item "$item" --arg route "$route" --argjson rc "$rc" --argjson handled "$(now)" '
    {kind:"event_handled",event_id:$item.event.id,issue:$item.event.issue,event:$item.event,
     event_time:($item.event.time // $item.queued_at // $handled),handled_at:$handled,
     route:$route,exit_code:$rc,disposition:($item.disposition // "handled"),
     superseded_by:($item.superseded_by // null)} |
    .latency_seconds=([0, (.handled_at-.event_time)]|max)'
}
manager_fallback_complete() {
  local slot=$1 job dir receipt
  job=$(cat "$slot.manager") || return 1
  dir=$(dirname "$(dirname "$job")")
  # A restart after terminal persistence only needs to clear the worker slot.
  [ -f "$job" ] || return 0
  receipt=$(manager_event_result "$(cat "$job")" fallback 0) || return 1
  mkdir -p "$dir/notices"
  printf '%s\n' "$receipt" > "$dir/notices/$(basename "$job").tmp"
  mv "$dir/notices/$(basename "$job").tmp" "$dir/notices/$(basename "$job")"
  printf '%s\n' "$receipt" >> "$dir/events.log"
  mv "$job" "${job%.json}.done"
}
manager_issue_in_fallback() {
  local dir=$1 issue=$2 job
  for job in "$dir"/fallback/*.json; do
    [ -f "$job" ] || continue
    if jq -e --arg issue "$issue" '.event.issue==$issue' "$job" >/dev/null; then return 0; fi
  done
  return 1
}
manager_fallback_dispatch() {
  local dir=$1 started batch job issue
  started=$(cat "$dir/run.lock/started" 2>/dev/null) || return 0
  [[ "$started" =~ ^[0-9]+$ ]] || return 0
  [ $(( $(now) - started )) -ge "$DV_MANAGER_MAX_WAIT" ] || return 0
  # An immutable reservation describes every issue the busy turn may touch.
  batch=$(cat "$dir/run.lock/batch.json" 2>/dev/null) || return 0
  for job in "$dir"/pending/*.json; do
    [ "$active" -lt "$DV_MAX_WORKERS" ] || break
    [ -f "$job" ] || continue
    issue=$(jq -er .event.issue "$job") || continue
    if jq -en --arg issue "$issue" --argjson batch "$batch" \
      'any($batch[]; .event.issue==$issue)' >/dev/null; then continue; fi
    manager_issue_in_fallback "$dir" "$issue" && continue
    mkdir -p "$dir/fallback"
    mv "$job" "$dir/fallback/$(basename "$job")"
    manager_fallback_recover
    retry_pending
  done
}
# Snapshot once under the reservation. Arrivals during a turn belong to the
# next batch, and issues with an outstanding fallback cannot race that worker.
manager_dispatch() {
  local meta dir job issue anchor enabled owner claim
  local jobs=() notices=()
  for meta in "$DV_HOME"/managers/*/meta.json; do
    [ -f "$meta" ] || continue
    dir=$(dirname "$meta")
    enabled=false
    jq -e .enabled "$meta" >/dev/null && enabled=true
    # Enabled managers own one slot per repository, outside the worker pool.
    if [ "$enabled" = false ] && [ "$active" -ge "$DV_MAX_WORKERS" ]; then continue; fi
    if ! manager_lock "$dir"; then
      owner=$(cat "$dir/run.lock/pid" 2>/dev/null || true)
      claim=$(cat "$dir/run.lock/claim" 2>/dev/null || true)
      # An empty owner may still be getting written. A live claim also covers
      # the brief handoff before the runner replaces its watcher's PID.
      if ! [[ "$owner" =~ ^[1-9][0-9]*$ ]] || kill -0 "$owner" 2>/dev/null ||
        { [[ "$claim" =~ ^[1-9][0-9]*$ ]] && kill -0 "$claim" 2>/dev/null; }; then
        manager_fallback_dispatch "$dir"; continue
      fi
      manager_unlock "$dir" "$owner"
      jq -cn --arg pid "$owner" --argjson time "$(now)" \
        '{kind:"stale_lock_cleared",pid:$pid,time:$time}' >> "$dir/events.log"
      # Jobs and notices remain queued; rebuild their reservation this pass.
      if ! manager_lock "$dir"; then manager_fallback_dispatch "$dir"; continue; fi
    fi
    jobs=(); notices=(); anchor=''
    for job in "$dir"/pending/*.json; do
      [ -f "$job" ] || continue
      issue=$(jq -er .event.issue "$job") || continue
      manager_issue_in_fallback "$dir" "$issue" && continue
      jobs+=("$job"); anchor=$job
    done
    for job in "$dir"/notices/*.json; do
      [ -f "$job" ] || continue
      notices+=("$job"); anchor=$job
    done
    if [ -z "$anchor" ]; then manager_unlock "$dir"; continue; fi
    if [ "${#jobs[@]}" = 0 ]; then printf '[]\n' > "$dir/run.lock/batch.json"
    else
      jq -n '[inputs | .+{job:input_filename}] | to_entries as $rows |
        ($rows | group_by(.value.event.issue) | map(max_by([.value.event.time // 0,.key]))) as $latest |
        $rows | map(. as $row | ($latest[] | select(.value.event.issue==$row.value.event.issue)) as $new |
          .value + if .key==$new.key then {disposition:"handled"}
          else {disposition:"superseded",superseded_by:$new.value.event.id} end)' \
        "${jobs[@]}" > "$dir/run.lock/batch.json"
    fi
    if [ "${#notices[@]}" = 0 ]; then printf '[]\n' > "$dir/run.lock/notices.json"
    else jq -n '[inputs | .+{job:input_filename}]' "${notices[@]}" > "$dir/run.lock/notices.json"; fi
    printf '%s\n' "$anchor" > "$dir/run.lock/job"
    "$DV_ROOT/bin/dv" _manager-run "$dir" "$anchor" > "${anchor%.json}.log" 2>&1 &
    if [ "$enabled" = true ]; then manager_pids="${manager_pids:-} $!"
    else pids="$pids $!"; active=$((active + 1)); fi
  done
}
cmd__manager_run() (
  [ "$#" = 2 ] || fail 'usage: dv _manager-run <manager-directory> <queued-job>'
  local dir=$1 job=$2 prompt rc=0 log item record
  [ "$(dirname "$dir")" = "$DV_HOME/managers" ] || fail 'invalid manager directory'
  if { [ "$(dirname "$job")" != "$dir/pending" ] && [ "$(dirname "$job")" != "$dir/notices" ]; } || [ ! -f "$job" ]; then
    fail 'invalid manager job'
  fi
  [ "$(cat "$dir/run.lock/pid" 2>/dev/null)" = "$PPID" ] || fail 'manager runner has no parent reservation'
  [ "$(cat "$dir/run.lock/job" 2>/dev/null)" = "$job" ] || fail 'manager runner job was not reserved'
  # Only one child can claim this exact reservation, even if invoked twice.
  (set -C; printf '%s\n' "$$" > "$dir/run.lock/claim") 2>/dev/null || fail 'manager reservation already claimed'
  # Transfer the watcher's reservation to this child before doing any work.
  printf '%s\n' "$$" > "$dir/run.lock/pid"
  trap 'manager_unlock "$dir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  local METRICS_MANAGER_BATCH="$dir/run.lock/batch.json"
  log="${job%.json}"
  prompt="$log.batch.prompt.md"
  {
    cat "$DV_ROOT/templates/worker-prompt.md"
    printf '\n작업자 호스트(DV_HOST): `%s`\n' "$DV_HOST"
    printf '\n이 저장소의 대기 이벤트를 이번 턴에서 모두 처리하세요. 이슈별 최신 이벤트만 실행하고 superseded 이벤트는 문맥으로만 읽으세요.\n이벤트 배치(JSON 데이터):\n```json\n'
    jq 'map(del(.job,.prompt))' "$dir/run.lock/batch.json"
    printf '```\n\n운영자 메모입니다. 이번 턴의 작업 문맥으로 읽으세요.\n```json\n'
    jq 'map(select(.kind=="operator_note") | del(.job))' "$dir/run.lock/notices.json"
    printf '```\n\nFleet alarms: inspect current queue and host bids, resolve scheduling here, and do not notify the owner.\n```json\n'
    jq 'map(select(.reason=="fleet-underused") | del(.job))' "$dir/run.lock/notices.json"
    printf '```\n\n별도 worker 처리 결과입니다. 이미 처리했으므로 다시 실행하지 말고 현재 상태를 확인하세요.\n```json\n'
    jq 'map(select(.kind!="operator_note" and .reason!="fleet-underused") | del(.job))' "$dir/run.lock/notices.json"
    printf '```\n'
  } > "$prompt"
  if jq -e .enabled "$dir/meta.json" >/dev/null; then
    manager_turn "$dir" "$prompt" "$log" || rc=$?
  elif [ -n "$DV_WORKER_CMD" ]; then
    bash -c "$DV_WORKER_CMD \"\$@\"" dv-worker "$prompt" || rc=$?
  else
    "$DV_HERMES_BIN" -p sion chat -Q --yolo -t terminal,connections -s devflow --query-file "$prompt" || rc=$?
  fi
  # Retain terminal failures for inspection, without an unbounded retry loop.
  while IFS= read -r item; do
    record=$(jq -r .job <<< "$item")
    manager_event_result "$item" manager "$rc" >> "$dir/events.log"
    if [ "$rc" = 0 ]; then metrics_handled "$(jq -c .event <<< "$item")"; mv "$record" "${record%.json}.done"
    else mv "$record" "$dir/failed/$(basename "$record")"; fi
  done < <(jq -c '.[]' "$dir/run.lock/batch.json")
  while IFS= read -r record; do
    if [ "$rc" = 0 ]; then mv "$record" "${record%.json}.done"
    else mv "$record" "$dir/failed/notice-$(basename "$record")"; fi
  done < <(jq -r '.[].job' "$dir/run.lock/notices.json")
  return "$rc"
)
