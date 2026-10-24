#!/usr/bin/env bash
# shellcheck disable=SC2016
manager_setup() {
  repo manager
  export DV_MANAGER_HOST="$DV_HOST" DV_MANAGER_AGENT=hermes DV_HERMES_BIN="$ROOT/tests/fixtures/manager-hermes"
  export DV_HOSTS='' DV_PULL_HOSTS='' DV_WORKER_CMD='' DV_WATCH_INTERVAL=0.05 DV_RECONCILE_INTERVAL=1800
  export DV_MANAGER_MAX_WAIT=120
  mkdir -p "$CASE_DIR/hermes"
  trap 'rm -f "$CASE_DIR/hermes/hold-resume" "$CASE_DIR/hermes/hold-worker"; teardown' EXIT
}
manager_wait_calls() {
  local count=$1
  for _ in {1..200}; do
    [ "$(wc -l < "$CASE_DIR/hermes/calls" | tr -d ' ')" -lt "$count" ] || return 0
    sleep 0.05
  done
  return 1
}
case_manager_batch() {
  manager_setup
  dv manager start "$REPO"
  manager_event M-1 "$REPO"; manager_event M-2 "$REPO"; manager_event M-3 "$REPO"
  dv-kick blocked M-1 'old blocked event' worker abc
  dv-kick 'done' M-1 'newest event' worker abc
  manager_watch_until 2
  test "$(wc -l < "$CASE_DIR/hermes/calls" | tr -d ' ')" = 2
  local dir
  dir=$(dirname "$(manager_meta)")
  test "$(find "$dir/pending" -name '*.done' | wc -l | tr -d ' ')" = 5
  grep -F 'newest event' "$CASE_DIR/hermes/prompt-2"
  grep -F 'old blocked event' "$CASE_DIR/hermes/prompt-2"
  grep -F '"superseded_by": "worker:M-1:done:abc"' "$CASE_DIR/hermes/prompt-2"
  jq -se '[.[]|select(.kind=="event_handled")]|length==5 and
    ([.[]|select(.disposition=="superseded")]|length)==2' "$dir/events.log"
}
case_manager_latency() {
  manager_setup
  dv manager start "$REPO"
  manager_event M-1 "$REPO"
  jq -c '.time-=10' "$DV_HOME/kick.q" > "$CASE_DIR/event"
  mv "$CASE_DIR/event" "$DV_HOME/kick.q"
  manager_watch_until 2
  jq -se '[.[]|select(.kind=="event_handled")]|length==1 and
    .[0].event_id=="worker:M-1:pr-ready:abc" and .[0].route=="manager" and
    .[0].latency_seconds>=10 and .[0].latency_seconds==.[0].handled_at-.[0].event_time and
    .[0].exit_code==0' "$(dirname "$(manager_meta)")/events.log"
}
case_manager_batch_order() {
  manager_setup
  dv manager start "$REPO"
  manager_event M-1 "$REPO"
  dv-kick blocked M-1 'delayed old event' worker abc
  jq -sc '.[1].time=.[0].time-10 | .[]' "$DV_HOME/kick.q" > "$CASE_DIR/events"
  mv "$CASE_DIR/events" "$DV_HOME/kick.q"
  manager_watch_until 2
  jq -se '[.[]|select(.kind=="event_handled")]|length==2 and
    .[0].disposition=="handled" and .[1].superseded_by=="worker:M-1:pr-ready:abc"' \
    "$(dirname "$(manager_meta)")/events.log"
}
case_manager_busy() {
  manager_setup
  export DV_MANAGER_MAX_WAIT=1 DV_MAX_WORKERS=2
  dv manager start "$REPO"
  touch "$CASE_DIR/hermes/hold-resume"
  manager_event M-1 "$REPO"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & local watcher=$!
  manager_wait_calls 2
  if [ "${1:-}" != notice ]; then dv-kick 'done' M-1 'same issue must wait' worker abc; fi
  manager_event M-2 "$REPO"
  manager_wait_calls 3
  jq -se 'length==3 and .[2].resume=="" and (.[2].args|index("--pass-session-id")|not)' "$CASE_DIR/hermes/calls"
  grep -F 'M-2' "$CASE_DIR/hermes/prompt-3"
  if grep -F 'same issue must wait' "$CASE_DIR/hermes/prompt-3"; then return 1; fi
  local dir
  dir=$(dirname "$(manager_meta)")
  for _ in {1..200}; do
    if jq -se 'any(.[]; .kind=="event_handled" and .route=="fallback")' "$dir/events.log" >/dev/null; then break; fi
    sleep 0.05
  done
  jq -se 'any(.[]; .event_id=="worker:M-2:pr-ready:abc" and .route=="fallback" and .latency_seconds>=0)' "$dir/events.log"
  rm "$CASE_DIR/hermes/hold-resume"
  manager_wait_calls 4
  touch "$DV_HOME/stop"; wait "$watcher"
  if [ "${1:-}" != notice ]; then grep -F 'same issue must wait' "$CASE_DIR/hermes/prompt-4"; fi
  grep -F '"route": "fallback"' "$CASE_DIR/hermes/prompt-4"
  grep -F 'worker:M-2:pr-ready:abc' "$CASE_DIR/hermes/prompt-4"
  test ! -f "$CASE_DIR/hermes/overlap"
  test ! -f "$CASE_DIR/hermes/over-capacity"
}
case_manager_notice() { case_manager_busy notice; }
case_manager_busy_default() {
  manager_setup
  unset DV_MANAGER_MAX_WAIT
  dv manager start "$REPO"
  touch "$CASE_DIR/hermes/hold-resume"
  manager_event M-1 "$REPO"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & local watcher=$!
  manager_wait_calls 2
  manager_event M-2 "$REPO"
  local dir
  dir=$(dirname "$(manager_meta)")
  wait_file "$dir/pending/$(manager_job_name 1 worker:M-2:pr-ready:abc).json"
  sleep 0.2
  test "$(wc -l < "$CASE_DIR/hermes/calls" | tr -d ' ')" = 2
  # Below the default a busy manager keeps its queue (devflow#326: 120 s sent
  # each later event to its own one-shot session).
  printf '%s\n' "$(( $(date +%s) - 1700 ))" > "$dir/run.lock/started"
  sleep 0.3
  test "$(wc -l < "$CASE_DIR/hermes/calls" | tr -d ' ')" = 2
  # Advance only the synthetic reservation's clock, proving the default is 1800s.
  printf '%s\n' "$(( $(date +%s) - 1801 ))" > "$dir/run.lock/started"
  manager_wait_calls 3
  jq -se '.[2].resume==""' "$CASE_DIR/hermes/calls"
  rm "$CASE_DIR/hermes/hold-resume"
  touch "$DV_HOME/stop"; wait "$watcher"
}
case_manager_capacity_restart() {
  manager_setup
  export DV_MANAGER_MAX_WAIT=0 DV_MAX_WORKERS=1
  dv manager start "$REPO"
  touch "$CASE_DIR/hermes/hold-resume" "$CASE_DIR/hermes/hold-worker"
  manager_event M-1 "$REPO"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & local watcher=$!
  manager_wait_calls 2
  manager_event M-2 "$REPO"; manager_event M-3 "$REPO"
  local dir
  dir=$(dirname "$(manager_meta)")
  manager_wait_calls 3
  wait_file "$dir/pending/$(manager_job_name 2 worker:M-3:pr-ready:abc).json"
  kill -KILL "$watcher"; wait "$watcher" 2>/dev/null || true
  dv-watch >> "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  sleep 0.4
  # The inherited manager has its own slot; the inherited fallback occupies
  # the only worker slot, so M-3 must still wait after a watcher restart.
  test "$(wc -l < "$CASE_DIR/hermes/calls" | tr -d ' ')" = 3
  rm "$CASE_DIR/hermes/hold-resume" "$CASE_DIR/hermes/hold-worker"
  wait_file "$dir/pending/$(manager_job_name 2 worker:M-3:pr-ready:abc).done"
  touch "$DV_HOME/stop"; wait "$watcher"
  jq -se 'length>=4 and all(.[]; .resume=="" or .resume=="session-1")' "$CASE_DIR/hermes/calls"
  test ! -f "$CASE_DIR/hermes/over-capacity"
  test ! -f "$CASE_DIR/hermes/overlap"
  grep -F M-2 "$CASE_DIR/hermes/prompt-3"
  grep -F M-3 "$CASE_DIR/hermes/prompt-4"
}
case_manager_fallback_restart() {
  manager_setup
  # Keep the first retry pending regardless of scheduler/poll timing. Advance
  # only this fixture's durable retry deadline after the watcher has stopped.
  export DV_WORKER_RETRY=3600
  dv manager start "$REPO"
  manager_event M-2 "$REPO"
  manager_functions
  local dir job line slot
  dir=$(dirname "$(manager_meta)")
  line=$(cat "$DV_HOME/kick.q")
  manager_enqueue "$line" "$CASE_DIR/brief" 0
  job="$dir/fallback/$(manager_job_name 0 worker:M-2:pr-ready:abc).json"
  mkdir -p "$dir/fallback"
  mv "$dir/pending/$(basename "$job")" "$job"
  # Simulate a crash after the durable handoff but before worker persistence.
  printf '1\n' > "$DV_HOME/cursor"
  jq -r .id <<< "$line" > "$DV_HOME/seen"
  touch "$CASE_DIR/hermes/fail-worker-once"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & local watcher=$!
  wait_file "$CASE_DIR/hermes/worker-failed"
  touch "$DV_HOME/stop"; wait "$watcher"
  test -f "$job"
  slot=$(manager_fallback_slot "$dir" "$job")
  test -s "$slot.retry"
  printf '0\n' > "$slot.retry"
  rm "$DV_HOME/stop"
  manager_watch_until 3
  test -f "${job%.json}.done"
  jq -se '[.[]|select(.kind=="event_handled")]|length==1 and .[0].route=="fallback"' "$dir/events.log"
  manager_enqueue "$line" "$CASE_DIR/brief" 0
  test ! -f "$dir/pending/$(basename "$job")"
  grep -F '"route": "fallback"' "$CASE_DIR/hermes/prompt-4"
}
case_manager_fallback_serial() {
  manager_setup
  export DV_MANAGER_MAX_WAIT=0 DV_MAX_WORKERS=3
  dv manager start "$REPO"
  touch "$CASE_DIR/hermes/hold-resume" "$CASE_DIR/hermes/hold-worker"
  manager_event M-1 "$REPO"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & local watcher=$!
  manager_wait_calls 2
  manager_event M-2 "$REPO"
  manager_wait_calls 3
  dv-kick 'done' M-2 'must wait for fallback' worker abc
  local dir
  dir=$(dirname "$(manager_meta)")
  wait_file "$dir/pending/$(manager_job_name 2 worker:M-2:done:abc).json"
  # Finish the manager while its other-issue fallback is still held.
  rm "$CASE_DIR/hermes/hold-resume"
  wait_file "$dir/pending/$(manager_job_name 0 worker:M-1:pr-ready:abc).done"
  manager_event M-3 "$REPO"
  manager_wait_calls 4
  jq -se 'length==4 and .[3].resume=="session-1"' "$CASE_DIR/hermes/calls"
  grep -F M-3 "$CASE_DIR/hermes/prompt-4"
  if grep -F 'must wait for fallback' "$CASE_DIR/hermes/prompt-4"; then return 1; fi
  wait_file "$dir/pending/$(manager_job_name 3 worker:M-3:pr-ready:abc).done"
  rm "$CASE_DIR/hermes/hold-worker"
  manager_wait_calls 5
  touch "$DV_HOME/stop"; wait "$watcher"
  grep -F 'must wait for fallback' "$CASE_DIR/hermes/prompt-5"
  grep -F '"route": "fallback"' "$CASE_DIR/hermes/prompt-5"
  test ! -f "$CASE_DIR/hermes/overlap"
  test ! -f "$CASE_DIR/hermes/over-capacity"
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
  manager_watch_until 2
  jq -se 'length==2 and .[1].resume=="session-1"' "$CASE_DIR/hermes/calls"
  test ! -f "$CASE_DIR/hermes/overlap"
  test "$(find "$DV_HOME/managers" -path '*/pending/*.json' | wc -l | tr -d ' ')" = 0
  grep -F 'M-1' "$CASE_DIR/hermes/prompt-2"
  grep -F 'M-2' "$CASE_DIR/hermes/prompt-2"
  if grep -F '장기 실행 관리자' "$CASE_DIR/hermes/prompt-2"; then return 1; fi
}
case_manager_parallel() {
  manager_setup
  dv manager start "$REPO"
  local first=$REPO
  repo other; dv manager start "$REPO"
  manager_event M-1 "$first"; manager_event M-2 "$REPO"; manager_event M-3 "$first"
  export HERMES_HOLD=1 DV_MAX_WORKERS=1
  manager_watch_until 4
  test -f "$CASE_DIR/hermes/parallel"
  test ! -f "$CASE_DIR/hermes/overlap"
  test ! -f "$CASE_DIR/hermes/over-capacity"
}
case_manager_fallback() {
  manager_setup
  dv manager start "$REPO"
  touch "$CASE_DIR/hermes/fail-resume"
  manager_event M-1 "$REPO"; manager_event M-2 "$REPO"
  manager_watch_until 2
  jq -se 'length==3 and .[1].resume=="session-1" and .[2].resume==""' "$CASE_DIR/hermes/calls"
  jq -e '.session_id=="session-2"' "$(manager_meta)"
  grep -F '장기 실행 관리자' "$CASE_DIR/hermes/prompt-3"
  grep -F 'M-1' "$CASE_DIR/hermes/prompt-3"
  grep -F 'M-2' "$CASE_DIR/hermes/prompt-3"
  grep -F 'resume_failed' "$(dirname "$(manager_meta)")/events.log"
  rm "$DV_HOME/stop"
  manager_event M-3 "$REPO"
  manager_watch_until 3
  jq -se 'length==4 and .[3].resume=="session-2"' "$CASE_DIR/hermes/calls"
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
manager_remote_repo_case() {
  manager_setup
  git -C "$REPO" remote add origin https://github.com/example/project.git
  dv manager start "$REPO"
  export SSH_MANAGER_REPO=$1
  local dir watcher
  dir=$(dirname "$(manager_meta)")
  test ! -d /Users/x/code/repo
  mkdir -p "$DV_HOME/submissions/M-1"
  jq -cn '{repo:"/Users/x/code/repo",host:"remote-box",status:"completed"}' > "$DV_HOME/submissions/M-1/task.json"
  # Hold either route so its durable queue record remains available to inspect.
  touch "$CASE_DIR/hermes/hold-resume" "$CASE_DIR/hermes/hold-worker"
  dv-kick pr-ready M-1 'remote checkout event' remote-box abc
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  manager_wait_calls 2
  if [ "$1" = success ]; then
    jq -e '.event.id=="remote-box:M-1:pr-ready:abc"' "$dir"/pending/*.json
    test "$(find "$DV_HOME/pending" -name '*.json' | wc -l | tr -d ' ')" = 0
    jq -se '.[1].resume=="session-1"' "$CASE_DIR/hermes/calls"
  else
    jq -e '.id=="remote-box:M-1:pr-ready:abc"' "$DV_HOME/pending/0.json"
    test "$(find "$dir/pending" -name '*.json' | wc -l | tr -d ' ')" = 0
    jq -se '.[1].resume==""' "$CASE_DIR/hermes/calls"
  fi
  # Even a failed lookup must reach SSH; returning the path happens to fall back too.
  test -f "$CASE_DIR/manager-origin-lookup"
  rm "$CASE_DIR/hermes/hold-resume" "$CASE_DIR/hermes/hold-worker"
  touch "$DV_HOME/stop"; wait "$watcher"
}
case_manager_remote_repo() { manager_remote_repo_case success; }
case_manager_remote_repo_failure() { manager_remote_repo_case failure; }
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
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & local watcher=$!
  manager_wait_calls 3
  touch "$DV_HOME/stop"; wait "$watcher"
  local dir
  dir=$(dirname "$(manager_meta)")
  test "$(find "$dir/failed" -name '*.json' | wc -l | tr -d ' ')" = 2
  jq -se 'length==3 and .[2].resume==""' "$CASE_DIR/hermes/calls"
  jq -se '[.[]|select(.kind=="event_handled")]|length==2 and all(.[]; .exit_code!=0)' "$dir/events.log"
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
case_manager_reused_issue() {
  manager_setup
  git -C "$REPO" remote add origin https://github.com/example/first.git
  dv manager start "$REPO"
  local first=$REPO
  repo second
  git -C "$REPO" remote add origin https://github.com/example/second.git
  dv manager start "$REPO"
  mkdir -p "$DV_HOME/submissions/M-1" "$DV_STATE/M-1"
  jq -cn --arg repo "$first" '{repo:$repo,host:"other-host",status:"completed",token:"old-award"}' > "$DV_HOME/submissions/M-1/task.json"
  jq -cn --arg repo "$REPO" --arg host "$DV_HOST" '{repo:$repo,host:$host}' > "$DV_STATE/M-1/meta"
  dv-kick pr-ready M-1 'reused ID on another host' "$DV_HOST" abc
  mkdir -p "$DV_HOME/submissions/M-2" "$DV_STATE/M-2"
  jq -cn --arg repo "$first" --arg host "$DV_HOST" '{repo:$repo,host:$host,status:"completed"}' > "$DV_HOME/submissions/M-2/task.json"
  jq -cn --arg repo "$REPO" --arg host "$DV_HOST" '{repo:$repo,host:$host}' > "$DV_STATE/M-2/meta"
  dv-kick pr-ready M-2 'same host, different repository' "$DV_HOST" def
  manager_watch_until 3
  jq -se 'length==3 and .[2].resume=="session-2"' "$CASE_DIR/hermes/calls"
  # A remote event whose host differs from the retained submission must use
  # the emitting host's metadata. These functions are read-only RPC stubs.
  (
    manager_functions
    DV_HOSTS=worker
    bid_limit() { shift; "$@"; }
    bid_rpc() { jq -cn '[{issue:"M-1",host:"worker",repo:"/remote/second"}]'; }
    ssh() { printf 'https://github.com/example/second.git\n'; }
    local event
    event=$(jq -cn '{issue:"M-1",host:"worker"}')
    test "$(manager_event_repo "$event")" = https://github.com/example/second.git
  )
}
case_manager_moved_checkout() {
  manager_setup
  git -C "$REPO" remote add origin https://github.com/example/movable.git
  dv manager start "$REPO"
  mv "$REPO" "$CASE_DIR/moved repo"
  REPO="$CASE_DIR/moved repo"
  dv manager start "$REPO"
  local root
  root=$(cd "$REPO" && pwd -P)
  jq -e --arg repo "$root" '.repo==$repo and .session_id=="session-1"' "$(manager_meta)"
  manager_event M-1 "$REPO"
  manager_watch_until 2
  jq -se --arg repo "$root" '.[1].resume=="session-1" and .[1].cwd==$repo and (.[1].args|index("--no-restore-cwd")!=null)' "$CASE_DIR/hermes/calls"
}
case_manager_stale_lock() {
  manager_setup
  dv manager start "$REPO"
  manager_functions
  local dir runner active=0 manager_pids='' pids=''
  dir=$(dirname "$(manager_meta)")
  touch "$CASE_DIR/hermes/hold-resume" "$dir/run.lock/keep"
  manager_event M-1 "$REPO"
  manager_enqueue "$(sed -n '1p' "$DV_HOME/kick.q")" "$CASE_DIR/brief" 0
  # Give the fake turn its own process group, like a service control group.
  set -m
  manager_dispatch
  runner=$!
  set +m
  manager_wait_calls 2
  wait_file "$CASE_DIR/hermes/active-session-1"
  for _ in {1..200}; do
    [ -f "$CASE_DIR/hermes/lock" ] || break
    sleep 0.05
  done
  test ! -f "$CASE_DIR/hermes/lock"
  test "$(cat "$dir/run.lock/pid")" = "$runner"
  manager_dispatch
  test "$(cat "$dir/run.lock/pid")" = "$runner"
  test "$(wc -l < "$CASE_DIR/hermes/calls" | tr -d ' ')" = 2
  kill -KILL -- "-$runner"
  wait "$runner" 2>/dev/null || true
  if kill -0 "$runner" 2>/dev/null; then return 1; fi
  test "$(cat "$dir/run.lock/pid")" = "$runner"
  test -f "$dir/pending/$(manager_job_name 0 worker:M-1:pr-ready:abc).json"
  # During the handoff a live claimant protects even a dead parent owner.
  printf '%s\n' "$$" > "$dir/run.lock/claim"
  manager_dispatch
  test "$(cat "$dir/run.lock/pid")" = "$runner"
  jq -se 'all(.[]; .kind!="stale_lock_cleared")' "$dir/events.log"
  printf '%s\n' "$runner" > "$dir/run.lock/claim"
  # SIGKILL cannot release the stub's bookkeeping marker either.
  rm "$CASE_DIR/hermes/hold-resume" "$CASE_DIR/hermes/active-session-1"
  manager_event M-2 "$REPO"
  manager_enqueue "$(sed -n '2p' "$DV_HOME/kick.q")" "$CASE_DIR/brief" 1
  manager_dispatch
  manager_wait_calls 3
  wait "$!"
  jq -se 'length==3 and .[1].resume=="session-1" and .[2].resume=="session-1"' "$CASE_DIR/hermes/calls"
  grep -F M-1 "$CASE_DIR/hermes/prompt-3"
  grep -F M-2 "$CASE_DIR/hermes/prompt-3"
  test -f "$dir/pending/$(manager_job_name 0 worker:M-1:pr-ready:abc).done"
  test -f "$dir/pending/$(manager_job_name 1 worker:M-2:pr-ready:abc).done"
  jq -se --arg pid "$runner" '[.[]|select(.kind=="stale_lock_cleared")]|length==1 and .[0].pid==$pid' "$dir/events.log"
  jq -se '[.[]|select(.kind=="event_handled")]|length==2 and all(.[]; .route=="manager" and .exit_code==0)' "$dir/events.log"
  test -f "$dir/run.lock/keep"
  test ! -f "$dir/run.lock/pid"
  test ! -f "$CASE_DIR/hermes/overlap"
}
case_manager_surviving_runner() {
  manager_setup
  dv manager start "$REPO"
  manager_functions
  local dir runner active=0 manager_pids='' pids=''
  dir=$(dirname "$(manager_meta)")
  touch "$CASE_DIR/hermes/hold-resume"
  manager_event M-1 "$REPO"
  manager_enqueue "$(sed -n '1p' "$DV_HOME/kick.q")" "$CASE_DIR/brief" 0
  manager_dispatch
  runner=$!
  manager_wait_calls 2
  # Kill only the outer dv process: the runner subshell and Hermes survive.
  kill -KILL "$runner"
  wait "$runner" 2>/dev/null || true
  manager_event M-2 "$REPO"
  manager_enqueue "$(sed -n '2p' "$DV_HOME/kick.q")" "$CASE_DIR/brief" 1
  manager_dispatch
  test "$(cat "$dir/run.lock/pid")" = "$runner"
  kill -0 "$(cat "$dir/run.lock/claim")"
  test "$(wc -l < "$CASE_DIR/hermes/calls" | tr -d ' ')" = 2
  jq -se 'all(.[]; .kind!="stale_lock_cleared")' "$dir/events.log"
  rm "$CASE_DIR/hermes/hold-resume"
  wait_file "$dir/pending/$(manager_job_name 0 worker:M-1:pr-ready:abc).done"
  for _ in {1..200}; do
    [ -f "$dir/run.lock/pid" ] || break
    sleep 0.05
  done
  test ! -f "$dir/run.lock/pid"
  manager_dispatch
  manager_wait_calls 3
  wait "$!"
  jq -se 'length==3 and .[1].resume=="session-1" and .[2].resume=="session-1"' "$CASE_DIR/hermes/calls"
  test -f "$dir/pending/$(manager_job_name 1 worker:M-2:pr-ready:abc).done"
  test ! -f "$CASE_DIR/hermes/overlap"
}
case_manager_runner_ownership() {
  manager_setup
  dv manager start "$REPO"
  local dir job
  dir=$(dirname "$(manager_meta)"); job="$dir/pending/00000000000000000001.json"
  jq -cn --arg prompt "$CASE_DIR/brief" '{prompt:$prompt,event:{id:"unowned"}}' > "$job"
  if dv _manager-run "$dir" "$job"; then return 1; fi
  test -f "$job"
  test ! -f "$dir/run.lock/pid"
  printf '1\n' > "$dir/run.lock/pid"
  printf '%s\n' "$job" > "$dir/run.lock/job"
  if dv _manager-run "$dir" "$job"; then return 1; fi
  test "$(cat "$dir/run.lock/pid")" = 1
  printf '%s\n' "$$" > "$dir/run.lock/pid"
  printf '%s\n' "$dir/pending/another.json" > "$dir/run.lock/job"
  if dv _manager-run "$dir" "$job"; then return 1; fi
  test "$(cat "$dir/run.lock/pid")" = "$$"
  printf '%s\n' "$job" > "$dir/run.lock/job"
  printf 'other-child\n' > "$dir/run.lock/claim"
  if dv _manager-run "$dir" "$job"; then return 1; fi
  test "$(cat "$dir/run.lock/claim")" = other-child
  test "$(cat "$dir/run.lock/pid")" = "$$"
  test -f "$job"
  test "$(wc -l < "$CASE_DIR/hermes/calls" | tr -d ' ')" = 1
}
# A rotate hook (exit 10) retires the manager session after a successful turn;
# the next event starts a fresh session with the role prompt (devflow#326).
case_manager_rotate() {
  manager_setup
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s/rotate-checks"\nexit 10\n' "$CASE_DIR" > "$CASE_DIR/rotate"
  chmod +x "$CASE_DIR/rotate"
  dv manager start "$REPO"
  export DV_MANAGER_ROTATE_CHECK="$CASE_DIR/rotate"
  manager_event M-1 "$REPO"
  manager_watch_until 2
  rm -f "$DV_HOME/stop"
  local dir
  dir=$(dirname "$(manager_meta)")
  jq -e '.session_id==null and .rotated_from=="session-1"' "$dir/meta.json"
  jq -se 'any(.[]; .kind=="rotated" and .previous_session=="session-1")' "$dir/events.log"
  test "$(cat "$CASE_DIR/rotate-checks")" = session-1
  manager_event M-2 "$REPO"
  manager_watch_until 3
  jq -se '.[2].resume==""' "$CASE_DIR/hermes/calls"
  grep -F '장기 실행 관리자' "$CASE_DIR/hermes/prompt-3"
  # The fresh session is itself checked; this hook always rotates.
  jq -e '.session_id==null and .rotated_from=="session-2"' "$dir/meta.json"
}
case_manager_rotate_keep() {
  manager_setup
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE_DIR/rotate"; chmod +x "$CASE_DIR/rotate"
  dv manager start "$REPO"
  export DV_MANAGER_ROTATE_CHECK="$CASE_DIR/rotate"
  manager_event M-1 "$REPO"
  manager_watch_until 2
  local dir
  dir=$(dirname "$(manager_meta)")
  jq -e '.session_id=="session-1"' "$dir/meta.json"
  jq -se 'all(.[]; .kind!="rotated")' "$dir/events.log"
}
