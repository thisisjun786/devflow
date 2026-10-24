#!/usr/bin/env bash
# Synthetic large inputs; no terminal, provider or GitHub processes required.
# Fixture callbacks and dynamically scoped product state are intentional.
# shellcheck disable=SC2034,SC2154,SC2317,SC2329
pipefail_lines() {
  awk 'BEGIN { for (i=1; i<=10000; i++) print "synthetic trailing output with no marker" }'
}
pipefail_screen_setup() {
  bidding_functions
  BACKEND=tmux SESSION=synthetic DV_START_WAIT=1 S=$CASE_DIR
  now() { cat "$CASE_DIR/clock"; }
  sleep() { printf '2\n' > "$CASE_DIR/clock"; }
  codex_screen() { cat "$CASE_DIR/screen"; }
  read_session() { codex_screen; }
  codex_start_failed() { return 1; }
  printf '0\n' > "$CASE_DIR/clock"
}
case_screen_large_hook() {
  pipefail_screen_setup
  codex_hook_trust_required "$(printf 'Hook needs review\n'; pipefail_lines)"
  if codex_hook_trust_required "$(pipefail_lines)"; then return 1; fi
}
case_screen_large_folder() {
  pipefail_screen_setup
  codex_folder_trust_required "$(printf 'Trust this directory\n'; pipefail_lines)"
  if codex_folder_trust_required "$(pipefail_lines)"; then return 1; fi
}
case_screen_large_goal() {
  pipefail_screen_setup
  { printf '* Pursuing goal\n'; pipefail_lines; } > "$CASE_DIR/screen"
  wait_codex_goal test
}
case_screen_large_ready() {
  pipefail_screen_setup
  DV_READY_PATTERN='^dv-ready>'
  { printf 'dv-ready>\n'; pipefail_lines; } > "$CASE_DIR/screen"
  send_text() { printf '%s\n' "$1" > "$CASE_DIR/sent"; }
  wait_codex_goal() { :; }
  inject_goal test
  grep -Fx '/goal test' "$CASE_DIR/sent"
}
case_screen_large_accept() {
  pipefail_screen_setup
  { printf 'Do you trust this folder?\n'; pipefail_lines; } > "$CASE_DIR/screen"
  session_enter() { touch "$CASE_DIR/entered"; }
  accept_folder_trust
  test -f "$CASE_DIR/entered"
}
case_screen_large_panes() {
  pipefail_screen_setup
  tmux_dv() { printf '0 1\n'; awk 'BEGIN { for (i=1; i<=10000; i++) print i, 0 }'; }
  agent_gone
}
pipefail_job_error() {
  job_test_load
  local message=$1 expected=$2
  JOB_ATTEMPT="$S/attempt"; mkdir "$JOB_ATTEMPT"
  # The classifier keeps 50 lines, but there is no limit on line width.
  { printf '%s\n' "$message"; awk 'BEGIN { for (i=1; i<=40; i++) printf "%16384s\n", "trailing output" }'; } > "$JOB_ATTEMPT/stderr"
  test "$(job_fallback_reason 1)" = "$expected"
  printf 'ordinary error\n' > "$JOB_ATTEMPT/stderr"
  test -z "$(job_fallback_reason 1)"
}
case_job_large_nproc() { pipefail_job_error 'fork: Resource temporarily unavailable' ulimit-nproc; }
case_job_large_memory() { pipefail_job_error 'runtime: out of memory' ulimit-memory; }
pipefail_dsh_stderr() (
  bidding_functions
  local phase=$1 rc=0 probes=0
  S="$CASE_DIR/dsh" ISSUE=PIPE-1; mkdir "$S"
  printf '{"status":"running"}\n' > "$S/meta"
  dsh_jail_prepare() { DSH_JAIL=off; }
  agent_transcript_dir() { printf '%s\n' "$S"; }
  dsh_exec_session_stamp() { :; }
  dsh_exec_tool_age() { printf '%s\n' -1; }
  dsh_event() { :; }
  dsh_restart_prompt() { :; }
  capacity_clear() { :; }
  capacity_wait() { touch "$S/capacity-wait"; return 1; }
  dsh_exec_stop() {
    if [ -n "${exec_child:-}" ]; then
      touch "$S/stopped"
      wait "$exec_child" || true
      exec_child=''
    fi
  }
  # A complete large stderr batch is visible at the first liveness probe.
  # Select the polling path or the post-exit path deterministically.
  dsh_child() {
    { printf 'dsh: QUOTA: exhausted\n'; pipefail_lines; } >&2
    touch "$S/batch-ready"
  }
  kill() {
    if [ "$1" = -0 ]; then
      while [ ! -f "$S/batch-ready" ]; do command sleep 0.01; done
      probes=$((probes + 1))
      [ "$phase" = polling ] && [ "$probes" = 1 ]
    else builtin kill "$@"; fi
  }
  dsh_exec_run test || rc=$?
  test "$rc" = 1
  test -f "$S/capacity-wait"
  jq -e '.exec_status=="blocked" and (.dsh_failures // 0)==0' "$S/meta"
  if [ "$phase" = polling ]; then test -f "$S/stopped"
  else test ! -e "$S/stopped"; fi
)
case_dsh_large_stderr_polling() { pipefail_dsh_stderr polling; }
case_dsh_large_stderr_exit() { pipefail_dsh_stderr exit; }
