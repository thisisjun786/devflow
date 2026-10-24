#!/usr/bin/env bash
# Reproduce macOS path and stat semantics without a macOS runner.
symlink_tmp_case() {
  mkdir -p "$CASE_DIR/physical"
  [ -L "$CASE_DIR/logical" ] || ln -s "$CASE_DIR/physical" "$CASE_DIR/logical"
  # Assigned by the shared test harness.
  # shellcheck disable=SC2153
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
case_symlink_task_land() { needs_tmux; symlink_tmp_case task_land; }
case_symlink_exec_send() {
  # A child shell may report the physical cwd for a symlinked worktree.
  printf 'set -P\n' > "$CASE_DIR/physical-cd"
  BASH_ENV="$CASE_DIR/physical-cd" symlink_tmp_case exec_send
}
case_symlink_send_branch_exec() {
  printf 'set -P\n' > "$CASE_DIR/physical-cd"
  BASH_ENV="$CASE_DIR/physical-cd" symlink_tmp_case send_branch_exec
}
case_symlink_task_mixed_files() { symlink_tmp_case task_mixed_files; }
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
# Fixture functions are called indirectly by loaded helpers.
# shellcheck disable=SC2317,SC2329
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
# Fixture functions are called indirectly by loaded helpers.
# shellcheck disable=SC2317,SC2329
case_host_darwin_shells() (
  # Apple's bash build enables SSH_SOURCE_BASHRC just like GNU bash.
  uname() { if [ "$1" = -s ]; then echo Darwin; else command uname "$@"; fi; }
  case_host_real_shells
)
case_portable_darwin_resources() (
  export DV_ENTRY="$ROOT/bin/dv"
  # shellcheck source=lib/common.sh
  source "$ROOT/lib/common.sh"
  # shellcheck source=lib/bidding.sh
  source "$ROOT/lib/bidding.sh"
  uname() { if [ "$1" = -s ]; then echo Darwin; else command uname "$@"; fi; }
  sysctl() { case "$*" in '-n vm.loadavg') echo '{ 1.50 2.25 3.00 }' ;; '-n hw.pagesize') echo 16384 ;; *) return 1 ;; esac; }
  vm_stat() {
    printf '%s\n' 'Mach Virtual Memory Statistics: (page size of 16384 bytes)' \
      'Pages free:                               65536.' 'Pages active:                            900000.' \
      'Pages inactive:                          131072.' 'Pages speculative:                        65536.' \
      'Pages throttled:                              0.' 'Pages wired down:                        200000.'
  }
  test "$(portable_load5)" = 2.25
  # (free + inactive + speculative) pages of 16 KiB.
  test "$(portable_memory_mb)" = 4096
  bid_resources | jq -e '.load5==2.25 and .memory_available_mb==4096'
)
