#!/usr/bin/env bash
# Scheduler locking only: isolated state, no watcher, transport or agent.
# shellcheck disable=SC2016
schedule_lock_fixture() {
  repo schedule-lock; bidding_functions
  # DV_HOST is provided by the shared setup.
  # shellcheck disable=SC2153
  export DV_MANAGER_HOST="$DV_HOST" DV_HOSTS=''
  mkdir -p "$DV_HOME/submissions/LOCK-1"
  jq -n --arg host "$DV_HOST" \
    '{issue:"LOCK-1",status:"working",host:$host,token:"attempt",submitted_at:1}' \
    > "$DV_HOME/submissions/LOCK-1/task.json"
}
schedule_lock_dead_holder() {
  local holder rc=0
  bash -c '
    DV_ENTRY="$ROOT/bin/dv"
    source "$ROOT/lib/common.sh"
    owned_lock "$DV_HOME/.schedule-lock" "$$" || exit 1
    kill -KILL "$$"
  ' & holder=$!
  wait "$holder" 2>/dev/null || rc=$?
  test "$rc" = 137
  ! kill -0 "$holder" 2>/dev/null
  test "$(cat "$DV_HOME/.schedule-lock/owner")" = "$holder"
}
schedule_lock_complete() {
  bid_event "$(event_json "done" LOCK-1 completed "$DV_HOST" head '' attempt)"
  jq -e '.status=="completed" and .head=="head"' "$DV_HOME/submissions/LOCK-1/task.json"
  test ! -e "$DV_HOME/.schedule-lock"
}
case_bid_schedule_lock_dead() {
  schedule_lock_fixture
  schedule_lock_dead_holder
  schedule_lock_complete
}
case_bid_schedule_lock_legacy() {
  schedule_lock_fixture
  mkdir "$DV_HOME/.schedule-lock"
  schedule_lock_complete
}
case_bid_schedule_lock_live() {
  schedule_lock_fixture
  # Same owned_lock protocol as autofill, held by this still-live process.
  owned_lock "$DV_HOME/.schedule-lock" "$$"
  cp "$DV_HOME/submissions/LOCK-1/task.json" "$CASE_DIR/task.before"
  local action
  for action in event cancel; do
    # A distinct shell PID contends; shorten only retry sleeps, not lock logic.
    bash -c '
      DV_ENTRY="$ROOT/bin/dv"
      source "$ROOT/lib/common.sh"
      source "$ROOT/lib/bidding.sh"
      sleep() { :; }
      if [ "$1" = event ]; then
        if bid_event "$(event_json "done" LOCK-1 completed "$DV_HOST" head)"; then exit 1; fi
      else
        if cmd_cancel LOCK-1; then exit 1; fi
      fi
    ' _ "$action"
    test "$(cat "$DV_HOME/.schedule-lock/owner")" = "$$"
    test -f "$DV_HOME/.schedule-lock/pid-$$"
    cmp "$CASE_DIR/task.before" "$DV_HOME/submissions/LOCK-1/task.json"
  done
  owned_unlock "$DV_HOME/.schedule-lock" "$$"
  schedule_lock_complete
}
case_bid_schedule_lock_cancel() {
  schedule_lock_fixture
  local state
  for state in dead legacy fresh; do
    bid_task_set "$DV_HOME/submissions/LOCK-1" '.status="submitted"|.host=null'
    case "$state" in
      dead) schedule_lock_dead_holder ;;
      legacy) mkdir "$DV_HOME/.schedule-lock" ;;
    esac
    cmd_cancel LOCK-1
    jq -e '.status=="canceled"' "$DV_HOME/submissions/LOCK-1/task.json"
    test ! -e "$DV_HOME/.schedule-lock"
  done
  # An error after acquisition must release the claim too.
  if cmd_cancel LOCK-1; then return 1; fi
  test ! -e "$DV_HOME/.schedule-lock"
}
case_bid_schedule_lock_probe() {
  schedule_lock_fixture
  export DV_HOSTS="$DV_HOST"
  bid_task_set "$DV_HOME/submissions/LOCK-1" '.status="submitted"|.host=null'
  # shellcheck disable=SC2329
  bid_rpc() {
    case "$2" in
      bid) printf '{"status":"submitted","score":100}\n' ;;
      _award)
        # The preceding bid_limit probe and its canceled timer must not run
        # bid_event's EXIT trap before the award finishes under the same lock.
        test "$(cat "$DV_HOME/.schedule-lock/owner")" = "$$" || return 1
        test -f "$DV_HOME/.schedule-lock/pid-$$" || return 1
        touch "$CASE_DIR/award-under-lock"
        jq '{token,status:"working",head:"head"}' ;;
      *) return 1 ;;
    esac
  }
  bid_event "$(event_json submitted LOCK-1 '' "$DV_HOST" '')"
  test -f "$CASE_DIR/award-under-lock"
  jq -e '.status=="working"' "$DV_HOME/submissions/LOCK-1/task.json"
  test ! -e "$DV_HOME/.schedule-lock"
}
