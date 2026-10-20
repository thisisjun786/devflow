#!/usr/bin/env bash
# jq programs use literal dollars.
# shellcheck disable=SC2016
claude_onboarding() {
  local onboarding=false bypass=false
  # With an explicit profile Claude keeps both files inside that directory.
  local config="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
  local settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
  # Slurp to reject empty files and streams of multiple JSON documents.
  if jq -se 'length==1 and (.[0] | type=="object" and .hasCompletedOnboarding==true)' "$config" >/dev/null 2>&1; then onboarding=true; fi
  if jq -se 'length==1 and (.[0] | type=="object" and .skipDangerousModePermissionPrompt==true)' "$settings" >/dev/null 2>&1; then bypass=true; fi
  jq -cn --argjson onboarding "$onboarding" --argjson bypass "$bypass" \
    '{hasCompletedOnboarding:$onboarding,skipDangerousModePermissionPrompt:$bypass}'
}
claude_trust_worktree() (
  # All dv writers share this lock; read only after acquiring it so concurrent
  # starts preserve each other's project records. Subshell traps own cleanup.
  local path=$1 config="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" lock
  local tries=0 tmp='' input new=false mode=''
  lock="$config.dv-lock"
  umask 077
  mkdir -p "$(dirname "$config")" || return 1
  until (set -C; : > "$lock") 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 100 ]; then printf 'dv: Claude trust config busy: %s\n' "$lock" >&2; return 1; fi
    sleep 0.1
  done
  trap '[ -z "$tmp" ] || rm -f "$tmp"; rm -f "$lock"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ -L "$config" ] || { [ -e "$config" ] && [ ! -f "$config" ]; }; then
    printf 'dv: Claude trust config must be a regular file: %s\n' "$config" >&2
    return 1
  fi
  input=$config
  if [ ! -e "$config" ]; then input=/dev/null; new=true; fi
  # Same-directory rename exposes either the old complete JSON or the new one.
  # New files are private (600). For existing files, cp -p carries the ACL as
  # well as ownership/mode on Linux and macOS. Abort if preservation fails.
  tmp=$(mktemp "$config.dv-tmp.XXXXXX") || return 1
  if [ "$new" = false ]; then
    mode=$(stat -c '%a' "$config" 2>/dev/null || stat -f '%Lp' "$config") || return 1
    cp -p "$config" "$tmp" || return 1
    chmod u+w "$tmp" || return 1
  fi
  jq -se --arg path "$path" --argjson new "$new" '
    if $new and length==0 then {}
    elif length==1 and (.[0]|type)=="object" then .[0]
    else error("Claude config must contain one JSON object") end |
    if .projects!=null and (.projects|type)!="object" then error("Claude projects must be an object")
    elif .projects[$path]!=null and (.projects[$path]|type)!="object" then error("Claude project must be an object")
    else .projects[$path].hasTrustDialogAccepted=true end
  ' "$input" > "$tmp" || return 1
  # Restore read-only modes and special bits that writing may have cleared;
  # chmod retains the copied ACL entries (and restores the Linux ACL mask).
  if [ "$new" = false ]; then chmod "$mode" "$tmp" || return 1; fi
  mv "$tmp" "$config" || return 1
)
