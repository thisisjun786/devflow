#!/usr/bin/env bash
# Test-only registration. The supervisor owns this directory for the entire
# case, even after a daemon client exits or its PID file is replaced.
if [ -n "${DV_TEST_PROCESS_DIR:-}" ] && [ -d "$DV_TEST_PROCESS_DIR/groups" ]; then
  dv_test_pgid=$(ps -o pgid= -p "$$" | tr -d ' ')
  if [[ "$dv_test_pgid" =~ ^[1-9][0-9]*$ ]] && [ "$dv_test_pgid" -gt 1 ] &&
    [ "$dv_test_pgid" != "$DV_TEST_SUPERVISOR_GROUP" ]; then
    : > "$DV_TEST_PROCESS_DIR/groups/$dv_test_pgid"
  fi
  unset dv_test_pgid
fi
