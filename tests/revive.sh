#!/usr/bin/env bash
# Follow-up recovery uses disposable Git worktrees and fake agents only.
# DV_STATE comes from the driver; the instruction tests literal shell syntax.
# shellcheck disable=SC2153,SC2016
revive_setup() {
  repo revive
  herdr_setup
  export DV_START_WAIT=2
  dv start "$REPO" RV-1 followup --mode exec
  wait_native RV-1
  RV_STATE="$DV_STATE/RV-1"
  RV_WT=$(jq -r .worktree "$RV_STATE/meta")
  printf 'Original review correction\n' > "$RV_STATE/review-fix.sent"
  printf '{"url":"https://github.com/test/repo/pull/1"}\n' > "$RV_STATE/pr.json"
  cp "$RV_STATE/meta" "$CASE_DIR/original-meta"
  cp "$RV_STATE/report.md" "$CASE_DIR/original-report"
  cp "$RV_STATE/done.json" "$CASE_DIR/original-done"
  printf 'unfinished work\n' > "$RV_WT/dirty"
}
revive_dead() {
  rm "$CASE_DIR/herdr/w-RV-1/detected" "$CASE_DIR/herdr/w-RV-1/exit"
  export DV_CODEX_BIN="$ROOT/tests/fixtures/revived-agent"
}
revive_wait() {
  wait_file "$RV_STATE/revived-input.json"
  wait_file "$RV_STATE/agent.exit"
  # The wrapper emits completion/failure after agent.exit.
  for _ in {1..100}; do
    if [ -f "$RV_STATE/revive/done" ] || [ -d "$RV_STATE/revive/blocked" ]; then
      # done/blocked precedes the wrapper's final event and log writes.
      wait_file "$CASE_DIR/herdr/w-RV-1/exit"
      return
    fi
    sleep 0.05
  done
  return 1
}
revive_preserved() {
  jq -e --slurpfile before "$CASE_DIR/original-meta" '
    .worktree==$before[0].worktree and .branch==$before[0].branch and .agent==$before[0].agent and .base==$before[0].base' "$RV_STATE/meta"
  test "$(git -C "$REPO" for-each-ref --format='%(refname)' refs/heads | wc -l | tr -d ' ')" = 2
  test "$(cat "$RV_WT/dirty")" = 'unfinished work'
  test "$(cat "$RV_STATE/review-fix.sent")" = 'Original review correction'
  cmp "$RV_STATE/report.md" "$CASE_DIR/original-report"
  jq -e '.url=="https://github.com/test/repo/pull/1"' "$RV_STATE/pr.json"
  test "$(wc -l < "$RV_STATE/revived-runs" | tr -d ' ')" = 1
}
case_revive_dead() {
  revive_setup; revive_dead
  # Shell syntax and newlines must arrive as literal first input.
  local message='Fix P1: literal $(touch SHOULD_NOT_EXIST) `echo unsafe`
then verify and finish.'
  dv send RV-1 "$message"
  revive_wait
  jq -e --arg wt "$(cd "$RV_WT" && pwd -P)" '.cwd==$wt' "$RV_STATE/revived-input.json"
  jq -e --arg message "$message" --arg s "$RV_STATE" '.args[-1] | startswith($message) and contains($s+"/brief.md") and contains($s+"/report.md")' "$RV_STATE/revived-input.json"
  test ! -e "$RV_WT/SHOULD_NOT_EXIST"
  revive_preserved
}
case_revive_live() {
  revive_setup
  dv send RV-1 'repair live agent'
  grep -Fx 'repair live agent' "$RV_STATE/sent-input"
  test ! -d "$RV_STATE/revive"
  jq -se '[.[]|select(.[0:2]==["pane","run"])]|length==1' "$CASE_DIR/herdr/calls"
}
case_revive_failure() {
  revive_setup; revive_dead
  export DV_REVIVE_TEST_FAIL=1
  dv send RV-1 'fix failed tests'
  revive_wait
  for _ in {1..100}; do
    if jq -se 'any(.[]; .kind=="blocked")' "$RV_STATE/events.log" >/dev/null; then break; fi
    sleep 0.05
  done
  if dv send RV-1 'retry same correction'; then return 1; fi
  jq -se '[.[]|select(.kind=="blocked")]|length==1' "$RV_STATE/events.log"
  cmp "$RV_STATE/done.json" "$CASE_DIR/original-done"
  revive_preserved
}
case_revive_goal_failure() {
  revive_setup; revive_dead
  jq '.agent="claude" | .mode="goal"' "$RV_STATE/meta" > "$CASE_DIR/goal-meta"
  mv "$CASE_DIR/goal-meta" "$RV_STATE/meta"
  export DV_CLAUDE_BIN="$ROOT/tests/fixtures/revived-agent" DV_REVIVE_TEST_FAIL=1
  dv send RV-1 'complete missing report'
  revive_wait
  for _ in {1..100}; do
    if jq -se 'any(.[]; .kind=="blocked")' "$RV_STATE/events.log" >/dev/null; then break; fi
    sleep 0.05
  done
  jq -se '[.[]|select(.kind=="blocked")]|length==1' "$RV_STATE/events.log"
  jq -e '.args[-1]|startswith("complete missing report")' "$RV_STATE/revived-input.json"
  cmp "$RV_STATE/done.json" "$CASE_DIR/original-done"
}
case_revive_transport() {
  revive_setup
  printf 'agent prompt\n' > "$CASE_DIR/herdr/fail"
  if dv send RV-1 'uncertain delivery'; then return 1; fi
  test ! -d "$RV_STATE/revive"
  test ! -f "$RV_STATE/revived-runs"
}
case_revive_tmux() {
  needs_tmux; repo revive-tmux
  start RT-1; wait_done RT-1
  export DV_AGENT_CMD_codex='' DV_CODEX_BIN="$ROOT/tests/fixtures/revived-agent"
  dv send RT-1 'fix in existing tmux worktree'
  wait_done RT-1
  local wt
  wt=$(jq -r .worktree "$DV_STATE/RT-1/meta")
  jq -e --arg wt "$(cd "$wt" && pwd -P)" '.cwd==$wt and (.args[-1]|startswith("fix in existing tmux worktree"))' "$DV_STATE/RT-1/revived-input.json"
  test "$(wc -l < "$DV_STATE/RT-1/revived-runs" | tr -d ' ')" = 1
}
case_revive_missing_pane() {
  revive_setup; revive_dead
  # The old workspace no longer exists in the fake terminal server.
  rm -rf "$CASE_DIR/herdr/w-RV-1"
  dv send RV-1 'restore missing pane'
  revive_wait
  jq -se '[.[]|select(.[0:2]==["workspace","create"])]|length==2' "$CASE_DIR/herdr/calls"
  revive_preserved
}
case_revive_missing_pane_live() {
  revive_setup; revive_dead
  rm -rf "$CASE_DIR/herdr/w-RV-1"
  printf '%s\n' "$$" > "$RV_STATE/agent.pid"
  if dv send RV-1 'do not duplicate surviving wrapper'; then return 1; fi
  test ! -d "$RV_STATE/revive"
  test ! -f "$RV_STATE/revived-runs"
}
case_revive_missing_pane_unknown() {
  revive_setup; revive_dead
  rm -rf "$CASE_DIR/herdr/w-RV-1"
  rm "$RV_STATE/agent.pid" "$RV_STATE/agent.exit"
  if dv send RV-1 'unknown wrapper must not be duplicated'; then return 1; fi
  test ! -d "$RV_STATE/revive"
  test ! -f "$RV_STATE/revived-runs"
}
case_revive_legacy_exit() {
  revive_setup; revive_dead
  rm -rf "$CASE_DIR/herdr/w-RV-1"
  rm "$RV_STATE/agent.pid"
  dv send RV-1 'legacy wrapper has exited'
  revive_wait
  revive_preserved
}
case_revive_start_failure() {
  revive_setup; revive_dead
  printf 'pane run\n' > "$CASE_DIR/herdr/fail"
  if dv send RV-1 'restore failed agent'; then return 1; fi
  if dv send RV-1 'restore failed agent'; then return 1; fi
  jq -se '[.[]|select(.kind=="blocked")]|length==1' "$RV_STATE/events.log"
  jq -se '[.[]|select(.[0:2]==["pane","run"])]|length==2' "$CASE_DIR/herdr/calls"
  cmp "$RV_STATE/done.json" "$CASE_DIR/original-done"
}
case_revive_undetected() {
  revive_setup; revive_dead
  # A missing detector must not replace a wrapper that is still alive.
  printf '%s\n' "$$" > "$RV_STATE/agent.pid"
  if dv send RV-1 'do not replace active command'; then return 1; fi
  test ! -d "$RV_STATE/revive"
}
case_revive_branch_guard() {
  revive_setup; revive_dead
  git -C "$RV_WT" checkout -qb unexpected
  if dv send RV-1 'stay on original branch'; then return 1; fi
  test ! -d "$RV_STATE/revive"
  test "$(cat "$RV_WT/dirty")" = 'unfinished work'
}
case_revive_goal_no_done() {
  revive_setup; revive_dead
  jq '.agent="devin" | .mode="goal"' "$RV_STATE/meta" > "$CASE_DIR/goal-meta"
  mv "$CASE_DIR/goal-meta" "$RV_STATE/meta"
  export DV_DEVIN_BIN="$ROOT/tests/fixtures/revived-agent" DV_REVIVE_TEST_NO_DONE=1
  dv send RV-1 'finish the current request'
  revive_wait
  for _ in {1..100}; do
    if jq -se 'any(.[]; .kind=="blocked")' "$RV_STATE/events.log" >/dev/null; then break; fi
    sleep 0.05
  done
  jq -se 'any(.[]; .kind=="blocked" and (.message|contains("without dv done")))' "$RV_STATE/events.log"
  jq -e '.args|index("--permission-mode")!=null' "$RV_STATE/revived-input.json"
  cmp "$RV_STATE/done.json" "$CASE_DIR/original-done"
}
case_revive_override() {
  revive_setup; revive_dead
  export DV_AGENT_CMD_codex='"$ROOT/tests/fixtures/revived-agent" "$DV_AGENT_INSTRUCTION"'
  dv send RV-1 'override context'
  revive_wait
  jq -e '.args|length==1 and (.[0]|startswith("override context"))' "$RV_STATE/revived-input.json"
  revive_preserved
}
case_revive_tmux_retained() {
  needs_tmux; repo revive-retained
  export DV_AGENT_CMD_codex='tmux -L "$DV_TMUX_SOCKET" set-option remain-on-exit on'
  start RR-1
  for _ in {1..100}; do
    if [ "$(tmux -L "$DV_TMUX_SOCKET" display-message -p -t dv-RR-1 '#{pane_dead}')" = 1 ]; then break; fi
    sleep 0.05
  done
  export DV_AGENT_CMD_codex='' DV_CODEX_BIN="$ROOT/tests/fixtures/revived-agent"
  dv send RR-1 'revive retained pane'
  wait_file "$DV_STATE/RR-1/revived-input.json"
  jq -e '.args[-1]|startswith("revive retained pane")' "$DV_STATE/RR-1/revived-input.json"
  wait_file "$DV_STATE/RR-1/revive/done"
}
case_revive_tmux_live() {
  needs_tmux; repo revive-live
  export DV_AGENT_CMD_codex='read -r input; printf "%s\n" "$input" > "$DV_STATE/$DV_ISSUE/live-input"'
  start RL-1
  dv send RL-1 'ordinary live input'
  wait_done RL-1
  grep -Fx 'ordinary live input' "$DV_STATE/RL-1/live-input"
  test ! -d "$DV_STATE/RL-1/revive"
}
case_revive_codex_goal() {
  revive_setup; revive_dead
  jq '.mode="goal"' "$RV_STATE/meta" > "$CASE_DIR/goal-meta"
  mv "$CASE_DIR/goal-meta" "$RV_STATE/meta"
  dv send RV-1 'continue the goal correction'
  revive_wait
  grep '^/goal continue the goal correction$' "$RV_STATE/goal-input"
  test -f "$RV_STATE/revive/done"
  test ! -d "$RV_STATE/revive/blocked"
  revive_preserved
}
case_revive_legacy_idle() {
  revive_setup; revive_dead
  rm "$RV_STATE/agent.pid" "$RV_STATE/agent.exit"
  dv send RV-1 'continue legacy work'
  revive_wait
  revive_preserved
}
case_revive_capacity_status() {
  revive_setup
  jq '.status="running" | del(.done_at)' "$RV_STATE/meta" > "$CASE_DIR/meta.tmp"
  mv "$CASE_DIR/meta.tmp" "$RV_STATE/meta"
  printf 'idle\n' > "$CASE_DIR/herdr/w-RV-1/status"
  printf 'Selected model is at capacity\n› \n' > "$CASE_DIR/herdr/w-RV-1/output"
  dv status RV-1 --json | jq -e '.[0].goal_stalled==true'
}
case_revive_legacy_busy() {
  revive_setup; revive_dead
  rm "$RV_STATE/agent.pid" "$RV_STATE/agent.exit"
  local process
  for process in codex node bash sleep; do
    jq -n --arg name "$process" '{result:{process_info:{pane_id:"w-RV-1:p1",shell_pid:123,
      foreground_process_group_id:456,foreground_processes:[{pid:456,name:$name}]}}}' > "$CASE_DIR/herdr/w-RV-1/process-info"
    if dv send RV-1 'do not duplicate a process'; then return 1; fi
    test ! -d "$RV_STATE/revive"
  done
}
case_revive_legacy_uncertain() {
  revive_setup; revive_dead
  rm "$RV_STATE/agent.pid" "$RV_STATE/agent.exit"
  printf 'pane process-info\n' > "$CASE_DIR/herdr/fail"
  if dv send RV-1 'transport is not absence'; then return 1; fi
  test ! -d "$RV_STATE/revive"
  rm "$CASE_DIR/herdr/fail"
  printf '{"result":{"process_info":{"pane_id":"w-RV-1:p1"}}}\n' > "$CASE_DIR/herdr/w-RV-1/process-info"
  if dv send RV-1 'missing telemetry is not absence'; then return 1; fi
  test ! -d "$RV_STATE/revive"
}
case_revive_legacy_unknown() {
  revive_setup; revive_dead
  rm "$RV_STATE/agent.pid" "$RV_STATE/agent.exit"
  jq '.status="running" | del(.done_at)' "$RV_STATE/meta" > "$CASE_DIR/meta.tmp"
  mv "$CASE_DIR/meta.tmp" "$RV_STATE/meta"
  # Cached agent identity can survive the process: unknown plus a confirmed
  # shell-only pane still proves absence, even when agent.get succeeds.
  touch "$CASE_DIR/herdr/w-RV-1/detected" "$CASE_DIR/herdr/prompt-error"
  printf 'unknown\n' > "$CASE_DIR/herdr/w-RV-1/status"
  dv status RV-1 --json | jq -e '.[0].agent_dead==true'
  dv send RV-1 'continue legacy work with cached identity'
  revive_wait
  revive_preserved
}
