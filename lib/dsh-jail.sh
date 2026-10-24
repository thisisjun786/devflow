#!/usr/bin/env bash
# Read isolation only; network and writes to the job's explicit mounts remain open.
# The jail is an allowlist: $HOME and the work roots become empty tmpfs, then
# only the toolchains, caches and job paths below are bound back.
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
dsh_jail_path() {
  # Physical paths match both symlinked worktrees and mounts below /data.
  case "$1" in /*) ;; *) printf 'dv: jail paths must be absolute\n' >&2; return 1 ;; esac
  [ -d "$1" ] || return 0
  (cd "$1" && pwd -P)
}
dsh_jail_mount() {
  # A missing optional path is simply not mounted. The caller has already
  # decided whether the path is read-only or read-write.
  case "$2" in
    /*) ;;
    *) printf 'dv: jail paths must be absolute: %s\n' "$2" >&2; return 1 ;;
  esac
  [ -d "$2" ] || [ -f "$2" ] || return 0
  DSH_JAIL_ARGS+=("--$1" "$2" "$2")
}
dsh_jail_prepare() {
  local path common sessions session_root wt home ro rw scratch
  dsh_jail_probe || {
    meta_set --arg reason "$DSH_JAIL_REASON" '.dsh_jail={status:"off",reason:$reason}'
    printf 'jail=off %s\n' "$DSH_JAIL_REASON" >> "$S/log"
    return 1
  }
  if [ "$DSH_JAIL" = on ]; then
    wt=$(cd "$WT" && pwd -P) || return 1
    home=$(dsh_jail_path "$HOME") || return 1
    [ -n "$home" ] || { printf 'dv: cannot resolve HOME for the dsh jail\n' >&2; return 1; }
    common=$(cd "$WT" && cd "$(git rev-parse --git-common-dir)" && pwd -P) || return 1
    session_root=$(agent_transcript_root dsh) || return 1
    sessions=$(agent_transcript_dir dsh "$wt") || return 1
    mkdir -p "$sessions" "$DV_DSH_HOME" || return 1
    if [ -n "${DV_TMP:-}" ]; then mkdir -p "$DV_TMP" || return 1; fi
    DSH_JAIL_ARGS=(--die-with-parent --dev-bind / /)
    # 1) Empty the user and work roots first. Every later bind is a child.
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      path=$(dsh_jail_path "$path") || return 1
      [ -z "$path" ] || DSH_JAIL_ARGS+=(--tmpfs "$path")
    done < <(printf '%s\n' "$home" /data /scratch /mnt /media /srv /tmp /var/tmp "$DV_WORK" | LC_ALL=C sort -u)
    # 2) Keep only the shared heavy slots and this job's state under DV_STATE.
    if [ -d "$DV_STATE" ]; then DSH_JAIL_ARGS+=(--tmpfs "$DV_STATE"); fi
    # 3) Read-only toolchains and configuration.
    ro=$(printf '%s\n' \
      "$home/node" "$home/.local/bin" "$home/.local/dsh" "$home/sdk" \
      "$home/.bun" "$home/.cargo" "$home/.rustup" \
      "$home/.gitconfig" "$home/.config/git" "${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$home/.config}/gh}" \
      "$home/.config/devflow" "$home/.profile" "$home/.bashrc" "$home/.zshenv" \
      "$DV_ROOT" "${DV_CONFIG:-}")
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      dsh_jail_mount ro-bind "$path" || return 1
    done < <(printf '%s\n' "$ro" | LC_ALL=C sort -u)
    # 4) Writable caches, dv home, job state and the job itself. A scratch root
    # that is itself hidden (the usual TMPDIR=/tmp) must not reopen it.
    scratch=''
    for path in "${DV_TMP:-}" "${TMPDIR:-}"; do
      [ -n "$path" ] || continue
      path=${path%/}
      [ -n "$path" ] || continue
      case "$path" in
        /|/tmp|/var/tmp|/data|/scratch|/mnt|/media|/srv|"$home"|"$DV_WORK") continue ;;
      esac
      case "$home/" in "$path"/*) continue ;; esac
      case "$DV_WORK/" in "$path"/*) continue ;; esac
      scratch="$scratch$path"$'\n'
    done
    rw=$(printf '%s\n' \
      "$home/.local/go" "$home/go" "${GOPATH:-}" \
      "${GOCACHE:-$home/.cache/go-build}" "${GOMODCACHE:-${GOPATH:-$home/.local/go}/pkg/mod}" \
      "$home/.cache/go-build" "$home/.cache/ms-playwright" "$home/.cache/pip" "$home/.cache/uv" \
      "$home/.cache/pnpm" "$home/.local/share/pnpm" "$home/.npm" "$home/.cache/node-gyp" "$home/.pub-cache" \
      "$DV_HOME" "$scratch" \
      "$DV_STATE/.heavy" "$DV_STATE/$ISSUE" \
      "$common" "$wt" "$DV_DSH_HOME" "${DV_DSH_JAIL_BIND:-}")
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      dsh_jail_mount bind "$path" || return 1
    done < <(printf '%s\n' "$rw" | LC_ALL=C sort -u)
    # 5) Other submissions and dsh sessions stay hidden; open this worktree's.
    if [ -d "$DV_HOME" ]; then DSH_JAIL_ARGS+=(--tmpfs "$DV_HOME/submissions"); fi
    DSH_JAIL_ARGS+=(--tmpfs "$session_root")
    dsh_jail_mount bind "$sessions" || return 1
    DSH_JAIL_ARGS+=(--chdir "$wt")
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
