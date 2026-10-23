#!/usr/bin/env bash
# Only short fake workloads; no agents or hosted PRs.
# shellcheck disable=SC2016
heavy_launch() {
  local name=$1; shift
  mkdir -p "$CASE_DIR/heavy"
  dv heavy -- "$@" > "$CASE_DIR/heavy/$name.out" 2> "$CASE_DIR/heavy/$name.err" &
  HEAVY_PID=$!
  printf '%s\n' "$HEAVY_PID" > "$CASE_DIR/heavy/$name.pid"
}
heavy_waiting() {
  local _
  for _ in {1..100}; do
    if grep -q '^waiting for heavy slot ' "$CASE_DIR/heavy/$1.err"; then return; fi
    sleep 0.1
  done
  cat "$CASE_DIR/heavy/$1.err" >&2
  return 1
}
case_heavy_serial() {
  export DV_HEAVY_SLOTS=1
  heavy_launch first bash -c 'echo first-start >> "$CASE_DIR/order"; touch "$CASE_DIR/started"; while [ ! -e "$CASE_DIR/release" ]; do sleep 0.1; done; sleep 0.1; echo first-end >> "$CASE_DIR/order"'
  local first=$HEAVY_PID second
  wait_file "$CASE_DIR/started"
  heavy_launch second bash -c 'echo second-start >> "$CASE_DIR/order"; sleep 0.1; echo second-end >> "$CASE_DIR/order"'
  second=$HEAVY_PID
  heavy_waiting second
  test "$(cat "$CASE_DIR/order")" = first-start
  touch "$CASE_DIR/release"
  wait "$first"; wait "$second"
  printf 'first-start\nfirst-end\nsecond-start\nsecond-end\n' > "$CASE_DIR/expected"
  cmp "$CASE_DIR/order" "$CASE_DIR/expected"
  test "$(cat "$CASE_DIR/heavy/second.err")" = 'waiting for heavy slot 1/1'
}
case_heavy_kill() {
  export DV_HEAVY_SLOTS=1
  heavy_launch holder bash -c 'touch "$CASE_DIR/started"; exec sleep 30'
  local holder=$HEAVY_PID next
  wait_file "$CASE_DIR/started"
  heavy_launch next bash -c 'touch "$CASE_DIR/next"; exec sleep 0.1'
  next=$HEAVY_PID
  heavy_waiting next
  test ! -e "$CASE_DIR/next"
  kill -KILL "$holder"; wait "$holder" 2>/dev/null || true
  wait_file "$CASE_DIR/next"; wait "$next"
  dv bid --json | jq -e '.heavy=={slots:1,in_use:0,waiting:0}'
}
case_heavy_slots() {
  export DV_HEAVY_SLOTS=2
  heavy_launch first bash -c 'touch "$CASE_DIR/first"; exec sleep 30'
  local first=$HEAVY_PID second next
  wait_file "$CASE_DIR/first"
  heavy_launch second bash -c 'touch "$CASE_DIR/second"; exec sleep 30'
  second=$HEAVY_PID
  wait_file "$CASE_DIR/second"
  heavy_launch next bash -c 'touch "$CASE_DIR/next"'
  next=$HEAVY_PID
  heavy_waiting next
  kill "$second"; wait "$second" 2>/dev/null || true
  wait_file "$CASE_DIR/next"; wait "$next"
  kill -0 "$first"
  kill "$first"; wait "$first" 2>/dev/null || true
}
case_heavy_status() {
  export DV_HEAVY_SLOTS=1
  heavy_launch holder bash -c 'touch "$CASE_DIR/started"; exec sleep 30'
  local holder=$HEAVY_PID waiter
  wait_file "$CASE_DIR/started"
  heavy_launch waiter sleep 0.1
  waiter=$HEAVY_PID
  heavy_waiting waiter
  mkdir -p "$DV_STATE/H-1"
  printf '{"issue":"H-1","status":"landed","agent":"codex","host":"test-host","backend":"exec","started":0}\n' > "$DV_STATE/H-1/meta"
  dv status --json | jq -e 'length==1 and .[0].heavy=={slots:1,in_use:1,waiting:1}'
  dv status | grep 'heavy=1/1 waiting=1'
  dv bid --json | jq -e '.heavy=={slots:1,in_use:1,waiting:1}'
  dv bid | grep 'heavy=1/1 waiting=1'
  kill -KILL "$waiter"; wait "$waiter" 2>/dev/null || true
  dv bid --json | jq -e '.heavy.waiting==0 and .heavy.in_use==1'
  kill "$holder"; wait "$holder" 2>/dev/null || true
  dv bid --json | jq -e '.heavy=={slots:1,in_use:0,waiting:0}'
}
case_heavy_command() {
  export DV_HEAVY_SLOTS=1
  local rc=0
  printf 'stdin value\n' | dv heavy -- bash -c 'read -r line; printf "%s\n" "$line" "$@"; echo stderr >&2; exit 23' _ 'two words' '' '*' > "$CASE_DIR/out" 2> "$CASE_DIR/err" || rc=$?
  test "$rc" = 23
  printf 'stdin value\ntwo words\n\n*\n' > "$CASE_DIR/expected"
  cmp "$CASE_DIR/out" "$CASE_DIR/expected"
  test "$(cat "$CASE_DIR/err")" = stderr
  dv heavy -- true
  dv heavy -- bash -c 'kill -KILL $$' 2>/dev/null || rc=$?
  test "$rc" = 137
  dv heavy -- true
}
case_heavy_priority() {
  local baseline expected actual
  baseline=$(bash -c 'ps -o nice= -p $$' | tr -d ' ')
  expected=$((baseline + 10)); [ "$expected" -le 19 ] || expected=19
  dv heavy -- bash -c 'ps -o nice= -p $$' > "$CASE_DIR/nice"
  actual=$(tr -d ' ' < "$CASE_DIR/nice")
  printf 'nice baseline=%s heavy=%s minimum=%s\n' "$baseline" "$actual" "$expected"
  test "$actual" -ge "$expected"
  if command -v ionice >/dev/null; then
    dv heavy -- bash -c 'ionice -p $$' > "$CASE_DIR/ionice"
    cat "$CASE_DIR/ionice"
    grep 'best-effort: prio 7' "$CASE_DIR/ionice"
  fi
}
case_heavy_config() {
  DV_HEAVY_SLOTS='' dv bid --json | jq -e '.heavy.slots==([1,(.cores/8|floor)]|max) and .heavy.in_use==0 and .heavy.waiting==0'
  local value
  for value in 0 -1 abc 1.5 08; do
    if DV_HEAVY_SLOTS=$value dv heavy -- touch "$CASE_DIR/invalid"; then return 1; fi
  done
  test ! -e "$CASE_DIR/invalid"
  if dv heavy --; then return 1; fi
  if dv heavy true; then return 1; fi
}
case_heavy_waiter_probe() {
  export DV_HEAVY_SLOTS=1
  heavy_launch holder bash -c 'touch "$CASE_DIR/started"; exec sleep 30'
  local holder=$HEAVY_PID waiter observer real_flock
  wait_file "$CASE_DIR/started"
  real_flock=$(command -v flock)
  mkdir "$CASE_DIR/lock-bin"
  cat > "$CASE_DIR/lock-bin/flock" <<'STUB'
#!/usr/bin/env bash
if [ "${*: -1}" = 8 ]; then
  touch "$CASE_DIR/registering"
  while [ ! -e "$CASE_DIR/probe-ready" ]; do sleep 0.01; done
fi
exec "$REAL_FLOCK" "$@"
STUB
  chmod +x "$CASE_DIR/lock-bin/flock"
  export REAL_FLOCK="$real_flock"
  PATH="$CASE_DIR/lock-bin:$PATH" heavy_launch waiter bash -c 'touch "$CASE_DIR/next"'
  waiter=$HEAVY_PID
  wait_file "$CASE_DIR/registering"
  # A status probe can lock the just-created marker before registration.
  "$real_flock" "$DV_STATE"/.heavy/wait-* bash -c 'touch "$CASE_DIR/probe-ready"; sleep 0.5' & observer=$!
  wait "$observer"
  heavy_waiting waiter
  kill "$holder"; wait "$holder" 2>/dev/null || true
  wait_file "$CASE_DIR/next"; wait "$waiter"
}
