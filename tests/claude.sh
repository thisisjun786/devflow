#!/usr/bin/env bash
# jq programs and child-shell snippets are literal strings.
# shellcheck disable=SC2016
claude_functions() {
  DV_ENTRY="$ROOT/bin/dv"
  # shellcheck source=lib/common.sh
  source "$ROOT/lib/common.sh"
}
claude_profile_setup() {
  export CLAUDE_CONFIG_DIR="$CASE_DIR/Claude profile"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{"hasCompletedOnboarding":true,"theme":"keep","projects":{"/other":{"history":[1]}}}\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
  printf '{"skipDangerousModePermissionPrompt":true,"other":"keep"}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
}
case_claude_profile_onboarding() {
  claude_functions; claude_profile_setup
  cp "$HOME/.claude.json" "$CASE_DIR/default-before"
  cp "$HOME/.claude/settings.json" "$CASE_DIR/default-settings-before"
  printf '{"hasCompletedOnboarding":false}\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
  claude_onboarding | jq -e '.hasCompletedOnboarding==false and .skipDangerousModePermissionPrompt==true'
  printf '{"hasCompletedOnboarding":true}\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
  printf '{"skipDangerousModePermissionPrompt":false}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  claude_onboarding | jq -e '.hasCompletedOnboarding==true and .skipDangerousModePermissionPrompt==false'
  printf '{broken\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
  printf '{} {}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  claude_onboarding | jq -e '.hasCompletedOnboarding==false and .skipDangerousModePermissionPrompt==false'
  rm "$CLAUDE_CONFIG_DIR/.claude.json" "$CLAUDE_CONFIG_DIR/settings.json"
  claude_onboarding | jq -e '.hasCompletedOnboarding==false and .skipDangerousModePermissionPrompt==false'
  test ! -e "$CLAUDE_CONFIG_DIR/.claude.json"
  test ! -e "$CLAUDE_CONFIG_DIR/settings.json"
  cmp "$HOME/.claude.json" "$CASE_DIR/default-before"
  cmp "$HOME/.claude/settings.json" "$CASE_DIR/default-settings-before"
  CLAUDE_CONFIG_DIR='' claude_onboarding | jq -e '.hasCompletedOnboarding and .skipDangerousModePermissionPrompt'
  # Explicitly selecting ~/.claude still puts the state file inside it.
  CLAUDE_CONFIG_DIR="$HOME/.claude" claude_onboarding | jq -e '.hasCompletedOnboarding==false and .skipDangerousModePermissionPrompt==true'
}
case_claude_profile_trust() {
  claude_functions; claude_profile_setup
  cp "$HOME/.claude.json" "$CASE_DIR/default-before"
  cp "$CLAUDE_CONFIG_DIR/.claude.json" "$CASE_DIR/profile-before"
  cp "$CLAUDE_CONFIG_DIR/settings.json" "$CASE_DIR/settings-before"
  local path="$CASE_DIR/work tree/quote\" and \\ slash"
  # A lock on the default profile must not block a different profile.
  : > "$HOME/.claude.json.dv-lock"
  mv() {
    test "$(dirname "$1")" = "$CLAUDE_CONFIG_DIR" || return 2
    test -f "$CLAUDE_CONFIG_DIR/.claude.json.dv-lock" || return 2
    test "$2" = "$CLAUDE_CONFIG_DIR/.claude.json" || return 2
    command mv "$@"
  }
  claude_trust_worktree "$path"
  unset -f mv
  jq -e --arg path "$path" --slurpfile before "$CASE_DIR/profile-before" '.==($before[0] | .projects[$path].hasTrustDialogAccepted=true)' "$CLAUDE_CONFIG_DIR/.claude.json"
  cp "$CLAUDE_CONFIG_DIR/.claude.json" "$CASE_DIR/profile-once"
  claude_trust_worktree "$path"
  cmp "$CLAUDE_CONFIG_DIR/.claude.json" "$CASE_DIR/profile-once"
  cmp "$HOME/.claude.json" "$CASE_DIR/default-before"
  cmp "$CLAUDE_CONFIG_DIR/settings.json" "$CASE_DIR/settings-before"
  test -f "$HOME/.claude.json.dv-lock"
  test ! -e "$CLAUDE_CONFIG_DIR/.claude.json.dv-lock"
  test -z "$(find "$CLAUDE_CONFIG_DIR" -name '.claude.json.dv-tmp.*' -print)"
}
case_claude_profile_create() {
  claude_functions
  export CLAUDE_CONFIG_DIR="$CASE_DIR/new profile/nested"
  cp "$HOME/.claude.json" "$CASE_DIR/default-before"
  claude_onboarding | jq -e '.hasCompletedOnboarding==false and .skipDangerousModePermissionPrompt==false'
  test ! -e "$CLAUDE_CONFIG_DIR"
  claude_trust_worktree /target
  jq -e '.=={projects:{"/target":{hasTrustDialogAccepted:true}}}' "$CLAUDE_CONFIG_DIR/.claude.json"
  test -n "$(find "$CLAUDE_CONFIG_DIR/.claude.json" -perm 600 -print)"
  test ! -e "$CLAUDE_CONFIG_DIR/settings.json"
  cmp "$HOME/.claude.json" "$CASE_DIR/default-before"
}
case_claude_profile_invalid() {
  claude_functions; claude_profile_setup
  cp "$HOME/.claude.json" "$CASE_DIR/default-before"
  printf '{broken\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
  cp "$CLAUDE_CONFIG_DIR/.claude.json" "$CASE_DIR/profile-before"
  if claude_trust_worktree /target; then return 1; fi
  cmp "$CLAUDE_CONFIG_DIR/.claude.json" "$CASE_DIR/profile-before"
  rm "$CLAUDE_CONFIG_DIR/.claude.json"
  ln -s "$CASE_DIR/profile-before" "$CLAUDE_CONFIG_DIR/.claude.json"
  if claude_trust_worktree /target; then return 1; fi
  test -L "$CLAUDE_CONFIG_DIR/.claude.json"
  cmp "$HOME/.claude.json" "$CASE_DIR/default-before"
  test ! -e "$CLAUDE_CONFIG_DIR/.claude.json.dv-lock"
  test -z "$(find "$CLAUDE_CONFIG_DIR" -name '.claude.json.dv-tmp.*' -print)"
}
case_claude_trust_mode() {
  claude_functions
  local mode
  for mode in 600 640 660 400 440 4600 2640; do
    chmod "$mode" "$HOME/.claude.json"
    claude_trust_worktree /target
    test -n "$(find "$HOME/.claude.json" -perm "$mode" -print)"
  done
  chmod 600 "$HOME/.claude.json"
}
claude_acl() {
  case "$(uname -s)" in
    Linux) getfacl -cp "$1" ;;
    Darwin) ls -le "$1" | sed -n '/^[[:space:]]*[0-9][0-9]*:/p' ;;
    *) return 1 ;;
  esac
}
case_claude_trust_acl() {
  claude_functions
  case "$(uname -s)" in
    Linux) setfacl -m u:65534:r-- "$HOME/.claude.json" ;;
    Darwin) chmod +a "$(id -un) allow read" "$HOME/.claude.json" ;;
    *) return 1 ;;
  esac
  claude_acl "$HOME/.claude.json" > "$CASE_DIR/acl-before"
  test -s "$CASE_DIR/acl-before"
  claude_trust_worktree /target
  claude_acl "$HOME/.claude.json" > "$CASE_DIR/acl-after"
  cmp "$CASE_DIR/acl-before" "$CASE_DIR/acl-after"
}
case_claude_trust_copy_failure() {
  claude_functions
  cp "$HOME/.claude.json" "$CASE_DIR/before"
  # Metadata-copy failure must never replace the original with a bare mktemp.
  cp() { return 1; }
  if claude_trust_worktree /target; then return 1; fi
  unset -f cp
  cmp "$HOME/.claude.json" "$CASE_DIR/before"
  test ! -e "$HOME/.claude.json.dv-lock"
  test -z "$(find "$HOME" -name '.claude.json.dv-tmp.*' -print)"
}
case_claude_profile_start() {
  repo claude-profile; herdr_setup; claude_profile_setup
  export DV_CLAUDE_BIN="$ROOT/tests/fixtures/claude"
  printf '{"hasCompletedOnboarding":false}\n' > "$HOME/.claude.json"
  printf '{"skipDangerousModePermissionPrompt":false}\n' > "$HOME/.claude/settings.json"
  cp "$HOME/.claude.json" "$CASE_DIR/default-before"
  dv start "$REPO" CP-1 trust --agent claude
  wait_native CP-1
  test -f "$DV_STATE/CP-1/trust-before-launch"
  cmp "$HOME/.claude.json" "$CASE_DIR/default-before"
}
case_claude_stale_server() {
  needs_tmux; repo stale-profile
  # Start the server before the caller selects a profile.
  tmux -L "$DV_TMUX_SOCKET" new-session -d -s preexisting 'sleep 60'
  if tmux -L "$DV_TMUX_SOCKET" show-environment -g CLAUDE_CONFIG_DIR; then return 1; fi
  claude_profile_setup
  cp "$HOME/.claude.json" "$CASE_DIR/default-before"
  export DV_CLAUDE_BIN="$ROOT/tests/fixtures/claude"
  dv start "$REPO" CS-1 trust --agent claude
  wait_done CS-1
  local path
  path=$(jq -r .worktree "$DV_STATE/CS-1/meta")
  jq -cn --arg path "$path" --slurpfile profile "$CLAUDE_CONFIG_DIR/.claude.json" --slurpfile default "$HOME/.claude.json" \
    '{selected_profile_trusted:($profile[0].projects[$path].hasTrustDialogAccepted==true),default_profile_trusted:($default[0].projects[$path].hasTrustDialogAccepted==true)}'
  jq -e --arg path "$path" '.projects[$path].hasTrustDialogAccepted==true' "$CLAUDE_CONFIG_DIR/.claude.json"
  test -f "$DV_STATE/CS-1/trust-before-launch"
  cmp "$HOME/.claude.json" "$CASE_DIR/default-before"
}
case_claude_stale_server_empty() {
  needs_tmux; repo stale-profile-empty; claude_profile_setup
  local stale_profile=$CLAUDE_CONFIG_DIR path
  cp "$stale_profile/.claude.json" "$CASE_DIR/profile-before"
  # The server keeps its old selection; an exported empty value must clear it
  # for this launch and select the default profile in both dv and the agent.
  tmux -L "$DV_TMUX_SOCKET" new-session -d -s preexisting 'sleep 60'
  test "$(tmux -L "$DV_TMUX_SOCKET" show-environment -g CLAUDE_CONFIG_DIR)" = "CLAUDE_CONFIG_DIR=$stale_profile"
  export CLAUDE_CONFIG_DIR='' DV_CLAUDE_BIN="$ROOT/tests/fixtures/claude"
  dv start "$REPO" CS-2 trust --agent claude
  wait_done CS-2
  path=$(jq -r .worktree "$DV_STATE/CS-2/meta")
  jq -cn --arg path "$path" --slurpfile stale "$stale_profile/.claude.json" --slurpfile default "$HOME/.claude.json" \
    '{stale_profile_trusted:($stale[0].projects[$path].hasTrustDialogAccepted==true),default_profile_trusted:($default[0].projects[$path].hasTrustDialogAccepted==true)}'
  jq -e --arg path "$path" '.projects[$path].hasTrustDialogAccepted==true' "$HOME/.claude.json"
  test -f "$DV_STATE/CS-2/trust-before-launch"
  cmp "$stale_profile/.claude.json" "$CASE_DIR/profile-before"
}
case_claude_profile_host() {
  host_setup; claude_profile_setup
  "$HOST_DV" host check --json > "$CASE_DIR/profile.json"
  jq -e '.claude.onboarding=={hasCompletedOnboarding:true,skipDangerousModePermissionPrompt:true}' "$CASE_DIR/profile.json"
  test ! -e "$HOME/.claude.json"
  test ! -e "$HOME/.claude"
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
