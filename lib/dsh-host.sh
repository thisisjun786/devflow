#!/usr/bin/env bash
# dsh uses a private npm prefix; host checks never print provider credentials.
# Probe state is local to the subshell; host_dsh_check probes independently.
# shellcheck disable=SC2016,SC2030,SC2031
host_dsh_sync() {
  local installed='' profile tmp
  dsh_validate
  dsh_node_ready || fail 'dsh requires Node >= 24.9; install a supported Node before host sync'
  installed=$(DV_DSH_BIN="$HOME/.local/dsh/node_modules/.bin/dsh" dsh_version) || true
  if [ "$installed" != "$DV_DSH_VERSION" ]; then
    need npm
    mkdir -p "$HOME/.local/dsh"
    npm install --prefix "$HOME/.local/dsh" --save-exact "@deepseek-ai/dsh@$DV_DSH_VERSION"
    # Installation is always in the documented private prefix, even if the
    # configured runner deliberately points at another binary.
    installed=$(DV_DSH_BIN="$HOME/.local/dsh/node_modules/.bin/dsh" dsh_version) || true
    [ "$installed" = "$DV_DSH_VERSION" ] || fail 'installed dsh has unexpected version'
  fi
  profile="$DV_DSH_HOME/profiles/$DV_DSH_PROFILE"
  mkdir -p "$profile"
  tmp=$(mktemp "$profile/.cordis.patch.XXXXXX") || return 1
  if ! cat "$DV_ROOT/templates/dsh/headless.cordis.patch.yml" > "$tmp"; then rm -f "$tmp"; return 1; fi
  if cmp -s "$tmp" "$profile/cordis.patch.yml"; then rm "$tmp"
  else mv "$tmp" "$profile/cordis.patch.yml"; fi
}
host_probe_dsh() (
  # dsh_child consumes run and DSH_JAIL_ARGS via Bash dynamic scope.
  # shellcheck disable=SC2034
  local S run=first dir session rc=0 DSH_JAIL=off
  # shellcheck disable=SC2034
  local DSH_JAIL_ARGS=()
  dsh_ready || return 1
  # Telemetry creation must be detectable; do not remove an existing identity.
  [ ! -e "$DV_DSH_HOME/.anonymous-user-id" ] || return 1
  tmp_make dir dv-host-probe || return 1
  trap 'rm -rf "$dir"' EXIT
  cd "$dir" || return 1
  S=$dir
  mkdir -p "$S/exec/first" "$S/exec/resume"
  printf 'Use the shell tool exactly once to run printf devflow-dsh-smoke, then reply OK.\n' > "$dir/prompt"
  host_limit 60 dsh_child "$DV_DSH_BIN" --profile "$DV_DSH_PROFILE" --json - < "$dir/prompt" > "$dir/first.jsonl" 2>/dev/null || return 1
  jq -se '([.[]|select(.type=="tool_call")]|length)==1 and ([.[]|select(.type=="status" and .phase=="turn_end")]|last|.reason.kind=="completed")' "$dir/first.jsonl" >/dev/null || return 1
  session=$(jq -sr '[.[]|select(.type=="session")|.session.sessionId // .sessionId][0] // empty' "$dir/first.jsonl")
  [[ "$session" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  # shellcheck disable=SC2034
  run=resume
  printf 'Reply OK to confirm this session resumed.\n' > "$dir/prompt"
  host_limit 60 dsh_child "$DV_DSH_BIN" --profile "$DV_DSH_PROFILE" --json --session-id "$session" - < "$dir/prompt" > "$dir/resume.jsonl" 2>/dev/null || rc=$?
  [ "$rc" = 0 ] && jq -se '[.[]|select(.type=="status" and .phase=="turn_end")]|last|.reason.kind=="completed"' "$dir/resume.jsonl" >/dev/null &&
    [ ! -e "$DV_DSH_HOME/.anonymous-user-id" ]
)
host_dsh_check() {
  local version='' profile=false key=false node=false jail_rc=0
  version=$(dsh_version) || true
  [ ! -f "$DV_DSH_HOME/profiles/$DV_DSH_PROFILE/cordis.patch.yml" ] || profile=true
  if dsh_key >/dev/null; then key=true; fi
  if dsh_node_ready; then node=true; fi
  dsh_jail_probe || jail_rc=$?
  jq -cn --arg version "$version" --arg expected "$DV_DSH_VERSION" --arg profile "$DV_DSH_PROFILE" \
    --argjson present "$profile" --argjson key "$key" --argjson node "$node" \
    --arg jail "$DSH_JAIL" --arg reason "$DSH_JAIL_REASON" --argjson jail_rc "$jail_rc" \
    '{version:$version,expected:$expected,profile:$profile,profile_present:$present,key_present:$key,node_ready:$node,
      jail:{status:$jail,reason:$reason,required_unavailable:($jail_rc!=0)}}'
}
