#!/usr/bin/env bash
# Read isolation only; network and writes to the job's explicit mounts remain open.
# shellcheck disable=SC2016
dsh_jail_probe() {
  DSH_JAIL=off; DSH_JAIL_REASON='disabled by configuration'
  case "$DV_DSH_JAIL" in auto|on|off) ;; *) return 1 ;; esac
  if [ "$(uname -s)" != Linux ]; then DSH_JAIL_REASON='non-Linux host'; return 0; fi
  [ "$DV_DSH_JAIL" != off ] || return 0
  if ! command -v bwrap >/dev/null; then DSH_JAIL_REASON='bwrap unavailable'
  elif ! bwrap --die-with-parent --dev-bind / / -- /bin/true >/dev/null 2>&1; then DSH_JAIL_REASON='bwrap unusable'
  else DSH_JAIL=on; DSH_JAIL_REASON='bwrap available'; return 0; fi
  [ "$DV_DSH_JAIL" != on ]
}
dsh_jail_sessions() {
  printf '%s\n' "$DV_OMP_SESSIONS" "$DV_CODEX_SESSIONS" "$DV_CLAUDE_SESSIONS" \
    "$DV_CURSOR_SESSIONS" "$DV_GROK_SESSIONS" "$DV_AGY_SESSIONS" "$DV_DSH_HOME/sessions" "$DV_DSH_SESSIONS"
}
dsh_jail_path() {
  # Physical paths match both symlinked worktrees and mounts below /data.
  case "$1" in /*) ;; *) printf 'dv: jail paths must be absolute\n' >&2; return 1 ;; esac
  [ -d "$1" ] || return 0
  (cd "$1" && pwd -P)
}
dsh_jail_prepare() {
  local path common sessions binds hides
  dsh_jail_probe || {
    meta_set --arg reason "$DSH_JAIL_REASON" '.dsh_jail={status:"off",reason:$reason}'
    printf 'jail=off %s\n' "$DSH_JAIL_REASON" >> "$S/log"
    return 1
  }
  if [ "$DSH_JAIL" = on ]; then
    sessions=$(agent_transcript_dir dsh "$(pwd -P)") || return 1
    mkdir -p "$sessions"
    common=$(cd "$WT" && cd "$(git rev-parse --git-common-dir)" && pwd -P) || return 1
    hides=$(printf '%s\n' "$HOME/code" "$DV_WORK" /data /scratch /mnt /media /tmp "$HOME/.hermes" "$DV_DSH_JAIL_HIDE"; dsh_jail_sessions)
    binds=$(printf '%s\n' "$WT" "$common" "$DV_ROOT" "$DV_STATE" "$DV_HOME" "$DV_TMP" "${TMPDIR:-/tmp}" \
      "${GOCACHE:-$HOME/.cache/go-build}" "${GOMODCACHE:-${GOPATH:-$HOME/.local/go}/pkg/mod}" \
      "$HOME/.local/dsh" "$HOME/node" "$DV_DSH_HOME" "${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}" "$DV_DSH_JAIL_BIND")
    DSH_JAIL_ARGS=(--die-with-parent --dev-bind / /)
    # Parent mounts precede children. All hidden roots precede every rebind.
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      path=$(dsh_jail_path "$path") || return 1
      [ -z "$path" ] || DSH_JAIL_ARGS+=(--tmpfs "$path")
    done < <(printf '%s\n' "$hides" | LC_ALL=C sort -u)
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      path=$(dsh_jail_path "$path") || return 1
      [ -z "$path" ] || DSH_JAIL_ARGS+=(--bind "$path" "$path")
    done < <(printf '%s\n' "$binds" | LC_ALL=C sort -u)
    # Binding a runtime home must not reopen any of its session stores.
    while IFS= read -r path; do
      path=$(dsh_jail_path "$path") || return 1
      [ -z "$path" ] || DSH_JAIL_ARGS+=(--tmpfs "$path")
    done < <(dsh_jail_sessions | LC_ALL=C sort -u)
    DSH_JAIL_ARGS+=(--bind "$sessions" "$sessions" --chdir "$WT")
    # Probe the complete mount plan too: individual bind destinations can be
    # unavailable even on a host where the basic namespace probe succeeded.
    if ! bwrap "${DSH_JAIL_ARGS[@]}" -- /bin/true >/dev/null 2>&1; then
      DSH_JAIL=off; DSH_JAIL_REASON='bwrap mount plan unavailable'
    fi
  fi
  meta_set --arg status "$DSH_JAIL" --arg reason "$DSH_JAIL_REASON" '.dsh_jail={status:$status,reason:$reason}'
  printf 'jail=%s %s\n' "$DSH_JAIL" "$DSH_JAIL_REASON" >> "$S/log"
  [ "$DV_DSH_JAIL" != on ] || [ "$DSH_JAIL" = on ] || [ "$(uname -s)" != Linux ]
}
