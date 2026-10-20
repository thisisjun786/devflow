#!/usr/bin/env bash
# Sourced by run.sh: temporary repositories and fake agents only.
# shellcheck disable=SC2154,SC2016
startup_case() {
  local mode=$1
  repo "startup $mode"; herdr_setup; export DV_START_WAIT=2
  mkdir -p "$CASE_DIR/herdr"
  printf '%s\n' "$mode" > "$CASE_DIR/herdr/startup-mode"
  dv start "$REPO" HS-1 startup
  wait_native HS-1
}
startup_failed() {
  local reason=$1
  jq -se --arg reason "$reason" 'length==1 and .[0].kind=="failed" and .[0].message==$reason and .[0].delivered' "$DV_STATE/HS-1/events.log"
  dv status HS-1 --json | jq -e --arg reason "$reason" '.[0] | .status=="start-failed" and .failure_reason==$reason and .alive'
  test ! -f "$DV_STATE/HS-1/done.json"
}
startup_no_keys() {
  jq -se 'all(.[]; .[0:2]!=["pane","send-keys"])' "$CASE_DIR/herdr/calls"
}
case_codex_hook_trust() {
  startup_case hook
  startup_failed 'codex hook trust required'
  test ! -f "$DV_STATE/HS-1/goal-input"
  startup_no_keys
  dv clean HS-1
}
case_codex_hook_actions() {
  startup_case hook-actions
  startup_failed 'codex hook trust required'
  test ! -f "$DV_STATE/HS-1/goal-input"
  startup_no_keys
  dv clean HS-1
}
case_codex_hook_modal() {
  startup_case hook-modal
  startup_failed 'codex hook trust required'
  test ! -f "$DV_STATE/HS-1/goal-input"
  startup_no_keys
  dv clean HS-1
}
case_codex_hook_after_prompt() {
  startup_case hook-late
  startup_failed 'codex hook trust required'
  test -f "$DV_STATE/HS-1/goal-input"
  startup_no_keys
  dv clean HS-1
}
case_codex_goal_stalled() {
  startup_case idle
  startup_failed 'codex goal did not start'
  test -f "$DV_STATE/HS-1/goal-input"
  startup_no_keys
  jq -se '[.[]|select(.[0:2]==["agent","prompt"])]|length==1' "$CASE_DIR/herdr/calls"
  dv clean HS-1
}
case_codex_goal_enter() {
  startup_case enter
  jq -se 'all(.[]; .kind!="failed")' "$DV_STATE/HS-1/events.log"
  jq -se '[.[]|select(.[0:2]==["pane","send-keys"])]==[["pane","send-keys","w-HS-1:p1","Enter"]]' "$CASE_DIR/herdr/calls"
  jq -se '[.[]|select(.[0:2]==["agent","prompt"])]|length==1' "$CASE_DIR/herdr/calls"
  dv clean HS-1
}
case_codex_goal_enter_stalled() {
  startup_case enter-stuck
  startup_failed 'codex goal did not start'
  jq -se '[.[]|select(.[0:2]==["pane","send-keys"])]==[["pane","send-keys","w-HS-1:p1","Enter"]]' "$CASE_DIR/herdr/calls"
  dv clean HS-1
}
case_codex_goal_screen_working() {
  startup_case screen-working
  jq -se 'all(.[]; .kind!="failed")' "$DV_STATE/HS-1/events.log"
  startup_no_keys
  dv clean HS-1
}
case_codex_goal_history() {
  startup_case history
  startup_failed 'codex goal did not start'
  startup_no_keys
  dv clean HS-1
}
case_codex_repo_trust() {
  repo 'trust root'; herdr_setup
  dv start "$REPO" HS-1 trust --mode exec
  wait_native HS-1
  wt=$(jq -r .worktree "$DV_STATE/HS-1/meta")
  jq -e --arg root "projects.$(jq -Rn --arg path "$REPO" '$path').trust_level=\"trusted\"" \
    --arg wt "projects.$(jq -Rn --arg path "$wt" '$path').trust_level=\"trusted\"" \
    'index($root)!=null and index($wt)!=null' "$DV_STATE/HS-1/args.json"
  dv clean HS-1
}
case_codex_tmux_startup() {
  needs_tmux; repo tmux-startup
  export DV_AGENT_CMD_codex='' DV_CODEX_BIN="$ROOT/tests/fixtures/interactive" DV_START_WAIT=2
  local mode reason
  for mode in hook idle; do
    printf '%s\n' "$mode" > "$CASE_DIR/codex-startup-mode"
    dv start "$REPO" "HT-$mode" startup
    wait_file "$DV_STATE/HT-$mode/events.log"
    reason='codex goal did not start'
    if [ "$mode" = hook ]; then
      reason='codex hook trust required'
      test ! -f "$DV_STATE/HT-$mode/goal-input"
    else test -f "$DV_STATE/HT-$mode/goal-input"; fi
    jq -se --arg reason "$reason" 'length==1 and .[0].kind=="failed" and .[0].message==$reason' "$DV_STATE/HT-$mode/events.log"
    jq -e '.status=="start-failed"' "$DV_STATE/HT-$mode/meta"
    test ! -f "$DV_STATE/HT-$mode/unexpected-input"
    dv clean "HT-$mode"
  done
}
