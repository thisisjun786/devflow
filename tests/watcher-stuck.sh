#!/usr/bin/env bash
# DF-126: all queues and agents below live in disposable test directories.
manager_job_name() {
  local sequence=$1 id=$2
  printf '%020d-%s' "$sequence" "$(printf '%s' "$id" | cksum | awk '{print $1 "-" $2}')"
}
case_manager_collision() {
  manager_setup
  dv manager start "$REPO"
  local dir location=${1:-pending} stranger
  dir=$(dirname "$(manager_meta)")
  mkdir -p "$dir/$location"
  stranger="$dir/$location/00000000000000000000.json"
  jq -cn '{event:{id:"operator-note",issue:"NOTE-1",time:1},text:"keep this note"}' > "$stranger"
  cp "$stranger" "$CASE_DIR/stranger"
  manager_event M-1 "$REPO"; manager_event M-2 "$REPO"
  manager_watch_until 2
  test "$(cat "$DV_HOME/cursor")" = 2
  test ! -e "$stranger"
  local saved
  saved=$(find "$dir/conflict" -name '*.json' -type f)
  test -n "$saved"
  cmp "$CASE_DIR/stranger" "$saved"
  jq -se 'any(.[]; .kind=="queue_conflict" and .event_id=="worker:M-1:pr-ready:abc")' "$dir/events.log"
  grep -F queue_conflict "$DV_HOME/manager.log"
  test -f "$dir/pending/$(manager_job_name 0 worker:M-1:pr-ready:abc).done"
  grep -F M-2 "$CASE_DIR/hermes/prompt-2"
}
case_manager_fallback_collision() { case_manager_collision fallback; }
case_manager_hash_collision() {
  manager_setup
  dv manager start "$REPO"
  manager_event M-1 "$REPO"
  manager_functions
  local dir line job
  dir=$(dirname "$(manager_meta)"); line=$(cat "$DV_HOME/kick.q")
  job="$dir/pending/$(manager_job_name 0 worker:M-1:pr-ready:abc).json"
  jq -cn '{event:{id:"stranger"},text:"preserve me"}' > "$job"
  cp "$job" "$CASE_DIR/stranger"
  manager_enqueue "$line" "$CASE_DIR/brief" 0
  jq -e '.event.id=="worker:M-1:pr-ready:abc"' "$job"
  cmp "$CASE_DIR/stranger" "$(find "$dir/conflict" -name '*.json')"
  manager_enqueue "$line" "$CASE_DIR/brief" 0
  test "$(find "$dir/pending" -name '*.json' | wc -l | tr -d ' ')" = 1
}
case_manager_legacy_replay() {
  manager_setup
  dv manager start "$REPO"
  manager_event M-1 "$REPO"
  manager_functions
  local dir line location suffix job
  dir=$(dirname "$(manager_meta)"); line=$(cat "$DV_HOME/kick.q")
  for location in pending failed fallback; do
    mkdir -p "$dir/$location"
    for suffix in json 'done'; do
      [ "$location:$suffix" != failed:done ] || continue
      job="$dir/$location/00000000000000000000.$suffix"
      jq -cn --argjson event "$line" '{event:$event}' > "$job"
      manager_enqueue "$line" "$CASE_DIR/brief" 0
      test ! -e "$dir/pending/$(manager_job_name 0 worker:M-1:pr-ready:abc).json"
      rm "$job"
    done
  done
}
# Shell syntax in the fixture/assertion is deliberately literal.
# shellcheck disable=SC2016
case_manager_note() {
  manager_setup
  dv manager start "$REPO"
  local dir first second
  dir=$(dirname "$(manager_meta)")
  printf 'Operator context\n\nKeep "quotes" and `code`.\n' > "$CASE_DIR/note"
  first=$(dv manager note "$REPO" "$CASE_DIR/note")
  second=$(dv manager note "$REPO" "$CASE_DIR/note")
  test "$first" != "$second"
  case "$first" in "$dir/notices/note-"*.json) ;; *) return 1 ;; esac
  jq -e --rawfile note "$CASE_DIR/note" '.kind=="operator_note" and .text==$note' "$first"
  if dv manager note "$REPO" "$CASE_DIR/missing"; then return 1; fi
  manager_watch_until 2
  test -f "${first%.json}.done"; test -f "${second%.json}.done"
  grep -F 'Operator context' "$CASE_DIR/hermes/prompt-2"
  test ! -s "$DV_HOME/kick.q"
  dv manager stop "$REPO"
  if dv manager note "$REPO" "$CASE_DIR/note"; then return 1; fi
}
case_manager_pool_independent() {
  manager_setup
  export DV_MAX_WORKERS=4
  dv manager start "$REPO"
  touch "$CASE_DIR/hermes/hold-worker" "$CASE_DIR/hermes/hold-resume"
  local n watcher
  for n in 1 2 3 4 5; do dv-kick blocked "POOL-$n" '' unknown h; done
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  manager_wait_calls 5
  manager_event M-1 "$REPO"
  manager_wait_calls 6
  jq -se 'length==6 and .[5].resume=="session-1" and
    ([.[]|select(.args|index("--pass-session-id")|not)]|length)==4' "$CASE_DIR/hermes/calls"
  test ! -f "$CASE_DIR/hermes/overlap"
  rm "$CASE_DIR/hermes/hold-resume" "$CASE_DIR/hermes/hold-worker"
  touch "$DV_HOME/stop"; wait "$watcher"
}
case_watch_capacity_eight() {
  watch_fixture
  export DV_MAX_WORKERS=8 DV_WORKER_GATE=1
  local n watcher
  for n in 1 2 3 4 5 6 7 8 9; do dv-kick blocked "POOL-$n" '' unknown h; done
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  for _ in {1..150}; do
    [ "$(find "$DV_HOME/workers" -name '*.started' 2>/dev/null | wc -l | tr -d ' ')" != 8 ] || break
    sleep 0.05
  done
  test "$(find "$DV_HOME/workers" -name '*.started' | wc -l | tr -d ' ')" = 8
  test "$(cat "$DV_HOME/cursor")" = 9
  touch "$DV_HOME/release"
  wait_seen 9
  touch "$DV_HOME/stop"; wait "$watcher"
}
case_watch_stuck() {
  manager_setup
  export DV_STALL_AFTER=1
  dv manager start "$REPO"
  # Fail only fixture queue publication, leaving the watcher running to retry.
  cat > "$DV_CONFIG" <<'CONFIG'
mv() {
  case "${2:-}" in
    "$DV_HOME"/managers/*/pending/*.json)
      [ ! -f "$DV_HOME/fail-publish" ] || return 1 ;;
  esac
  command mv "$@"
}
CONFIG
  touch "$DV_HOME/fail-publish"
  manager_event M-1 "$REPO"
  local watcher
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  for _ in {1..150}; do
    if jq -se 'any(.[]; .kind=="watcher-stuck")' "$DV_HOME/events.log" >/dev/null; then break; fi
    sleep 0.05
  done
  jq -se '[.[]|select(.kind=="watcher-stuck")]|length==1 and
    (.[0].message|contains("line 1") and contains("manager_enqueue"))' "$DV_HOME/events.log"
  grep -F watcher-stuck "$CASE_DIR/watch.log"
  sleep 1.1
  jq -se '[.[]|select(.kind=="watcher-stuck")]|length==1' "$DV_HOME/events.log"
  rm "$DV_HOME/fail-publish"
  manager_wait_calls 2
  # The alarm is an ordinary durable event, processed after the blockage clears.
  for _ in {1..100}; do
    [ "$(cat "$DV_HOME/cursor" 2>/dev/null)" != 2 ] || break
    sleep 0.05
  done
  test "$(cat "$DV_HOME/cursor")" = 2
  touch "$DV_HOME/fail-publish"
  manager_event M-2 "$REPO"
  for _ in {1..150}; do
    if jq -se '[.[]|select(.kind=="watcher-stuck")]|length==2' "$DV_HOME/events.log" >/dev/null; then break; fi
    sleep 0.05
  done
  jq -se '[.[]|select(.kind=="watcher-stuck")]|length==2 and .[1].issue=="WATCHER" and
    (.[1].message|contains("line 3"))' "$DV_HOME/events.log"
  rm "$DV_HOME/fail-publish"
  for _ in {1..100}; do
    [ "$(cat "$DV_HOME/cursor")" != 4 ] || break
    sleep 0.05
  done
  test "$(cat "$DV_HOME/cursor")" = 4
  sleep 1.1
  jq -se '[.[]|select(.kind=="watcher-stuck")]|length==2' "$DV_HOME/events.log"
  touch "$DV_HOME/stop"; wait "$watcher"
}
case_manager_reserved_collision() {
  manager_setup
  dv manager start "$REPO"
  manager_event M-1 "$REPO"
  manager_functions
  local dir line job
  dir=$(dirname "$(manager_meta)"); line=$(cat "$DV_HOME/kick.q")
  job="$dir/pending/$(manager_job_name 0 worker:M-1:pr-ready:abc).json"
  jq -cn '{event:{id:"running-stranger"}}' > "$job"
  cp "$job" "$CASE_DIR/stranger"
  printf '%s\n' "$$" > "$dir/run.lock/pid"
  jq -cn --arg job "$job" '[{job:$job}]' > "$dir/run.lock/batch.json"
  manager_enqueue "$line" "$CASE_DIR/brief" 0
  cmp "$CASE_DIR/stranger" "$job"
  cmp "$CASE_DIR/stranger" "$(find "$dir/conflict" -name '*.json')"
  jq -e '.event.id=="worker:M-1:pr-ready:abc"' "${job%.json}-1.json"
  manager_enqueue "$line" "$CASE_DIR/brief" 0
  test "$(find "$dir/pending" -name '*.json' | wc -l | tr -d ' ')" = 2
  # Completing the stranger must not hide the suffixed incoming job on replay.
  mv "$job" "${job%.json}.done"
  manager_unlock "$dir"
  manager_enqueue "$line" "$CASE_DIR/brief" 0
  test "$(find "$dir/pending" -name '*.json' | wc -l | tr -d ' ')" = 1
}
case_manager_note_busy() {
  manager_setup
  dv manager start "$REPO"
  manager_event M-1 "$REPO"
  touch "$CASE_DIR/hermes/hold-resume"
  local watcher first second
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  manager_wait_calls 2
  printf 'Next turn only\n' > "$CASE_DIR/note"
  dv manager note "$REPO" "$CASE_DIR/note" > "$CASE_DIR/note-1" & first=$!
  dv manager note "$REPO" "$CASE_DIR/note" > "$CASE_DIR/note-2" & second=$!
  wait "$first"; wait "$second"
  test "$(cat "$CASE_DIR/note-1")" != "$(cat "$CASE_DIR/note-2")"
  test "$(wc -l < "$CASE_DIR/hermes/calls" | tr -d ' ')" = 2
  if grep -F 'Next turn only' "$CASE_DIR/hermes/prompt-2"; then return 1; fi
  rm "$CASE_DIR/hermes/hold-resume"
  manager_wait_calls 3
  touch "$DV_HOME/stop"; wait "$watcher"
  grep -F 'Next turn only' "$CASE_DIR/hermes/prompt-3"
  test ! -f "$CASE_DIR/hermes/overlap"
}
case_watch_stuck_route() {
  watch_fixture
  export DV_STALL_AFTER=1 WATCH_FAULT=${1:-qa}
  touch "$DV_HOME/fail-route"
  if [ "$WATCH_FAULT" = empty ]; then printf '\n' > "$DV_HOME/kick.q"
  else dv-kick landed W-1 test unknown h; fi
  local watcher reason
  case "$WATCH_FAULT" in
    qa) reason=qa_enqueue ;; bid) reason=bid_event ;; stack) reason=stack_landed_event ;;
    empty) reason='empty queue line' ;; worker) reason='worker queue persistence' ;;
  esac
  BASH_ENV="$ROOT/tests/fixtures/watch-faults" dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  for _ in {1..150}; do
    if [ -f "$DV_HOME/events.log" ] && jq -se 'any(.[]; .kind=="watcher-stuck")' "$DV_HOME/events.log" >/dev/null; then break; fi
    sleep 0.05
  done
  jq -se --arg reason "$reason" '[.[]|select(.kind=="watcher-stuck")]|length==1 and .[0].issue=="WATCHER" and
    (.[0].message|contains("line 1") and contains($reason))' "$DV_HOME/events.log"
  grep -F "$reason" "$CASE_DIR/watch.log"
  rm "$DV_HOME/fail-route"
  if [ "$WATCH_FAULT" = empty ]; then
    sed '1s/^$/{"id":"empty-repaired","kind":"probe","issue":"W-1","host":"unknown","head":"","time":1}/' "$DV_HOME/kick.q" > "$CASE_DIR/repaired"
    mv "$CASE_DIR/repaired" "$DV_HOME/kick.q"
  fi
  wait_seen 2
  sleep 1.1
  jq -se '[.[]|select(.kind=="watcher-stuck")]|length==1' "$DV_HOME/events.log"
  touch "$DV_HOME/stop"; wait "$watcher"
}
case_watch_stuck_bid() { case_watch_stuck_route bid; }
case_watch_stack_background_failure() {
  watch_fixture
  export WATCH_FAULT=stack DV_RECONCILE_INTERVAL=1 DV_STALL_AFTER=1
  touch "$DV_HOME/fail-route"
  dv-kick landed W-1 test unknown h
  BASH_ENV="$ROOT/tests/fixtures/watch-faults" dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  # Stack publication now runs in the bounded background reconciliation.
  # Its failure must be logged/retried without holding the event cursor.
  wait_seen 1
  for _ in {1..100}; do
    if grep -q 'reconcile host=.*failed' "$DV_HOME/reconcile.log"; then break; fi
    sleep 0.05
  done
  grep 'reconcile host=.*failed' "$DV_HOME/reconcile.log"
  jq -se 'all(.[]; .kind!="watcher-stuck")' "$DV_HOME/events.log"
  rm "$DV_HOME/fail-route"
  wait_file "$DV_HOME/stack-route-ok"
  test "$(cat "$DV_HOME/cursor")" = 1
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
}
case_watch_stuck_empty() { case_watch_stuck_route empty; }
case_watch_stuck_worker() { case_watch_stuck_route worker; }
case_manager_real_conflict() {
  manager_setup
  dv manager start "$REPO"
  manager_event OLD "$REPO"
  manager_functions
  local dir old location=${1:-fallback} source_name
  dir=$(dirname "$(manager_meta)"); old=$(cat "$DV_HOME/kick.q")
  manager_enqueue "$old" "$CASE_DIR/brief" 0
  source_name=$(manager_job_name 0 worker:OLD:pr-ready:abc)
  mkdir -p "$dir/$location"
  mv "$dir/pending/$source_name.json" "$dir/$location/00000000000000000000.json"
  # Legacy work survives a reset cursor even if that line now names a new job.
  : > "$DV_HOME/kick.q"
  manager_event NEW "$REPO"
  manager_watch_until 2
  jq -se '[.[]|select(.kind=="event_handled")]|length==2 and
    ([.[]|.event_id]|sort)==["worker:NEW:pr-ready:abc","worker:OLD:pr-ready:abc"]' "$dir/events.log"
  test "$(cat "$DV_HOME/cursor")" = 1
  # Replaying recovery after completed receipts cannot dispatch OLD twice.
  manager_conflict_recover
  test "$(find "$dir/pending" "$dir/fallback" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" = 0
}
case_manager_real_pending_conflict() { case_manager_real_conflict pending; }
case_manager_conflict_restart() {
  manager_setup
  dv manager start "$REPO"
  manager_event OLD "$REPO"
  manager_functions
  local dir old line source_name
  dir=$(dirname "$(manager_meta)"); old=$(cat "$DV_HOME/kick.q")
  manager_enqueue "$old" "$CASE_DIR/brief" 0
  source_name=$(manager_job_name 0 worker:OLD:pr-ready:abc)
  mkdir -p "$dir/fallback"
  mv "$dir/pending/$source_name.json" "$dir/fallback/00000000000000000000.json"
  : > "$DV_HOME/kick.q"
  manager_event NEW "$REPO"
  line=$(cat "$DV_HOME/kick.q")
  manager_enqueue "$line" "$CASE_DIR/brief" 0
  manager_conflict_recover
  local marker
  for marker in "$dir"/conflict/*/requeued; do
    # Model a crash after publishing the job, before acknowledging recovery.
    mv "$marker" "${marker%/requeued}/requeue"
  done
  # Restart before fallback restoration or cursor save.
  manager_watch_until 2
  jq -se '[.[]|select(.kind=="event_handled")]|length==2 and
    ([.[]|.event_id]|sort)==["worker:NEW:pr-ready:abc","worker:OLD:pr-ready:abc"]' "$dir/events.log"
  for marker in "$dir"/conflict/*/requeued; do mv "$marker" "${marker%/requeued}/requeue"; done
  manager_conflict_recover
  test "$(find "$dir/pending" "$dir/fallback" -name '*.json' | wc -l | tr -d ' ')" = 0
}
case_manager_reexec() {
  manager_setup
  update_fixture
  export DV_WORKER_CMD='' DV_MAX_WORKERS=1
  trap 'rm -f "$CASE_DIR/hermes/hold-resume" "$CASE_DIR/hermes/hold-worker"; watcher_teardown' EXIT
  dv manager start "$REPO"
  touch "$CASE_DIR/hermes/hold-resume"
  manager_event M-1 "$REPO"
  "$UPDATE_ROOT/bin/dv-watch" > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  manager_wait_calls 2
  update_wait_idle
  local dir manager_pid rc=0
  dir=$(dirname "$(manager_meta)")
  manager_pid=$(cat "$dir/run.lock/pid")
  update_publish
  git -C "$UPDATE_ROOT" fetch -q origin
  git -C "$UPDATE_ROOT" merge --ff-only origin/main > /dev/null
  update_wait_watcher "$UPDATE_NEW"
  test "$(cat "$dir/run.lock/pid")" = "$manager_pid"
  test "$(wc -l < "$CASE_DIR/hermes/calls" | tr -d ' ')" = 2
  touch "$DV_HOME/stop"
  sleep 1
  # Shutdown after exec must still wait for its existing manager child.
  if ! kill -0 "$watcher" 2>/dev/null; then
    printf 'watcher exited before its reserved manager finished\n' >&2
    rc=1
  fi
  rm "$CASE_DIR/hermes/hold-resume"
  wait "$watcher"; watcher=''
  wait_file "$dir/pending/$(manager_job_name 0 worker:M-1:pr-ready:abc).done"
  test ! -f "$CASE_DIR/hermes/overlap"
  test ! -f "$dir/run.lock/pid"
  return "$rc"
}
