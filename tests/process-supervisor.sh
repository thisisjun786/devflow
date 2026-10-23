#!/usr/bin/env bash
# Sourced by run.sh. Keep the heavy fd in the supervisor, never in fixtures.
runner_group_ids() {
  local file child
  for file in "$1"/groups/*; do
    [ -f "$file" ] || continue
    printf '%s\n' "${file##*/}"
  done
  for file in "$1"/children/*; do
    [ -f "$file" ] || continue
    child=$(cat "$file" 2>/dev/null) || continue
    [ ! -d "$child" ] || runner_group_ids "$child"
  done
}
runner_live_groups() {
  local groups
  # BSD awk rejects literal newlines in a -v value. Group IDs are integers;
  # pass one whitespace-delimited line rather than a multiline string.
  groups=$(runner_group_ids "$DV_TEST_PROCESS_DIR" | tr '\n' ' ')
  "$DV_TEST_PS" -eo pgid=,stat= | awk -v groups="$groups" '
    BEGIN {n=split(groups,a," "); for(i=1;i<=n;i++) owned[a[i]]=1}
    owned[$1] && $2 !~ /^Z/ {live[$1]=1}
    END {for(g in live) print g}'
}
runner_remove_case_dirs() {
  local dir=$1 file child case_dir
  for file in "$dir"/children/*; do
    [ -f "$file" ] || continue
    child=$(cat "$file" 2>/dev/null) || continue
    [ ! -d "$child" ] || runner_remove_case_dirs "$child"
  done
  if [ -f "$dir/case-dir" ]; then
    case_dir=$(cat "$dir/case-dir")
    if [ "${DV_TEST_KEEP:-0}" = 1 ] || [ -f "$case_dir/.test-failed" ]; then printf 'Retained: %s\n' "$case_dir"
    else rm -rf "$case_dir"; fi
  fi
  rm -rf "$dir"
}
runner_stop_tmux() {
  local dir=$1 file child socket
  for file in "$dir"/children/*; do
    [ -f "$file" ] || continue
    child=$(cat "$file" 2>/dev/null) || continue
    [ ! -d "$child" ] || runner_stop_tmux "$child"
  done
  if [ -f "$dir/tmux-socket" ] && command -v tmux >/dev/null; then
    socket=$(cat "$dir/tmux-socket" 2>/dev/null) || return 0
    [ -z "$socket" ] || tmux -L "$socket" kill-server 2>/dev/null || true
  fi
}
runner_cleanup_case() {
  local rc=$? groups group _
  # Preserve failed fixtures even when a case supplies its own EXIT handler.
  if [ "$rc" != 0 ] && [ "$rc" != 77 ]; then DV_TEST_KEEP=1; fi
  trap - EXIT
  trap '' TERM INT HUP
  runner_stop_tmux "$DV_TEST_PROCESS_DIR"
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
  runner_remove_case_dirs "$DV_TEST_PROCESS_DIR"
  exit "$rc"
}
runner_supervise_case() {
  local runner_child='' rc=0 process_root=${DV_TEST_TMP:-${TMPDIR:-/tmp}} parent=${DV_TEST_PROCESS_DIR:-}
  # A parent must own nested registries too: simultaneous TERM of both
  # supervisors must not let the outer KILL deadline strand inner fixtures.
  # Keep the registry in the child's selected scratch root; only its reference
  # belongs to the parent, which may have a different DV_TEST_TMP/TMPDIR.
  DV_TEST_PROCESS_DIR=$(mktemp -d "$process_root/dv-processes.XXXXXX")
  mkdir "$DV_TEST_PROCESS_DIR/groups"
  if [ -n "$parent" ] && [ -d "$parent/groups" ]; then
    mkdir -p "$parent/children"
    printf '%s\n' "$DV_TEST_PROCESS_DIR" > "$parent/children/$$-${DV_TEST_PROCESS_DIR##*/}"
  fi
  DV_TEST_PS=${DV_TEST_PS:-$(command -v ps)}
  DV_TEST_SUPERVISOR_GROUP=$("$DV_TEST_PS" -o pgid= -p "$$")
  DV_TEST_SUPERVISOR_GROUP=${DV_TEST_SUPERVISOR_GROUP//[[:space:]]/}
  export DV_TEST_PROCESS_DIR DV_TEST_SUPERVISOR_GROUP DV_TEST_PS
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
