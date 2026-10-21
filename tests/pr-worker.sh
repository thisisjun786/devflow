#!/usr/bin/env bash
# PR ownership tests use only the disposable repository and gh/agent fixtures.
case_pr_worker_foreground() {
  pr_fixture
  printf '[{"body":"P1: fix the write","path":"file.sh","line":3,"commit_id":"old"}]\n' > "$GH_STUB_DIR/comments"
  dv pr-wait P-1 --foreground > "$CASE_DIR/snapshot"
  jq -e '.green and .review_timed_out and .snapshot.inline_comments[0].body=="P1: fix the write"' "$CASE_DIR/snapshot"
  test ! -s "$DV_HOME/kick.q"
  jq -e '.status=="pr"' "$DV_STATE/P-1/meta"
}
case_pr_worker_done_gate() {
  pr_fixture
  if dv done P-1 > "$CASE_DIR/rejected" 2>&1; then
    printf 'BUG: done accepted without CI/review evidence\n'; return 1
  fi
  test ! -f "$DV_STATE/P-1/done.json"
  test ! -s "$DV_HOME/kick.q"
}
case_pr_worker_red() {
  pr_fixture
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]\n' > "$GH_STUB_DIR/checks"
  dv pr-wait P-1
  jq -e '.status=="pr"' "$DV_STATE/P-1/meta"
  test ! -s "$DV_HOME/kick.q"
}
case_pr_worker_loop() {
  pr_fixture
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]\n' > "$GH_STUB_DIR/checks"
  printf '[{"body":"P1: fix the write","path":"file.sh","line":3}]\n' > "$GH_STUB_DIR/comments"
  (cd "$REPO" && DV_ISSUE=P-1 "$ROOT/tests/fixtures/pr-worker")
  jq -e '.checks=="green" and .review=="handled"' "$DV_STATE/P-1/done.json"
  jq -se 'length==1 and .[0].kind=="done" and (.[0].message|contains("checks=green review=handled"))' "$DV_HOME/kick.q"
  test "$(git -C "$REPO" log --oneline --grep='fix review P1' | wc -l | tr -d ' ')" = 1
  # Re-entering the same loop preserves the review correction and does not fix twice.
  (cd "$REPO" && DV_ISSUE=P-1 "$ROOT/tests/fixtures/pr-worker")
  test "$(git -C "$REPO" log --oneline --grep='fix review P1' | wc -l | tr -d ' ')" = 1
  jq -e '.ci_rounds==1 and .review_handled' "$DV_STATE/P-1/pr-ready.json"
}
case_pr_worker_cap() {
  pr_fixture
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]\n' > "$GH_STUB_DIR/checks"
  local n head
  for n in 1 2 3; do
    git -C "$REPO" commit --allow-empty -qm "CI round $n"
    head=$(git -C "$REPO" rev-parse HEAD)
    jq --arg head "$head" '.head=$head' "$DV_STATE/P-1/meta" > "$CASE_DIR/meta"
    mv "$CASE_DIR/meta" "$DV_STATE/P-1/meta"
    if [ "$n" = 3 ]; then
      if dv pr-wait P-1 --foreground > "$CASE_DIR/snapshot"; then return 1; fi
      if dv pr-wait P-1 --foreground > "$CASE_DIR/snapshot"; then return 1; fi
    else
      dv pr-wait P-1 --foreground > "$CASE_DIR/snapshot"
      dv pr-wait P-1 --foreground > "$CASE_DIR/snapshot"
      test ! -s "$DV_HOME/kick.q"
    fi
  done
  jq -e '.blocked and .ci_rounds==3' "$CASE_DIR/snapshot"
  jq -se 'length==1 and .[0].kind=="blocked"' "$DV_HOME/kick.q"
  if dv done P-1; then return 1; fi
}
case_pr_worker_stale() {
  pr_fixture
  dv pr-wait P-1 --foreground > /dev/null
  dv pr-wait P-1 --foreground --review-handled > /dev/null
  git -C "$REPO" commit --allow-empty -qm correction
  if dv done P-1; then return 1; fi
  test ! -f "$DV_STATE/P-1/done.json"
  test ! -s "$DV_HOME/kick.q"
}
case_pr_worker_live_checks() {
  pr_fixture
  dv pr-wait P-1 --foreground > /dev/null
  dv pr-wait P-1 --foreground --review-handled > /dev/null
  printf '[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null}]\n' > "$GH_STUB_DIR/checks"
  if dv done P-1; then return 1; fi
  test ! -f "$DV_STATE/P-1/done.json"
  test ! -s "$DV_HOME/kick.q"
}
case_pr_worker_comments_failure() {
  pr_fixture
  touch "$GH_STUB_DIR/comments-fail"
  if dv pr-wait P-1 --foreground; then return 1; fi
  test ! -f "$DV_STATE/P-1/pr-ready.json"
}
case_pr_worker_handoff() {
  pr_fixture
  printf '[]\n' > "$GH_STUB_DIR/checks"
  dv pr-wait P-1 > "$CASE_DIR/background" 2>&1 & waiter=$!
  wait_file "$GH_STUB_DIR/viewed"
  dv pr-wait P-1 --foreground > "$CASE_DIR/foreground" & local fg=$!
  sleep 0.2
  test ! -s "$CASE_DIR/foreground"
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]\n' > "$GH_STUB_DIR/checks"
  wait "$waiter"; waiter=''
  wait "$fg"
  jq -e .green "$CASE_DIR/foreground"
  test ! -s "$DV_HOME/kick.q"
}
case_pr_worker_revive() {
  repo worker-revive remote
  herdr_setup
  export DV_AGENT_CMD_codex="$ROOT/tests/fixtures/pr-worker" DV_PR_EARLY_EXIT=1
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]\n' > "$GH_STUB_DIR/checks"
  printf '[{"body":"P1: fix the write","path":"file.sh","line":3}]\n' > "$GH_STUB_DIR/comments"
  dv start "$REPO" PW-1 worker --mode "${DV_PR_TEST_MODE:-goal}"
  if [ "${DV_PR_EXIT_GATE:-0}" = 1 ]; then
    wait_file "$DV_STATE/PW-1/live-checked"
    touch "$DV_STATE/PW-1/exit-release"
    wait_file "$CASE_DIR/herdr/w-PW-1/exit"
    touch "$DV_STATE/PW-1/waiter-release"
  fi
  wait_file "$DV_STATE/PW-1/agent.exit"
  wait_file "$DV_STATE/PW-1/revive/done"
  wait_file "$CASE_DIR/herdr/w-PW-1/exit"
  local wt
  wt=$(jq -r .worktree "$DV_STATE/PW-1/meta")
  test -f "$wt/ci-fix" && test -f "$wt/review-fix"
  grep -F 'pr-snapshot.json' "$DV_STATE/PW-1/worker-input"
  jq -e '.checks=="green" and .review=="handled"' "$DV_STATE/PW-1/done.json"
  jq -se 'all(.[]; .kind=="done") and any(.[]; .kind=="done")' "$DV_HOME/kick.q"
}
case_pr_worker_no_rereview() {
  pr_fixture
  local head
  head=$(git -C "$REPO" rev-parse HEAD)
  jq -n --arg head "$head" '[{author:{login:"devin-ai-integration[bot]"},commit:{oid:$head}},{author:{login:"chatgpt-codex-connector[bot]"},commit:{oid:$head}}]' > "$GH_STUB_DIR/reviews"
  export DV_REVIEW_WAIT=30
  dv pr-wait P-1 --foreground > /dev/null
  dv pr-wait P-1 --foreground --review-handled > /dev/null
  git -C "$REPO" commit --allow-empty -qm 'CI correction after review'
  dv pr P-1
  dv pr-wait P-1 --foreground > "$CASE_DIR/snapshot" & waiter=$!
  # The foreground result must arrive well before the new-head review timeout.
  wait_file "$CASE_DIR/snapshot"
  wait "$waiter"; waiter=''
  jq -e '.green and .review_handled and (.review_timed_out|not) and (.bot_review|not)' "$CASE_DIR/snapshot"
}
case_pr_worker_revive_exec() {
  export DV_PR_EXIT_CODE=1 DV_PR_TEST_MODE=exec
  case_pr_worker_revive
}
case_pr_worker_exit_race() {
  cat > "$CASE_DIR/waiter-race-env" <<'STUB'
DV_RACE_WAITER=0
[ "${1:-}" != pr-wait ] || DV_RACE_WAITER=1
kill() {
  builtin kill "$@" || return $?
  if [ "$DV_RACE_WAITER" = 1 ] && [ "$#" = 2 ] && [ "$1" = -0 ] &&
    [ "$2" = "$(cat "$DV_STATE/PW-1/agent.pid" 2>/dev/null)" ] &&
    [ -f "$DV_STATE/PW-1/pr-ready.json" ] && mkdir "$DV_STATE/PW-1/race-once" 2>/dev/null; then
    touch "$DV_STATE/PW-1/live-checked"
    while [ ! -f "$DV_STATE/PW-1/waiter-release" ]; do sleep 0.05; done
  fi
  return 0
}
STUB
  export BASH_ENV="$CASE_DIR/waiter-race-env" DV_PR_EXIT_GATE=1
  case_pr_worker_revive
}
case_pr_worker_exec_missing_pr() {
  repo missing-pr remote
  herdr_setup
  export DV_AGENT_CMD_codex=true
  dv start "$REPO" PW-2 missing-pr --mode exec
  wait_file "$DV_STATE/PW-2/agent.exit"
  wait_file "$CASE_DIR/herdr/w-PW-2/exit"
  jq -e '.status=="failed" and (.failure_reason|contains("completion"))' "$DV_STATE/PW-2/meta"
  jq -se 'any(.[]; .kind=="failed") and all(.[]; .kind!="done")' "$DV_HOME/kick.q"
  test "$(cat "$DV_STATE/PW-2/agent.exit")" = 1
}
case_pr_worker_native_exec() {
  exec_setup pr-loop remote
  export DV_PR_EARLY_EXIT=1 DV_STALL_AFTER=30
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]\n' > "$GH_STUB_DIR/checks"
  printf '[{"body":"P1: fix the write","path":"file.sh","line":3}]\n' > "$GH_STUB_DIR/comments"
  dv start "$REPO" EX-1 worker
  exec_wait
  jq -e '.backend=="exec" and .exec_status=="done" and .status=="ready"' "$DV_STATE/EX-1/meta"
  jq -e '.checks=="green" and .review=="handled"' "$DV_STATE/EX-1/done.json"
  jq -se 'map(.kind)==["done"]' "$DV_STATE/EX-1/events.log"
  test "$(cat "$DV_STATE/EX-1/stub-count")" = 2
  test ! -d "$DV_STATE/EX-1/revive"
}
