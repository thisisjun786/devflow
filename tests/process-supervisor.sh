#!/usr/bin/env bash
# Sourced by run.sh. Keep the heavy fd in the supervisor, never in fixtures.
runner_live_groups() {
  local file groups=''
  for file in "$DV_TEST_PROCESS_DIR"/groups/*; do
    [ -f "$file" ] || continue
    groups="$groups ${file##*/}"
  done
  ps -eo pgid=,stat= | awk -v groups="$groups" '
    BEGIN {n=split(groups,a," "); for(i=1;i<=n;i++) owned[a[i]]=1}
    owned[$1] && $2 !~ /^Z/ {live[$1]=1}
    END {for(g in live) print g}'
}
runner_cleanup_case() {
  local rc=$? groups group _ case_dir=''
  trap - EXIT
  trap '' TERM INT HUP
  if [ -f "$DV_TEST_PROCESS_DIR/tmux-socket" ] && command -v tmux >/dev/null; then
    tmux -L "$(cat "$DV_TEST_PROCESS_DIR/tmux-socket")" kill-server 2>/dev/null || true
  fi
  groups=$(runner_live_groups)
  for group in $groups; do kill -TERM -- "-$group" 2>/dev/null || true; done
  for _ in {1..30}; do
    groups=$(runner_live_groups)
    [ -n "$groups" ] || break
    sleep 0.1
  done
  for group in $groups; do kill -KILL -- "-$group" 2>/dev/null || true; done
  [ -z "$runner_child" ] || wait "$runner_child" 2>/dev/null || true
  for _ in {1..30}; do
    groups=$(runner_live_groups)
    [ -n "$groups" ] || break
    sleep 0.1
  done
  if [ -n "$groups" ]; then
    printf 'Fixture groups did not stop: %s (retained %s)\n' "$groups" "$DV_TEST_PROCESS_DIR" >&2
    exit 1
  fi
  if [ -f "$DV_TEST_PROCESS_DIR/case-dir" ]; then
    case_dir=$(cat "$DV_TEST_PROCESS_DIR/case-dir")
    if [ "${DV_TEST_KEEP:-0}" = 1 ]; then printf 'Retained: %s\n' "$case_dir"
    else rm -rf "$case_dir"; fi
  fi
  rm -rf "$DV_TEST_PROCESS_DIR"
  exit "$rc"
}
runner_supervise_case() {
  local runner_child='' rc=0
  DV_TEST_PROCESS_DIR=$(mktemp -d "${DV_TEST_TMP:-${TMPDIR:-/tmp}}/dv-processes.XXXXXX")
  mkdir "$DV_TEST_PROCESS_DIR/groups"
  DV_TEST_SUPERVISOR_GROUP=$(ps -o pgid= -p "$$" | tr -d ' ')
  export DV_TEST_PROCESS_DIR DV_TEST_SUPERVISOR_GROUP
  if [ "${BASH_ENV:-}" != "${DV_TEST_PROCESS_SOURCE:-}/process-env.sh" ]; then
    export DV_TEST_PREVIOUS_BASH_ENV=${BASH_ENV:-}
  fi
  export DV_TEST_PROCESS_SOURCE="$ROOT/tests"
  export BASH_ENV="$ROOT/tests/process-env.sh"
  trap runner_cleanup_case EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap 'exit 129' HUP
  # Job control works on macOS Bash 3.2 as well as Linux, without setsid.
  set -m
  DV_TEST_EXECUTE_CASE=1 "$BASH" "$ROOT/tests/run.sh" --case "$1" 9>&- <&0 & runner_child=$!
  set +m
  : > "$DV_TEST_PROCESS_DIR/groups/$runner_child"
  wait "$runner_child" || rc=$?
  exit "$rc"
}
runner_suite_stop() {
  local rc=$1
  trap '' TERM INT HUP
  if [ -n "${runner_case:-}" ]; then
    kill -TERM "$runner_case" 2>/dev/null || true
    wait "$runner_case" 2>/dev/null || true
  fi
  exit "$rc"
}
