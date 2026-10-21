#!/usr/bin/env bash
# Reproduce macOS path and stat semantics without a macOS runner.
symlink_tmp_case() {
  mkdir -p "$CASE_DIR/physical"
  [ -L "$CASE_DIR/logical" ] || ln -s "$CASE_DIR/physical" "$CASE_DIR/logical"
  TMPDIR="$CASE_DIR/logical/" DV_TEST_TMP="$CASE_DIR/logical/" bash "$ROOT/tests/run.sh" --case "$1"
}
case_symlink_paths() {
  local name
  for name in codex_persisted_trust codex_trust_conflict codex_trust_duplicate codex_trust_formats codex_trust_refuse codex_trust_linked submit_local_origin manager_moved_checkout; do
    # Each child gets a fresh setup/teardown under the same symlinked parent.
    symlink_tmp_case "$name"
  done
}
case_symlink_claude_stale_server() { needs_tmux; symlink_tmp_case claude_stale_server; }
case_symlink_claude_stale_server_empty() { needs_tmux; symlink_tmp_case claude_stale_server_empty; }
case_symlink_revive_dead() { symlink_tmp_case revive_dead; }
case_symlink_revive_tmux() { needs_tmux; symlink_tmp_case revive_tmux; }
case_revive_wait_exit() {
  # Completion metadata precedes the fake terminal wrapper's final writes.
  RV_STATE="$DV_STATE/RV-1"
  mkdir -p "$RV_STATE/revive" "$CASE_DIR/herdr/w-RV-1"
  touch "$RV_STATE/revived-input.json" "$RV_STATE/agent.exit" "$RV_STATE/revive/done"
  local writer rc=0
  (sleep 0.3; touch "$CASE_DIR/herdr/w-RV-1/exit") & writer=$!
  revive_wait
  test -f "$CASE_DIR/herdr/w-RV-1/exit" || rc=1
  wait "$writer"
  return "$rc"
}
case_claude_bsd_stat_mode() (
  claude_functions
  # BSD stat's L subfield is only the low nine bits; raw %Op includes type
  # and special permission bits. Reject GNU syntax to exercise the fallback.
  stat() {
    case "$1 $2" in
      '-c %a') return 1 ;;
      '-f %Lp') printf '%s\n' "${bsd_mode#?}" ;;
      '-f %Op') printf '10%s\n' "$bsd_mode" ;;
      *) return 1 ;;
    esac
  }
  local bsd_mode
  for bsd_mode in 0600 0640 0660 0400 0440 4600 2640; do
    chmod "$bsd_mode" "$HOME/.claude.json"
    claude_trust_worktree /target
    test -n "$(find "$HOME/.claude.json" -perm "$bsd_mode" -print)"
  done
)
case_host_darwin_shells() (
  # Apple's bash build enables SSH_SOURCE_BASHRC just like GNU bash.
  uname() { if [ "$1" = -s ]; then echo Darwin; else command uname "$@"; fi; }
  case_host_real_shells
)
