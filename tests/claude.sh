#!/usr/bin/env bash
# jq programs and child-shell snippets are literal strings.
# shellcheck disable=SC2016
claude_functions() {
  DV_ENTRY="$ROOT/bin/dv"
  # shellcheck source=lib/common.sh
  source "$ROOT/lib/common.sh"
}
case_claude_trust_create() {
  claude_functions
  rm "$HOME/.claude.json"
  local path="$CASE_DIR/work tree/quote\" and \\ slash"
  claude_trust_worktree "$path"
  jq -e --arg path "$path" '.=={projects:{($path):{hasTrustDialogAccepted:true}}}' "$HOME/.claude.json"
  test ! -e "$HOME/.claude.json.dv-lock"
}
case_claude_trust_preserve() {
  claude_functions
  printf '{"hasCompletedOnboarding":true,"theme":"dark","projects":{"/other":{"hasTrustDialogAccepted":false,"history":[1]},"/target":{"hasTrustDialogAccepted":false,"allowedTools":["Read"]}}}\n' > "$HOME/.claude.json"
  cp "$HOME/.claude.json" "$CASE_DIR/before"
  claude_trust_worktree /target
  jq -e --slurpfile before "$CASE_DIR/before" '.==($before[0] | .projects["/target"].hasTrustDialogAccepted=true)' "$HOME/.claude.json"
  cp "$HOME/.claude.json" "$CASE_DIR/once"
  claude_trust_worktree /target
  cmp "$HOME/.claude.json" "$CASE_DIR/once"
}
case_claude_trust_parallel() {
  claude_functions
  local n pid rc=0 pids=()
  # Hold the shared lock until every writer has been launched; they must all
  # read the latest document after acquiring it, not before waiting.
  : > "$HOME/.claude.json.dv-lock"
  for n in {1..12}; do
    claude_trust_worktree "$CASE_DIR/work $n" > "$CASE_DIR/writer-$n.log" 2>&1 & pids+=("$!")
  done
  sleep 0.2
  jq '. + {concurrentSetting:"keep"}' "$HOME/.claude.json" > "$CASE_DIR/updated"
  mv "$CASE_DIR/updated" "$HOME/.claude.json"
  rm "$HOME/.claude.json.dv-lock"
  for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
  if [ "$rc" != 0 ]; then cat "$CASE_DIR"/writer-*.log; return 1; fi
  jq -e '.hasCompletedOnboarding==true and .concurrentSetting=="keep" and (.projects|length)==12 and all(.projects[]; .hasTrustDialogAccepted==true)' "$HOME/.claude.json"
  test ! -e "$HOME/.claude.json.dv-lock"
}
case_claude_trust_invalid() {
  claude_functions
  local value
  for value in '' '{broken' '[]' 'null' '{} {}' '{"projects":[]}' '{"projects":{"/target":false}}'; do
    printf '%s\n' "$value" > "$HOME/.claude.json"
    cp "$HOME/.claude.json" "$CASE_DIR/before"
    if claude_trust_worktree /target; then return 1; fi
    cmp "$HOME/.claude.json" "$CASE_DIR/before"
    test ! -e "$HOME/.claude.json.dv-lock"
  done
  rm "$HOME/.claude.json"
  ln -s "$CASE_DIR/before" "$HOME/.claude.json"
  if claude_trust_worktree /target; then return 1; fi
  test -L "$HOME/.claude.json"
}
case_claude_trust_atomic() {
  claude_functions
  cp "$HOME/.claude.json" "$CASE_DIR/before"
  # Inspect the original at the rename boundary, then inject rename failure.
  mv() {
    cmp "$HOME/.claude.json" "$CASE_DIR/before" || return 2
    jq -e '.projects["/target"].hasTrustDialogAccepted==true' "$1" || return 2
    test "$(dirname "$1")" = "$HOME" || return 2
    touch "$CASE_DIR/rename-reached"
    return 1
  }
  if claude_trust_worktree /target; then return 1; fi
  unset -f mv
  test -f "$CASE_DIR/rename-reached"
  cmp "$HOME/.claude.json" "$CASE_DIR/before"
  test ! -e "$HOME/.claude.json.dv-lock"
  test -z "$(find "$HOME" -name '.claude.json.dv-tmp.*' -print)"
}
case_claude_onboarding() {
  claude_functions
  claude_onboarding | jq -e '.hasCompletedOnboarding==true and .skipDangerousModePermissionPrompt==true'
  local value
  for value in '{}' '{"hasCompletedOnboarding":false}' '{"hasCompletedOnboarding":"true"}' '{broken' '' '[]' '{"hasCompletedOnboarding":true} {}'; do
    printf '%s\n' "$value" > "$HOME/.claude.json"
    claude_onboarding | jq -e '.hasCompletedOnboarding==false and .skipDangerousModePermissionPrompt==true'
  done
  rm "$HOME/.claude.json" "$HOME/.claude/settings.json"
  claude_onboarding | jq -e '.hasCompletedOnboarding==false and .skipDangerousModePermissionPrompt==false'
  test ! -e "$HOME/.claude.json"
}
case_claude_start() {
  repo claude; herdr_setup
  export DV_CLAUDE_BIN="$ROOT/tests/fixtures/claude"
  dv start "$REPO" CT-1 trust --agent claude
  wait_native CT-1
  test -f "$DV_STATE/CT-1/trust-before-launch"
}
case_claude_start_tmux() {
  needs_tmux; repo claude-tmux
  export DV_CLAUDE_BIN="$ROOT/tests/fixtures/claude"
  dv start "$REPO" CT-2 trust --agent claude
  wait_done CT-2
  test -f "$DV_STATE/CT-2/trust-before-launch"
}
case_claude_start_failed() {
  repo claude-failed; herdr_setup
  export DV_CLAUDE_BIN="$ROOT/tests/fixtures/claude" DV_AWARD_TOKEN=test-token
  local mode issue
  for mode in onboarding bypass missing invalid; do
    issue="CF-$mode"
    printf '{"hasCompletedOnboarding":true}\n' > "$HOME/.claude.json"
    printf '{"skipDangerousModePermissionPrompt":true,"other":"keep"}\n' > "$HOME/.claude/settings.json"
    case "$mode" in
      onboarding) printf '{"hasCompletedOnboarding":false}\n' > "$HOME/.claude.json" ;;
      bypass) printf '{"skipDangerousModePermissionPrompt":false,"other":"keep"}\n' > "$HOME/.claude/settings.json" ;;
      missing) rm "$HOME/.claude.json" ;;
      invalid) printf '{broken\n' > "$HOME/.claude.json" ;;
    esac
    cp "$HOME/.claude/settings.json" "$CASE_DIR/settings-before"
    dv start "$REPO" "$issue" trust --agent claude
    wait_file "$CASE_DIR/herdr/w-$issue/exit"
    test "$(cat "$CASE_DIR/herdr/w-$issue/exit")" != 0
    test "$(cat "$DV_STATE/$issue/agent.exit")" != 0
    jq -e '.status=="start-failed" and (.failure_reason|length)>0' "$DV_STATE/$issue/meta"
    jq -se '[.[]|select(.kind=="failed")]|length==1' "$DV_STATE/$issue/events.log"
    if [ "$mode" != invalid ]; then
      jq -e '.failure_reason|contains("기기에서 claude를 한 번 대화형으로 실행해 온보딩을 끝내라")' "$DV_STATE/$issue/meta"
    fi
    test ! -f "$DV_STATE/$issue/claude-launched"
    test ! -f "$DV_STATE/$issue/agent.started"
    cmp "$HOME/.claude/settings.json" "$CASE_DIR/settings-before"
  done
  jq -se 'all(.[]; .[0]!="pane" or .[1]!="send-keys")' "$CASE_DIR/herdr/calls"
}
case_claude_host() {
  host_setup
  "$HOST_DV" host check --json > "$CASE_DIR/missing.json"
  jq -e '.claude.onboarding=={hasCompletedOnboarding:false,skipDangerousModePermissionPrompt:false}' "$CASE_DIR/missing.json"
  test ! -e "$HOME/.claude.json"
  test ! -e "$HOME/.claude"
  mkdir "$HOME/.claude"
  printf '{"hasCompletedOnboarding":true,"private":"hidden"}\n' > "$HOME/.claude.json"
  printf '{"skipDangerousModePermissionPrompt":false}\n' > "$HOME/.claude/settings.json"
  "$HOST_DV" host check --json > "$CASE_DIR/partial.json"
  jq -e '.claude.onboarding=={hasCompletedOnboarding:true,skipDangerousModePermissionPrompt:false}' "$CASE_DIR/partial.json"
  printf '{"skipDangerousModePermissionPrompt":true}\n' > "$HOME/.claude/settings.json"
  cp "$HOME/.claude.json" "$CASE_DIR/before"
  cp "$HOME/.claude/settings.json" "$CASE_DIR/settings-before"
  "$HOST_DV" host check --json > "$CASE_DIR/ready.json"
  jq -e '.claude.onboarding=={hasCompletedOnboarding:true,skipDangerousModePermissionPrompt:true}' "$CASE_DIR/ready.json"
  "$HOST_DV" host check > "$CASE_DIR/ready.txt"
  grep -F 'hasCompletedOnboarding=true skipDangerousModePermissionPrompt=true' "$CASE_DIR/ready.txt"
  cmp "$HOME/.claude.json" "$CASE_DIR/before"
  cmp "$HOME/.claude/settings.json" "$CASE_DIR/settings-before"
  if grep -F hidden "$CASE_DIR/ready.json" "$CASE_DIR/ready.txt"; then return 1; fi
}
