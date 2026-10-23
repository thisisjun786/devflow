#!/usr/bin/env bash
# Requested PR #90 P1 regressions: fake agents, local Git, synthetic events only.
# shellcheck disable=SC2154,SC2016
exec_unlocked() {
  if [ -d "$DV_STATE/EX-1/.exec-lock" ]; then
    printf 'FAIL: completed wrapper left .exec-lock behind\n'
    cat "$DV_STATE/EX-1/log"
    return 1
  fi
  if grep -q 'unbound variable' "$DV_STATE/EX-1/log"; then return 1; fi
}
case_exec_cleanup_success() {
  exec_setup
  dv start "$REPO" EX-1 cleanup
  exec_wait
  exec_unlocked
  # Model an unreaped old wrapper: kill -0 succeeds but ps says zombie.
  export DV_TEST_ZOMBIE_PID
  DV_TEST_ZOMBIE_PID=$(cat "$DV_STATE/EX-1/agent.pid")
  cat > "$CASE_DIR/zombie-env" <<'ENV'
kill() {
  if [ "${1:-}" = -0 ] && [ "${2:-}" = "$DV_TEST_ZOMBIE_PID" ]; then return 0; fi
  builtin kill "$@"
}
ps() {
  if [ "${1:-}" = -p ] && [ "${2:-}" = "$DV_TEST_ZOMBIE_PID" ]; then printf 'Z\n'; return; fi
  command ps "$@"
}
ENV
  export BASH_ENV="$CASE_DIR/zombie-env"
  dv send EX-1 'follow-up after a zombie wrapper'
  exec_wait
  exec_unlocked
  test "$(cat "$DV_STATE/EX-1/stub-count")" = 2
}
case_exec_cleanup_failure() {
  exec_setup nonzero
  dv start "$REPO" EX-1 cleanup
  exec_wait
  exec_unlocked
  test "$(cat "$DV_STATE/EX-1/agent.exit")" = 7
}
case_exec_cleanup_signal() {
  exec_setup hold
  dv start "$REPO" EX-1 cleanup
  wait_file "$DV_STATE/EX-1/stub-runs.jsonl"
  local pid child i
  pid=$(cat "$DV_STATE/EX-1/agent.pid")
  child=$(cat "$DV_STATE/EX-1/exec/$(jq -r .exec_run "$DV_STATE/EX-1/meta")/pid")
  kill -TERM "$pid"
  for i in {1..100}; do
    [ -d "$DV_STATE/EX-1/.exec-lock" ] || break
    sleep 0.05
  done
  exec_unlocked
  if kill -0 "$child" 2>/dev/null; then return 1; fi
}
case_exec_exhausted_rebids() {
  exec_setup nonzero
  export DV_AWARD_TOKEN=exec-round DV_KICK="$ROOT/tests/fixtures/exec-kick"
  dv start "$REPO" EX-1 exhausted
  exec_wait
  bidding_functions
  export DV_MANAGER_HOST="$DV_HOST" DV_HOSTS=fake-host
  local dir="$DV_HOME/submissions" event
  mkdir -p "$dir/EX-1" "$dir/QUEUED-1"
  jq -n --arg repo "$REPO" '{issue:"EX-1",repo:$repo,agent:"codex",mode:"exec",status:"working",host:"fake-host",token:"exec-round",submitted_at:1}' > "$dir/EX-1/task.json"
  jq -n --arg repo "$REPO" '{issue:"QUEUED-1",repo:$repo,agent:"codex",mode:"exec",status:"submitted",host:null,submitted_at:2}' > "$dir/QUEUED-1/task.json"
  # Replay the receipt state observed when each event was actually delivered,
  # not the later terminal state that would conceal the pre-exit failure race.
  # shellcheck disable=SC2329
  bid_rpc() {
    case "$2" in
      _receipt) jq -n --argjson exited "$(cat "$CASE_DIR/event-exited")" '{status:"working",token:"exec-round",exited:$exited}' ;;
      bid)
        if [ "$(cat "$CASE_DIR/event-exited")" = true ]; then printf '{"status":"submitted","score":100}\n'
        else printf '{"status":"rejected","score":0}\n'; fi ;;
      _award) cat > "$CASE_DIR/reawarded"; jq '{status:"working",token,head:"new-head"}' "$CASE_DIR/reawarded" ;;
    esac
  }
  while IFS= read -r event; do
    printf '%s\n' "$event" | jq -r .exited > "$CASE_DIR/event-exited"
    bid_event "$event"
  done < "$CASE_DIR/exec-kicks.jsonl"
  jq -e '.status=="failed"' "$dir/EX-1/task.json"
  jq -e '.status=="working" and .host=="fake-host"' "$dir/QUEUED-1/task.json"
  jq -e '.issue=="QUEUED-1"' "$CASE_DIR/reawarded"
  jq -se 'any(.[]; .kind=="failed" and .exited)' "$CASE_DIR/exec-kicks.jsonl"
}
exec_land_setup() {
  exec_setup "${1:-done-hold}" "${2:-}"
  dv start "$REPO" EX-1 land
  wait_file "$DV_STATE/EX-1/after-done"
}
case_exec_land_running() {
  exec_land_setup
  local before
  before=$(git -C "$REPO" rev-parse main)
  if DV_TEST_CMD=true dv land EX-1 > "$CASE_DIR/land-output" 2>&1; then return 1; fi
  cat "$CASE_DIR/land-output"
  test "$(git -C "$REPO" rev-parse main)" = "$before"
  jq -e '.status!="landed"' "$DV_STATE/EX-1/meta"
  touch "$DV_STATE/EX-1/release"
  exec_wait
  DV_TEST_CMD=true dv land EX-1
  test "$(git -C "$REPO" rev-parse main)" != "$before"
}
case_exec_land_github_running() {
  exec_land_setup done-hold remote
  printf '{"url":"https://github.com/test/repo/pull/1"}\n' > "$DV_STATE/EX-1/pr.json"
  if dv land EX-1 > "$CASE_DIR/land-output" 2>&1; then return 1; fi
  cat "$CASE_DIR/land-output"
  test ! -f "$GH_STUB_DIR/merged"
  jq -e '.status!="landed"' "$DV_STATE/EX-1/meta"
  touch "$DV_STATE/EX-1/release"
  exec_wait
}
case_exec_land_failed() {
  exec_land_setup done-fail
  local before
  before=$(git -C "$REPO" rev-parse main)
  touch "$DV_STATE/EX-1/release"
  exec_wait
  if DV_TEST_CMD=true dv land EX-1 > "$CASE_DIR/land-output" 2>&1; then return 1; fi
  cat "$CASE_DIR/land-output"
  test "$(git -C "$REPO" rev-parse main)" = "$before"
  jq -e '.status=="blocked"' "$DV_STATE/EX-1/meta"
}
