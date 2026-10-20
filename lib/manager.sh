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
  local dir=$1 pid
  if ! mkdir "$dir/run.lock" 2>/dev/null; then
    pid=$(cat "$dir/run.lock/pid" 2>/dev/null) || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    if kill -0 "$pid" 2>/dev/null; then return 1; fi
    # A dead holder can be recovered. An ownerless lock needs inspection.
    rm -f "$dir/run.lock/pid"
    rmdir "$dir/run.lock" 2>/dev/null || return 1
    mkdir "$dir/run.lock" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" > "$dir/run.lock/pid"
}
manager_unlock() {
  local dir=$1
  [ "$(cat "$dir/run.lock/pid" 2>/dev/null)" = "$$" ] || return 0
  rm -f "$dir/run.lock/pid"; rmdir "$dir/run.lock"
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
    [ -z "$session" ] || set -- "$@" --resume "$session"
    bash -c "$DV_WORKER_CMD \"\$@\"" dv-worker "$@" > "$log.out" 2> "$log.err"
  else
    set -- -p sion chat -Q --yolo -t terminal,connections -s devflow --pass-session-id
    [ -z "$session" ] || set -- "$@" --resume "$session"
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
    manager_call "$dir" "$prompt" "$session" "$log.resume" || rc=$?
    next=$(manager_session_id "$log.resume.err")
    if [ "$rc" = 0 ] && [ -n "$next" ]; then
      manager_set "$dir" --arg id "$next" '.session_id=$id | del(.last_error)' || return 1
      manager_log "$dir" resumed "$session" "$next" 0
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
}
manager_start() (
  [ "$#" -ge 1 ] || fail 'usage: dv manager start <repo> [--agent hermes]'
  local repo=$1 agent=$DV_MANAGER_AGENT dir key tries=0
  shift
  if [ "$#" -gt 0 ]; then
    [ "$#" = 2 ] && [ "$1" = --agent ] || fail 'usage: dv manager start <repo> [--agent hermes]'
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
    jq -cn --arg repo "$repo" --arg key "$key" --arg host "$DV_HOST" \
      '{repo:$repo,identity:$key,host:$host,agent:"hermes",enabled:false,session_id:null}' > "$dir/meta.json"
  fi
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
cmd_manager() {
  [ "$DV_HOST" = "$DV_MANAGER_HOST" ] || fail "run manager commands on $DV_MANAGER_HOST"
  local action=${1:-}; [ "$#" = 0 ] || shift
  case "$action" in start|status|stop) "manager_$action" "$@" ;; *) fail 'usage: dv manager start|status|stop' ;; esac
}
manager_event_repo() {
  local line=$1 issue host repo rows
  issue=$(printf '%s\n' "$line" | jq -er '.issue|select(type=="string" and test("^[A-Za-z0-9][A-Za-z0-9_-]*$"))') || return 1
  host=$(printf '%s\n' "$line" | jq -er .host) || return 1
  if [ -f "$DV_HOME/submissions/$issue/task.json" ]; then
    jq -er '.repo | select(type=="string" and length>0)' "$DV_HOME/submissions/$issue/task.json"
  elif [ "$host" = "$DV_HOST" ] && [ -f "$DV_STATE/$issue/meta" ]; then
    jq -er --arg host "$host" 'select(.host==$host) | .repo' "$DV_STATE/$issue/meta"
  else
    case " $DV_HOSTS " in *" $host "*) ;; *) return 1 ;; esac
    rows=$(bid_limit "$DV_BID_TIMEOUT" bid_rpc "$host" status "$issue" --json < /dev/null) || return 1
    repo=$(printf '%s\n' "$rows" | jq -er --arg issue "$issue" --arg host "$host" '.[] | select(.issue==$issue and .host==$host) | .repo') || return 1
    # Resolve a remote checkout on its host; basename matching can cross repos.
    bid_limit "$DV_BID_TIMEOUT" ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$host" "$(shell_join git -C "$repo" config --get remote.origin.url)"
  fi
}
manager_enqueue() {
  local line=$1 prompt=$2 sequence=$3 repo dir job tmp previous
  [ -d "$DV_HOME/managers" ] || return 1
  repo=$(manager_event_repo "$line") || return 1
  dir=$(manager_dir "$repo") || return 1
  [ -f "$dir/meta.json" ] && jq -e .enabled "$dir/meta.json" >/dev/null || return 1
  job="$dir/pending/$(printf '%020d' "$sequence").json"
  # A crash between enqueue and cursor persistence must not overwrite a job
  # already running or replay one that has finished.
  for previous in "$job" "${job%.json}.done" "$dir/failed/$(basename "$job")"; do
    if [ -f "$previous" ]; then
      jq -e --argjson event "$line" '.event.id==$event.id' "$previous" >/dev/null || return 2
      return 0
    fi
  done
  tmp=$(mktemp "$dir/.pending.XXXXXX") || return 2
  jq -cn --argjson event "$line" --arg prompt "$prompt" '{event:$event,prompt:$prompt}' > "$tmp" || return 2
  mv "$tmp" "$job" || return 2
}
# Called by the existing watcher. Only running children consume worker slots;
# queued events for a busy repo cannot prevent another repo from being started.
manager_dispatch() {
  local meta dir job
  for meta in "$DV_HOME"/managers/*/meta.json; do
    [ "$active" -lt "$DV_MAX_WORKERS" ] || break
    [ -f "$meta" ] || continue
    dir=$(dirname "$meta")
    for job in "$dir"/pending/*.json; do
      [ -f "$job" ] || break
      manager_lock "$dir" || break
      "$DV_ROOT/bin/dv" _manager-run "$dir" "$job" > "${job%.json}.log" 2>&1 &
      pids="$pids $!"; active=$((active + 1))
      break
    done
  done
}
cmd__manager_run() (
  local dir=$1 job=$2 prompt rc=0 log
  # Transfer the watcher's reservation to this child before doing any work.
  printf '%s\n' "$$" > "$dir/run.lock/pid"
  trap 'manager_unlock "$dir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  prompt=$(jq -er .prompt "$job") || return 1
  log="${job%.json}"
  if jq -e .enabled "$dir/meta.json" >/dev/null; then
    manager_turn "$dir" "$prompt" "$log" || rc=$?
  elif [ -n "$DV_WORKER_CMD" ]; then
    bash -c "$DV_WORKER_CMD \"\$@\"" dv-worker "$prompt" || rc=$?
  else
    "$DV_HERMES_BIN" -p sion chat -Q --yolo -t terminal,connections -s devflow --query-file "$prompt" || rc=$?
  fi
  # Retain terminal failures for inspection, without an unbounded retry loop.
  if [ "$rc" = 0 ]; then mv "$job" "${job%.json}.done"
  else mv "$job" "$dir/failed/$(basename "$job")"; fi
  return "$rc"
)
