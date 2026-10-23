#!/usr/bin/env bash
# Synthetic nested runners exercise their real EXIT/signal paths. On red, the
# outer test still stops every group it created before reporting the failure.
# shellcheck disable=SC2016
process_cleanup_probe() {
  local mode=$1 lab="$CASE_DIR/lifecycle" runner rc=0 leaked=0 group pid stat _
  mkdir -p "$lab/root" "$lab/tmp"
  cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$ROOT/tests" "$ROOT/config.example.sh" "$lab/root/"
  cat >> "$lab/root/tests/review-loop.sh" <<'PROBE'
case_cleanup_probe() {
  if [ "$PROBE_MODE" = nested ] && [ "${PROBE_LEAF:-0}" = 0 ]; then
    PROBE_LEAF=1 bash "$ROOT/tests/run.sh" --case cleanup_probe
    return
  fi
  if { : >&9; } 2>/dev/null; then touch "$PROBE_LAB/inherited-slot"; fi
  appserver_setup
  client=$(cat "$DV_STATE/AS-1/appserver/client.pid")
  printf '%s\n' "$client" >> "$PROBE_LAB/groups"
  # Lose a client as in daemon/reconnect tests: its proxy tree remains after
  # the PID file is replaced, so PID-file-only teardown cannot find it.
  kill -KILL "$client"
  rm -f "$DV_STATE/AS-1/appserver/client.pid"
  dv send AS-1 'reconnect synthetic client' >/dev/null
  client=$(cat "$DV_STATE/AS-1/appserver/client.pid")
  printf '%s\n' "$client" >> "$PROBE_LAB/groups"
  # Also leave a non-appserver fixture with an ordinary background child.
  POLISH_MODE=timeout bash "$ROOT/tests/fixtures/polish" 'synthetic prompt' >/dev/null 2>&1 &
  bash -c 'trap "" TERM; touch "$PROBE_LAB/stubborn-ready"; sleep 60 & wait' &
  wait_file "$PROBE_LAB/stubborn-ready"
  # host_limit also launches env -i commands and a shell-only watchdog in
  # separate job-control groups: neither starts with our BASH_ENV.
  (
    set -m
    env -i PATH="$PATH" bash -c 'sleep 60 & wait' & isolated=$!
    printf '%s\n' "$isolated" >> "$PROBE_LAB/groups"
    touch "$PROBE_LAB/isolated-ready"
    wait "$isolated"
  ) &
  wait_file "$PROBE_LAB/isolated-ready"
  ps -o pgid= -p "$$" | tr -d ' ' >> "$PROBE_LAB/groups"
  printf '%s\n' "$$" > "$PROBE_LAB/case.pid"
  ps -eo pid=,pgid=,stat= > "$PROBE_LAB/before"
  touch "$PROBE_LAB/ready"
  while [ ! -f "$PROBE_LAB/release" ]; do sleep 0.1; done
  case "$PROBE_MODE" in
    pass) return 0 ;;
    fail) return 23 ;;
    *) while :; do sleep 0.1; done ;;
  esac
}
registered_cases() { printf '%s\n' cleanup_probe; }
PROBE
  # Supply a real advisory lock without using the host's heavy state.
  : > "$lab/groups"
  set -m
  PROBE_LAB="$lab" PROBE_MODE="$mode" DV_TEST_TMP="$lab/tmp" TMPDIR="$lab/tmp" \
    bash -c 'exec 9> "$PROBE_LAB/slot.lock"; flock 9; exec bash "$PROBE_LAB/root/tests/run.sh"' \
    > "$lab/output" 2>&1 & runner=$!
  set +m
  printf '%s\n' "$runner" >> "$lab/groups"
  for _ in {1..300}; do
    [ ! -f "$lab/ready" ] || break
    kill -0 "$runner" 2>/dev/null || break
    sleep 0.1
  done
  if [ -f "$lab/ready" ]; then
    if flock -n "$lab/slot.lock" true; then
      printf 'suite released the heavy slot before finishing\n'
      leaked=1
    fi
    if [ -f "$lab/inherited-slot" ]; then
      printf 'case inherited the heavy slot fd\n'
      leaked=1
    fi
    touch "$lab/release"
    case "$mode" in
      term|nested) kill -TERM "$runner" ;;
      timeout) kill -TERM "$(cat "$lab/case.pid")" ;;
    esac
  else
    kill -TERM "$runner" 2>/dev/null || true
  fi
  wait "$runner" || rc=$?
  # A short grace period only accounts for reaping, not for fixture timeouts.
  sleep 0.2
  ps -eo pid=,pgid=,stat= > "$lab/after"
  while read -r pid group stat; do
    if grep -Fxq "$group" "$lab/groups" && [[ "$stat" != Z* ]]; then
      printf 'survived suite %s: pid=%s pgid=%s\n' "$mode" "$pid" "$group"
      leaked=1
    fi
  done < "$lab/after"
  if ! flock -n "$lab/slot.lock" true; then
    printf 'suite %s left the heavy slot locked\n' "$mode"
    leaked=1
  fi
  # These groups were recorded at launch, never discovered by process name.
  while IFS= read -r group; do kill -TERM -- "-$group" 2>/dev/null || true; done < "$lab/groups"
  sleep 0.2
  while IFS= read -r group; do kill -KILL -- "-$group" 2>/dev/null || true; done < "$lab/groups"
  cat "$lab/output"
  printf 'suite %s exit=%s leaked=%s\n' "$mode" "$rc" "$leaked"
  test -f "$lab/ready"
  test "$leaked" = 0
  case "$mode" in pass) test "$rc" = 0 ;; term|nested) test "$rc" = 143 ;; *) test "$rc" = 1 ;; esac
}
case_process_cleanup_pass() { process_cleanup_probe pass; }
case_process_cleanup_fail() { process_cleanup_probe fail; }
case_process_cleanup_timeout() { process_cleanup_probe timeout; }
case_process_cleanup_term() { process_cleanup_probe term; }
case_process_cleanup_nested() { process_cleanup_probe nested; }

case_heavy_descendant_slot() {
  export DV_HEAVY_SLOTS=1
  local rc=0 waiter
  dv heavy -- bash -c '
    bash -c '\''touch "$CASE_DIR/descendant-ready"; while [ ! -f "$CASE_DIR/release" ]; do sleep 0.1; done'\'' &
    exit 17
  ' || rc=$?
  test "$rc" = 17
  wait_file "$CASE_DIR/descendant-ready"
  # Real work must retain fd 9 even after its measured parent has exited.
  dv bid --json | jq -e '.heavy.in_use==1'
  heavy_launch follower touch "$CASE_DIR/follower-ready"
  waiter=$HEAVY_PID
  heavy_waiting follower
  test ! -e "$CASE_DIR/follower-ready"
  touch "$CASE_DIR/release"
  wait "$waiter"
  test -f "$CASE_DIR/follower-ready"
  dv bid --json | jq -e '.heavy.in_use==0'
}
