#!/usr/bin/env bash
# Register Bash children, including detached dv clients and native wrappers.
# Preserve an explicitly supplied test environment (e.g. race injection).
# shellcheck source=tests/process-group.sh
source "$DV_TEST_PROCESS_SOURCE/process-group.sh"
# A job-control subshell or env -i command does not read BASH_ENV. Record the
# jobs owned by this shell before blocking, including host_limit's watchdog.
# Keep wait's arguments, signal handling and status in the Bash builtin.
wait() {
  local dv_test_job dv_test_group
  if [ -d "${DV_TEST_PROCESS_DIR:-}/groups" ]; then
    for dv_test_job in $(jobs -p); do
      dv_test_group=$(ps -o pgid= -p "$dv_test_job" 2>/dev/null | tr -d ' ') || dv_test_group=''
      if [ "$dv_test_group" = "$dv_test_job" ] && [ "$dv_test_group" -gt 1 ]; then
        : > "$DV_TEST_PROCESS_DIR/groups/$dv_test_group"
      fi
    done
  fi
  builtin wait "$@"
}
if [ -n "${DV_TEST_PREVIOUS_BASH_ENV:-}" ]; then
  # shellcheck disable=SC1090
  source "$DV_TEST_PREVIOUS_BASH_ENV"
fi
