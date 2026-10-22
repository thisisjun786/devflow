#!/usr/bin/env bash
# Reliability cases use disposable repositories and the normal gh/worker stubs.
case_watcher_teardown_waiter() {
  local fixture="$CASE_DIR/teardown" pid stopped=false
  mkdir -p "$fixture/state/P-1" "$fixture/home"
  cat > "$CASE_DIR/late-waiter" <<'WAITER'
#!/usr/bin/env bash
trap 'sleep 0.3; touch "$CASE_DIR/waiter-stopped"; exit 0' TERM
touch "$CASE_DIR/waiter-ready"
while :; do sleep 0.1; done
WAITER
  bash "$CASE_DIR/late-waiter" & pid=$!
  printf '%s\n' "$pid" > "$fixture/state/P-1/pr-wait.pid"
  wait_file "$CASE_DIR/waiter-ready"
  CASE_DIR="$fixture" DV_STATE="$fixture/state" DV_HOME="$fixture/home" DV_TEST_KEEP=0 watcher_teardown
  [ ! -f "$CASE_DIR/waiter-stopped" ] || stopped=true
  wait "$pid" || true
  test "$stopped" = true
  test ! -e "$fixture"
}
watcher_teardown() {
  touch "$DV_HOME/release" "$DV_HOME/stop"
  local pid
  for pid in ${contenders:-} "${waiter:-}" "${watcher:-}"; do
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
    [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  done
  if [ -f "$DV_STATE/P-1/pr-wait.pid" ]; then
    pid=$(cat "$DV_STATE/P-1/pr-wait.pid")
    if [ "$pid" != "$$" ]; then
      teardown_stop_pidfile "$DV_STATE/P-1/pr-wait.pid" || return 1
    fi
  fi
  teardown
}
pr_fixture() {
  trap watcher_teardown EXIT
  repo waiter remote
  git -C "$REPO" checkout -qb feature
  mkdir "$DV_STATE/P-1"
  jq -n --arg repo "$REPO" --arg head "$(git -C "$REPO" rev-parse HEAD)" \
    '{issue:"P-1",repo:$repo,worktree:$repo,branch:"feature",base:"main",slug:"waiter",host:"test-host",agent:"codex",started:1,status:"pr",head:$head,start_head:$head}' > "$DV_STATE/P-1/meta"
  printf '{"url":"https://github.com/test/repo/pull/1"}\n' > "$DV_STATE/P-1/pr.json"
  # The test driver stands in for a live worker; the safety net must not revive it.
  printf '%s\n' "$$" > "$DV_STATE/P-1/agent.pid"
}
watch_fixture() {
  trap watcher_teardown EXIT
  export DV_WORKER_CMD="$ROOT/tests/fixtures/worker" DV_WATCH_INTERVAL=0.1 DV_WORKER_RETRY=1 DV_HOSTS=''
}
wait_seen() {
  local count=$1
  for _ in {1..100}; do
    [ ! -f "$DV_HOME/seen" ] || [ "$(wc -l < "$DV_HOME/seen" | tr -d ' ')" != "$count" ] || return 0
    sleep 0.1
  done
  return 1
}
case_pr_late_checks() {
  pr_fixture
  printf '[]\n' > "$GH_STUB_DIR/checks"
  dv pr-wait P-1 > "$CASE_DIR/waiter.log" 2>&1 & waiter=$!
  wait_file "$GH_STUB_DIR/viewed"
  sleep 0.3
  test ! -f "$DV_STATE/P-1/pr-ready.json"
  printf '[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null}]\n' > "$GH_STUB_DIR/checks"
  sleep 1.2
  test ! -f "$DV_STATE/P-1/pr-ready.json"
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]\n' > "$GH_STUB_DIR/checks"
  wait_pr_ready P-1; wait "$waiter"; waiter=''
  jq -e '.green and .checks_exit==0' "$DV_STATE/P-1/pr-ready.json"
}
case_pr_wait_stale() {
  pr_fixture
  mkdir "$DV_STATE/P-1/.pr-wait"
  # A reaped child supplies a definitely dead PID, without assumptions about PID limits.
  true & local dead=$!; wait "$dead"
  touch "$DV_STATE/P-1/.pr-wait/pid-$dead"
  # A competing acquirer can also die after its candidate is nested by mv.
  mkdir "$DV_STATE/P-1/.pr-wait/.pr-wait.abandoned"
  touch "$DV_STATE/P-1/.pr-wait/.pr-wait.abandoned/pid-$dead"
  printf '%s\n' "$dead" > "$DV_STATE/P-1/pr-wait.pid"
  dv pr-wait P-1
  test -s "$DV_STATE/P-1/pr-ready.json"
  test ! -d "$DV_STATE/P-1/.pr-wait"
  # Upgrade from the old empty-directory lock is recoverable too.
  rm "$DV_STATE/P-1/pr-ready.json"
  mkdir "$DV_STATE/P-1/.pr-wait"
  dv pr-wait P-1
  test -s "$DV_STATE/P-1/pr-ready.json"
}
case_pr_wait_killed() {
  pr_fixture
  printf '[]\n' > "$GH_STUB_DIR/checks"
  dv pr-wait P-1 > "$CASE_DIR/waiter.log" 2>&1 & waiter=$!
  wait_file "$GH_STUB_DIR/viewed"
  kill -KILL "$waiter"; wait "$waiter" 2>/dev/null || true; waiter=''
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]\n' > "$GH_STUB_DIR/checks"
  dv pr-wait P-1
  test -s "$DV_STATE/P-1/pr-ready.json"
  test ! -d "$DV_STATE/P-1/.pr-wait"
}
case_pr_wait_live() {
  pr_fixture
  mkdir "$DV_STATE/P-1/.pr-wait"
  touch "$DV_STATE/P-1/.pr-wait/pid-$$"
  printf '%s\n' "$$" > "$DV_STATE/P-1/pr-wait.pid"
  dv pr-wait P-1
  test ! -f "$GH_STUB_DIR/viewed"
  test -f "$DV_STATE/P-1/.pr-wait/pid-$$"
  rm "$DV_STATE/P-1/.pr-wait/pid-$$"
  dv pr-wait P-1
  test ! -f "$GH_STUB_DIR/viewed"
  # Do not let teardown signal the test runner itself.
  rm "$DV_STATE/P-1/pr-wait.pid"
}
case_pr_wait_detached() {
  pr_fixture
  if [ "${1:-}" = fallback ]; then
    cat > "$CASE_DIR/no-setsid" <<'STUB'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = setsid ]; then return 1; fi
  builtin command "$@"
}
STUB
    export BASH_ENV="$CASE_DIR/no-setsid"
  fi
  printf '[]\n' > "$GH_STUB_DIR/checks"
  dv pr P-1
  wait_file "$GH_STUB_DIR/viewed"
  waiter=$(cat "$DV_STATE/P-1/pr-wait.pid")
  kill -0 "$waiter"
  test "$(ps -o pgid= -p "$waiter" | tr -d ' ')" = "$waiter"
  test "$(ps -o pgid= -p "$$" | tr -d ' ')" != "$waiter"
  if [ "${1:-}" != fallback ] && command -v setsid >/dev/null; then
    test "$(ps -o sid= -p "$waiter" | tr -d ' ')" = "$waiter"
    test "$(ps -o sid= -p "$$" | tr -d ' ')" != "$waiter"
  fi
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]\n' > "$GH_STUB_DIR/checks"
  wait_pr_ready P-1; waiter=''
}
case_pr_wait_fallback() { case_pr_wait_detached fallback; }
case_pr_wait_concurrent() {
  pr_fixture
  printf '[]\n' > "$GH_STUB_DIR/checks"
  mkdir "$DV_STATE/P-1/.pr-wait"
  contenders=''
  local n pid
  for n in {1..8}; do
    dv pr-wait P-1 > "$CASE_DIR/contender-$n.log" 2>&1 & contenders="$contenders $!"
  done
  wait_file "$GH_STUB_DIR/viewed"
  sleep 0.3
  test "$(find "$DV_STATE/P-1/.pr-wait" -name 'pid-*' | wc -l | tr -d ' ')" = 1
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]\n' > "$GH_STUB_DIR/checks"
  for pid in $contenders; do wait "$pid"; done
  contenders=''
  test ! -s "$DV_HOME/kick.q"
  test ! -d "$DV_STATE/P-1/.pr-wait"
}
case_pr_wait_head() {
  pr_fixture
  printf '[]\n' > "$GH_STUB_DIR/checks"
  git -C "$REPO" rev-parse HEAD > "$GH_STUB_DIR/head"
  dv pr-wait P-1 > "$CASE_DIR/waiter.log" 2>&1 & waiter=$!
  wait_file "$GH_STUB_DIR/viewed"
  git -C "$REPO" commit --allow-empty -qm correction
  local head
  head=$(git -C "$REPO" rev-parse HEAD)
  jq --arg head "$head" '.head=$head' "$DV_STATE/P-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/P-1/meta"
  # A completed rollup for the old head cannot ready the correction.
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]\n' > "$GH_STUB_DIR/checks"
  sleep 1.2
  test ! -f "$DV_STATE/P-1/pr-ready.json"
  printf '%s\n' "$head" > "$GH_STUB_DIR/head"
  wait_pr_ready P-1; wait "$waiter"; waiter=''
  jq -e --arg head "$head" '.green and .head==$head' "$DV_STATE/P-1/pr-ready.json"
}
case_pr_wait_failed_checks() {
  pr_fixture
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"StatusContext","state":"ERROR"}]\n' > "$GH_STUB_DIR/checks"
  dv pr-wait P-1
  jq -e '(.green|not) and (.review_timed_out|not) and .ci_rounds==1' "$DV_STATE/P-1/pr-ready.json"
  jq -e '.status=="pr"' "$DV_STATE/P-1/meta"
}
case_watch_retry() {
  watch_fixture
  export DV_WORKER_FAIL_ONCE=1
  dv-kick 'done' RETRY-1 '' test h
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_seen 1
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  test "$(find "$DV_HOME/workers" -name '*.started' | wc -l | tr -d ' ')" = 2
  test "$(find "$DV_HOME/workers" -name '*.finished' | wc -l | tr -d ' ')" = 1
}
case_watch_retry_restart() {
  watch_fixture
  export DV_WORKER_FAIL_ONCE=1 DV_WORKER_RETRY=2
  dv-kick 'done' RETRY-1 '' test h
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  for _ in {1..100}; do [ ! -d "$DV_HOME/failed-once" ] || break; sleep 0.1; done
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  test ! -s "$DV_HOME/seen"
  rm "$DV_HOME/stop"
  dv-watch >> "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_seen 1
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  test "$(find "$DV_HOME/workers" -name '*.finished' | wc -l | tr -d ' ')" = 1
}
case_watch_inflight_replay() {
  watch_fixture
  export DV_WORKER_GATE=1
  dv-kick 'done' REPLAY-1 '' test h
  dv-kick 'done' REPLAY-1 '' test h
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  for _ in {1..100}; do
    [ ! -f "$DV_HOME/cursor" ] || [ "$(cat "$DV_HOME/cursor")" != 2 ] || break
    sleep 0.1
  done
  test ! -s "$DV_HOME/seen"
  # Queue persistence precedes dispatch. Observe the child actually starting
  # before counting it, rather than racing the watcher after cursor advance.
  for _ in {1..100}; do
    [ "$(find "$DV_HOME/workers" -name '*.started' | wc -l | tr -d ' ')" = 0 ] || break
    sleep 0.1
  done
  test "$(find "$DV_HOME/workers" -name '*.started' | wc -l | tr -d ' ')" = 1
  touch "$DV_HOME/release"
  wait_seen 1
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  test "$(find "$DV_HOME/workers" -name '*.started' | wc -l | tr -d ' ')" = 1
}
case_watch_killed() {
  watch_fixture
  export DV_WORKER_GATE=1
  dv-kick 'done' REPLAY-1 '' test h
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_file "$DV_HOME/pending/0.pid"
  kill -KILL "$watcher"; wait "$watcher" 2>/dev/null || true; watcher=''
  dv-watch >> "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  sleep 0.3
  test "$(find "$DV_HOME/workers" -name '*.started' | wc -l | tr -d ' ')" = 1
  touch "$DV_HOME/release"
  wait_seen 1
  test "$(find "$DV_HOME/workers" -name '*.started' | wc -l | tr -d ' ')" = 1
}
case_reconcile_delivery() {
  watch_fixture
  export DV_HOSTS=test-box DV_RECONCILE_INTERVAL=1
  printf '[{"issue":"DONE-1","status":"done","head":"h"},{"issue":"PR-1","status":"pr","done_at":1,"head":"h","done_head":"h"},{"issue":"READY-1","status":"ready","done_at":1,"head":"h","done_head":"h"},{"issue":"PR-2","status":"pr","head":"h"},{"issue":"READY-2","status":"ready","head":"h"},{"issue":"RUN-1","status":"running","done_at":1,"head":"h"}]\n' > "$CASE_DIR/remote-status"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_seen 3
  sleep 1.2
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  jq -se '[.[]|select(.kind=="done")|.issue]|sort==["DONE-1","PR-1","READY-1"]' "$DV_HOME/kick.q"
}
wait_seen_id() {
  local id=$1
  for _ in {1..100}; do
    if grep -Fxq -- "$id" "$DV_HOME/seen" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  printf 'Timed out waiting for seen ID: %s\n' "$id" >&2
  return 1
}
case_reconcile_corrected_head() {
  pr_fixture; watch_fixture
  export DV_HOSTS="$DV_HOST" DV_RECONCILE_INTERVAL=1
  local head_a head_b phase probe
  head_a=$(git -C "$REPO" rev-parse HEAD)
  dv pr-wait P-1 --foreground > /dev/null
  dv pr-wait P-1 --foreground --review-handled > /dev/null
  dv 'done' P-1 --note 'Original A complete'
  git -C "$REPO" commit --allow-empty -qm correction
  head_b=$(git -C "$REPO" rev-parse HEAD)
  printf '[]\n' > "$GH_STUB_DIR/checks"
  dv pr P-1
  wait_file "$GH_STUB_DIR/viewed"
  jq -e --arg head "$head_a" '.head==$head' "$DV_STATE/P-1/done.json"
  jq -e --arg head "$head_b" '.head==$head and .status=="pr" and .done_at!=null' "$DV_STATE/P-1/meta"
  # Keeping the historical completion timestamp must not consume a bid slot.
  bidding_functions
  test "$(bid_active)" = 0
  for phase in pr ready; do
    if [ "$phase" = ready ]; then
      printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]\n' > "$GH_STUB_DIR/checks"
      wait_pr_ready P-1
      jq -e '.status=="pr"' "$DV_STATE/P-1/meta"
    fi
    # The queue is consumed only after startup reconciliation. Seeing this
    # marker proves that the safety net ran before the negative assertion.
    probe="$DV_HOST:SYNC-$phase:probe:$head_b"
    dv-kick probe "SYNC-$phase" '' "$DV_HOST" "$head_b"
    rm -f "$DV_HOME/stop"
    dv-watch >> "$CASE_DIR/watch.log" 2>&1 & watcher=$!
    wait_seen_id "$probe"
    touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
    printf 'No premature done for B while status=%s\n' "$phase"
    jq -se --arg head "$head_b" 'all(.[]; .kind!="done" or .head!=$head)' "$DV_HOME/kick.q"
  done
  dv 'done' P-1 --note 'Correction B complete'
  rm "$DV_HOME/stop"
  dv-watch >> "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_seen_id "$DV_HOST:P-1:done:$head_b"
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  jq -se --arg head "$head_b" '[.[]|select(.kind=="done" and .head==$head)] | length==1 and (.[0].message|endswith("Correction B complete"))' "$DV_HOME/kick.q"
  grep -l 'Correction B complete' "$DV_HOME/workers/"*.log
  dv status --json | jq -e --arg head "$head_b" '.[0].done_head==$head and .[0].head==$head'
}
case_status_done_head() {
  pr_fixture
  local head
  head=$(git -C "$REPO" rev-parse HEAD)
  # Existing done.json files remain authoritative; no metadata migration.
  printf '{"head":"%s","done_at":1}\n' "$head" > "$DV_STATE/P-1/done.json"
  dv status --json | jq -e --arg head "$head" '.[0].done_head==$head'
  rm "$DV_STATE/P-1/done.json"
  dv status --json | jq -e '.[0].done_head==null'
  printf '{broken\n' > "$DV_STATE/P-1/done.json"
  dv status --json | jq -e '.[0].done_head==null'
}
case_reconcile_waiter() {
  pr_fixture; watch_fixture
  # One initial scan proves recovery; repeated scans can launch a successor
  # waiter while teardown is stopping the watcher and its detached children.
  export DV_HOSTS="$DV_HOST" DV_RECONCILE_INTERVAL=99999
  mkdir "$DV_STATE/P-1/.pr-wait"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_pr_ready P-1
  test ! -s "$DV_HOME/kick.q"
}
case_reconcile_waiter_remote() {
  pr_fixture; watch_fixture
  export DV_HOSTS=test-box SSH_FIXTURE_EXEC=1 DV_RECONCILE_INTERVAL=99999
  mkdir "$CASE_DIR/remote-home"
  printf 'DV_HOME=%q\nDV_STATE=%q\n' "$DV_HOME" "$DV_STATE" > "$CASE_DIR/remote-home/config.sh"
  mkdir "$DV_STATE/P-1/.pr-wait"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_pr_ready P-1
  test ! -s "$DV_HOME/kick.q"
}
