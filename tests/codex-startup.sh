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
  # Git resolves /var -> /private/var on macOS and removes duplicate slashes.
  # Exec uses persisted repository trust, not unsupported session overrides.
  local canonical_repo
  canonical_repo=$(cd "$REPO" && pwd -P)
  grep -Fx "[projects.$(jq -Rn --arg path "$canonical_repo" '$path')]" "$HOME/.codex/config.toml"
  grep -Fx 'trust_level = "trusted"' "$HOME/.codex/config.toml"
  jq -e 'all(.[]; startswith("projects.")|not)' "$DV_STATE/HS-1/args.json"
  dv clean HS-1
}
case_codex_tmux_startup() {
  needs_tmux; repo tmux-startup
  export DV_AGENT_CMD_codex='' DV_CODEX_BIN="$ROOT/tests/fixtures/interactive" DV_START_WAIT=2
  local mode reason
  for mode in hook folder idle; do
    printf '%s\n' "$mode" > "$CASE_DIR/codex-startup-mode"
    dv start "$REPO" "HT-$mode" startup
    wait_file "$DV_STATE/HT-$mode/events.log"
    reason='codex goal did not start'
    if [ "$mode" = hook ] || [ "$mode" = folder ]; then
      reason="codex $mode trust required"
      test ! -f "$DV_STATE/HT-$mode/goal-input"
    else test -f "$DV_STATE/HT-$mode/goal-input"; fi
    jq -se --arg reason "$reason" 'length==1 and .[0].kind=="failed" and .[0].message==$reason' "$DV_STATE/HT-$mode/events.log"
    jq -e '.status=="start-failed"' "$DV_STATE/HT-$mode/meta"
    test ! -f "$DV_STATE/HT-$mode/unexpected-input"
    dv clean "HT-$mode"
  done
}
startup_recovered() {
  local mode=$1 reason=$2
  startup_case "$mode"
  startup_failed "$reason"
  # Model the operator resolving startup before sending a new goal. The
  # production injector must not accept the hook dialog itself.
  rm "$CASE_DIR/herdr/w-HS-1/startup-mode"
  dv send HS-1 '/goal resumed by operator'
  grep -Fx '/goal resumed by operator' "$DV_STATE/HS-1/goal-input"
  dv 'done' HS-1 --note recovered
  test -s "$DV_STATE/HS-1/done.json"
  jq '{status,failure_reason}' "$DV_STATE/HS-1/meta"
  dv status HS-1 --json > "$CASE_DIR/recovered-status.json"
  # This is also the status filter used by dv-watch reconciliation.
  jq -e '[.[] | select(.status=="done")] | length==1 and .[0].issue=="HS-1" and (.[0]|has("failure_reason")|not)' "$CASE_DIR/recovered-status.json"
  jq -se 'map(.kind)==["failed","done"] and .[1].message=="recovered"' "$DV_STATE/HS-1/events.log"
  dv clean HS-1
}
case_codex_hook_recovered() { startup_recovered hook 'codex hook trust required'; }
case_codex_start_recovered() { startup_recovered idle 'codex goal did not start'; }
case_codex_done_delivery_status() {
  startup_case screen-working
  local status
  for status in pr ready; do
    jq --arg status "$status" '.status=$status' "$DV_STATE/HS-1/meta" > "$CASE_DIR/delivery-meta"
    mv "$CASE_DIR/delivery-meta" "$DV_STATE/HS-1/meta"
    dv 'done' HS-1
    jq -e --arg status "$status" '.status==$status and (.done_at|type)=="number"' "$DV_STATE/HS-1/meta"
  done
  dv clean HS-1
}
