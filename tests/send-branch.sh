#!/usr/bin/env bash
# Same-job steering after a branch switch, with disposable agents and state.
# shellcheck disable=SC2016,SC2154
send_branch_environment() {
  export TMPDIR="$CASE_DIR/tmp" XDG_CONFIG_HOME="$HOME/.config"
  export XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache"
  export XDG_RUNTIME_DIR="$CASE_DIR/runtime" DV_AWARD_TOKEN=send-branch-award
  mkdir -p "$TMPDIR" "$XDG_RUNTIME_DIR"
}
send_branch_switch() {
  SEND_STATE="$DV_STATE/$1"
  SEND_WT=$(jq -r .worktree "$SEND_STATE/meta")
  jq '{issue,repo,worktree,branch,started,award_token,thread_id,herdr_pane}' "$SEND_STATE/meta" > "$CASE_DIR/send-identity"
  git -C "$SEND_WT" checkout -qb stacked-followup
}
send_branch_preserved() {
  jq '{issue,repo,worktree,branch,started,award_token,thread_id,herdr_pane}' "$SEND_STATE/meta" > "$CASE_DIR/send-after"
  cmp "$CASE_DIR/send-identity" "$CASE_DIR/send-after" || return
  test "$(git -C "$SEND_WT" symbolic-ref --short HEAD)" = stacked-followup
}
send_branch_appserver() {
  send_branch_environment; appserver_setup
  send_branch_switch AS-1
  if [ "$1" = reconnect ]; then
    teardown_stop_pidfile "$SEND_STATE/appserver/client.pid"
    wait_file "$SEND_STATE/appserver/exited"
  fi
  dv send AS-1 'continue the stacked change' | jq -e '.outcome=="accepted"'
  jq -se '[.[]|select(.method=="turn/steer")]|length==1 and .[0].params.threadId=="thread-1" and .[0].params.input[0].text=="continue the stacked change"' "$CASE_DIR/server/requests"
  send_branch_preserved
}
case_send_branch_appserver() { send_branch_appserver live; }
case_send_branch_appserver_reconnect() { send_branch_appserver reconnect; }
case_send_branch_exec() {
  send_branch_environment; exec_setup
  dv start "$REPO" EX-1 exec --mode exec; exec_wait
  send_branch_switch EX-1
  export DV_EXEC_SCENARIO=hold
  dv send EX-1 'continue the stacked change'
  local attempt
  for attempt in {1..100}; do
    if jq -se 'length==2' "$SEND_STATE/stub-runs.jsonl" >/dev/null; then break; fi
    sleep 0.1
  done
  # macOS TMPDIR can name /var while the child reports /private/var.
  # Release the held fixture even when a delivery assertion fails.
  local result=0
  jq -se 'length==2 and (.[1].args|index("resume")!=null and index("fixture-thread")!=null) and (.[1].args[-1]|startswith("continue the stacked change"))' "$SEND_STATE/stub-runs.jsonl" || result=1
  test "$(cd "$(jq -sr '.[1].cwd' "$SEND_STATE/stub-runs.jsonl")" && pwd -P)" = "$(cd "$SEND_WT" && pwd -P)" || result=1
  send_branch_preserved || result=1
  # Completion still guards the original branch; only delivery is relaxed.
  git -C "$SEND_WT" checkout -q "$(jq -r .branch "$SEND_STATE/meta")"
  touch "$SEND_STATE/release"; exec_wait
  return "$result"
}
case_send_branch_tmux() {
  needs_tmux; send_branch_environment; repo send-terminal
  export DV_AGENT_CMD_codex='touch "$DV_STATE/$DV_ISSUE/input-ready"; read -r input; printf "%s\n" "$input" > "$DV_STATE/$DV_ISSUE/live-input"; while [ ! -f "$DV_STATE/$DV_ISSUE/release" ]; do sleep 0.1; done'
  start ST-1
  wait_file "$DV_STATE/ST-1/input-ready"
  send_branch_switch ST-1
  dv send ST-1 'continue the stacked change'
  wait_file "$SEND_STATE/live-input"
  grep -Fx 'continue the stacked change' "$SEND_STATE/live-input"
  send_branch_preserved
  test ! -d "$SEND_STATE/revive"
  git -C "$SEND_WT" checkout -q "$(jq -r .branch "$SEND_STATE/meta")"
  touch "$SEND_STATE/release"; wait_done ST-1
}
case_send_branch_herdr() {
  send_branch_environment; revive_setup
  send_branch_switch RV-1
  dv send RV-1 'continue the stacked change'
  grep -Fx 'continue the stacked change' "$SEND_STATE/sent-input"
  send_branch_preserved
  test ! -d "$SEND_STATE/revive"
}
case_send_branch_revive() {
  send_branch_environment; revive_setup; revive_dead
  send_branch_switch RV-1
  export DV_REVIVE_TEST_HOLD=1
  dv send RV-1 'continue the stacked change'
  wait_file "$SEND_STATE/revived-input.json"
  jq -e '.args[-1]|startswith("continue the stacked change") and contains("stacked-followup")' "$SEND_STATE/revived-input.json"
  send_branch_preserved
  git -C "$SEND_WT" checkout -q "$(jq -r .branch "$SEND_STATE/meta")"
  touch "$SEND_STATE/revive-release"; revive_wait
  test "$(cat "$SEND_WT/dirty")" = 'unfinished work'
}
case_send_branch_guards() {
  send_branch_environment; exec_setup
  dv start "$REPO" EX-1 exec --mode exec; exec_wait
  send_branch_switch EX-1
  local command
  for command in land clean pr; do
    if dv "$command" EX-1 > "$CASE_DIR/guard-$command" 2>&1; then return 1; fi
    grep -F 'worktree branch changed' "$CASE_DIR/guard-$command"
    test -d "$SEND_WT"
  done
  send_branch_preserved
}
case_send_branch_missing() {
  send_branch_environment; exec_setup
  dv start "$REPO" EX-1 exec --mode exec; exec_wait
  send_branch_switch EX-1
  mv "$SEND_WT" "$CASE_DIR/saved-worktree"
  if dv send EX-1 'must not deliver' > "$CASE_DIR/refused" 2>&1; then return 1; fi
  grep -F 'worktree is missing' "$CASE_DIR/refused"
  test "$(cat "$SEND_STATE/stub-count")" = 1
}
send_branch_replaced() {
  local kind=$1
  send_branch_environment; exec_setup
  dv start "$REPO" EX-1 exec --mode exec; exec_wait
  send_branch_switch EX-1
  mv "$SEND_WT" "$CASE_DIR/saved-worktree"
  if [ "$kind" = repository ]; then
    git clone -q "$REPO" "$SEND_WT"
  else
    mkdir -p "$SEND_WT"
  fi
  if dv send EX-1 'must not deliver' > "$CASE_DIR/refused" 2>&1; then return 1; fi
  grep -F "worktree $kind changed" "$CASE_DIR/refused"
  test "$(cat "$SEND_STATE/stub-count")" = 1
  cmp "$CASE_DIR/send-identity" <(jq '{issue,repo,worktree,branch,started,award_token,thread_id,herdr_pane}' "$SEND_STATE/meta")
}
case_send_branch_replaced_repo() { send_branch_replaced repository; }
case_send_branch_replaced_path() { send_branch_replaced path; }
