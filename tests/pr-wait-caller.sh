#!/usr/bin/env bash
# Exercise command-runner cleanup with a real group kill and the normal gh stub.
case_pr_wait_caller_killed() {
  pr_fixture
  local dead caller rc=0 mode=${1:-setsid} state="$DV_STATE/P-1"
  true & dead=$!; wait "$dead"
  mkdir "$state/.pr-wait"
  printf '%s\n' "$dead" > "$state/pr-wait.pid"
  if [ "$mode" = fallback ]; then
    # Also cover upgrading an empty legacy lock while updating an existing PR.
    cat > "$CASE_DIR/no-setsid" <<'STUB'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = setsid ]; then return 1; fi
  builtin command "$@"
}
STUB
    export BASH_ENV="$CASE_DIR/no-setsid"
  else
    touch "$state/.pr-wait/pid-$dead"
    rm "$state/pr.json"
    printf 'Test public PR body.\n' > "$state/pr.md"
  fi
  printf '[]\n' > "$GH_STUB_DIR/checks"
  if [ "$mode" = delayed ] && command -v setsid >/dev/null; then
    # Model a descheduled launcher before setsid can detach it. Without a
    # separate launch group, caller cleanup kills it in this startup window.
    DV_TEST_REAL_SETSID=$(command -v setsid)
    export DV_TEST_REAL_SETSID
    mkdir "$CASE_DIR/slow-bin"
    cat > "$CASE_DIR/slow-bin/setsid" <<'STUB'
#!/usr/bin/env bash
sleep 0.3
exec "$DV_TEST_REAL_SETSID" "$@"
STUB
    chmod +x "$CASE_DIR/slow-bin/setsid"
    export PATH="$CASE_DIR/slow-bin:$PATH"
  fi

  # Job control isolates only this caller's group, including on macOS. Kill it
  # immediately after dv pr returns, before waiting for any waiter startup.
  set -m
  bash -c '
    set -euo pipefail
    test "$(ps -o pgid= -p "$$" | tr -d " ")" = "$$"
    printf "caller pgid=%s\n" "$$"
    dv pr P-1
    touch "$CASE_DIR/pr-returned"
    kill -KILL -- "-$$"
    exit 1
  ' > "$CASE_DIR/caller.log" 2>&1 & caller=$!
  set +m
  wait "$caller" 2>/dev/null || rc=$?
  cat "$CASE_DIR/caller.log"
  test "$rc" = 137
  test -f "$CASE_DIR/pr-returned"
  printf 'caller killed after dv pr returned: exit=%s\n' "$rc"

  wait_file "$GH_STUB_DIR/viewed"
  waiter=$(cat "$state/pr-wait.pid")
  kill -0 "$waiter"
  test "$waiter" != "$dead"
  test ! -f "$state/.pr-wait/pid-$dead"
  test -f "$state/.pr-wait/pid-$waiter"
  test "$(ps -o pgid= -p "$waiter" | tr -d ' ')" = "$waiter"
  test "$waiter" != "$caller"
  if [ "$mode" != fallback ] && command -v setsid >/dev/null; then
    test "$(ps -o sid= -p "$waiter" | tr -d ' ')" = "$waiter"
    test "$(ps -o sid= -p "$$" | tr -d ' ')" != "$waiter"
    printf 'waiter owns session=%s\n' "$waiter"
  fi
  printf 'waiter survived: pid=%s; reclaimed dead pid=%s (%s)\n' "$waiter" "$dead" "$mode"
  test ! -f "$state/pr-ready.json"
  jq -e '.status=="pr"' "$state/meta"

  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]\n' > "$GH_STUB_DIR/checks"
  wait_pr_ready P-1; waiter=''
  jq -e --arg head "$(git -C "$REPO" rev-parse HEAD)" '.green and .head==$head' "$state/pr-ready.json"
  jq -e '.status=="ready"' "$state/meta"
  jq -se '[.[]|select(.kind=="pr-ready" and .issue=="P-1")]|length==1' "$DV_HOME/kick.q"
  printf 'ready for current head; one pr-ready event; lock released\n'
}
case_pr_wait_caller_fallback() { case_pr_wait_caller_killed fallback; }
case_pr_wait_caller_delayed() { case_pr_wait_caller_killed delayed; }
