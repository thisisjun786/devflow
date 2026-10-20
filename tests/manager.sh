#!/usr/bin/env bash
# shellcheck disable=SC2016
manager_setup() {
  repo manager
  export DV_MANAGER_HOST="$DV_HOST" DV_MANAGER_AGENT=hermes DV_HERMES_BIN="$ROOT/tests/fixtures/manager-hermes"
  export DV_HOSTS='' DV_PULL_HOSTS='' DV_WORKER_CMD='' DV_WATCH_INTERVAL=0.05 DV_RECONCILE_INTERVAL=1800
  mkdir -p "$CASE_DIR/hermes"
}
manager_meta() { find "$DV_HOME/managers" -name meta.json | head -n 1; }
manager_event() {
  local issue=$1 repo=$2
  mkdir -p "$DV_HOME/submissions/$issue"
  jq -cn --arg repo "$repo" '{repo:$repo,host:"worker",status:"completed"}' > "$DV_HOME/submissions/$issue/task.json"
  dv-kick pr-ready "$issue" "event $issue" worker abc
}
manager_watch_until() {
  local count=$1 watcher
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  for _ in {1..300}; do
    if [ -f "$CASE_DIR/hermes/finished" ] && [ "$(wc -l < "$CASE_DIR/hermes/finished" | tr -d ' ')" -ge "$count" ]; then break; fi
    sleep 0.05
  done
  touch "$DV_HOME/stop"; wait "$watcher"
  test "$(wc -l < "$CASE_DIR/hermes/finished" | tr -d ' ')" -ge "$count"
}
case_manager_start() {
  manager_setup
  dv manager start "$REPO"
  dv manager start "$REPO/." --agent hermes
  test "$(wc -l < "$CASE_DIR/hermes/calls" | tr -d ' ')" = 1
  dv manager status "$REPO" --json | jq -e 'length==1 and .[0].enabled and .[0].session_id=="session-1" and .[0].agent=="hermes"'
  dv manager status | grep 'session-1'
  sed -n '/^당신은 시온입니다/,$p' "$CASE_DIR/hermes/prompt-1" > "$CASE_DIR/shared"
  cmp "$ROOT/templates/worker-prompt.md" "$CASE_DIR/shared"
  dv manager stop "$REPO"
  dv manager stop "$REPO"
  dv manager status --json | jq -e 'length==1 and (.[0].enabled|not) and .[0].session_id=="session-1"'
  dv manager start "$REPO"
  test "$(wc -l < "$CASE_DIR/hermes/calls" | tr -d ' ')" = 1
  test -d "$REPO/.git"
}
case_manager_identity() {
  manager_setup
  git -C "$REPO" remote add origin git@github.com:Example/Project.git
  dv manager start "$REPO"
  dv manager status https://github.com/example/project --json | jq -e 'length==1 and .[0].enabled'
  dv manager status https://github.com/someone/project --json | jq -e 'length==0'
  export DV_MANAGER_HOST=elsewhere
  if dv manager start "$REPO"; then return 1; fi
}
case_manager_serial() {
  manager_setup
  dv manager start "$REPO"
  manager_event M-1 "$REPO"; manager_event M-2 "$REPO"
  export HERMES_HOLD=0.3
  manager_watch_until 3
  jq -se '.[1].resume=="session-1" and .[2].resume=="session-1"' "$CASE_DIR/hermes/calls"
  test ! -f "$CASE_DIR/hermes/overlap"
  test "$(find "$DV_HOME/managers" -path '*/pending/*.json' | wc -l | tr -d ' ')" = 0
  grep -F 'M-1' "$CASE_DIR/hermes/prompt-2"
  grep -F 'M-2' "$CASE_DIR/hermes/prompt-3"
  if grep -F '장기 실행 관리자' "$CASE_DIR/hermes/prompt-2"; then return 1; fi
}
case_manager_parallel() {
  manager_setup
  dv manager start "$REPO"
  local first=$REPO
  repo other; dv manager start "$REPO"
  manager_event M-1 "$first"; manager_event M-2 "$REPO"; manager_event M-3 "$first"
  export HERMES_HOLD=1 DV_MAX_WORKERS=2
  manager_watch_until 5
  test -f "$CASE_DIR/hermes/parallel"
  test ! -f "$CASE_DIR/hermes/overlap"
  test ! -f "$CASE_DIR/hermes/over-capacity"
}
case_manager_fallback() {
  manager_setup
  dv manager start "$REPO"
  touch "$CASE_DIR/hermes/fail-resume"
  manager_event M-1 "$REPO"; manager_event M-2 "$REPO"
  manager_watch_until 3
  jq -se 'length==4 and .[1].resume=="session-1" and .[2].resume=="" and .[3].resume=="session-2"' "$CASE_DIR/hermes/calls"
  jq -e '.session_id=="session-2"' "$(manager_meta)"
  grep -F '장기 실행 관리자' "$CASE_DIR/hermes/prompt-3"
  grep -F 'M-1' "$CASE_DIR/hermes/prompt-3"
  grep -F 'resume_failed' "$(dirname "$(manager_meta)")/events.log"
}
case_manager_no_id() {
  manager_setup
  touch "$CASE_DIR/hermes/no-id"
  if dv manager start "$REPO"; then return 1; fi
  jq -e '.session_id==null and (.enabled|not)' "$(manager_meta)"
  rm "$CASE_DIR/hermes/no-id"
  dv manager start "$REPO"
  jq -e '.enabled and .session_id!=null' "$(manager_meta)"
}
case_manager_unmanaged() {
  manager_setup
  manager_event M-1 "$REPO"
  manager_watch_until 1
  jq -se 'length==1 and .[0].resume=="" and (.[0].args|index("--pass-session-id")|not)' "$CASE_DIR/hermes/calls"
  test ! -d "$DV_HOME/managers"
}
case_manager_local() {
  manager_setup
  dv manager start "$REPO"
  mkdir -p "$DV_STATE/M-1"
  jq -cn --arg repo "$REPO" --arg host "$DV_HOST" '{repo:$repo,host:$host}' > "$DV_STATE/M-1/meta"
  dv-kick pr-ready M-1 'local event' "$DV_HOST" abc
  manager_watch_until 2
  jq -se '.[1].resume=="session-1"' "$CASE_DIR/hermes/calls"
}
case_manager_stop_pending() {
  manager_setup
  dv manager start "$REPO"; dv manager stop "$REPO"
  manager_event M-1 "$REPO"
  manager_watch_until 2
  jq -se '.[1].resume==""' "$CASE_DIR/hermes/calls"
}
case_manager_concurrent_start() {
  manager_setup
  export HERMES_HOLD=0.5
  dv manager start "$REPO" > "$CASE_DIR/start1" & local first=$!
  dv manager start "$REPO" > "$CASE_DIR/start2" & local second=$!
  wait "$first"; wait "$second"
  test "$(wc -l < "$CASE_DIR/hermes/calls" | tr -d ' ')" = 1
}
case_manager_failed_event() {
  manager_setup
  dv manager start "$REPO"
  touch "$CASE_DIR/hermes/fail-resume" "$CASE_DIR/hermes/fail-fresh"
  manager_event M-1 "$REPO"; manager_event M-2 "$REPO"
  manager_watch_until 2
  local dir
  dir=$(dirname "$(manager_meta)")
  test "$(find "$dir/failed" -name '*.json' | wc -l | tr -d ' ')" = 1
  jq -se 'length==4 and .[3].resume==""' "$CASE_DIR/hermes/calls"
  test ! -f "$dir/run.lock/pid"
}
manager_functions() {
  DV_ENTRY="$ROOT/bin/dv"
  # shellcheck source=lib/common.sh
  source "$ROOT/lib/common.sh"
  # shellcheck source=lib/manager.sh
  source "$ROOT/lib/manager.sh"
}
case_manager_restart_queue() {
  manager_setup
  dv manager start "$REPO"
  manager_event M-1 "$REPO"
  manager_functions
  local dir line prompt
  dir=$(dirname "$(manager_meta)")
  line=$(cat "$DV_HOME/kick.q"); prompt="$CASE_DIR/restart.prompt.md"
  cat "$ROOT/templates/worker-prompt.md" > "$prompt"
  printf '%s\n' "$line" >> "$prompt"
  manager_enqueue "$line" "$prompt" 0
  # Model dispatch persistence followed by a watcher restart.
  printf '1\n' > "$DV_HOME/cursor"
  manager_watch_until 2
  manager_enqueue "$line" "$prompt" 0
  test "$(find "$dir/pending" -name '*.json' | wc -l | tr -d ' ')" = 0
}
case_manager_unmanaged_override() {
  manager_setup
  export DV_WORKER_CMD="$ROOT/tests/fixtures/worker"
  manager_event M-1 "$REPO"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & local watcher=$!
  for _ in {1..100}; do
    [ "$(find "$DV_HOME" -name '*.finished' | wc -l | tr -d ' ')" = 1 ] && break
    sleep 0.05
  done
  touch "$DV_HOME/stop"; wait "$watcher"
  test "$(find "$DV_HOME" -name '*.finished' | wc -l | tr -d ' ')" = 1
  test ! -f "$CASE_DIR/hermes/calls"
}
case_manager_unknown_repo() {
  manager_setup
  dv manager start "$REPO"
  dv-kick pr-ready M-1 'no metadata' worker abc
  jq -c --arg repo "$REPO" '.+{repo:$repo}' "$DV_HOME/kick.q" > "$CASE_DIR/event"
  mv "$CASE_DIR/event" "$DV_HOME/kick.q"
  manager_watch_until 2
  jq -se '.[1].resume==""' "$CASE_DIR/hermes/calls"
}
