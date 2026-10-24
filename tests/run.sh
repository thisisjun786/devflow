#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export ROOT

# tests/shellcheck.sh checks each tests/*.sh directly. Only test-suite imports
# use source=/dev/null below, keeping ShellCheck out of one unbounded graph.

seed_host_capacity() {
  local cores=$1 cap=${2:-8}
  mkdir -p "$DV_STATE/.host-capacity"
  jq -cn --arg host "$DV_HOST" --argjson cores "$cores" --argjson cap "$cap" \
    '{version:1,host:$host,cores:$cores,learned_cap:$cap,computed_at:0,sample_count:0,curve:[]}' > "$DV_STATE/.host-capacity/cap.json"
}

setup() {
  CASE_DIR=$(mktemp -d "${DV_TEST_TMP:-${TMPDIR:-/tmp}}/dv-test.XXXXXX")
  export CASE_DIR
  if [ -n "${DV_TEST_PROCESS_DIR:-}" ]; then
    printf '%s\n' "$CASE_DIR" > "$DV_TEST_PROCESS_DIR/case-dir"
  fi
  export DV_TEST_TMP=${DV_TEST_TMP:-${TMPDIR:-/tmp}}
  export TMPDIR="$CASE_DIR/temporary-root"
  mkdir -p "$TMPDIR"
  unset DV_TMP
  export HOME="$CASE_DIR/agent home"
  export GOCACHE="$HOME/.cache/go-build"
  mkdir -p "$HOME/.claude"
  printf '{"hasCompletedOnboarding":true}\n' > "$HOME/.claude.json"
  printf '{"skipDangerousModePermissionPrompt":true}\n' > "$HOME/.claude/settings.json"
  export DV_CONFIG="$CASE_DIR/config.sh" DV_STATE="$CASE_DIR/state" DV_WORK="$CASE_DIR/work" DV_HOME="$CASE_DIR/home"
  export DV_KICK="$ROOT/bin/dv-kick" DV_AGENT_CMD_codex="$ROOT/tests/fixtures/agent"
  export DV_TMUX_SOCKET="dv-test-$$" DV_REVIEW_WAIT=0 DV_POLL_INTERVAL=1 DV_CHECKS_INTERVAL=1
  if [ -n "${DV_TEST_PROCESS_DIR:-}" ]; then
    printf '%s\n' "$DV_TMUX_SOCKET" > "$DV_TEST_PROCESS_DIR/tmux-socket"
  fi
  export DV_CODEX_BIN="$ROOT/tests/fixtures/codex" DV_HOST=test-host
  export DV_HERDR=0
  export DV_AUTO_UPDATE=0
  # Capacity cases override these synthetic budgets; other cases ignore live load.
  export DV_MAX_JOBS=8 DV_TARGET_LOAD=1000000 DV_MIN_MEMORY_MB=0 DV_AUTOFILL_REPOS='' DV_HOST_CAPACITY_WINDOW=86400
  export DV_CODEX_MODE=goal DV_APPSERVER_POLL=5
  # Ordinary lifecycle tests use the product's deadlines, even on a busy host.
  # Isolate the defaults so sourcing config cannot change other fixture values.
  # Cases that exercise timeout behavior select their short deadline explicitly.
  read -r DV_START_WAIT DV_APPSERVER_TIMEOUT DV_STALL_AFTER DV_BID_TIMEOUT DV_AWARD_TIMEOUT < <(
    unset DV_START_WAIT DV_APPSERVER_TIMEOUT DV_STALL_AFTER DV_BID_TIMEOUT DV_AWARD_TIMEOUT
    # Checked separately; avoid expanding every setting into test dataflow.
    # shellcheck source=/dev/null
    source "$ROOT/config.example.sh"
    printf '%s %s %s %s %s\n' "$DV_START_WAIT" "$DV_APPSERVER_TIMEOUT" "$DV_STALL_AFTER" "$DV_BID_TIMEOUT" "$DV_AWARD_TIMEOUT"
  )
  export DV_START_WAIT DV_APPSERVER_TIMEOUT DV_STALL_AFTER DV_BID_TIMEOUT DV_AWARD_TIMEOUT
  unset DV_MODE
  # Host sync/probes must never inherit a real dsh install or key location.
  unset DV_DSH_BIN DV_DSH_HOME DV_DSH_PROFILE DV_DSH_VERSION DV_DSH_KEY_FILE DV_DSH_KEY_VAR
  unset DV_DSH_SESSIONS DV_DSH_FALLBACK DV_DSH_JAIL DV_DSH_JAIL_HIDE DV_DSH_JAIL_BIND DV_AGENT_READY_dsh
  unset DV_DSH_SCENARIO DV_DSH_SMOKE DV_DSH_SMOKE_BAD
  unset RIPGREP_CONFIG_PATH DV_RG_MAX_FILESIZE DV_RG_MAX_COLUMNS DV_RG_EXCLUDE_GLOBS
  unset DV_RECOVER_MAX DV_CAPACITY_BACKOFF DV_CAPACITY_MAX_WAIT
  unset CODEX_HOME
  export DV_TRUSTED_REPOS='' DV_CODEX_ENV_FILE="$HOME/.opencodex/codex-auth-env.sh"
  unset DV_AGENT_QUESTIONS DV_AWARD_TOKEN CLAUDE_CONFIG_DIR
  export DV_CODEX_SESSIONS="$CASE_DIR/codex sessions" DV_CLAUDE_SESSIONS="$CASE_DIR/claude projects"
  export DV_OMP_SESSIONS="$CASE_DIR/omp sessions" DV_AGY_SESSIONS="$CASE_DIR/agy conversations"
  export DV_GROK_SESSIONS="$CASE_DIR/grok sessions" DV_CURSOR_SESSIONS="$CASE_DIR/cursor projects"
  export DV_POLISH=0 DV_POLISH_TIMEOUT=3 DV_POLISH_CMD="$ROOT/tests/fixtures/polish"
  export GH_STUB_DIR="$CASE_DIR/gh" PATH="$ROOT/tests/fixtures:$ROOT/bin:$PATH"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
  mkdir -p "$GH_STUB_DIR" "$DV_STATE" "$DV_WORK" "$DV_HOME"
  # Unrelated cases use a premeasured synthetic cap; learner cases replace it.
  seed_host_capacity "$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)"
  printf '"auto"\n' > "$GH_STUB_DIR/reviews"
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]\n' > "$GH_STUB_DIR/checks"
  printf '# Test brief\nImplement one file.\n' > "$CASE_DIR/brief"
  trap 'teardown "$?"' EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap 'exit 129' HUP
}
teardown_stop_pidfile() {
  local pidfile=$1 pid attempt state
  [ -f "$pidfile" ] || return 0
  pid=$(cat "$pidfile" 2>/dev/null) || return 0
  if ! [[ "$pid" =~ ^[1-9][0-9]*$ ]] || [ "$pid" -le 1 ] || [ "$pid" = "$$" ]; then
    printf 'Refusing invalid fixture PID: %s\n' "$pidfile" >&2
    return 1
  fi
  kill "$pid" 2>/dev/null || true
  for attempt in {1..100}; do
    state=$(ps -p "$pid" -o stat= 2>/dev/null | tr -d ' ') || state=''
    if ! kill -0 "$pid" 2>/dev/null || [[ "$state" = Z* ]]; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.1
  done
  printf 'Fixture process %s did not stop: %s\n' "$pid" "$pidfile" >&2
  return 1
}
# ShellCheck 0.9 does not see the exit status passed by the EXIT trap.
# Direct fixture teardown calls intentionally default to a successful case.
# shellcheck disable=SC2120
teardown() {
  # Failed question assertions must not leave the deliberately held fake agent.
  local pidfile pane_pid rc=0 scan_rc=0 case_result=${1:-0} diagnostic
  for pidfile in "$CASE_DIR"/heavy/*.pid "$DV_STATE"/*/appserver/client.pid "$CASE_DIR"/server/work-*.pid "$DV_STATE"/*/held.pid "$DV_STATE"/*/wrapper.pid "$CASE_DIR"/herdr/wait-*.pid "$DV_HOME/watch.pid"; do
    teardown_stop_pidfile "$pidfile" || rc=1
  done
  if command -v tmux >/dev/null; then
    # kill-server returns before pane shutdown handlers finish. Observe live
    # panes on this case's private socket, stop and join them before deleting
    # any fixture state (including the simulated remote-host state trees).
    for pane_pid in $(tmux -L "$DV_TMUX_SOCKET" list-panes -a -F '#{pane_pid} #{pane_dead}' 2>/dev/null | awk '$2==0 {print $1}' || true); do
      pidfile="$CASE_DIR/tmux-pane-$pane_pid.pid"
      printf '%s\n' "$pane_pid" > "$pidfile"
      teardown_stop_pidfile "$pidfile" || rc=1
    done
    tmux -L "$DV_TMUX_SOCKET" kill-server 2>/dev/null || true
  fi
  # Fake SSH hosts keep native wrappers outside DV_STATE. tmux can return
  # before those wrappers finish writing their final receipts and logs.
  for pidfile in "$CASE_DIR"/hosts/*/state/*/agent.pid; do
    teardown_stop_pidfile "$pidfile" || rc=1
  done
  # Shutdown handlers can still publish receipts/exited markers after TERM.
  # Preserve their directory if termination cannot be confirmed.
  if [ "$rc" != 0 ]; then printf 'Retained live fixture: %s\n' "$CASE_DIR" >&2; return 1; fi
  if [ "$case_result" != 0 ] && [ "$case_result" != 77 ]; then
    # Preserve evidence for rare startup failures instead of losing it at EXIT.
    for diagnostic in "$DV_STATE"/*/log "$DV_STATE"/*/appserver/outbox/*.receipt "$CASE_DIR/server/requests"; do
      [ -f "$diagnostic" ] || continue
      printf 'Failure diagnostic: %s\n' "$diagnostic" >&2
      tail -c 8192 "$diagnostic" >&2
      printf '\n' >&2
    done
    printf 'Retained failed fixture: %s\n' "$CASE_DIR" >&2
    touch "$CASE_DIR/.test-failed"
  fi
  # Probe errors can be swallowed by host reporting; a rejected scan still fails.
  if [ -s "$CASE_DIR/host-tmp-scans" ]; then
    printf 'Forbidden live tmp scan:\n' >&2
    cat "$CASE_DIR/host-tmp-scans" >&2
    scan_rc=1
  fi
  # The supervisor first stops all registered groups, including orphans whose
  # client.pid has disappeared. Only then may it remove this case's files.
  if [ -n "${DV_TEST_PROCESS_DIR:-}" ] &&
    [ "$(cat "$DV_TEST_PROCESS_DIR/case-dir" 2>/dev/null)" = "$CASE_DIR" ]; then return "$scan_rc"; fi
  if [ -f "$CASE_DIR/.test-failed" ]; then return "$scan_rc"; fi
  if [ "${DV_TEST_KEEP:-0}" = 1 ]; then printf 'Retained: %s\n' "$CASE_DIR"; else rm -rf "$CASE_DIR"; fi
  return "$scan_rc"
}
repo() {
  REPO="$CASE_DIR/repo $1"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email test@example.invalid
  git -C "$REPO" config user.name Test
  printf 'base\n' > "$REPO/base"
  git -C "$REPO" add .
  git -C "$REPO" commit -qm initial
  export DV_TRUSTED_REPOS="$REPO"
  if [ "${2:-}" = remote ]; then
    git init -q --bare "$CASE_DIR/remote.git"
    git -C "$CASE_DIR/remote.git" symbolic-ref HEAD refs/heads/main
    git -C "$REPO" config url."$CASE_DIR/remote.git".insteadOf https://github.com/test/repo.git
    git -C "$REPO" remote add origin https://github.com/test/repo.git
    git -C "$REPO" push -qu origin main
  fi
}
start() { dv start "$REPO" "$1" change --brief "$CASE_DIR/brief" --mode exec; }
wait_done() {
  for _ in {1..100}; do
    # agent.exit precedes the wrapper's final done/kick. Wait for its TTY to exit
    # before assertions or teardown can race the last state-directory writes.
    if [ -s "$DV_STATE/$1/events.log" ] && [ -f "$DV_STATE/$1/agent.exit" ] &&
      ! tmux -L "$DV_TMUX_SOCKET" has-session -t "=dv-$1" 2>/dev/null; then
      # Exec's resource supervisor can outlive the limited body's exit file.
      if [ "$(jq -r .backend "$DV_STATE/$1/meta")" != exec ] ||
        ! kill -0 "$(cat "$DV_STATE/$1/agent.pid")" 2>/dev/null; then return; fi
    fi
    sleep 0.1
  done
  cat "$DV_STATE/$1/log" >&2
  return 1
}
needs_tmux() { command -v tmux >/dev/null || exit 77; }
terminal_failed_status() {
  local kind=$1 backend=$2 recovery=${3:-send} mode=exec wt state status exit_code
  [ "$backend" != tmux ] || needs_tmux
  [ "$backend" != herdr ] || herdr_setup
  # The regression is exercised with isolated HOME/XDG/state and a caller's
  # non-/tmp scratch root, including the provider's own temporary files.
  export TMPDIR="$CASE_DIR/tmp" XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
  export XDG_CACHE_HOME="$HOME/.cache" XDG_RUNTIME_DIR="$CASE_DIR/runtime"
  mkdir -p "$TMPDIR" "$XDG_RUNTIME_DIR"
  if [ "$kind" = task ]; then task_setup; else repo failed-status; fi
  [ "$recovery" != stall ] || mode=goal
  cat > "$CASE_DIR/failing-agent" <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail
state="$DV_STATE/$DV_ISSUE"
mkdir -p out
printf 'unfinished deliverable\n' > out/partial.txt
: > "$state/report.md"
touch "$state/status-ready"
while [ ! -f "$state/status-release" ]; do sleep 0.05; done
if [ "$(jq -r '.kind // "code"' "$state/meta")" = task ]; then
  dv done "$DV_ISSUE"
else
  exit 1
fi
AGENT
  chmod +x "$CASE_DIR/failing-agent"
  export DV_AGENT_CMD_codex="$CASE_DIR/failing-agent"
  if [ "$kind" = task ]; then
    dv submit --kind task "$CASE_DIR/Desk project" FS-1 failure --brief "$CASE_DIR/task-brief"
  else
    dv start "$REPO" FS-1 failure --brief "$CASE_DIR/brief" --mode "$mode"
  fi
  state="$DV_STATE/FS-1"
  wt=$(jq -r .worktree "$state/meta")
  wait_file "$state/status-ready"
  # An exit record alone must not override a terminal that is still running.
  printf '1\n' > "$state/agent.exit"
  dv status FS-1 --json | jq -e '.[0] | .status=="running" and .agent_status=="unknown" and .alive and (.agent_dead|not)'
  rm "$state/agent.exit"
  touch "$state/status-release"
  if [ "$backend" = tmux ]; then wait_done FS-1
  else wait_file "$CASE_DIR/herdr/w-FS-1/exit"; fi
  test "$(cat "$state/agent.exit")" = 1
  jq -se 'any(.[]; .kind=="failed" and .delivered==true)' "$state/events.log"
  cp "$state/meta" "$CASE_DIR/saved-meta"
  cp "$state/events.log" "$CASE_DIR/saved-events"
  cp "$state/report.md" "$CASE_DIR/saved-report"
  cp "$wt/out/partial.txt" "$CASE_DIR/saved-output"
  dv status FS-1
  dv status FS-1 --json > "$CASE_DIR/failed-status.json"
  cat "$CASE_DIR/failed-status.json"
  jq -e '.[0] | .status=="failed" and .agent_status=="failed" and .agent_dead and (.goal_stalled|not)' "$CASE_DIR/failed-status.json"
  dv status FS-1 | awk -F '\t' '$2=="failed" && $8=="agent=failed" { found=1 } END { exit !found }'
  if [ "$backend" = herdr ]; then
    # A retained shell and a removed pane both expose the confirmed failure.
    jq -e '.[0].alive==true' "$CASE_DIR/failed-status.json"
    touch "$CASE_DIR/herdr/w-FS-1/missing-pane"
    dv status FS-1 --json | jq -e '.[0] | .status=="failed" and .agent_status=="failed" and (.alive|not) and .agent_dead'
    rm "$CASE_DIR/herdr/w-FS-1/missing-pane"
    printf 'agent get\n' > "$CASE_DIR/herdr/fail"
    dv status FS-1 --json | jq -e '.[0] | .status=="running" and .agent_status=="unknown" and (.agent_dead|not)'
    rm "$CASE_DIR/herdr/fail"
  else
    jq -e '.[0] | (.alive|not) and (.tmux|not)' "$CASE_DIR/failed-status.json"
  fi
  cmp "$state/meta" "$CASE_DIR/saved-meta"
  cmp "$state/events.log" "$CASE_DIR/saved-events"
  cmp "$state/report.md" "$CASE_DIR/saved-report"
  cmp "$wt/out/partial.txt" "$CASE_DIR/saved-output"
  test ! -e "$state/done.json"
  # Missing, malformed or successful exits are not confirmed failures.
  for exit_code in missing '' invalid 0; do
    if [ "$exit_code" = missing ]; then rm "$state/agent.exit"
    else printf '%s\n' "$exit_code" > "$state/agent.exit"; fi
    dv status FS-1 --json | jq -e '.[0] | .status=="running" and .agent_status=="exited"'
  done
  printf '1\n' > "$state/agent.exit"
  # A later exit must not replace an explicit lifecycle state.
  for status in 'done' ready pr landed cancelled blocked start-failed waiting-capacity; do
    jq --arg status "$status" '.status=$status' "$CASE_DIR/saved-meta" > "$state/meta"
    dv status FS-1 --json | jq -e --arg status "$status" '.[0].status==$status'
  done
  cp "$CASE_DIR/saved-meta" "$state/meta"
  if [ "$kind" = task ]; then export DV_AGENT_CMD_codex="$ROOT/tests/fixtures/task-agent"
  else export DV_AGENT_CMD_codex="$ROOT/tests/fixtures/agent"; fi
  if [ "$recovery" = stall ]; then
    stall_functions
    # Read by stall_scan from tests/stall.sh.
    # shellcheck disable=SC2034
    STALL_ROW=$(dv status FS-1 --json | jq -c '.[0]')
    stall_scan; stall_tick; stall_count 1
    dv _stall-recover FS-1 "$(jq -r '.[].id' "$DV_HOME/stalls.json")" ''
  else
    dv send FS-1 'Finish the saved deliverable and report'
  fi
  if [ "$backend" = tmux ]; then wait_done FS-1; else wait_native FS-1; fi
  test "$(cat "$state/revive/previous-agent.exit")" = 1
  cmp "$state/revive/id" "$state/revive/done"
  cmp "$wt/out/partial.txt" "$CASE_DIR/saved-output"
  test -s "$state/report.md"
  jq -e --arg wt "$wt" '.worktree==$wt and .status=="done"' "$state/meta"
  dv status FS-1 --json | jq -e '.[0].status=="done"'
}
case_task_tmux_failed_status() { terminal_failed_status task tmux; }
case_task_herdr_failed_status() { terminal_failed_status task herdr; }
case_code_tmux_failed_status() { terminal_failed_status code tmux; }
case_code_herdr_failed_status() { terminal_failed_status code herdr; }
case_code_tmux_failed_stall() { terminal_failed_status code tmux stall; }
case_code_herdr_failed_stall() { terminal_failed_status code herdr stall; }
task_done_failed_status() {
  local backend=$1 s="$DV_STATE/TK-1" head wt exit_code file
  if [ "$backend" = tmux ]; then needs_tmux; else export DV_HERDR=1; fi
  task_setup
  export DV_TASK_TEST_WAIT_AFTER_DONE=1 DV_TASK_TEST_EXIT_AFTER_DONE=7
  task_start
  wait_file "$s/after-done"
  head=$(jq -r .head "$s/done.json")
  wt=$(jq -r .worktree "$s/meta")
  cp "$s/done.json" "$CASE_DIR/saved-done"
  cp -R "$s/task-snapshots/$head" "$CASE_DIR/saved-snapshot"
  # A stale exit marker must not override the still-running terminal.
  printf '7\n' > "$s/agent.exit"
  dv status TK-1 --json | jq -e '.[0] | .status=="done" and .alive and .agent_status=="unknown" and (.agent_dead|not) and .agent_exit_code==null'
  rm "$s/agent.exit"
  touch "$s/release"
  task_terminal_wait "$backend"
  test "$(cat "$s/agent.exit")" = 7
  for file in meta events.log report.md; do cp "$s/$file" "$CASE_DIR/saved-$file"; done
  dv status TK-1 --json > "$CASE_DIR/failed-status.json"
  cat "$CASE_DIR/failed-status.json"
  jq -e --arg head "$head" '.[0] | .status=="done" and .done_head==$head and .agent_status=="failed" and .agent_dead and .agent_exit_code==7' "$CASE_DIR/failed-status.json"
  dv status TK-1 | awk -F '\t' '$2=="done" && $8=="agent=failed" && $10=="exit=7" { found=1 } END { exit !found }'
  if [ "$backend" = herdr ]; then
    jq -e '.[0].alive' "$CASE_DIR/failed-status.json"
    touch "$CASE_DIR/herdr/w-TK-1/missing-pane"
    dv status TK-1 --json | jq -e '.[0] | (.alive|not) and .agent_status=="failed" and .agent_exit_code==7'
    rm "$CASE_DIR/herdr/w-TK-1/missing-pane"
    printf 'agent get\n' > "$CASE_DIR/herdr/fail"
    dv status TK-1 --json | jq -e '.[0] | .status=="done" and .agent_status=="unknown" and (.agent_dead|not) and .agent_exit_code==null'
    rm "$CASE_DIR/herdr/fail"
  else
    jq -e '.[0] | (.alive|not) and (.tmux|not)' "$CASE_DIR/failed-status.json"
  fi
  if dv land TK-1 --checked "$head" > "$CASE_DIR/land.log" 2>&1; then return 1; fi
  grep -F 'task terminal agent did not exit successfully' "$CASE_DIR/land.log"
  test ! -e "$CASE_DIR/destination/TK-1"
  cmp "$s/done.json" "$CASE_DIR/saved-done"
  diff -r "$s/task-snapshots/$head" "$CASE_DIR/saved-snapshot"
  diff -r "$wt/out" "$CASE_DIR/saved-snapshot/out"
  for file in meta events.log report.md; do cmp "$s/$file" "$CASE_DIR/saved-$file"; done
  # Absent, malformed and successful exits are not failed executions.
  for exit_code in missing '' invalid 0; do
    if [ "$exit_code" = missing ]; then rm "$s/agent.exit"
    else printf '%s\n' "$exit_code" > "$s/agent.exit"; fi
    dv status TK-1 --json | jq -e '.[0] | .status=="done" and .agent_status=="unknown" and (.agent_dead|not) and .agent_exit_code==null'
  done
}
case_task_tmux_done_failed_status() { task_done_failed_status tmux; }
case_task_herdr_done_failed_status() { task_done_failed_status herdr; }
tmux_start_failure() {
  local kind=$1 failure=$2 issue=TS-1 socket=$DV_TMUX_SOCKET rc=0 next_rc=0
  needs_tmux; task_setup
  export DV_HERDR=0 DV_MAX_JOBS=1
  export TMPDIR="$CASE_DIR/tmp" XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
  export XDG_CACHE_HOME="$HOME/.cache" XDG_RUNTIME_DIR="$CASE_DIR/runtime"
  mkdir -p "$TMPDIR" "$XDG_RUNTIME_DIR"
  if [ "$kind" = code ]; then
    repo socket
    export DV_AGENT_CMD_codex="$ROOT/tests/fixtures/agent"
  fi
  if [ "$failure" = socket ]; then
    # A socket name containing a missing directory fails in the real server.
    socket="$CASE_DIR/runtime/missing/socket"
    : > "$CASE_DIR/tmux-env"
  else
    # An unrelated session must not satisfy the post-start existence check.
    tmux -L "$DV_TMUX_SOCKET" new-session -d -s "dv-$issue-other" 'sleep 60'
    export DV_TEST_TMUX_RC=0
    [ "$failure" != nonzero ] || DV_TEST_TMUX_RC=1
    cat > "$CASE_DIR/tmux-env" <<'ENV'
tmux() {
  if [ "${1:-}" = -L ] && [ "${3:-}" = new-session ]; then
    printf 'new-session\n' >> "$CASE_DIR/tmux-start-calls"
    return "$DV_TEST_TMUX_RC"
  fi
  env tmux "$@"
}
ENV
  fi
  if [ "$kind" = task ]; then
    BASH_ENV="$CASE_DIR/tmux-env" DV_TMUX_SOCKET="$socket" \
      dv submit --kind task "$CASE_DIR/Desk project" "$issue" socket --brief "$CASE_DIR/task-brief" > "$CASE_DIR/start.out" 2>&1 || rc=$?
  else
    BASH_ENV="$CASE_DIR/tmux-env" DV_TMUX_SOCKET="$socket" \
      start "$issue" > "$CASE_DIR/start.out" 2>&1 || rc=$?
  fi
  cat "$CASE_DIR/start.out"
  printf 'start_exit=%s\n' "$rc"
  DV_TMUX_SOCKET="$socket" dv status "$issue" --json > "$CASE_DIR/start-status.json"
  cat "$CASE_DIR/start-status.json"
  # Correcting the socket must admit another task in the same one-slot state.
  export DV_AGENT_CMD_codex="$ROOT/tests/fixtures/task-agent"
  dv submit --kind task "$CASE_DIR/Desk project" TS-2 summary --brief "$CASE_DIR/task-brief" > "$CASE_DIR/next.out" 2>&1 || next_rc=$?
  cat "$CASE_DIR/next.out"
  printf 'next_submit_exit=%s\n' "$next_rc"
  test "$rc" != 0
  grep -F 'tmux startup failed' "$CASE_DIR/start.out"
  jq -e '.backend=="tmux" and .status=="start-failed"' "$DV_STATE/$issue/meta"
  jq -e '.[0] | .status=="start-failed" and .alive==false and .tmux==false' "$CASE_DIR/start-status.json"
  test ! -e "$DV_STATE/$issue/agent.pid"
  test ! -e "$DV_STATE/$issue/done.json"
  test -d "$(jq -r .worktree "$DV_STATE/$issue/meta")"
  test ! -d "$DV_STATE/.admission-lock"
  if [ "$failure" != socket ]; then
    test "$(cat "$CASE_DIR/tmux-start-calls")" = new-session
  fi
  test "$next_rc" = 0
  wait_done TS-2
  jq -e '.status=="done"' "$DV_STATE/TS-2/meta"
}
case_task_tmux_socket_failed() { tmux_start_failure task socket; }
case_code_tmux_socket_failed() { tmux_start_failure code socket; }
case_task_tmux_session_missing() { tmux_start_failure task missing; }
case_code_tmux_session_missing() { tmux_start_failure code missing; }
case_task_tmux_new_session_failed() { tmux_start_failure task nonzero; }
case_code_tmux_new_session_failed() { tmux_start_failure code nonzero; }
tmux_fast_completion() {
  local kind=$1 action=$2 rc=0 args=()
  needs_tmux
  if [ "$kind" = task ]; then
    task_setup
    args=(submit --kind task "$CASE_DIR/Desk project" TF-1 fast --brief "$CASE_DIR/task-brief")
  else
    repo fast
    args=(start "$REPO" TF-1 fast --brief "$CASE_DIR/brief" --mode exec)
  fi
  cat > "$CASE_DIR/fast-tmux-env" <<'ENV'
tmux() {
  env tmux "$@" || return
  if [ "${1:-}" = -L ] && [ "${3:-}" = new-session ]; then
    local attempt
    # Delay only the launch reply until the synthetic wrapper has exited.
    for attempt in {1..100}; do
      if ! env tmux -L "$DV_TMUX_SOCKET" has-session -t =dv-TF-1 2>/dev/null; then return 0; fi
      sleep 0.1
    done
    return 1
  fi
}
ENV
  if [ "$action" = start ]; then
    BASH_ENV="$CASE_DIR/fast-tmux-env" dv "${args[@]}" > "$CASE_DIR/start.out" 2>&1 || rc=$?
  else
    dv "${args[@]}"; wait_done TF-1
    if [ "$action" = stale ]; then
      # A goal wrapper can exit zero without completing this revival. Its old
      # done.json plus the new agent.exit must not pass the launch check.
      cp "$DV_STATE/TF-1/done.json" "$CASE_DIR/old-done.json"
      jq '.mode="goal"' "$DV_STATE/TF-1/meta" > "$CASE_DIR/goal-meta"
      mv "$CASE_DIR/goal-meta" "$DV_STATE/TF-1/meta"
      export DV_AGENT_CMD_codex=true
    elif [ "$kind" = code ]; then
      export DV_AGENT_CMD_codex="$ROOT/tests/fixtures/revived-agent"
    fi
    BASH_ENV="$CASE_DIR/fast-tmux-env" dv send TF-1 'Check the result again' > "$CASE_DIR/start.out" 2>&1 || rc=$?
  fi
  cat "$CASE_DIR/start.out"
  printf 'fast_%s_%s_exit=%s\n' "$kind" "$action" "$rc"
  jq '{status,done_at,done_episode}' "$DV_STATE/TF-1/meta"
  if [ "$action" = stale ]; then
    test "$rc" != 0
    cmp "$CASE_DIR/old-done.json" "$DV_STATE/TF-1/done.json"
    test ! -e "$DV_STATE/TF-1/revive/done"
    test -d "$DV_STATE/TF-1/revive/blocked"
    return
  fi
  test "$rc" = 0
  test "$(cat "$DV_STATE/TF-1/agent.exit")" = 0
  jq -e '.status=="done"' "$DV_STATE/TF-1/meta"
  test -s "$DV_STATE/TF-1/done.json"
  if [ "$action" = revive ]; then
    cmp "$DV_STATE/TF-1/revive/id" "$DV_STATE/TF-1/revive/done"
    test ! -d "$DV_STATE/TF-1/revive/blocked"
  fi
}
case_task_tmux_fast_completion() { tmux_fast_completion task start; }
case_code_tmux_fast_completion() { tmux_fast_completion code start; }
case_code_tmux_fast_revival() { tmux_fast_completion code revive; }
case_task_tmux_stale_completion() { tmux_fast_completion task stale; }
case_code_tmux_stale_completion() { tmux_fast_completion code stale; }
case_start_done() {
  needs_tmux; repo remote remote; start T-1; wait_done T-1
  jq -e '.status=="ready" and .agent=="codex" and .host=="test-host"' "$DV_STATE/T-1/meta"
  jq -e '.files==1 and (.head|length)==40 and (.report|endswith("report.md"))' "$DV_STATE/T-1/done.json"
  jq -e '.kind=="done" and .issue=="T-1"' "$DV_HOME/kick.q"
  test -s "$DV_STATE/T-1/brief.md"
  dv status --json | jq -e 'length==1 and .[0].issue=="T-1"'
  dv status T-1 | grep 'ready'
  head -c 200000 /dev/zero | tr '\0' 'x' >> "$DV_STATE/T-1/log"; printf '\n' >> "$DV_STATE/T-1/log"
  dv status T-1 >/dev/null && dv status --json | jq -e 'length==1'
  if start T-1; then return 1; fi
}
case_kick_failure() {
  needs_tmux; repo local; export DV_KICK=false; start T-2; wait_done T-2
  dv 'done' T-2 --note 'delivery failed safely'
  jq -e '.delivered==false' "$DV_STATE/T-2/events.log"
  jq -e '.status=="done"' "$DV_STATE/T-2/meta"
}
case_kick_stale_lock() {
  local lock="$DV_HOME/.kick-lock" dead
  # A writer killed between taking and releasing the queue lock leaves its
  # claim behind; the next event must reclaim it instead of failing forever.
  bash -c 'exit 0' & dead=$!; wait "$dead"
  mkdir "$lock"; printf '%s\n' "$dead" > "$lock/pid-$dead"; ln "$lock/pid-$dead" "$lock/owner"
  dv-kick 'done' T-9 'after crash'
  test ! -e "$lock"
  # A kill between mkdir and the owner record leaves an ownerless claim.
  mkdir "$lock"
  dv-kick 'done' T-10 'after early crash'
  test ! -e "$lock"
  jq -se 'length==2 and .[0].issue=="T-9" and .[1].issue=="T-10"' "$DV_HOME/kick.q"
  # A live writer's claim still excludes another writer.
  mkdir "$lock"; printf '%s\n' "$$" > "$lock/pid-$$"; ln "$lock/pid-$$" "$lock/owner"
  if dv-kick 'done' T-11 'blocked'; then return 1; fi
  test "$(cat "$lock/owner")" = "$$"
  if grep -q 'T-11' "$DV_HOME/kick.q"; then return 1; fi
  rm -f "$lock/owner" "$lock/pid-$$"; rmdir "$lock"
}
case_local_land() {
  needs_tmux; repo local; start T-3; wait_done T-3
  before=$(git -C "$REPO" rev-parse HEAD)
  if DV_TEST_CMD=false dv land T-3; then return 1; fi
  test "$(git -C "$REPO" rev-parse HEAD)" = "$before"
  test -d "$(jq -r .worktree "$DV_STATE/T-3/meta")"
  DV_TEST_CMD='test -f T-3.txt' dv land T-3
  test -f "$REPO/T-3.txt"
  jq -e '.status=="landed"' "$DV_STATE/T-3/meta"
  test ! -d "$(jq -r .worktree "$DV_STATE/T-3/meta")"
}
case_pr_land() {
  needs_tmux; repo remote remote; start T-4; wait_done T-4
  dv pr T-4
  wait_pr_ready T-4
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]\n' > "$GH_STUB_DIR/checks"
  if dv land T-4; then return 1; fi
  test ! -f "$GH_STUB_DIR/merged"
  printf '[]\n' > "$GH_STUB_DIR/checks"
  if dv land T-4; then return 1; fi
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]\n' > "$GH_STUB_DIR/checks"
  dv land T-4
  test -f "$GH_STUB_DIR/merged"
  grep -- '--match-head-commit' "$GH_STUB_DIR/calls"
  if grep -E -- '--delete-branch|--force|--admin' "$GH_STUB_DIR/calls"; then return 1; fi
}
case_pr_public_body() {
  needs_tmux; repo remote remote; start T-41; wait_done T-41
  pr-template-body 'Adds the thing.' 41 > "$DV_STATE/T-41/pr.md"
  DV_POLISH=0 dv pr T-41
  wait_pr_ready T-41
  cmp "$DV_STATE/T-41/pr.md" "$GH_STUB_DIR/live-body"
  if grep -q -- "$DV_STATE" "$GH_STUB_DIR/live-body"; then return 1; fi
}
case_review_loop_rule() {
  grep -Fq 'DV_REVIEW_ROUNDS' "$ROOT/templates/rules.md"
  grep -Fq 'review-rounds' "$ROOT/templates/worker-prompt.md"
  ! grep -Fq 'late-review.sent' "$ROOT/templates/worker-prompt.md"
}
case_blocked_event_ids() {
  # Two different block reasons at the same head and award are two events;
  # the same reason resent is one.
  DV_ENTRY="$ROOT/bin/dv" bash -s <<'BLOCKED_IDS'
set -euo pipefail
source "$ROOT/lib/common.sh"
a=$(event_json blocked T-9 'needs scope A' h1 abc '' tok | jq -r .id)
b=$(event_json blocked T-9 'needs scope B' h1 abc '' tok | jq -r .id)
c=$(event_json blocked T-9 'needs scope A' h1 abc '' tok | jq -r .id)
d=$(event_json failed T-9 'needs scope A' h1 abc '' tok | jq -r .id)
[ "$a" != "$b" ] && [ "$a" = "$c" ]
case "$a" in h1:T-9:blocked:abc:tok:m*) ;; *) exit 1 ;; esac
[ "$d" = 'h1:T-9:failed:abc:tok' ]
BLOCKED_IDS
}
case_clean() {
  needs_tmux; repo remote remote; start T-5; wait_done T-5
  branch=$(jq -r .branch "$DV_STATE/T-5/meta")
  git -C "$REPO" push -q origin "$branch"
  wt=$(jq -r .worktree "$DV_STATE/T-5/meta")
  printf 'uncommitted\n' > "$wt/dirty"
  if dv clean T-5; then return 1; fi
  test -f "$wt/dirty"
  rm "$wt/dirty"
  dv clean T-5
  git -C "$REPO" show-ref --verify "refs/heads/$branch"
  git -C "$CASE_DIR/remote.git" show-ref --verify "refs/heads/$branch"
}
resume_capacity_rejected() {
  local rc=0
  dv submit --kind task "$CASE_DIR/Desk project" TK-2 summary --brief "$CASE_DIR/task-brief" > "$CASE_DIR/second-submit" 2>&1 || rc=$?
  cat "$CASE_DIR/second-submit"
  printf 'second_submit_exit=%s\n' "$rc"
  test "$rc" != 0
  grep -F 'host has no free task slots' "$CASE_DIR/second-submit"
  test ! -e "$DV_STATE/TK-2"
}
resume_capacity_observed() {
  local issue=$1
  jq -e '.cleaned_at==null' "$DV_STATE/$issue/meta"
  # Metrics fingerprinting currently requires Git. Exercise its cleanup
  # classification on dev jobs; keep non-Git task fixtures non-Git.
  if jq -e '.kind!="task"' "$DV_STATE/$issue/meta" >/dev/null; then
    dv _metrics-sample | jq -e --arg issue "$issue" '.[] | select(.issue==$issue) | .status!="cleaned"'
  fi
  # Check a copy for later cleanup eligibility, never the live fixture.
  DV_ENTRY="$ROOT/bin/dv" bash -s -- "$issue" <<'DISK_CHECK'
set -euo pipefail
source "$ROOT/lib/common.sh"
if disk_terminal_at "$DV_STATE/$1/meta"; then exit 1; fi
jq '.status="landed" | .landed_at=123' "$DV_STATE/$1/meta" > "$CASE_DIR/terminal-meta"
test "$(disk_terminal_at "$CASE_DIR/terminal-meta")" = 123
DISK_CHECK
}
resume_capacity() {
  local kind=$1 backend=$2 issue=RC-1 wt branch
  task_setup
  export DV_MAX_JOBS=1 DV_STALL_AFTER=300 DV_CODEX_MODE=exec
  export DV_CODEX_BIN="$ROOT/tests/fixtures/resume-capacity" DV_AGENT_CMD_codex=''
  if [ "$backend" = tmux ]; then
    needs_tmux
    export DV_AGENT_CMD_codex="$ROOT/tests/fixtures/resume-capacity"
  fi
  if [ "$kind" = task ]; then
    issue=TK-1
    export DV_TRUSTED_REPOS="$CASE_DIR/Desk project"
    task_start
  else
    repo resume
    export DV_TRUSTED_REPOS="$DV_TRUSTED_REPOS"$'\n'"$CASE_DIR/Desk project"
    dv start "$REPO" "$issue" resume --mode exec
  fi
  if [ "$backend" = exec ]; then exec_wait "$issue"; else wait_done "$issue"; fi
  wt=$(jq -r .worktree "$DV_STATE/$issue/meta")
  cp "$DV_STATE/$issue/report.md" "$CASE_DIR/report-before"
  dv clean "$issue"
  jq -e '.cleaned_at>0' "$DV_STATE/$issue/meta"
  if [ "$kind" = task ]; then
    test -f "$wt/out/summary.txt"
  else
    # Restore the retained unmerged branch explicitly. Send must not recreate
    # a worktree deleted by code clean.
    test ! -d "$wt"
    if dv send "$issue" 'Missing worktree must stay missing'; then return 1; fi
    jq -e '.cleaned_at>0' "$DV_STATE/$issue/meta"
    branch=$(jq -r .branch "$DV_STATE/$issue/meta")
    git -C "$REPO" worktree add "$wt" "$branch"
  fi
  cmp "$DV_STATE/$issue/report.md" "$CASE_DIR/report-before"
  touch "$DV_STATE/$issue/hold"
  dv send "$issue" 'Revise the synthetic summary before delivery.'
  if [ "$backend" = exec ]; then
    dv status "$issue" --json | jq -e '.[0] | .alive and .status=="running" and .exec_status=="working"'
  fi
  wait_file "$DV_STATE/$issue/held.pid"
  dv status "$issue" --json | jq -e '.[0].alive'
  resume_capacity_rejected
  resume_capacity_observed "$issue"
  touch "$DV_STATE/$issue/release"
  if [ "$backend" = exec ]; then exec_wait "$issue"; else wait_done "$issue"; fi
  dv clean "$issue"
  jq -e '.cleaned_at>0' "$DV_STATE/$issue/meta"
  cmp "$DV_STATE/$issue/report.md" "$CASE_DIR/report-before"
  if [ "$kind" = task ]; then test -f "$wt/out/summary.txt"; else test ! -d "$wt"; fi
  dv submit --kind task "$CASE_DIR/Desk project" TK-2 summary --brief "$CASE_DIR/task-brief"
  if [ "$backend" = exec ]; then exec_wait TK-2; else wait_done TK-2; fi
}
case_clean_resume_task_exec() { resume_capacity task exec; }
case_clean_resume_code_exec() { resume_capacity code exec; }
case_clean_resume_task_tmux() { resume_capacity task tmux; }
case_clean_resume_code_tmux() { resume_capacity code tmux; }
clean_resume_appserver() {
  task_appserver_setup; task_start
  export DV_MAX_JOBS=1
  local s="$DV_STATE/TK-1" wt outcome=$1 rc=0
  wt=$(jq -r .worktree "$s/meta")
  printf 'summary\n' > "$wt/out/summary.txt"
  printf 'synthetic report\n' > "$s/report.md"
  printf 'idle\n' > "$CASE_DIR/server/status"
  dv 'done' TK-1
  dv clean TK-1
  teardown_stop_pidfile "$s/appserver/client.pid"
  jq -e '.cleaned_at>0' "$s/meta"
  printf 'refused\n' > "$CASE_DIR/server/outcome"
  if dv send TK-1 'Refused follow-up'; then return 1; fi
  jq -e '.cleaned_at>0' "$s/meta"
  printf '%s\n' "$outcome" > "$CASE_DIR/server/outcome"
  dv send TK-1 'Revise the summary' > "$CASE_DIR/resume-receipt" || rc=$?
  jq -e --arg outcome "$outcome" '.outcome==$outcome' "$CASE_DIR/resume-receipt"
  if [ "$outcome" = accepted ]; then test "$rc" = 0; else test "$rc" != 0; fi
  dv status TK-1 --live --json | jq -e '.[0] | .alive and .agent_status=="working"'
  resume_capacity_rejected
  resume_capacity_observed TK-1
  test -f "$wt/out/summary.txt"
}
case_clean_resume_appserver() { clean_resume_appserver accepted; }
case_clean_resume_appserver_unknown() { clean_resume_appserver unknown; }
case_parallel() {
  needs_tmux; repo parallel
  # A linked source worktree must use the same repository lock as the main one.
  git -C "$REPO" worktree add --detach "$CASE_DIR/source" main
  export BASH_ENV="$ROOT/tests/fixtures/race-env" DV_TEST_RACE=worktree
  DV_TEST_ACTOR=1 start T-6 & p1=$!
  wait_file "$CASE_DIR/entered-1"
  DV_TEST_ACTOR=2 dv start "$CASE_DIR/source" T-7 change --brief "$CASE_DIR/brief" --mode exec & p2=$!
  local rc=0
  wait_contender || rc=1
  touch "$CASE_DIR/release"
  wait "$p1" || rc=1; wait "$p2" || rc=1
  unset BASH_ENV DV_TEST_RACE
  [ "$rc" = 0 ]
  wait_done T-6; wait_done T-7
  wt1=$(jq -r .worktree "$DV_STATE/T-6/meta")
  wt2=$(jq -r .worktree "$DV_STATE/T-7/meta")
  test -f "$wt1/T-6.txt"; test ! -f "$wt1/T-7.txt"
  test -f "$wt2/T-7.txt"; test ! -f "$wt2/T-6.txt"
  test "$(jq -r .branch "$DV_STATE/T-6/meta")" != "$(jq -r .branch "$DV_STATE/T-7/meta")"
  test ! -e "$REPO/.git/devflow-worktree.lock"
  # A failed Git operation must release the lock without removing user files.
  git -C "$REPO" branch feat/9-change
  printf 'keep\n' > "$REPO/dirty"
  if start T-9; then return 1; fi
  test ! -e "$REPO/.git/devflow-worktree.lock"
  test "$(cat "$REPO/dirty")" = keep
  start T-10; wait_done T-10
  case_parallel_timeout
}
case_parallel_timeout() {
  needs_tmux; repo parallel-timeout
  local lock="$REPO/.git/devflow-worktree.lock"
  mkdir "$lock"
  printf '%s\n' "$$" > "$lock/pid-$$"
  ln "$lock/pid-$$" "$lock/owner"
  if BASH_ENV="$ROOT/tests/fixtures/race-env" DV_TEST_RACE=timeout DV_TEST_ACTOR=timeout \
    start TIMEOUT-1 > "$CASE_DIR/timeout-output" 2>&1; then return 1; fi
  grep 'repository worktree creation busy' "$CASE_DIR/timeout-output"
  test ! -e "$DV_STATE/TIMEOUT-1"
  test "$(cat "$lock/owner")" = "$$"
  rm "$lock/pid-$$" "$lock/owner"
  rmdir "$lock"
  # Retrying the same issue succeeds once the other owner releases the lock.
  start TIMEOUT-1; wait_done TIMEOUT-1
}
wait_contender() {
  local tries
  for tries in {1..200}; do
    if [ -f "$CASE_DIR/contended-2" ] || [ -f "$CASE_DIR/entered-2" ]; then return; fi
    sleep 0.05
  done
  echo 'Timed out waiting for lock contention' >&2
  return 1
}
case_install() {
  test_home="$CASE_DIR/install home"
  fresh_home="$CASE_DIR/fresh"
  env HOME="$fresh_home" bash "$ROOT/install.sh" --host
  cmp "$ROOT/config.example.sh" "$fresh_home/.config/devflow/config.sh"
  mkdir -p "$test_home/.config/devflow"
  printf '# existing\nDV_TEST_CMD=true\n' > "$test_home/.config/devflow/config.sh"
  cp "$test_home/.config/devflow/config.sh" "$CASE_DIR/original"
  env HOME="$test_home" bash "$ROOT/install.sh" --mac --watch
  cp "$test_home/Library/LaunchAgents/dev.devflow.watch.plist" "$CASE_DIR/plist"
  env HOME="$test_home" bash "$ROOT/install.sh" --mac --watch
  cmp "$CASE_DIR/original" "$test_home/.config/devflow/config.sh"
  cmp "$CASE_DIR/plist" "$test_home/Library/LaunchAgents/dev.devflow.watch.plist"
  # A hand-edited plist survives a later install (review P1).
  printf '# hand edit\n' >> "$test_home/Library/LaunchAgents/dev.devflow.watch.plist"
  cp "$test_home/Library/LaunchAgents/dev.devflow.watch.plist" "$CASE_DIR/plist-edited"
  env HOME="$test_home" bash "$ROOT/install.sh" --mac --watch
  cmp "$CASE_DIR/plist-edited" "$test_home/Library/LaunchAgents/dev.devflow.watch.plist"
  test -L "$test_home/.local/bin/dv"
  test -L "$test_home/.hermes/profiles/sion/skills/software-development/devflow"
  env HOME="$test_home" DV_CONFIG="$test_home/.config/devflow/config.sh" "$test_home/.local/bin/dv" status --json | jq -e 'length==0'
}
case_install_linux_watch() {
  linux_home="$CASE_DIR/linux home"
  env HOME="$linux_home" bash "$ROOT/install.sh" --host --watch > "$CASE_DIR/linux.out"
  unit="$linux_home/.config/systemd/user/dev.devflow.watch.service"
  grep -Fx "ExecStart=\"$linux_home/.local/bin/dv-watch\"" "$unit"
  if command -v systemd-analyze >/dev/null; then
    mkdir -p "$linux_home/.local/bin" && ln -sf "$ROOT/bin/dv-watch" "$linux_home/.local/bin/dv-watch"
    systemd-analyze --user verify "$unit"
  fi
  grep -Fx 'Restart=on-failure' "$unit"
  grep 'systemctl --user enable --now dev.devflow.watch.service' "$CASE_DIR/linux.out"
  test -L "$linux_home/.hermes/profiles/sion/skills/software-development/devflow"
  test ! -e "$linux_home/Library"
  printf '# hand edit\n' >> "$unit"; cp "$unit" "$CASE_DIR/unit-edited"
  env HOME="$linux_home" bash "$ROOT/install.sh" --host --watch > /dev/null
  cmp "$CASE_DIR/unit-edited" "$unit"
}
case_review() {
  needs_tmux; repo local; start T-8; wait_done T-8
  dv review T-8; dv review T-8
  test "$(cat "$DV_STATE/T-8/review.count")" = 2
  grep -- '--base main' "$DV_STATE/T-8/review-1.log"
}
case_watch() {
  export DV_WORKER_CMD="$ROOT/tests/fixtures/worker" DV_WATCH_INTERVAL=0.1 DV_RECONCILE_INTERVAL=1800 DV_HOSTS=''
  dv-kick 'done' W-1 hello host abc
  cat "$DV_HOME/kick.q" >> "$DV_HOME/events.log"
  dv-kick 'done' W-1 hello host abc
  dv-kick pr-ready W-2 ready host def
  dv-watch & watcher=$!
  for _ in {1..100}; do
    [ "$(find "$DV_HOME/workers" -name '*.finished' 2>/dev/null | wc -l | tr -d ' ')" = 2 ] && break
    sleep 0.1
  done
  touch "$DV_HOME/stop"; wait "$watcher"
  test "$(find "$DV_HOME/workers" -name '*.finished' | wc -l | tr -d ' ')" = 2
  grep -l 'W-1' "$DV_HOME/workers/"*.prompt.md
  grep -l 'W-2' "$DV_HOME/workers/"*.prompt.md
}
case_reconcile() {
  export DV_WORKER_CMD="$ROOT/tests/fixtures/worker" DV_WATCH_INTERVAL=0.1 DV_RECONCILE_INTERVAL=1 DV_HOSTS='test-box'
  printf '[{"issue":"LOST-1","status":"done","head":"abc","host":"test-box","done_at":1}]' > "$CASE_DIR/remote-status"
  dv-watch & watcher=$!
  for _ in {1..100}; do
    [ -f "$DV_HOME/kick.q" ] && grep -q LOST-1 "$DV_HOME/kick.q" && break
    sleep 0.1
  done
  touch "$DV_HOME/stop"; wait "$watcher"
  grep LOST-1 "$DV_HOME/kick.q"
  test "$(wc -l < "$DV_HOME/kick.q" | tr -d ' ')" = 1
}

case_reconcile_slow_host() {

  # A slow remote status (seconds per host) must not hold queue dispatch:
  # reconcile is a safety net, not the delivery path.
  export DV_WORKER_CMD="$ROOT/tests/fixtures/worker" DV_WATCH_INTERVAL=0.1 DV_RECONCILE_INTERVAL=1 DV_HOSTS='test-box'
  printf '[]' > "$CASE_DIR/remote-status"
  printf '8\n' > "$CASE_DIR/remote-status-delay"
  dv-watch & watcher=$!
  sleep 1.5 # the first reconcile is now waiting on the slow host
  dv-kick 'done' SLOW-1 hello host abc
  # The slow host answers 8 s after the first reconcile began; dispatch must
  # not wait for it.
  local delivered=false
  for _ in {1..40}; do
    if [ "$(find "$DV_HOME/workers" -name '*.finished' 2>/dev/null | wc -l | tr -d ' ')" = 1 ]; then delivered=true; break; fi
    sleep 0.1
  done
  touch "$DV_HOME/stop"; wait "$watcher"
  [ "$delivered" = true ]
  grep -l 'SLOW-1' "$DV_HOME/workers/"*.prompt.md
}

case_kick_pull() {
  export SSH_FIXTURE_EXEC=1
  # The remote host's own config moves its queue: the stream must load it.
  mkdir -p "$CASE_DIR/remote-home" "$CASE_DIR/rq"
  printf 'DV_HOME=%q\n' "$CASE_DIR/rq" > "$CASE_DIR/remote-home/config.sh"
  remote_q="$CASE_DIR/rq/kick.q"
  event() { jq -cn --arg i "$1" --arg m "$2" '{id:("box:"+$i+":done:h"),kind:"done",issue:$i,message:$m,host:"box",head:"h",time:1}'; }
  lines() { if [ -f "$DV_HOME/kick.q" ]; then wc -l < "$DV_HOME/kick.q" | tr -d ' '; else echo 0; fi; }
  until_lines() {
    local checkpoint
    for _ in {1..100}; do
      checkpoint=''
      if [ -f "$DV_HOME/pull-box.offset" ]; then read -r checkpoint _ < "$DV_HOME/pull-box.offset"; fi
      # The queue append precedes the reconnect checkpoint. Killing the pull
      # between them deliberately leaves an uncheckpointed event to replay.
      if [ "$(lines)" = "$1" ] && [ "$checkpoint" = "${2:-$1}" ]; then return 0; fi
      sleep 0.1
    done
    return 1
  }
  # Stop only this case's pull (its EXIT trap ends ssh/tail); never pkill by pattern.
  stop_pull() { kill "$!" 2>/dev/null || true; wait "$!" 2>/dev/null || true; }
  { event P-1 ''; event P-2 'two words'; } > "$remote_q"
  dv-kick-pull box 2> "$CASE_DIR/pull.err" & until_lines 2
  event P-3 'later' >> "$remote_q"; until_lines 3; stop_pull
  read -r offset _ < "$DV_HOME/pull-box.offset"; test "$offset" = 3
  jq -se '[.[].issue]==["P-1","P-2","P-3"] and .[1].message=="two words" and .[0].message=="" and all(.[]; .host=="box" and .head=="h")' "$DV_HOME/kick.q"
  # Reconnect resumes after the checkpoint: nothing replayed.
  event P-4 '' >> "$remote_q"
  dv-kick-pull box 2>> "$CASE_DIR/pull.err" & until_lines 4; stop_pull
  # A failed local write is not checkpointed; the next stream redelivers it.
  # The blocking claim is a live writer's: an ownerless leftover is claimable.
  mkdir "$DV_HOME/.kick-lock"
  printf '%s\n' "$$" > "$DV_HOME/.kick-lock/pid-$$"
  ln "$DV_HOME/.kick-lock/pid-$$" "$DV_HOME/.kick-lock/owner"
  event P-5 '' >> "$remote_q"
  if dv-kick-pull box 2>> "$CASE_DIR/pull.err"; then return 1; fi
  read -r offset _ < "$DV_HOME/pull-box.offset"; test "$offset" = 4
  rm -f "$DV_HOME/.kick-lock/owner" "$DV_HOME/.kick-lock/pid-$$"
  rmdir "$DV_HOME/.kick-lock"
  dv-kick-pull box 2>> "$CASE_DIR/pull.err" & until_lines 5; stop_pull
  # A replaced queue (new inode) restarts from its first line.
  event P-6 '' > "$remote_q.new"; mv "$remote_q.new" "$remote_q"
  dv-kick-pull box 2>> "$CASE_DIR/pull.err" & until_lines 6 1; stop_pull
  jq -se '[.[].issue]==["P-1","P-2","P-3","P-4","P-5","P-6"]' "$DV_HOME/kick.q"
}
case_kick_pull_checkpoint() {
  cat > "$CASE_DIR/delayed-checkpoint-env" <<'ENV'
mv() {
  if [ "${2:-}" = "$DV_HOME/pull-box.offset" ]; then env sleep 0.3; fi
  env mv "$@"
}
ENV
  export BASH_ENV="$CASE_DIR/delayed-checkpoint-env"
  case_kick_pull
}
case_watch_pull() {
  export SSH_FIXTURE_EXEC=1 DV_PULL_HOSTS=box DV_PULL_RETRY=1 DV_WATCH_INTERVAL=0.1
  export DV_WORKER_CMD="$ROOT/tests/fixtures/worker" DV_HOSTS=''
  mkdir -p "$CASE_DIR/remote-home/state"
  printf 'DV_HOME=%q\n' "$CASE_DIR/remote-home/state" > "$CASE_DIR/remote-home/config.sh"
  jq -cn '{id:"box:W-1:done:h",kind:"done",issue:"W-1",message:"",host:"box",head:"h",time:1}' > "$CASE_DIR/remote-home/state/kick.q"
  dv-watch & watcher=$!
  for _ in {1..100}; do [ -f "$DV_HOME/seen" ] && grep -q 'box:W-1:done:h' "$DV_HOME/seen" && break; sleep 0.1; done
  touch "$DV_HOME/stop"; wait "$watcher"
  grep -Fx 'box:W-1:done:h' "$DV_HOME/seen"
  pid=$(cat "$DV_HOME/pull-box.pid"); if kill -0 "$pid" 2>/dev/null; then return 1; fi
}
case_question_pull_replay() {
  export SSH_FIXTURE_EXEC=1 DV_WORKER_CMD="$ROOT/tests/fixtures/worker" DV_WATCH_INTERVAL=0.1 DV_HOSTS=''
  mkdir -p "$CASE_DIR/remote-home" "$CASE_DIR/rq"
  printf 'DV_HOME=%q\n' "$CASE_DIR/rq" > "$CASE_DIR/remote-home/config.sh"
  local remote_q="$CASE_DIR/rq/kick.q" puller count
  # Two genuine source events at one head, each with a distinct blocked episode.
  DV_HOME="$CASE_DIR/rq" DV_QUESTION_EPISODE='w1:p1:123:1' dv-kick question Q-1 first box same-head '' award-1
  DV_HOME="$CASE_DIR/rq" DV_QUESTION_EPISODE='w1:p1:123:3' dv-kick question Q-1 second box same-head
  cp "$remote_q" "$CASE_DIR/source-events"
  for count in 2 4; do
    dv-kick-pull box 2>> "$CASE_DIR/pull.err" & puller=$!
    for _ in {1..100}; do
      if [ -f "$DV_HOME/kick.q" ] && [ "$(wc -l < "$DV_HOME/kick.q" | tr -d ' ')" = "$count" ]; then break; fi
      sleep 0.05
    done
    kill "$puller"; wait "$puller" || true
    test "$(wc -l < "$DV_HOME/kick.q" | tr -d ' ')" = "$count"
    # Replacing the queue's inode models replay after reconnect/checkpoint loss.
    cp "$CASE_DIR/source-events" "$remote_q.new"; mv "$remote_q.new" "$remote_q"
  done
  jq -se --slurpfile source "$CASE_DIR/source-events" \
    '($source|map({id,token})) as $events | map({id,token})==($events+$events) and (map(.id)|unique|length)==2' "$DV_HOME/kick.q"
  dv-watch & watcher=$!
  for _ in {1..100}; do
    [ "$(find "$DV_HOME/workers" -name '*.finished' 2>/dev/null | wc -l | tr -d ' ')" = 2 ] && break
    sleep 0.05
  done
  touch "$DV_HOME/stop"; wait "$watcher"
  test "$(find "$DV_HOME/workers" -name '*.finished' | wc -l | tr -d ' ')" = 2
}

wait_file() {
  local path=$1
  for _ in {1..100}; do [ ! -f "$path" ] || return 0; sleep 0.1; done
  printf 'Timed out waiting for %s\n' "$path" >&2
  return 1
}
wait_pr_ready() {
  local pid
  for _ in {1..100}; do
    if [ -s "$DV_STATE/$1/pr-ready.json" ] && [ ! -d "$DV_STATE/$1/.pr-wait" ]; then
      # The waiter releases its lock before checking worker recovery. Wait for
      # that process too, so teardown cannot race its final metadata writes.
      pid=$(cat "$DV_STATE/$1/pr-wait.pid" 2>/dev/null || true)
      if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null ||
        [ "$(ps -p "$pid" -o stat= 2>/dev/null | cut -c 1)" = Z ]; then return; fi
    fi
    sleep 0.1
  done
  printf 'Timed out waiting for PR waiter to finish: %s\n' "$1" >&2
  return 1
}
case_reconcile_local() {
  # The watcher's own host is read without ssh: the ssh fixture would serve nothing here.
  export DV_WORKER_CMD="$ROOT/tests/fixtures/worker" DV_WATCH_INTERVAL=0.1 DV_RECONCILE_INTERVAL=1 DV_HOSTS="$DV_HOST"
  repo remote remote; needs_tmux; start L-1; wait_done L-1
  : > "$DV_HOME/kick.q"; printf '[]' > "$CASE_DIR/remote-status"
  dv-watch & watcher=$!
  for _ in {1..100}; do
    grep -q 'L-1' "$DV_HOME/kick.q" 2>/dev/null && break
    sleep 0.1
  done
  touch "$DV_HOME/stop"; wait "$watcher"
  jq -e 'select(.issue=="L-1") | .message=="Recovered by status safety net"' "$DV_HOME/kick.q"
}
case_kick_local_host() {
  # No DV_KICK and the kick host is this host: the event lands in the local queue without ssh.
  export DV_KICK='' DV_KICK_HOST="$DV_HOST"
  dv kick pr-ready K-1 local
  jq -e 'select(.issue=="K-1") | .kind=="pr-ready" and .host=="test-host"' "$DV_HOME/kick.q"
  jq -e '.delivered==true' "$DV_STATE/K-1/events.log"
}
case_worker_prompt_host() {
  export DV_WORKER_CMD="$ROOT/tests/fixtures/worker" DV_WATCH_INTERVAL=0.1
  "$ROOT/bin/dv-kick" test P-1 hi "$DV_HOST" ''
  dv-watch & watcher=$!
  for _ in {1..100}; do ls "$DV_HOME/workers/"*.prompt.md >/dev/null 2>&1 && break; sleep 0.1; done
  touch "$DV_HOME/stop"; wait "$watcher"
  grep -F "작업자 호스트(DV_HOST): \`test-host\`" "$DV_HOME/workers/"*.prompt.md
}
assert_question_args() {
  local issue=$1 agent=$2 mode=${DV_AGENT_QUESTIONS:-sion}
  if [ "$(jq -r .backend "$DV_STATE/$issue/meta")" != herdr ]; then mode=off; fi
  if [ "$agent" = codex ]; then
    jq -e --arg mode "$mode" '
      index("tools.experimental_request_user_input.enabled=false") as $i |
      if $mode=="off" then $i!=null and .[$i-1]=="-c" else $i==null end
    ' "$DV_STATE/$issue/args.json"
  else
    jq -e --arg mode "$mode" '
      index("--disallowedTools") as $i |
      if $mode=="off" then $i!=null and .[$i+1]=="AskUserQuestion"
      else $i==null and index("AskUserQuestion")==null end
    ' "$DV_STATE/$issue/args.json"
  fi
}
case_agent_cli() {
  needs_tmux; repo cli
  # Exercise the unset default as well as the explicit off override.
  if [ -n "${1:-}" ]; then export DV_AGENT_QUESTIONS=$1; fi
  export DV_AGENT_CMD_codex='' DV_CODEX_BIN="$ROOT/tests/fixtures/interactive"
  export DV_CLAUDE_BIN="$ROOT/tests/fixtures/interactive" DV_DEVIN_BIN="$ROOT/tests/fixtures/interactive"
  dv start "$REPO" C-1 goal --brief "$CASE_DIR/brief"
  wait_file "$DV_STATE/C-1/events.log"
  grep '^/goal .*brief.md' "$DV_STATE/C-1/goal-input"
  jq -e 'index("gpt-6-astra")!=null and index("hooks")!=null and index("plugins.\"crw@crw\".enabled=false")!=null and any(.[]; contains("trust_level=\"trusted\""))' "$DV_STATE/C-1/args.json"
  assert_question_args C-1 codex
  # Assert literal shell metacharacters survive paste without evaluation.
  # shellcheck disable=SC2016
  dv send C-1 'extra instruction $literal `safe`'
  wait_file "$DV_STATE/C-1/sent-input"
  # shellcheck disable=SC2016
  grep -F 'extra instruction $literal `safe`' "$DV_STATE/C-1/sent-input"
  dv clean C-1
  DV_CODEX_DISABLE_CRW=0 DV_CODEX_DISABLE_HOOKS=0 dv start "$REPO" C-2 exec --mode exec
  wait_done C-2
  jq -e 'index("exec")!=null and index("hooks")==null and index("plugins.\"crw@crw\".enabled=false")==null' "$DV_STATE/C-2/args.json"
  assert_question_args C-2 codex
  dv start "$REPO" C-3 claude --agent claude
  wait_file "$DV_STATE/C-3/events.log"
  jq -e 'index("opus")!=null and index("xhigh")!=null and index("--dangerously-skip-permissions")!=null' "$DV_STATE/C-3/args.json"
  assert_question_args C-3 claude
  dv start "$REPO" C-4 devin --agent devin
  wait_file "$DV_STATE/C-4/events.log"
  test -f "$DV_STATE/C-4/trust-enter"
  jq -e 'index("fusion-gpt-6-astra-xhigh-sidekick-swe-2-high")!=null and index("dangerous")!=null and index("--")!=null' "$DV_STATE/C-4/args.json"
}
case_agent_cli_off() { case_agent_cli off; }
case_agent_cli_more() {
  needs_tmux; repo cli-more
  local agent
  export DV_OMP_BIN="$ROOT/tests/fixtures/interactive" DV_AGY_BIN="$ROOT/tests/fixtures/interactive"
  export DV_GROK_BIN="$ROOT/tests/fixtures/interactive" DV_CURSOR_BIN="$ROOT/tests/fixtures/interactive"
  export DV_CURSOR_MODEL=fixture-model
  for agent in omp agy grok cursor; do
    dv start "$REPO" "M-$agent" "$agent" --agent "$agent"
    wait_file "$DV_STATE/M-$agent/events.log"
    jq -se 'all(.[]; .kind=="done")' "$DV_STATE/M-$agent/events.log"
    # The instruction is always the last argument, after an option terminator.
    jq -e --arg s "$DV_STATE/M-$agent" '.[-1]|startswith("Read "+$s+"/brief.md")' "$DV_STATE/M-$agent/args.json"
  done
  jq -e 'index("--model") as $i | $i!=null and .[$i+1]=="inferhub/deepseek-v4.1-flash" and index("--approval-mode=yolo")!=null and .[-2]=="--"' "$DV_STATE/M-omp/args.json"
  # The interactive first-run wizard would otherwise hide the initial prompt.
  test "$(cat "$DV_STATE/M-omp/omp-skip-setup")" = 1
  jq -e 'index("--model") as $i | $i!=null and .[$i+1]=="gemini-4-argon" and index("--dangerously-skip-permissions")!=null and .[-2]=="-i"' "$DV_STATE/M-agy/args.json"
  jq -e 'index("--always-approve")!=null and index("-m")==null and .[-2]=="--"' "$DV_STATE/M-grok/args.json"
  jq -e 'index("--yolo")!=null and index("--trust")!=null and (index("--model") as $i | $i!=null and .[$i+1]=="fixture-model") and .[-2]=="--"' "$DV_STATE/M-cursor/args.json"
  test -f "$DV_STATE/M-agy/trust-enter"; test -f "$DV_STATE/M-grok/trust-enter"
  test ! -f "$DV_STATE/M-omp/trust-enter"; test ! -f "$DV_STATE/M-cursor/trust-enter"
}
case_pr_ready() {
  needs_tmux; repo ready remote; start P-1; wait_done P-1
  head=$(git -C "$(jq -r .worktree "$DV_STATE/P-1/meta")" rev-parse HEAD)
  jq -n --arg head "$head" '[{author:{login:"devin-ai-integration[bot]"},commit:{oid:$head}},{author:{login:"chatgpt-codex-connector[bot]"},commit:{oid:$head}}]' > "$GH_STUB_DIR/reviews"
  dv pr P-1
  dv pr-wait P-1 --foreground > /dev/null
  jq -e '.green and .bot_review and (.review_timed_out|not)' "$DV_STATE/P-1/pr-ready.json"
  jq -se 'all(.[]; .kind!="pr-ready")' "$DV_HOME/kick.q"
  dv 'done' P-1
  jq -e '.status=="ready"' "$DV_STATE/P-1/meta"
  test "$(grep -c 'pr create' "$GH_STUB_DIR/calls")" = 1
  jq '.[0:1]' "$GH_STUB_DIR/reviews" > "$GH_STUB_DIR/reviews.one"
  mv "$GH_STUB_DIR/reviews.one" "$GH_STUB_DIR/reviews"
  if dv pr-wait P-1; then return 1; fi
  jq -e '(.bot_review|not) and (.review_handled|not) and .review_timed_out and .blocked' "$DV_STATE/P-1/pr-ready.json"
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"}]' > "$GH_STUB_DIR/checks"
  if dv land P-1; then return 1; fi
}
case_base_merge() {
  needs_tmux; repo base
  git -C "$REPO" branch -m develop
  printf "DV_TEST_CMD='test -f M-1.txt && test -f later'\nDV_LAND_MODE=merge\n" > "$REPO/.devflow"
  git -C "$REPO" add .; git -C "$REPO" commit -qm config
  dv start "$REPO" M-1 merge --mode exec --base develop; wait_done M-1
  printf 'later\n' > "$REPO/later"
  git -C "$REPO" add .; git -C "$REPO" commit -qm later
  dv land M-1
  test "$(git -C "$REPO" rev-list --parents -n 1 HEAD | wc -w | tr -d ' ')" = 3
  test -f "$REPO/M-1.txt"
}
case_watch_capacity() {
  export DV_WORKER_CMD="$ROOT/tests/fixtures/worker" DV_WORKER_GATE=1 DV_WATCH_INTERVAL=0.1 DV_HOSTS=''
  for n in 1 2 3 4 5; do dv-kick 'done' "CAP-$n" '' test h; done
  dv-watch & watcher=$!
  for _ in {1..100}; do
    [ "$(find "$DV_HOME/workers" -name '*.started' 2>/dev/null | wc -l | tr -d ' ')" = 4 ] && break
    sleep 0.1
  done
  test "$(find "$DV_HOME/workers" -name '*.started' | wc -l | tr -d ' ')" = 4
  # Reception persists all events even while the execution slots are full.
  test "$(cat "$DV_HOME/cursor")" = 5
  test "$(find "$DV_HOME/pending" -name '*.json' | wc -l | tr -d ' ')" = 5
  touch "$DV_HOME/release"
  for _ in {1..100}; do
    [ "$(find "$DV_HOME/workers" -name '*.finished' | wc -l | tr -d ' ')" = 5 ] && break
    sleep 0.1
  done
  test "$(find "$DV_HOME/workers" -name '*.finished' | wc -l | tr -d ' ')" = 5
  touch "$DV_HOME/stop"; wait "$watcher"
  rm "$DV_HOME/stop"
  dv-kick 'done' CAP-1 '' test h
  dv-watch & watcher=$!
  for _ in {1..100}; do [ "$(cat "$DV_HOME/cursor")" = 6 ] && break; sleep 0.1; done
  touch "$DV_HOME/stop"; wait "$watcher"
  test "$(cat "$DV_HOME/cursor")" = 6
  test "$(find "$DV_HOME/workers" -name '*.started' | wc -l | tr -d ' ')" = 5
}

case_land_checkout_race() {
  needs_tmux; repo checkout-race; start RACE-1; wait_done RACE-1
  before=$(git -C "$REPO" rev-parse main)
  git -C "$REPO" branch unrelated
  # Hold the candidate test until the base worktree has changed branches.
  # The test subprocess, not this shell, expands CASE_DIR.
  # shellcheck disable=SC2016
  DV_TEST_CMD='touch "$CASE_DIR/test-started"; while [ ! -f "$CASE_DIR/test-release" ]; do sleep 0.05; done' dv land RACE-1 > "$CASE_DIR/land-output" 2>&1 &
  landpid=$!
  wait_file "$CASE_DIR/test-started"
  git -C "$REPO" checkout -q unrelated
  touch "$CASE_DIR/test-release"
  if wait "$landpid"; then cat "$CASE_DIR/land-output"; return 1; fi
  grep 'base worktree changed branches' "$CASE_DIR/land-output"
  test "$(git -C "$REPO" rev-parse main)" = "$before"
  test "$(git -C "$REPO" rev-parse unrelated)" = "$before"
  test -d "$(jq -r .worktree "$DV_STATE/RACE-1/meta")"
  jq -e '.status=="done"' "$DV_STATE/RACE-1/meta"
}

herdr_setup() {
  export DV_HERDR=1 DV_AGENT_CMD_codex='' DV_CODEX_BIN="$ROOT/tests/fixtures/herdr-agent"
  export DV_CLAUDE_BIN="$ROOT/tests/fixtures/herdr-agent" DV_DEVIN_BIN="$ROOT/tests/fixtures/herdr-agent"
  export DV_OMP_BIN="$ROOT/tests/fixtures/herdr-agent" DV_AGY_BIN="$ROOT/tests/fixtures/herdr-agent"
  export DV_GROK_BIN="$ROOT/tests/fixtures/herdr-agent" DV_CURSOR_BIN="$ROOT/tests/fixtures/herdr-agent"
}
wait_native() {
  if [ "$(jq -r .backend "$DV_STATE/$1/meta")" = exec ]; then
    wait_done "$1"
    test "$(cat "$DV_STATE/$1/agent.exit")" = 0
    return
  fi
  wait_file "$CASE_DIR/herdr/w-$1/exit"
  test "$(cat "$CASE_DIR/herdr/w-$1/exit")" = 0
  wait_file "$DV_STATE/$1/agent.exit"
  wait_file "$DV_STATE/$1/events.log"
  test "$(cat "$DV_STATE/$1/agent.exit")" = 0
}
case_question_cli() {
  repo question-cli; herdr_setup
  export DV_AGENT_QUESTIONS=${1:-sion}
  dv start "$REPO" Q-1 flags --mode exec; wait_native Q-1
  assert_question_args Q-1 codex
  dv start "$REPO" Q-2 flags --agent claude; wait_native Q-2
  assert_question_args Q-2 claude
  dv start "$REPO" Q-3 flags; wait_native Q-3
  assert_question_args Q-3 codex
}
case_question_cli_off() { case_question_cli off; }
question_setup() {
  repo questions; herdr_setup
  export DV_BLOCKED_GRACE=1
  if [ "${1:-codex}" = codex ]; then
    # Use the ordinary award startup receipt. A held provider alone does not
    # prove the goal observer has finished before the test changes its screen.
    export DV_AWARD_TOKEN="question-$$"
  fi
  mkdir -p "$CASE_DIR/herdr"
  touch "$CASE_DIR/herdr/question-mode"
  if [ "${QUESTION_LATE_DETECTION:-0}" = 1 ]; then touch "$CASE_DIR/herdr/late-detection"; fi
  dv start "$REPO" Q-1 questions --agent "${1:-codex}"
  local marker deadline=$((SECONDS + DV_START_WAIT * 2)) markers=("$DV_STATE/Q-1/held.pid")
  if [ "${1:-codex}" = codex ]; then markers+=("$DV_STATE/Q-1/agent.started"); fi
  for marker in "${markers[@]}"; do
    while [ ! -f "$marker" ]; do
      [ "$SECONDS" -lt "$deadline" ] || { printf 'Startup did not finish: %s\n' "$marker" >&2; return 1; }
      sleep 0.05
    done
  done
  if [ -s "$DV_STATE/Q-1/events.log" ]; then
    jq -se 'all(.[]; .kind!="failed")' "$DV_STATE/Q-1/events.log"
  fi
  qdir="$CASE_DIR/herdr/w-Q-1"
}
question_state() {
  local seq=1
  [ ! -f "$qdir/seq" ] || seq=$(cat "$qdir/seq")
  printf '%s\n' "$((seq + 1))" > "$qdir/seq"
  printf '%s\n' "$1" > "$qdir/status"
}
question_count() {
  if [ -f "$DV_STATE/Q-1/events.log" ]; then
    jq -s '[.[] | select(.kind=="question")] | length' "$DV_STATE/Q-1/events.log"
  else printf '0\n'; fi
}
wait_questions() {
  for _ in {1..100}; do
    [ "$(question_count)" != "$1" ] || return 0
    sleep 0.05
  done
  printf 'Expected %s question events, got %s\n' "$1" "$(question_count)" >&2
  return 1
}
question_pending() {
  dv status Q-1 --json | jq -e --argjson pending "$1" '.[0].question_pending==$pending'
}
question_finish() {
  touch "$DV_STATE/Q-1/release"
  wait_native Q-1
  question_pending false
  test "$(find "$CASE_DIR/herdr" -name 'wait-*.pid' | wc -l | tr -d ' ')" = 0
}
question_record_setup() {
  question_setup "${1:-codex}"
  question_session=01234567-89ab-cdef-0123-456789abcdef
  printf '%s\n' "$question_session" > "$qdir/session"
  mkdir -p "$DV_CODEX_SESSIONS/2026/10/20" "$DV_CLAUDE_SESSIONS/project-with-spaces"
  codex_record="$DV_CODEX_SESSIONS/2026/10/20/rollout-2026-10-20T10-00-00-$question_session.jsonl"
  claude_record="$DV_CLAUDE_SESSIONS/project-with-spaces/$question_session.jsonl"
  jq -cn --arg id "$question_session" '{type:"session_meta",payload:{id:$id}}' > "$codex_record"
  printf '\033[31m screen fallback \033[0m\n' > "$qdir/output"
  # Shell-looking text is question data, and whitespace inside it is significant.
  # shellcheck disable=SC2016
  jq -n --arg text 'Which format? $(touch SHOULD-NOT-EXIST) `literal`' \
    '{questions:[{id:"format",header:"형식",question:($text+"\n  keep  spaces"),options:[{label:"JSON",description:"Recommended"},{label:"CSV",description:"Alternative"}]}]}' > "$CASE_DIR/exact-question.json"
}
question_codex_call() {
  jq -cn --arg name "$1" --arg id "${3:-$1}" --slurpfile question "$2" \
    '{type:"response_item",payload:{type:"function_call",call_id:$id,name:$name,arguments:($question[0]|tojson)}}' >> "$codex_record"
}
question_record_assert() {
  question_state blocked
  wait_questions 1
  jq -se --slurpfile expected "$CASE_DIR/exact-question.json" \
    '.[0] | .kind=="question" and .delivered and ((.message|fromjson)==$expected[0])' "$DV_STATE/Q-1/events.log"
  # Reading the transcript should avoid the lossy eight-line visible snapshot.
  jq -se 'all(.[]; .!=["pane","read","w-Q-1:p1","--source","visible","--lines","8"])' "$CASE_DIR/herdr/calls"
  test ! -e "$(jq -r .worktree "$DV_STATE/Q-1/meta")/SHOULD-NOT-EXIST"
  question_finish
}
case_question_codex_record() {
  question_record_setup
  printf '{"questions":[{"question":"old question"}]}\n' > "$CASE_DIR/old-question.json"
  question_codex_call request_user_input "$CASE_DIR/old-question.json"
  jq -cn '{type:"response_item",payload:{type:"function_call_output",call_id:"request_user_input",output:"answered"}}' >> "$codex_record"
  # A different session's file must not win, regardless of its modification time.
  cp "$codex_record" "$DV_CODEX_SESSIONS/rollout-2026-10-20-other-session.jsonl"
  question_codex_call functions.request_user_input_async "$CASE_DIR/exact-question.json"
  question_codex_call unrelated_tool "$CASE_DIR/old-question.json"
  # A live writer can leave a partial final JSONL record.
  printf '{"type":' >> "$codex_record"
  question_record_assert
}
case_question_record_limit() {
  question_record_setup
  jq -n '{questions:[{question:([range(2500)|"한"]|join(""))}]}' > "$CASE_DIR/exact-question.json"
  question_codex_call request_user_input_async "$CASE_DIR/exact-question.json"
  question_state blocked
  wait_questions 1
  jq -se --slurpfile expected "$CASE_DIR/exact-question.json" \
    '.[0].message | length==2000 and .==($expected[0]|tojson|.[0:2000])' "$DV_STATE/Q-1/events.log"
  question_finish
}
case_question_record_fallback() {
  question_record_setup
  local mode count=0
  for mode in missing wrong-session no-question invalid-arguments; do
    case "$mode" in
      missing) rm "$codex_record" ;;
      wrong-session)
        jq -cn '{type:"session_meta",payload:{id:"another-session"}}' > "$codex_record"
        question_codex_call request_user_input "$CASE_DIR/exact-question.json" ;;
      no-question)
        jq -cn --arg id "$question_session" '{type:"session_meta",payload:{id:$id}}' > "$codex_record"
        question_codex_call unrelated_tool "$CASE_DIR/exact-question.json" ;;
      invalid-arguments)
        question_codex_call request_user_input "$CASE_DIR/exact-question.json"
        jq -cn '{type:"response_item",payload:{type:"function_call",call_id:"request_user_input",name:"request_user_input",arguments:"{unfinished"}}' >> "$codex_record" ;;
    esac
    question_state blocked
    count=$((count + 1)); wait_questions "$count"
    jq -se '.[-1].message=="screen fallback"' "$DV_STATE/Q-1/events.log"
    question_state working
    for _ in {1..100}; do question_pending false >/dev/null && break; sleep 0.05; done
    question_pending false
  done
  question_finish
}
case_question_claude_record() {
  question_record_setup claude
  jq -cn --arg id "$question_session" '{sessionId:$id,type:"assistant",message:{content:[{type:"tool_use",name:"AskUserQuestion",input:{questions:[{question:"old question"}]}}]}}' > "$claude_record"
  jq -cn --arg id "$question_session" --slurpfile question "$CASE_DIR/exact-question.json" \
    '{sessionId:$id,type:"assistant",message:{content:[{type:"text",text:"thinking"},{type:"tool_use",name:"AskUserQuestion",input:$question[0]},{type:"tool_use",name:"Read",input:{file_path:"unrelated"}}]}}' >> "$claude_record"
  jq -cn '{sessionId:"another-session",type:"assistant",message:{content:[{type:"tool_use",name:"AskUserQuestion",input:{questions:[{question:"wrong session"}]}}]}}' >> "$claude_record"
  question_record_assert
}
case_question_episodes() {
  question_setup
  sleep 1.2
  test "$(question_count)" = 0
  printf 'old transcript\n\033[31m  Which in-scope option?  \033[0m\n  1. route\n  2. handler\n' > "$qdir/output"
  question_state blocked
  wait_questions 1
  question_pending true
  dv status Q-1 | grep 'agent=blocked'
  sleep 1.2
  test "$(question_count)" = 1
  jq -se '.[0] | .kind=="question" and .delivered and (.message|contains("Which in-scope option?")) and (.message|length)<=1000 and (.message|test("[\u0000-\u001f]")|not)' "$DV_STATE/Q-1/events.log"
  question_state working
  for _ in {1..100}; do question_pending false >/dev/null && break; sleep 0.05; done
  question_pending false
  question_state blocked
  wait_questions 2
  sleep 1.2
  test "$(question_count)" = 2
  jq -se '[.[]|select(.kind=="question")]|length==2 and (map(.id)|unique|length)==2' "$DV_HOME/kick.q"
  jq -se --slurpfile events "$DV_STATE/Q-1/events.log" 'map(.id)==($events|map(.id))' "$DV_HOME/kick.q"
  jq -se 'any(.[]; .==["pane","read","w-Q-1:p1","--source","visible","--lines","8"])' "$CASE_DIR/herdr/calls"
  export DV_WORKER_CMD="$ROOT/tests/fixtures/worker" DV_WATCH_INTERVAL=0.1 DV_HOSTS=''
  dv-watch & watcher=$!
  for _ in {1..100}; do
    [ "$(find "$DV_HOME/workers" -name '*.finished' 2>/dev/null | wc -l | tr -d ' ')" = 2 ] && break
    sleep 0.05
  done
  touch "$DV_HOME/stop"; wait "$watcher"
  test "$(find "$DV_HOME/workers" -name '*.finished' | wc -l | tr -d ' ')" = 2
  question_finish
}
case_question_grace() {
  question_setup
  question_state blocked
  for _ in {1..100}; do
    if jq -se 'any(.[]; .[0:2]==["agent","wait"] and index("--timeout")!=null)' "$CASE_DIR/herdr/calls" >/dev/null; then break; fi
    sleep 0.05
  done
  jq -se 'any(.[]; .[0:2]==["agent","wait"] and index("--timeout")!=null)' "$CASE_DIR/herdr/calls"
  question_state idle
  sleep 1.2
  test "$(question_count)" = 0
  question_pending false
  question_finish
}
case_question_exit() {
  question_setup
  # The fake agent still commits and records done after release. Hold the
  # grace response so this tests cancellation on exit, not Git's speed.
  touch "$CASE_DIR/herdr/hold-question-grace"
  question_state blocked
  wait_file "$CASE_DIR/herdr/question-grace-entered"
  question_finish
  rm "$CASE_DIR/herdr/hold-question-grace"
  sleep 1.2
  test "$(question_count)" = 0
}
case_question_wait_failure() {
  question_setup
  printf 'agent wait\n' > "$CASE_DIR/herdr/fail"
  question_state blocked
  sleep 1.2
  test "$(question_count)" = 0
  question_pending false
  question_finish
}
case_question_startup() {
  export QUESTION_LATE_DETECTION=1
  question_setup
  question_state blocked
  wait_questions 1
  jq -se 'any(.[]; .[0:2]==["pane","wait-output"] and index("visible")!=null)' "$CASE_DIR/herdr/calls"
  question_finish
}
case_question_signal() {
  question_setup
  kill "$(cat "$DV_STATE/Q-1/held.pid")"
  wait_file "$CASE_DIR/herdr/w-Q-1/exit"
  test "$(cat "$DV_STATE/Q-1/agent.exit")" -ne 0
  question_pending false
  test "$(find "$CASE_DIR/herdr" -name 'wait-*.pid' | wc -l | tr -d ' ')" = 0
  sleep 1.2
  test "$(question_count)" = 0
}
question_other_agent() {
  question_setup "$1"
  # Trimming is bounded even if the visible terminal has extremely long lines.
  head -c 4000 /dev/zero | tr '\0' x > "$qdir/output"
  printf ' last question\n' >> "$qdir/output"
  question_state blocked
  wait_questions 1
  question_pending true
  jq -se '.[0].message | length==1000 and endswith("last question")' "$DV_STATE/Q-1/events.log"
  question_state unknown
  for _ in {1..100}; do question_pending false >/dev/null && break; sleep 0.05; done
  question_pending false
  question_finish
}
case_question_claude() { question_other_agent claude; }
case_question_devin() { question_other_agent devin; }
case_question_omp() { question_other_agent omp; }
case_question_agy() { question_other_agent agy; }
case_question_grok() { question_other_agent grok; }
case_question_cursor() { question_other_agent cursor; }
case_question_banner_agents() {
  bidding_functions
  local line pattern=${HERDR_AGENT_BANNER#'(?m)'}
  # Startup screens measured on the real CLIs; the sentinel waits for one once.
  for line in '│ OpenAI Codex (v0.163.0)' ' ▐▛███▜▌   Claude Code v2.1.304' 'Devin CLI' \
    '      ▄▀▀▄        Antigravity CLI 1.4.6' '  │  ⠀⠀⠀⠀⠀⠀⣀⣀⡀⠀⠀⠀⢀⠄   Grok Build  1.0.67' \
    '                     Cursor Agent' ' π > ◒ DeepSeek V4.1 Flash (InferHub) > ⑂ main'; do
    printf '%s\n' "$line" | grep -Eq "$pattern" || { printf 'banner not matched: %s\n' "$line" >&2; return 1; }
  done
  if printf '%s\n' '$ omp --model inferhub/deepseek-v4.1-flash' | grep -Eq "$pattern"; then return 1; fi
}
case_herdr_start_clean() {
  repo herdr; herdr_setup; unset DV_HERDR
  dv start "$REPO" H-1 native --brief "$CASE_DIR/brief"
  wait_native H-1
  wt=$(jq -r .worktree "$DV_STATE/H-1/meta")
  jq -e '.backend=="herdr" and .herdr_workspace=="w-H-1" and .herdr_pane=="w-H-1:p1"' "$DV_STATE/H-1/meta"
  if command -v tmux >/dev/null && tmux -L "$DV_TMUX_SOCKET" has-session -t '=dv-H-1' 2>/dev/null; then return 1; fi
  jq -se --arg wt "$wt" '.[0]==["workspace","create","--label","dv-H-1","--cwd",$wt,"--no-focus"] and .[1][0:3]==["pane","wait-output","w-H-1:p1"] and .[2][0:3]==["pane","run","w-H-1:p1"] and (.[2][3]|contains("tmux")|not)' "$CASE_DIR/herdr/calls"
  jq -e 'index("hooks")==null and index("plugins.\"crw@crw\".enabled=false")!=null' "$DV_STATE/H-1/args.json"
  grep '^/goal .*brief.md' "$DV_STATE/H-1/goal-input"
  grep -F 'native output before done' "$DV_STATE/H-1/log"
  # Metadata controls existing issues, even when creation is disabled later.
  # shellcheck disable=SC2016
  DV_HERDR=0 dv send H-1 'literal $text `safe`'
  # shellcheck disable=SC2016
  grep -Fx 'literal $text `safe`' "$DV_STATE/H-1/sent-input"
  for status in working idle 'done' blocked; do
    printf '%s\n' "$status" > "$CASE_DIR/herdr/w-H-1/status"
    dv status H-1 --json | jq -e --arg status "$status" '.[0] | .backend=="herdr" and .alive and (.tmux|not) and .agent_status==$status and .last_log=="native output after done"'
    dv status H-1 | grep "agent=$status"
  done
  jq -se 'any(.[]; .==["pane","read","w-H-1:p1","--source","recent-unwrapped","--lines","1"])' "$CASE_DIR/herdr/calls"
  printf 'dirty\n' > "$wt/dirty"
  if dv clean H-1; then return 1; fi
  test -f "$CASE_DIR/herdr/w-H-1/workspace"
  rm "$wt/dirty"
  DV_HERDR=0 dv clean H-1
  test ! -d "$wt"; test ! -f "$CASE_DIR/herdr/w-H-1/workspace"
  grep -F 'native output after done' "$DV_STATE/H-1/log"
  dv clean H-1
  jq -se '[.[]|select(.[0:2]==["workspace","close"])]==[["workspace","close","w-H-1"]]' "$CASE_DIR/herdr/calls"
  dv status H-1 --json | jq -e '.[0] | (.alive|not) and .last_log=="native output after done"'
}
case_herdr_send_retry() {
  repo herdr-send; herdr_setup
  dv start "$REPO" H-2 native; wait_native H-2
  printf 'once\n' > "$CASE_DIR/herdr/blocked"
  dv send H-2 retry
  grep -Fx retry "$DV_STATE/H-2/sent-input"
  jq -se '[.[]|select(.[0:2]==["agent","prompt"] and .[3]=="retry")]|length==2' "$CASE_DIR/herdr/calls"
  jq -se 'any(.[]; .[0:3]==["agent","wait","w-H-2:p1"])' "$CASE_DIR/herdr/calls"
  printf 'always\n' > "$CASE_DIR/herdr/blocked"
  if dv send H-2 still-blocked; then return 1; fi
  jq -se '[.[]|select(.[0:2]==["agent","prompt"] and .[3]=="still-blocked")]|length==2' "$CASE_DIR/herdr/calls"
  rm "$CASE_DIR/herdr/blocked"
  touch "$CASE_DIR/herdr/prompt-error"
  if dv send H-2 stalled; then return 1; fi
  jq -se '[.[]|select(.[0:2]==["agent","prompt"] and .[3]=="stalled")]|length==1' "$CASE_DIR/herdr/calls"
  test "$(wc -l < "$DV_STATE/H-2/sent-input" | tr -d ' ')" = 1
  dv clean H-2
}
case_herdr_undetected() {
  repo herdr-undetected
  export DV_HERDR=1
  # Wait for sentinel startup before exiting the fake command. This case tests
  # unknown-agent status/logs; immediate exit can interrupt mktemp's stdout.
  # shellcheck disable=SC2016
  export DV_AGENT_CMD_codex='
    for attempt in {1..100}; do
      if jq -se "any(.[]; .[0:2]==[\"agent\",\"wait\"])" "$CASE_DIR/herdr/calls" >/dev/null; then
        printf "plain text: ❯"; exit 0
      fi
      sleep 0.05
    done
    exit 1'
  dv start "$REPO" HU-1 native --mode goal
  wait_file "$CASE_DIR/herdr/w-HU-1/exit"
  test "$(cat "$CASE_DIR/herdr/w-HU-1/exit")" = 0
  dv status HU-1 --json > "$CASE_DIR/undetected-status.json"
  # The command exited without dv done: the shell-only pane reports it as exited.
  if ! jq -e '.[0] | .alive and .agent_dead and .agent_status=="exited" and .last_log=="plain text: ❯"' "$CASE_DIR/undetected-status.json"; then
    cat "$CASE_DIR/undetected-status.json" "$CASE_DIR/herdr/w-HU-1/output"
    return 1
  fi
  # Keep this send check about a live, undetected wrapper. A confirmed dead
  # wrapper now revives once (covered separately by the recovery cases).
  cp "$DV_STATE/HU-1/agent.pid" "$CASE_DIR/original-agent.pid"
  printf '%s\n' "$$" > "$DV_STATE/HU-1/agent.pid"
  if dv send HU-1 hello > "$CASE_DIR/send.out" 2> "$CASE_DIR/send.err"; then return 1; fi
  grep -F agent_not_found "$CASE_DIR/send.err"
  test ! -s "$CASE_DIR/send.out"
  mv "$CASE_DIR/original-agent.pid" "$DV_STATE/HU-1/agent.pid"
  dv 'done' HU-1
  cmp "$CASE_DIR/herdr/w-HU-1/output" "$DV_STATE/HU-1/log"
  # Already closed workspaces are reported on stderr, and clean stays idempotent.
  herdr workspace close w-HU-1
  dv status HU-1 --json | jq -e '.[0] | (.alive|not) and .last_log=="plain text: ❯"'
  dv clean HU-1
  test ! -d "$(jq -r .worktree "$DV_STATE/HU-1/meta")"
  jq -e '.herdr_workspace==null and .herdr_pane==null' "$DV_STATE/HU-1/meta"
}
case_herdr_cleanup_owner() (
  # Reproduce the pre-exec child's inherited EXIT handler deterministically:
  # a descendant must not remove its live parent's reply/pending files.
  # shellcheck source=lib/herdr.sh
  source "$ROOT/lib/herdr.sh"
  S="$DV_STATE/owner"; mkdir "$S"
  question_tmp=$(mktemp -d "$S/.question.XXXXXX")
  # shellcheck disable=SC2034
  question_owner_subshell=$BASH_SUBSHELL question_child=''
  touch "$S/question.pending" "$question_tmp/reply"
  (trap herdr_question_cleanup EXIT; exit 0)
  if [ ! -f "$question_tmp/reply" ] || [ ! -f "$S/question.pending" ]; then
    printf 'Child EXIT handler removed live sentinel files\n' >&2
    exit 1
  fi
  herdr_question_cleanup
  test ! -d "$question_tmp"; test ! -f "$S/question.pending"
)
case_herdr_goal_retry() {
  repo goal-retry; herdr_setup
  mkdir -p "$CASE_DIR/herdr"
  printf 'retry\n' > "$CASE_DIR/herdr/goal-mode"
  dv start "$REPO" HG-1 native
  if ! wait_native HG-1; then
    cat "$CASE_DIR/herdr/w-HG-1/output"
    printf 'Expected /goal delivery after transient not-ready/blocked failures\n' >&2
    return 1
  fi
  grep '^/goal .*brief.md' "$DV_STATE/HG-1/goal-input"
  test ! -f "$CASE_DIR/herdr/w-HG-1/early-prompt"
  test "$(cat "$CASE_DIR/herdr/w-HG-1/goal-attempts")" = 3
  jq -se 'all(.[]; .kind!="failed")' "$DV_STATE/HG-1/events.log"
  dv clean HG-1
}
case_herdr_goal_timeout() {
  repo goal-timeout; herdr_setup; export DV_START_WAIT=2
  mkdir -p "$CASE_DIR/herdr"
  # Complete each rejected poll before advancing the deadline. A two-second
  # wall clock can otherwise expire before even the first prompt attempt.
  cat > "$DV_CONFIG" <<'CONFIG'
date() {
  if [ "$*" = +%s ]; then cat "$CASE_DIR/goal-clock"; else command date "$@"; fi
}
sleep() {
  if [ "${FUNCNAME[1]:-}" = inject_goal ] && [ "$*" = 0.2 ]; then
    local polls
    polls=$(cat "$CASE_DIR/goal-polls")
    polls=$((polls + 1))
    printf '%s\n' "$polls" > "$CASE_DIR/goal-polls"
    # Include the first not-ready observation and multiple rejected prompts.
    printf '%s\n' "$((1000 + polls / 2))" > "$CASE_DIR/goal-clock"
  else command sleep "$@"; fi
}
CONFIG
  for mode in never-ready never-accepted; do
    printf '1000\n' > "$CASE_DIR/goal-clock"
    printf '0\n' > "$CASE_DIR/goal-polls"
    printf '%s\n' "$mode" > "$CASE_DIR/herdr/goal-mode"
    issue="HG-$mode"
    dv start "$REPO" "$issue" native
    if ! wait_native "$issue"; then
      cat "$CASE_DIR/herdr/w-$issue/output"
      printf 'Expected failed event when /goal cannot be submitted\n' >&2
      return 1
    fi
    test ! -f "$DV_STATE/$issue/goal-input"
    grep -Fx 'Codex prompt not detected; use dv send to submit /goal.' "$DV_STATE/$issue/log"
    jq -se '[.[]|select(.kind=="failed" and .message=="Codex prompt not detected")]|length==1' "$DV_STATE/$issue/events.log"
    test "$(cat "$CASE_DIR/goal-clock")" -ge 1002
    if [ "$mode" = never-ready ]; then test ! -f "$CASE_DIR/herdr/w-$issue/goal-attempts"
    else test "$(cat "$CASE_DIR/herdr/w-$issue/goal-attempts")" -gt 1; fi
    dv clean "$issue"
  done
}
case_herdr_agents_land() {
  repo herdr-agents; herdr_setup
  dv start "$REPO" H-3 native --agent devin; wait_native H-3
  test -f "$DV_STATE/H-3/trust-enter"
  jq -se 'any(.[]; .==["pane","send-keys","w-H-3:p1","Enter"])' "$CASE_DIR/herdr/calls"
  dv start "$REPO" H-4 native --agent claude; wait_native H-4
  jq -e 'index("opus")!=null and index("--dangerously-skip-permissions")!=null' "$DV_STATE/H-4/args.json"
  dv start "$REPO" H-5 native --mode exec; wait_native H-5
  jq -e 'index("exec")!=null and index("hooks")!=null' "$DV_STATE/H-5/args.json"
  DV_TEST_CMD='test -f H-5.txt' dv land H-5
  test ! -f "$CASE_DIR/herdr/w-H-5/workspace"
  test -f "$CASE_DIR/herdr/w-H-3/workspace"; test -f "$CASE_DIR/herdr/w-H-4/workspace"
  dv clean H-3; dv clean H-4
}
case_herdr_more_agents() {
  repo herdr-more; herdr_setup
  local agent
  for agent in omp agy grok cursor; do
    dv start "$REPO" "HM-$agent" native --agent "$agent"; wait_native "HM-$agent"
    jq -e --arg agent "$agent" '.backend=="herdr" and .agent==$agent and .status=="done"' "$DV_STATE/HM-$agent/meta"
  done
  # Only agy and grok show a folder trust dialog; cursor trusts by flag.
  for agent in agy grok; do
    jq -se --arg pane "w-HM-$agent:p1" 'any(.[]; .==["pane","send-keys",$pane,"Enter"])' "$CASE_DIR/herdr/calls"
  done
  for agent in omp cursor; do
    jq -se --arg pane "w-HM-$agent:p1" 'all(.[]; .[0:3]!=["pane","send-keys",$pane])' "$CASE_DIR/herdr/calls"
  done
  for agent in omp agy grok cursor; do dv clean "HM-$agent"; done
}
case_agent_transcripts() {
  bidding_functions
  local wt='/scratch/dv-wt/my repo.v2-T_1'
  test "$(agent_transcript_dir omp "$wt")" = "$DV_OMP_SESSIONS/--scratch-dv-wt-my repo.v2-T_1--"
  test "$(agent_transcript_dir claude "$wt")" = "$DV_CLAUDE_SESSIONS/-scratch-dv-wt-my-repo-v2-T-1"
  test "$(agent_transcript_dir grok "$wt")" = "$DV_GROK_SESSIONS/%2Fscratch%2Fdv-wt%2Fmy%20repo.v2-T_1"
  test "$(agent_transcript_dir cursor "$wt")" = "$DV_CURSOR_SESSIONS/scratch-dv-wt-my-repo-v2-T-1/agent-transcripts"
  for agent in codex agy devin; do
    if agent_transcript_dir "$agent" "$wt"; then return 1; fi
  done
  test "$(agent_transcript_root codex)" = "$DV_CODEX_SESSIONS"
  test "$(agent_transcript_root agy)" = "$DV_AGY_SESSIONS"
  if agent_transcript_root devin; then return 1; fi
}
case_revive_transcript() {
  repo revive-transcript; herdr_setup
  local state="$DV_STATE/RT-1" wt dir
  dv start "$REPO" RT-1 transcript --agent omp
  wait_native RT-1
  wt=$(cd "$(jq -r .worktree "$state/meta")" && pwd -P)
  dir="$DV_OMP_SESSIONS/--$(printf '%s' "${wt#/}" | tr '/' '-')--"
  # Before the agent writes a session, status falls back to the store root.
  dv status RT-1 --json | jq -e --arg root "$DV_OMP_SESSIONS" '.[0].transcript==$root'
  mkdir -p "$dir"
  dv status RT-1 --json | jq -e --arg dir "$dir" '.[0].transcript==$dir'
  rm "$CASE_DIR/herdr/w-RT-1/detected" "$CASE_DIR/herdr/w-RT-1/exit"
  export DV_OMP_BIN="$ROOT/tests/fixtures/revived-agent"
  dv send RT-1 'continue after the lost pane'
  wait_file "$state/revived-input.json"
  wait_file "$state/revive/done"
  grep -F "$dir" "$state/revive/prompt.md"
  jq -e --arg dir "$dir" '.args[-1]|contains($dir)' "$state/revived-input.json"
}
case_herdr_disabled_legacy() {
  needs_tmux; repo herdr-disabled; start H-6; wait_done H-6
  jq -e '.backend=="tmux"' "$DV_STATE/H-6/meta"
  jq 'del(.backend)' "$DV_STATE/H-6/meta" > "$CASE_DIR/legacy"
  mv "$CASE_DIR/legacy" "$DV_STATE/H-6/meta"
  DV_HERDR=1 dv status H-6 --json | jq -e '.[0].backend=="tmux"'
  DV_HERDR=1 dv clean H-6
  test ! -e "$CASE_DIR/herdr/calls"
}
herdr_isolated_path() {
  # Exclude user PATH and ~/.local/bin so native tests cannot reach real herdr.
  mkdir -p "$CASE_DIR/path" "$CASE_DIR/empty-home"
  for tool in bash dirname git jq mkdir date tr basename cat env sleep mktemp mv rmdir sed sort tail wc grep rm touch awk ln getconf df uname id ps tee; do
    ln -s "$(command -v "$tool")" "$CASE_DIR/path/$tool"
  done
  # Host admission samples memory/load on macOS through these standard tools.
  for tool in sysctl vm_stat; do
    if command -v "$tool" >/dev/null; then ln -s "$(command -v "$tool")" "$CASE_DIR/path/$tool"; fi
  done
  if [ "${1:-}" = tmux ]; then ln -s "$(command -v tmux)" "$CASE_DIR/path/tmux"; fi
  export PATH="$ROOT/bin:$CASE_DIR/path"
}
case_herdr_missing() {
  needs_tmux; repo missing; herdr_isolated_path tmux
  export DV_HERDR=1
  HOME="$CASE_DIR/empty-home" start H-7 2> "$CASE_DIR/start.err"
  wait_done H-7
  HOME="$CASE_DIR/empty-home" dv clean H-7 2> "$CASE_DIR/clean.err"
  test ! -e "$CASE_DIR/herdr/calls"
  if grep -i herdr "$CASE_DIR/start.err" "$CASE_DIR/clean.err"; then return 1; fi
  jq -e '.backend=="tmux" and .herdr_workspace==null' "$DV_STATE/H-7/meta"
}
case_herdr_home_no_tmux() {
  repo herdr-home; herdr_setup
  mkdir -p "$CASE_DIR/empty-home/.local/bin"
  ln -s "$ROOT/tests/fixtures/herdr" "$CASE_DIR/empty-home/.local/bin/herdr"
  herdr_isolated_path
  if command -v tmux >/dev/null; then return 1; fi
  HOME="$CASE_DIR/empty-home" dv start "$REPO" H-8 native
  wait_native H-8
  jq -e '.backend=="herdr"' "$DV_STATE/H-8/meta"
  HOME="$CASE_DIR/empty-home" dv send H-8 hello
  HOME="$CASE_DIR/empty-home" dv status H-8 --json | jq -e '.[0].alive'
  HOME="$CASE_DIR/empty-home" dv clean H-8
  test ! -f "$CASE_DIR/herdr/w-H-8/workspace"
}
case_herdr_failure() {
  repo herdr-failure; herdr_setup; mkdir -p "$CASE_DIR/herdr"
  n=0
  for stage in 'workspace create' 'pane wait-output' 'pane run'; do
    n=$((n + 1)); issue="HF-$n"
    printf '%s\n' "$stage" > "$CASE_DIR/herdr/fail"
    if dv start "$REPO" "$issue" native 2> "$CASE_DIR/start.err"; then return 1; fi
    grep -F 'herdr startup failed' "$CASE_DIR/start.err"
    jq -e '.backend=="herdr" and .status=="start-failed"' "$DV_STATE/$issue/meta"
    test ! -e "$DV_STATE/$issue/agent.exit"
    rm "$CASE_DIR/herdr/fail"
    dv clean "$issue"
    test ! -f "$CASE_DIR/herdr/w-$issue/workspace"
  done
}
case_herdr_clean_safety() {
  repo herdr-safety; herdr_setup
  dv start "$REPO" H-9 native; wait_native H-9
  wt=$(jq -r .worktree "$DV_STATE/H-9/meta")
  # A reused id with a different label belongs to somebody else.
  jq '.result.workspace.label="another workspace"' "$CASE_DIR/herdr/w-H-9/workspace" > "$CASE_DIR/other"
  mv "$CASE_DIR/other" "$CASE_DIR/herdr/w-H-9/workspace"
  if dv clean H-9; then return 1; fi
  test -d "$wt"; test -f "$CASE_DIR/herdr/w-H-9/workspace"
  jq '.result.workspace.label="dv-H-9"' "$CASE_DIR/herdr/w-H-9/workspace" > "$CASE_DIR/other"
  mv "$CASE_DIR/other" "$CASE_DIR/herdr/w-H-9/workspace"
  printf 'workspace close\n' > "$CASE_DIR/herdr/fail"
  if dv clean H-9; then return 1; fi
  test -d "$wt"
  jq -e '.herdr_workspace=="w-H-9"' "$DV_STATE/H-9/meta"
  printf 'pane read\n' > "$CASE_DIR/herdr/fail"
  cp "$DV_STATE/H-9/log" "$CASE_DIR/log-before"
  dv 'done' H-9
  cmp "$CASE_DIR/log-before" "$DV_STATE/H-9/log"
  rm "$CASE_DIR/herdr/fail"
  printf 'agent get\n' > "$CASE_DIR/herdr/fail"
  dv status H-9 --json | jq -e '.[0].alive' # pane get fallback
  rm "$CASE_DIR/herdr/fail"
  rm "$CASE_DIR/herdr/w-H-9/workspace" # manually closed in herdr
  dv clean H-9
  test ! -d "$wt"
}

polish_setup() {
  repo polish remote
  git -C "$REPO" worktree add -qb codex/polish "$DV_WORK/polish"
  mkdir -p "$DV_STATE/POL-1"
  printf '%s\n' "$$" > "$DV_STATE/POL-1/agent.pid"
  jq -n --arg repo "$REPO" --arg wt "$DV_WORK/polish" '{repo:$repo,worktree:$wt,branch:"codex/polish",base:"main",slug:"polish",status:"running"}' > "$DV_STATE/POL-1/meta"
  cat > "$DV_STATE/POL-1/pr-body.md" <<'BODY'
# Summary

It is worth noting that this fixes 18 cases.
Run `dv pr DF-18` or ``echo `date` ``; see [docs](https://example.test/path?q=18#result).
Keep https://example.test/other and <mailto:dev@example.test>.

```bash
printf '%s\n' "$HOME" # literal, not evaluated
```

~~~~md
```nested```
~~~~

    indented code
    still code

> - ~~~sh
>   printf 'quoted code stays'
>   ~~~

Closes #18
BODY
  cp "$DV_STATE/POL-1/pr-body.md" "$CASE_DIR/original"
  cp "$CASE_DIR/original" "$GH_STUB_DIR/live-body"
  cp "$CASE_DIR/original" "$DV_STATE/POL-1/brief.md"
  printf '{"url":"https://github.com/test/repo/pull/1"}\n' > "$DV_STATE/POL-1/pr.json"
  export DV_POLISH=1 POLISH_MODE=success
}
case_polish_success() {
  polish_setup
  dv polish POL-1
  cmp "$CASE_DIR/original" "$DV_STATE/POL-1/pr-body.orig.md"
  sed 's/It is worth noting that this fixes/This fixes/' "$CASE_DIR/original" > "$CASE_DIR/expected"
  cmp "$CASE_DIR/expected" "$GH_STUB_DIR/edited-body"
  cmp "$CASE_DIR/expected" "$DV_STATE/POL-1/pr-body.md"
  grep -Fx 'api repos/test/repo/pulls/1' "$GH_STUB_DIR/calls"
  grep -F 'api -X PATCH repos/test/repo/pulls/1 -F body=@' "$GH_STUB_DIR/calls"
  cmp "$CASE_DIR/expected" "$GH_STUB_DIR/live-body"
  grep -F '사실·숫자·경로·명령·코드 블록·링크·제목 구조' "$CASE_DIR/polish-prompt"
  dv polish POL-1
  cmp "$CASE_DIR/original" "$DV_STATE/POL-1/pr-body.orig.md"
}
polish_rejected() {
  polish_setup
  export POLISH_MODE=$1
  dv polish POL-1
  cmp "$CASE_DIR/original" "$DV_STATE/POL-1/pr-body.md"
  cmp "$CASE_DIR/original" "$DV_STATE/POL-1/pr-body.orig.md"
  test ! -f "$GH_STUB_DIR/edited-body"
  grep -i "$2" "$DV_STATE/POL-1/polish.log"
}
case_polish_code_missing() { polish_rejected code validation; }
case_polish_tilde_missing() { polish_rejected tilde validation; }
case_polish_indented_missing() { polish_rejected indented validation; }
case_polish_quoted_code() { polish_rejected quoted validation; }
case_polish_inline_missing() { polish_rejected inline validation; }
case_polish_url_missing() { polish_rejected url validation; }
case_polish_empty() { polish_rejected empty empty; }
case_polish_failure() { polish_rejected failure 'command failed'; }
case_polish_timeout() {
  export DV_POLISH_TIMEOUT=1
  polish_rejected timeout timeout
  test ! -d "$DV_STATE/POL-1/.polish"
  if kill -0 "$(cat "$CASE_DIR/polish-child.pid")" 2>/dev/null; then
    test "$(ps -o stat= -p "$(cat "$CASE_DIR/polish-child.pid")" | cut -c 1)" = Z
  fi
}
case_polish_disabled() {
  polish_setup
  DV_POLISH=0 dv polish POL-1
  test ! -f "$CASE_DIR/polish-prompt"
  test ! -f "$GH_STUB_DIR/edited-body"
  cmp "$CASE_DIR/original" "$DV_STATE/POL-1/pr-body.md"
}
case_polish_edit_failure() {
  polish_setup
  touch "$GH_STUB_DIR/edit-fail"
  dv polish POL-1
  cmp "$CASE_DIR/original" "$DV_STATE/POL-1/pr-body.md"
  cmp "$CASE_DIR/original" "$GH_STUB_DIR/live-body"
  grep -F 'gh api PATCH failed' "$DV_STATE/POL-1/polish.log"
}
case_polish_remote_edit() {
  polish_setup
  export POLISH_MODE=remote-edit
  dv polish POL-1
  cmp "$CASE_DIR/human-body" "$GH_STUB_DIR/live-body"
  cmp "$CASE_DIR/original" "$DV_STATE/POL-1/pr-body.md"
  cmp "$CASE_DIR/original" "$DV_STATE/POL-1/pr-body.orig.md"
  test ! -f "$GH_STUB_DIR/edited-body"
  if grep -F 'api -X PATCH ' "$GH_STUB_DIR/calls"; then return 1; fi
  grep -F 'live PR body changed; edit skipped' "$DV_STATE/POL-1/polish.log"
}
case_polish_read_failure() {
  polish_setup
  touch "$GH_STUB_DIR/read-fail"
  dv polish POL-1
  cmp "$CASE_DIR/original" "$DV_STATE/POL-1/pr-body.md"
  cmp "$CASE_DIR/original" "$GH_STUB_DIR/live-body"
  test ! -f "$GH_STUB_DIR/edited-body"
  if grep -F 'api -X PATCH ' "$GH_STUB_DIR/calls"; then return 1; fi
  grep -F 'gh api read failed; edit skipped' "$DV_STATE/POL-1/polish.log"
}
case_polish_pr_url() {
  polish_setup
  printf '{"url":"https://github.com/another-owner/another.repo/pull/37"}\n' > "$DV_STATE/POL-1/pr.json"
  export GH_STUB_PR_ENDPOINT=repos/another-owner/another.repo/pulls/37
  dv polish POL-1
  test -f "$GH_STUB_DIR/edited-body"
  grep -Fx 'api repos/another-owner/another.repo/pulls/37' "$GH_STUB_DIR/calls"
  grep -F 'api -X PATCH repos/another-owner/another.repo/pulls/37 -F body=@' "$GH_STUB_DIR/calls"
}
case_polish_default() {
  polish_setup
  # An isolated PATH makes both routing tests independent of real installed agy/ssh.
  local client="$CASE_DIR/client" remote="$CASE_DIR/remote-bin" utility
  mkdir "$client" "$remote"
  for utility in bash dirname readlink jq mkdir rm cat cp awk grep cmp mv date sleep sed touch env; do
    ln -s "$(command -v "$utility")" "$client/$utility"
  done
  ln -s "$ROOT/tests/fixtures/gh" "$client/gh"
  ln -s "$ROOT/tests/fixtures/ssh" "$client/ssh"
  cat > "$remote/agy" <<'AGY'
#!/usr/bin/env bash
set -eu
test "$#" = 4 && test "$1" = --model && test "$2" = gemini-4-argon-high && test "$3" = -p
exec "$ROOT/tests/fixtures/polish" "$4"
AGY
  chmod +x "$remote/agy"
  ln -s "$remote/agy" "$client/agy"
  PATH="$client" DV_POLISH_CMD='' "$ROOT/bin/dv" polish POL-1
  test -f "$GH_STUB_DIR/edited-body"
  test ! -f "$CASE_DIR/polish-ssh"
  cp "$CASE_DIR/polish-prompt" "$CASE_DIR/local-prompt"
  cp "$CASE_DIR/original" "$DV_STATE/POL-1/pr-body.md"
  cp "$CASE_DIR/original" "$GH_STUB_DIR/live-body"
  rm "$client/agy" "$GH_STUB_DIR/edited-body"
  PATH="$client" DV_POLISH_CMD='' SSH_POLISH_PATH="$remote:$client" "$ROOT/bin/dv" polish POL-1
  test -f "$GH_STUB_DIR/edited-body"
  test -f "$CASE_DIR/polish-ssh"
  cmp "$CASE_DIR/local-prompt" "$CASE_DIR/polish-prompt"
}
case_polish_parallel() {
  polish_setup
  cp "$CASE_DIR/original" "$DV_STATE/POL-1/report.md"
  rm "$DV_STATE/POL-1/pr-body.md"
  rm "$DV_STATE/POL-1/pr.json"
  export POLISH_MODE=hold DV_POLISH_TIMEOUT=30
  dv pr POL-1
  wait_file "$CASE_DIR/polish-started"
  wait_pr_ready POL-1
  # CI/review completion and merge do not wait for the held polish command.
  test ! -f "$GH_STUB_DIR/edited-body"
  dv land POL-1
  test -f "$GH_STUB_DIR/merged"
  touch "$CASE_DIR/polish-release"
  wait_file "$GH_STUB_DIR/edited-body"
  for _ in {1..100}; do
    [ -d "$DV_STATE/POL-1/.polish" ] || break
    sleep 0.1
  done
  test ! -d "$DV_STATE/POL-1/.polish"
}

# shellcheck source=/dev/null
source "$ROOT/tests/codex-startup.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/codex-trust.sh"

failed_start_fixture() {
  # Failed receipt tests must observe wrapper exit before start acknowledges.
  # Preserve any outer scheduling fault injection used by a regression run.
  {
    if [ -n "${BASH_ENV:-}" ]; then printf 'source %q\n' "$BASH_ENV"; fi
    printf 'source %q\n' "$ROOT/tests/fixtures/failed-start-env"
  } > "$CASE_DIR/failed-start-env"
  export BASH_ENV="$CASE_DIR/failed-start-env"
}
bidding_hosts() {
  needs_tmux; repo bidding
  export SSH_BIDDING=1 DV_MANAGER_HOST=test-host DV_HOSTS='lina-os go2-linux hx-linux'
  export DV_WORKER_CMD="$ROOT/tests/fixtures/worker" DV_WATCH_INTERVAL=0.1 DV_RECONCILE_INTERVAL=99999
  local host
  for host in hx-linux go2-linux lina-os; do
    mkdir -p "$CASE_DIR/hosts/$host"
    cat > "$CASE_DIR/hosts/$host/config" <<EOF
DV_HOST=$host
DV_STATE='$CASE_DIR/hosts/$host/state'
DV_WORK='$CASE_DIR/hosts/$host/work'
DV_MAX_JOBS=1
DV_AGENT_CMD_codex='while :; do sleep 1; done'
EOF
  done
}
wait_task() {
  for _ in {1..200}; do
    if [ -f "$DV_HOME/submissions/$1/task.json" ] && jq -e --arg s "$2" '.status==$s' "$DV_HOME/submissions/$1/task.json" >/dev/null; then return; fi
    sleep 0.1
  done
  cat "$DV_HOME/submissions/$1/task.json" >&2
  return 1
}
case_bid_readonly() {
  needs_tmux; repo bid
  export DV_MAX_JOBS=2
  before=$(find "$CASE_DIR" -type f | sort)
  dv bid --json --repo "$REPO" --agent codex > "$CASE_DIR/bid.json"
  jq -e '.status=="submitted" and .capacity==2 and .free_slots==2 and .repo_cloned and .agent_ready and .cores>=1 and .load5>=0 and .memory_available_mb>=0 and (.score|type)=="number"' "$CASE_DIR/bid.json"
  rm "$CASE_DIR/bid.json"
  test "$before" = "$(find "$CASE_DIR" -type f | sort)"
  mkdir -p "$DV_STATE/B-1" "$DV_STATE/B-2"
  for n in 1 2; do printf '{"status":"running"}\n' > "$DV_STATE/B-$n/meta"; done
  dv bid --json --repo "$REPO" --agent codex | jq -e '.status=="rejected" and .free_slots==0'
  printf '0\n' > "$DV_STATE/B-1/agent.exit"
  dv bid --json --repo "$REPO" --agent codex | jq -e '.free_slots==1'
  DV_AGENT_CMD_codex='' DV_CODEX_BIN=false dv bid --json --repo "$REPO" --agent codex | jq -e '.status=="rejected" and (.agent_ready|not)'
  dv bid --json --repo "$CASE_DIR/missing" --agent codex | jq -e '.status=="rejected" and (.repo_cloned|not)'
  DV_MAX_JOBS='' dv bid --json --repo "$REPO" --agent codex | jq -e '.max_jobs==null and .capacity==.learned_cap'
}
case_submit_spread() {
  bidding_hosts
  local ticks expected attempt
  # Scores on these real local fake hosts differ slightly; manager is always last.
  dv submit "$REPO" BID-1 one --brief "$CASE_DIR/brief"
  dv submit "$REPO" BID-2 two --brief "$CASE_DIR/brief"
  dv submit "$REPO" BID-3 three --brief "$CASE_DIR/brief"
  dv submit "$REPO" BID-4 four --brief "$CASE_DIR/brief"
  : > "$CASE_DIR/watch-ticks"
  BASH_ENV="$ROOT/tests/fixtures/watch-tick-env" dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_task BID-1 working; wait_task BID-2 working; wait_task BID-3 working
  test "$(jq -r .host "$DV_HOME/submissions/BID-3/task.json")" = lina-os
  jq -s -e '[.[].host]|unique|length==3' "$DV_HOME"/submissions/BID-{1,2,3}/task.json
  wait_file "$DV_HOME/submissions/BID-4/bids.json"
  wait_task BID-4 submitted
  # bids.json can appear before scheduling commits its cursor. Wait until
  # all four submissions are handled, then observe two complete idle ticks.
  for attempt in {1..200}; do
    [ "$(cat "$DV_HOME/cursor" 2>/dev/null)" = 4 ] && break
    sleep 0.1
  done
  test "$(cat "$DV_HOME/cursor")" = 4
  grep -E ' dv (bid|_award) ' "$CASE_DIR/ssh.calls" > "$CASE_DIR/calls.before"
  ticks=$(wc -l < "$CASE_DIR/watch-ticks"); expected=$((ticks + 2))
  for attempt in {1..200}; do
    ticks=$(wc -l < "$CASE_DIR/watch-ticks")
    [ "$ticks" -ge "$expected" ] && break
    sleep 0.1
  done
  test "$ticks" -ge "$expected"
  # Status/maintenance RPCs do not constitute a new bid or award.
  grep -E ' dv (bid|_award) ' "$CASE_DIR/ssh.calls" > "$CASE_DIR/calls.after"
  cmp "$CASE_DIR/calls.before" "$CASE_DIR/calls.after"
  host=$(jq -r .host "$DV_HOME/submissions/BID-1/task.json")
  DV_CONFIG="$CASE_DIR/hosts/$host/config" dv 'done' BID-1
  wait_task BID-1 completed; wait_task BID-4 working
  test "$(jq -r .host "$DV_HOME/submissions/BID-4/task.json")" = "$host"
  touch "$DV_HOME/stop"; wait "$watcher"
  dv queue --json | jq -e 'length==4'
  if dv submit "$REPO" BID-1 one --brief "$CASE_DIR/brief"; then return 1; fi
}
case_submit_failover() {
  bidding_hosts; failed_start_fixture
  touch "$CASE_DIR/hosts/hx-linux/offline"
  # A launch error (missing base) must not prevent trying another bidder.
  cat >> "$CASE_DIR/hosts/go2-linux/config" <<EOF
DV_AGENT_CMD_codex=false
EOF
  dv submit "$REPO" FAIL-1 change --brief "$CASE_DIR/brief" --mode exec
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_task FAIL-1 working
  test "$(jq -r .host "$DV_HOME/submissions/FAIL-1/task.json")" = lina-os
  touch "$DV_HOME/stop"; wait "$watcher"
}
case_submit_cancel() {
  export DV_MANAGER_HOST="$DV_HOST" DV_HOSTS=''
  repo cancel
  dv submit "$REPO" CAN-1 change --brief "$CASE_DIR/brief"
  dv cancel CAN-1
  dv queue CAN-1 --json | jq -e '.[0].status=="canceled"'
  if dv submit "$REPO" BAD-1 change --brief "$CASE_DIR/missing"; then return 1; fi
  test ! -e "$DV_HOME/submissions/BAD-1"
}
case_submit_order() {
  bidding_hosts
  for host in hx-linux go2-linux lina-os; do
    printf '{"status":"submitted","score":100}\n' > "$CASE_DIR/hosts/$host/bid.json"
  done
  dv submit "$REPO" ORDER-1 change --brief "$CASE_DIR/brief"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_task ORDER-1 working
  test "$(jq -r .host "$DV_HOME/submissions/ORDER-1/task.json")" = hx-linux
  test "$(sed -n '/dv bid /s/ .*//p' "$CASE_DIR/ssh.calls" | tail -1)" = lina-os
  touch "$DV_HOME/stop"; wait "$watcher"
}
case_submit_order_amd() {
  bidding_hosts
  export DV_HOSTS='gos-linux amd-linux'
  local host
  for host in amd-linux gos-linux; do
    mkdir -p "$CASE_DIR/hosts/$host"
    sed "s/^DV_HOST=.*/DV_HOST=$host/; s#/hosts/lina-os/#/hosts/$host/#g" "$CASE_DIR/hosts/lina-os/config" > "$CASE_DIR/hosts/$host/config"
    printf '{"status":"submitted","score":100}\n' > "$CASE_DIR/hosts/$host/bid.json"
  done
  dv submit "$REPO" ORDER-2 change --brief "$CASE_DIR/brief"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_task ORDER-2 working
  # Equal scores: amd-linux (work host, 10-20) ranks before gos-linux (last resort).
  test "$(jq -r .host "$DV_HOME/submissions/ORDER-2/task.json")" = amd-linux
  touch "$DV_HOME/stop"; wait "$watcher"
}
case_submit_order_amd_go2() {
  bidding_hosts
  export DV_HOSTS='go2-linux amd-linux'
  local host
  for host in amd-linux go2-linux; do
    mkdir -p "$CASE_DIR/hosts/$host"
    sed "s/^DV_HOST=.*/DV_HOST=$host/; s#/hosts/lina-os/#/hosts/$host/#g" "$CASE_DIR/hosts/lina-os/config" > "$CASE_DIR/hosts/$host/config"
    printf '{"status":"submitted","score":100}\n' > "$CASE_DIR/hosts/$host/bid.json"
  done
  dv submit "$REPO" ORDER-3 change --brief "$CASE_DIR/brief"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_task ORDER-3 working
  # Equal scores: amd-linux ranks before go2-linux (jun 10-20: hx -> amd -> go2).
  test "$(jq -r .host "$DV_HOME/submissions/ORDER-3/task.json")" = amd-linux
  touch "$DV_HOME/stop"; wait "$watcher"
}
case_submit_timeout() {
  bidding_hosts
  export DV_BID_TIMEOUT=2
  touch "$CASE_DIR/hosts/hx-linux/hang-bid" "$CASE_DIR/hosts/go2-linux/drop-award"
  dv submit "$REPO" TIME-1 change --brief "$CASE_DIR/brief"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_task TIME-1 working
  test "$(jq -r .host "$DV_HOME/submissions/TIME-1/task.json")" = go2-linux
  test ! -e "$CASE_DIR/hosts/lina-os/state/TIME-1"
  test "$(grep -c 'go2-linux dv _award' "$CASE_DIR/ssh.calls")" = 1
  touch "$DV_HOME/stop"; wait "$watcher"
}
case_submit_forward() {
  bidding_hosts
  # Simulate submit from a developer host; the manager receives brief bytes via stdin.
  cp "$CASE_DIR/hosts/lina-os/config" "$CASE_DIR/hosts/lina-os/config.before"
  printf '\nDV_MANAGER_HOST=lina-os\n' >> "$CASE_DIR/hosts/lina-os/config"
  DV_MANAGER_HOST=lina-os dv submit "$REPO" FOR-1 change --brief "$CASE_DIR/brief"
  jq -e '.issue=="FOR-1" and .brief=="# Test brief\nImplement one file.\n" and .status=="submitted"' "$DV_HOME/submissions/FOR-1/task.json"
}
case_award_capacity() {
  bidding_hosts
  request() {
    jq -cn --arg issue "$1" --arg repo "$REPO" --argjson deadline "$(( $(date +%s) + DV_AWARD_TIMEOUT ))" \
      '{issue:$issue,repo:$repo,slug:"capacity",agent:"codex",mode:"goal",base:"",brief:"held fake agent",token:$issue,deadline:$deadline}'
  }
  request CAPA-1 | DV_CONFIG="$CASE_DIR/hosts/hx-linux/config" dv _award > "$CASE_DIR/a1" & a1=$!
  request CAPA-2 | DV_CONFIG="$CASE_DIR/hosts/hx-linux/config" dv _award > "$CASE_DIR/a2" & a2=$!
  wait "$a1"; wait "$a2"
  jq -se '[.[].status]|sort==["rejected","working"]' "$CASE_DIR/a1" "$CASE_DIR/a2"
  test "$(find "$CASE_DIR/hosts/hx-linux/state" -name meta | wc -l | tr -d ' ')" = 1
  test ! -e "$CASE_DIR/hosts/hx-linux/state/.admission-lock"
}
case_admission_owner() {
  repo admission
  cat > "$CASE_DIR/award" <<'AWARD'
#!/usr/bin/env bash
set -euo pipefail
DV_ENTRY="$ROOT/bin/dv"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/bidding.sh"
cmd_bid() {
  printf '%s\n' "$$" > "$CASE_DIR/entered-$DV_TEST_ACTOR"
  local tries=0
  until [ -f "$CASE_DIR/release-$DV_TEST_ACTOR" ]; do
    tries=$((tries+1)); [ "$tries" -lt 200 ] || return 1
    sleep 0.05
  done
  printf '{"status":"rejected"}\n'
}
cmd__award
AWARD
  jq -cn --arg repo "$REPO" --argjson deadline "$(( $(date +%s) + 30 ))" \
    '{issue:"OWNER-1",repo:$repo,slug:"owner",agent:"codex",mode:"goal",base:"",brief:"fake",token:"owner",deadline:$deadline}' > "$CASE_DIR/request"
  BASH_ENV="$ROOT/tests/fixtures/race-env" DV_TEST_RACE=admission DV_TEST_ACTOR=1 bash "$CASE_DIR/award" < "$CASE_DIR/request" > "$CASE_DIR/a1" & a1=$!
  wait_file "$CASE_DIR/entered-1"
  BASH_ENV="$ROOT/tests/fixtures/race-env" DV_TEST_RACE=admission DV_TEST_ACTOR=2 bash "$CASE_DIR/award" < "$CASE_DIR/request" > "$CASE_DIR/a2" & a2=$!
  local rc=0
  wait_contender || rc=1
  if [ -f "$CASE_DIR/entered-2" ]; then echo 'non-owner entered admission' >&2; rc=1; fi
  test ! -f "$CASE_DIR/removers" || rc=1
  touch "$CASE_DIR/release-1" "$CASE_DIR/release-2"
  wait "$a1" || rc=1; wait "$a2" || rc=1
  # Each EXIT trap must remove exactly its own lock, in acquisition order.
  printf '1 %s\n2 %s\n' "$(cat "$CASE_DIR/entered-1")" "$(cat "$CASE_DIR/entered-2")" > "$CASE_DIR/expected-removers"
  cmp "$CASE_DIR/expected-removers" "$CASE_DIR/removers"
  test ! -e "$DV_STATE/.admission-lock"
  [ "$rc" = 0 ]
}
case_submit_scores() {
  bidding_hosts
  printf '{"status":"submitted","score":100}\n' > "$CASE_DIR/hosts/hx-linux/bid.json"
  printf '{"status":"submitted","score":200}\n' > "$CASE_DIR/hosts/go2-linux/bid.json"
  printf '{"status":"submitted","score":999}\n' > "$CASE_DIR/hosts/lina-os/bid.json"
  dv submit "$REPO" SCORE-1 change --brief "$CASE_DIR/brief"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_task SCORE-1 working
  test "$(jq -r .host "$DV_HOME/submissions/SCORE-1/task.json")" = go2-linux
  dv-kick question SCORE-1 'in-scope choice' go2-linux h
  wait_task SCORE-1 input-required
  # Old-host completion cannot finish the current assignment.
  dv-kick 'done' SCORE-1 stale hx-linux h
  sleep 0.2
  wait_task SCORE-1 input-required
  dv-kick landed SCORE-1 complete go2-linux h
  wait_task SCORE-1 completed
  touch "$DV_HOME/stop"; wait "$watcher"
}
case_bid_clone() {
  needs_tmux; repo remote remote
  export DV_REPO_ROOT="$CASE_DIR/clones" DV_MAX_JOBS=1
  # The origin is rewritten to a disposable bare repo; no network or real PR.
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$CASE_DIR/remote.git.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/test/repo.git
  dv bid --json --repo https://github.com/test/repo.git --agent codex | jq -e '.status=="submitted" and (.repo_cloned|not)'
  test ! -e "$DV_REPO_ROOT"
  jq -cn --argjson deadline "$(( $(date +%s) + DV_AWARD_TIMEOUT ))" \
    '{issue:"CLONE-1",repo:"https://github.com/test/repo.git",slug:"clone",agent:"codex",mode:"goal",base:"",brief:"held fake agent",token:"clone",deadline:$deadline}' |
    DV_AGENT_CMD_codex='exec sleep 30' dv _award | jq -e '.status=="working"'
  test -d "$DV_REPO_ROOT/repo/.git"
  dv bid --json --repo https://github.com/test/repo.git --agent codex | jq -e '.repo_cloned and .status=="rejected" and .reason=="full"'
  dv bid --json --repo https://github.com/other/repo.git --agent codex | jq -e '(.repo_cloned|not) and .status=="rejected"'
}
case_bid_rejections() {
  needs_tmux; repo rejections
  DV_MIN_MEMORY_MB=999999999 dv bid --json --repo "$REPO" | jq -e '.status=="rejected" and .reason=="low memory"'
  DV_CLAUDE_BIN=false dv bid --json --repo "$REPO" --agent claude | jq -e '.status=="rejected" and (.agent_ready|not)'
  DV_DEVIN_BIN=false dv bid --json --repo "$REPO" --agent devin | jq -e '.status=="rejected" and (.agent_ready|not)'
  if dv bid --json --repo "$REPO" --agent gemini; then return 1; fi
  if DV_MAX_JOBS=0 dv bid --json; then return 1; fi
  if DV_BID_TIMEOUT=garbage dv bid --json; then return 1; fi
  mkdir -p "$DV_STATE/UNCERTAIN"
  printf '{"status":"input-required"}\n' > "$DV_STATE/UNCERTAIN/meta"
  DV_MAX_JOBS=1 dv bid --json --repo "$REPO" | jq -e '.status=="rejected" and .active==1'
}
bid_ready() { dv bid --json --repo "$REPO" --agent "$1" | jq -e '.agent_ready'; }
bid_unready() { dv bid --json --repo "$REPO" --agent "$1" | jq -e '.status=="rejected" and (.agent_ready|not)'; }
case_bid_more_agents() {
  needs_tmux; repo more-agents
  # agy, grok and cursor list models only with working authentication.
  DV_AGY_BIN=true bid_ready agy; DV_AGY_BIN=false bid_unready agy
  DV_GROK_BIN=true bid_ready grok; DV_GROK_BIN=false bid_unready grok
  DV_CURSOR_BIN=true bid_ready cursor; DV_CURSOR_BIN=false bid_unready cursor
  # cursor-agent status can report a login while every request fails.
  cat > "$CASE_DIR/cursor-status-only" <<'STUB'
#!/usr/bin/env bash
[ "$1" != models ]
STUB
  chmod +x "$CASE_DIR/cursor-status-only"
  DV_CURSOR_BIN="$CASE_DIR/cursor-status-only" bid_unready cursor
  # omp has no auth command: its custom provider and key must be configured.
  unset INFERHUB_API_KEY
  export DV_OMP_BIN=true
  bid_unready omp
  mkdir -p "$HOME/.omp/agent"
  printf 'providers:\n  other:\n    apiKey: OTHER_KEY\n  inferhub:\n    baseUrl: https://example.invalid\n    apiKey: INFERHUB_API_KEY\n    models:\n      - id: deepseek-v4.1-flash\n' > "$HOME/.omp/agent/models.yml"
  bid_unready omp
  INFERHUB_API_KEY=fixture bid_ready omp
  printf 'INFERHUB_API_KEY=fixture\n' > "$HOME/.omp/agent/.env"
  bid_ready omp
  DV_OMP_MODEL=missing/model bid_unready omp
  DV_OMP_BIN="$CASE_DIR/no-omp" bid_unready omp
  # The operator probe replaces the default in both directions.
  DV_GROK_BIN=true DV_AGENT_READY_grok=false bid_unready grok
  DV_GROK_BIN=false DV_AGENT_READY_grok=true bid_ready grok
  DV_AGENT_CMD_cursor='exec true' DV_CURSOR_BIN=false bid_ready cursor
}
case_submit_route() {
  repo route
  export DV_MANAGER_HOST=test-host
  submit_agent() { jq -r '.agent+":"+.mode' "$DV_HOME/submissions/$1/task.json"; }
  printf '# Docs\nRoute: writing\nRewrite the README intro.\n' > "$CASE_DIR/writing"
  printf '# Fix\nRoute: small\nFix one function.\n' > "$CASE_DIR/small"
  printf '# Plain\nRoute: default\nAnything.\n' > "$CASE_DIR/default"
  printf '# Typo\nRoute: smal\n' > "$CASE_DIR/typo"
  printf '# Prose\nRoute: small code\n' > "$CASE_DIR/prose"
  printf '# Windows\r\nRoute: writing\r\nRoute: small\r\n' > "$CASE_DIR/crlf"
  dv submit "$REPO" RO-1 docs --brief "$CASE_DIR/writing" 2> "$CASE_DIR/route.err"
  test "$(submit_agent RO-1)" = agy:goal
  grep -F 'Route: writing' "$CASE_DIR/route.err"
  dv submit "$REPO" RO-2 fix --brief "$CASE_DIR/small"
  test "$(submit_agent RO-2)" = dsh:exec
  dv submit "$REPO" RO-3 plain --brief "$CASE_DIR/brief"
  test "$(submit_agent RO-3)" = codex:goal
  dv submit "$REPO" RO-4 plain --brief "$CASE_DIR/default"
  test "$(submit_agent RO-4)" = codex:goal
  # An explicit agent or a Codex-only mode always wins over the brief.
  dv submit "$REPO" RO-5 explicit --brief "$CASE_DIR/writing" --agent claude
  test "$(submit_agent RO-5)" = claude:goal
  dv submit "$REPO" RO-6 exec --brief "$CASE_DIR/small" --mode exec
  test "$(submit_agent RO-6)" = codex:exec
  DV_ROUTE_WRITING='' dv submit "$REPO" RO-7 off --brief "$CASE_DIR/writing"
  test "$(submit_agent RO-7)" = codex:goal
  DV_ROUTE_SMALL=grok dv submit "$REPO" RO-8 grok --brief "$CASE_DIR/small"
  test "$(submit_agent RO-8)" = grok:goal
  if dv submit "$REPO" RO-9 typo --brief "$CASE_DIR/typo"; then return 1; fi
  if dv submit "$REPO" RO-9 prose --brief "$CASE_DIR/prose"; then return 1; fi
  # The first Route line decides; carriage returns are ignored.
  dv submit "$REPO" RO-11 crlf --brief "$CASE_DIR/crlf"
  test "$(submit_agent RO-11)" = agy:goal
  test ! -e "$DV_HOME/submissions/RO-9"
  if DV_ROUTE_SMALL=gemini dv submit "$REPO" RO-10 bad --brief "$CASE_DIR/small"; then return 1; fi
}
case_bid_rpc_timeout() {
  # A nested RPC shell inherits command-substitution stdout. Killing only its
  # outer wrapper leaves that pipe open until the descendant exits naturally.
  # shellcheck source=lib/bidding.sh
  source "$ROOT/lib/bidding.sh"
  # Passed by name to bid_limit below.
  # shellcheck disable=SC2317,SC2329
  slow_rpc() ( sleep 5; printf 'late reply\n'; )
  local before=$SECONDS reply rc=0
  reply=$(bid_limit 1 slow_rpc) || rc=$?
  test "$rc" != 0
  test -z "$reply"
  test "$((SECONDS-before))" -lt 4
}
bidding_functions() {
  # Exercise an individual event without unrelated reconciliation or workers.
  DV_ENTRY="$ROOT/bin/dv"
  # shellcheck source=lib/common.sh
  source "$ROOT/lib/common.sh"
  # shellcheck source=lib/herdr.sh
  source "$ROOT/lib/herdr.sh"
  # shellcheck source=lib/commands.sh
  source "$ROOT/lib/commands.sh"
  # shellcheck source=lib/bidding.sh
  source "$ROOT/lib/bidding.sh"
}
case_award_rejected_next() {
  bidding_hosts; bidding_functions
  export DV_HOSTS='hx-linux go2-linux'
  printf '{"status":"submitted","score":200}\n' > "$CASE_DIR/hosts/hx-linux/bid.json"
  printf '{"status":"submitted","score":100}\n' > "$CASE_DIR/hosts/go2-linux/bid.json"
  touch "$CASE_DIR/hosts/hx-linux/reject-award"
  dv submit "$REPO" REJECT-1 change --brief "$CASE_DIR/brief"
  bid_event "$(event_json submitted REJECT-1 '' "$DV_HOST" '')"
  jq -e '.status=="working" and .host=="go2-linux"' "$DV_HOME/submissions/REJECT-1/task.json"
  test "$(grep -c 'dv _award' "$CASE_DIR/ssh.calls")" = 2
}
case_award_new_round() {
  bidding_hosts; bidding_functions
  # This case supplies every event directly through bid_event. Do not let
  # failed fake agents race cleanup while writing an unused watcher queue.
  export DV_KICK=true
  local host kind issue saved
  failed_start_fixture
  export DV_HOSTS='hx-linux go2-linux'
  for kind in 'done' failed landed submitted; do
    issue="ROUND-$kind"
    for host in $DV_HOSTS; do
      printf '\nDV_AGENT_CMD_codex=false\n' >> "$CASE_DIR/hosts/$host/config"
    done
    dv submit "$REPO" "$issue" change --brief "$CASE_DIR/brief" --mode exec
    bid_event "$(event_json submitted "$issue" '' "$DV_HOST" '')"
    jq -e '.status=="submitted" and .host==null and (.attempts|length)==2' "$DV_HOME/submissions/$issue/task.json"
    # Confirmed failed receipts/state must be preserved when a later event retries.
    saved=$(cat "$CASE_DIR/hosts/hx-linux/state/.awards/$issue/receipt.json")
    printf '%s\n' "$saved" > "$CASE_DIR/old-receipt"
    for host in $DV_HOSTS; do
      printf '\nDV_AGENT_CMD_codex="exec sleep 30"\n' >> "$CASE_DIR/hosts/$host/config"
    done
    bid_event "$(event_json "$kind" "$issue" '' other-host h)"
    jq -e '.status=="working"' "$DV_HOME/submissions/$issue/task.json"
    host=$(jq -r .host "$DV_HOME/submissions/$issue/task.json")
    # The previously failed round's receipt remains byte-for-byte available.
    find "$CASE_DIR/hosts/hx-linux/state/.awards/$issue" -name receipt.json -exec cat '{}' + |
      jq -se --argjson old "$saved" 'any(.[]; .==$old)'
    bid_event "$(event_json failed "$issue" 'old startup failure' "$host" h)"
    jq -e '.status=="working"' "$DV_HOME/submissions/$issue/task.json"
    # Release this round's slot without fabricating a manager event.
    DV_CONFIG="$CASE_DIR/hosts/$host/config" dv clean "$issue"
    printf '0\n' > "$CASE_DIR/hosts/$host/state/$issue/agent.exit"
  done
}
case_award_uncertain_round() {
  bidding_hosts; bidding_functions
  export DV_HOSTS=hx-linux
  dv submit "$REPO" UNCERTAIN-1 change --brief "$CASE_DIR/brief"
  bid_task_set "$DV_HOME/submissions/UNCERTAIN-1" '.host="hx-linux"|.token="uncertain"|.attempts=["hx-linux"]'
  local receipt="$CASE_DIR/hosts/hx-linux/state/.awards/UNCERTAIN-1/receipt.json"
  mkdir -p "$(dirname "$receipt")"
  printf '{"token":"uncertain","status":"starting"}\n' > "$receipt"
  cp "$receipt" "$CASE_DIR/receipt.before"
  bid_event "$(event_json submitted UNCERTAIN-1 '' "$DV_HOST" '')"
  bid_event "$(event_json 'done' OTHER-1 '' other-host h)"
  jq -e '.status=="input-required" and .host=="hx-linux" and .token=="uncertain"' "$DV_HOME/submissions/UNCERTAIN-1/task.json"
  cmp "$CASE_DIR/receipt.before" "$receipt"
  if grep 'dv _award' "$CASE_DIR/ssh.calls"; then return 1; fi
}
case_goal_exit_rebids() {
  bidding_hosts
  export DV_HOSTS=hx-linux
  printf '\nDV_AGENT_CMD_codex=%q\n' "$ROOT/tests/fixtures/goal-exit" >> "$CASE_DIR/hosts/hx-linux/config"
  dv submit "$REPO" EXIT-1 first --brief "$CASE_DIR/brief"
  dv submit "$REPO" EXIT-2 second --brief "$CASE_DIR/brief"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_task EXIT-1 working
  wait_file "$DV_HOME/submissions/EXIT-2/bids.json"
  jq -e '.status=="submitted"' "$DV_HOME/submissions/EXIT-2/task.json"
  touch "$CASE_DIR/release-EXIT-1"
  wait_task EXIT-1 failed
  wait_task EXIT-2 working
  touch "$CASE_DIR/done-EXIT-2" "$CASE_DIR/release-EXIT-2"
  wait_task EXIT-2 completed
  wait_file "$CASE_DIR/hosts/hx-linux/state/EXIT-2/agent.exit"
  jq -se 'all(.[]; .kind!="failed")' "$CASE_DIR/hosts/hx-linux/state/EXIT-2/events.log"
  touch "$DV_HOME/stop"; wait "$watcher"
}
case_goal_exit_agents() {
  repo exits; bidding_functions
  local selected exit_code completed issue rc
  # No terminal is needed: isolate the exit wrapper from interactive injection.
  tmux_dv() { :; }
  inject_goal() { :; }
  accept_folder_trust() { :; }
  export DV_AGENT_CMD_codex='' DV_CODEX_BIN="$ROOT/tests/fixtures/goal-exit"
  export DV_CLAUDE_BIN="$ROOT/tests/fixtures/goal-exit" DV_DEVIN_BIN="$ROOT/tests/fixtures/goal-exit"
  export DV_OMP_BIN="$ROOT/tests/fixtures/goal-exit" DV_AGY_BIN="$ROOT/tests/fixtures/goal-exit"
  export DV_GROK_BIN="$ROOT/tests/fixtures/goal-exit" DV_CURSOR_BIN="$ROOT/tests/fixtures/goal-exit"
  for selected in codex claude devin omp agy grok cursor custom; do
    for exit_code in 0 9; do
      for completed in no yes; do
        issue="EXIT-$selected-$exit_code-$completed"
        mkdir "$DV_STATE/$issue"
        jq -n --arg issue "$issue" --arg repo "$REPO" --arg agent "${selected/custom/codex}" --arg head "$(git -C "$REPO" rev-parse HEAD)" \
          '{issue:$issue,repo:$repo,worktree:$repo,branch:"main",base:"main",agent:$agent,host:"test-host",mode:"goal",status:"running",start_head:$head}' > "$DV_STATE/$issue/meta"
        touch "$CASE_DIR/release-$issue"
        printf '%s\n' "$exit_code" > "$CASE_DIR/exit-$issue"
        [ "$completed" != yes ] || touch "$CASE_DIR/done-$issue"
        if [ "$selected" = custom ]; then export DV_AGENT_CMD_codex="$ROOT/tests/fixtures/goal-exit"; fi
        rc=0; (run_agent "$issue") || rc=$?
        test "$rc" = "$exit_code"
        if [ "$completed" = yes ]; then jq -se 'all(.[]; .kind!="failed")' "$DV_STATE/$issue/events.log"
        else jq -se '[.[]|select(.kind=="failed")]|length==1' "$DV_STATE/$issue/events.log"; fi
      done
    done
  done
}
case_award_timeout_lock() {
  bidding_hosts; bidding_functions
  export DV_MAX_JOBS=1 DV_AGENT_CMD_codex='exec sleep 30'
  mkdir "$CASE_DIR/tool"
  cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$ROOT/config.example.sh" "$CASE_DIR/tool/"
  mv "$CASE_DIR/tool/bin/dv" "$CASE_DIR/tool/bin/dv-real"
  cat > "$CASE_DIR/tool/bin/dv" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = start ] && [ -f "$CASE_DIR/delay-start" ]; then
  touch "$CASE_DIR/start-entered"
  exec sleep 30
fi
if [ "${1:-}" = start ] && [ "${DV_TEST_AWARD_DELAY:-0}" != 0 ]; then sleep "$DV_TEST_AWARD_DELAY"; fi
exec "$(dirname "$0")/dv-real" "$@"
STUB
  chmod +x "$CASE_DIR/tool/bin/dv"
  export DV_ROOT="$CASE_DIR/tool"
  award_request() {
    jq -cn --arg issue "$1" --arg repo "$REPO" --argjson deadline "$(( $(date +%s) + DV_AWARD_TIMEOUT ))" \
      '{issue:$issue,repo:$repo,slug:"timeout",agent:"codex",mode:"goal",base:"",brief:"fake",token:$issue,deadline:$deadline}'
  }
  touch "$CASE_DIR/delay-start"
  if award_request LOCK-1 | bid_limit 1 bid_rpc "$DV_HOST" _award > "$CASE_DIR/timeout.json"; then return 1; fi
  test -f "$CASE_DIR/start-entered"
  test -d "$DV_STATE/.admission-lock"
  cp "$DV_STATE/.awards/LOCK-1/receipt.json" "$CASE_DIR/uncertain-receipt"
  rm "$CASE_DIR/delay-start"
  award_request LOCK-2 | bid_limit "$DV_AWARD_TIMEOUT" bid_rpc "$DV_HOST" _award > "$CASE_DIR/next.json"
  jq -e '.status=="working"' "$CASE_DIR/next.json"
  cmp "$CASE_DIR/uncertain-receipt" "$DV_STATE/.awards/LOCK-1/receipt.json"
  test ! -d "$DV_STATE/.admission-lock"
  # A living owner's lock must not be reclaimed by a competing award.
  mkdir "$DV_STATE/.admission-lock"
  printf '%s\n' "$$" > "$DV_STATE/.admission-lock/pid-$$"
  ln "$DV_STATE/.admission-lock/pid-$$" "$DV_STATE/.admission-lock/owner"
  export BASH_ENV="$ROOT/tests/fixtures/race-env" DV_TEST_RACE=admission_cancel DV_TEST_ACTOR=cancelled
  if award_request LOCK-3 | bid_limit 1 bid_rpc "$DV_HOST" _award > "$CASE_DIR/live-owner.json"; then return 1; fi
  test -f "$CASE_DIR/contended-cancelled"
  unset BASH_ENV DV_TEST_RACE DV_TEST_ACTOR
  test -f "$DV_STATE/.admission-lock/pid-$$"
  test "$(cat "$DV_STATE/.admission-lock/owner")" = "$$"
  test ! -e "$DV_STATE/LOCK-3"
  # Cancellation may leave a non-owner candidate. Release only our own claim;
  # an empty directory is not part of the live-owner protection contract.
  owned_unlock "$DV_STATE/.admission-lock" "$$"
  test ! -e "$DV_STATE/.admission-lock/owner"
  test ! -e "$DV_STATE/.admission-lock/pid-$$"
}
case_award_timeout_slow_success() {
  export DV_TEST_AWARD_DELAY=4
  case_award_timeout_lock
}
bid_without_tmux() {
  cat > "$CASE_DIR/no-tmux-env" <<'NO_TMUX'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = tmux ]; then return 1; fi
  builtin command "$@"
}
NO_TMUX
  local rc=0
  BASH_ENV="$CASE_DIR/no-tmux-env" bash "$ROOT/tests/run.sh" --case "$1" > "$CASE_DIR/no-tmux.log" 2>&1 || rc=$?
  if [ "$rc" != 77 ]; then cat "$CASE_DIR/no-tmux.log"; printf 'Expected skip 77, got %s\n' "$rc"; return 1; fi
}
case_bid_readonly_no_tmux() { bid_without_tmux bid_readonly; }
case_bid_rejections_no_tmux() { bid_without_tmux bid_rejections; }
# Parse the complete driver before running it. Editing the file while an old
# runner was reading its tail previously produced a truncated `e` command.
# shellcheck source=/dev/null
source "$ROOT/tests/host.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/autofill.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/host-capacity.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/learned-capacity.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/delivery.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/pr-body.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/pr-format.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/claude.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/followups.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/watcher.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/stall.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/screen-locale.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/pr-wait-caller.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/bidding-edge.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/bidding-order.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/manager.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/revive.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/appserver.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/codex-exec.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/dsh.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/send-branch.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/codex-exec-review.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/portability.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/qa.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/qa-merge.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/gh-cache.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/metrics.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/pr-worker.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/self-update.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/disk.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/tmp.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/stack.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/watcher-stuck.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/stale-jobs.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/closed-issues.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/task.sh"
task_content_setup() {
  task_setup
  export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache"
  # Each case has its own process; another case's subshell cannot affect this setup.
  # shellcheck disable=SC2031
  export TMPDIR="$CASE_DIR/tmp"
  mkdir -p "$TMPDIR"
  export DV_CODEX_MODE=exec DV_AGENT_CMD_codex=''
  export DV_TRUSTED_REPOS="$CASE_DIR/Desk project" DV_CODEX_BIN="$CASE_DIR/task-content-agent"
  export DV_TASK_CONTENT=$1
  cat > "$DV_CODEX_BIN" <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-} ${2:-}" = 'login status' ]; then exit 0; fi
printf '{"type":"thread.started","thread_id":"task-content-fixture"}\n'
mkdir -p out/nested
: > out/empty.txt
: > out/nested/empty.txt
if [ "$DV_TASK_CONTENT" = mixed ]; then printf '\0' > out/nested/payload.bin; fi
printf 'Synthetic deliverables for content validation.\n' > "$DV_STATE/$DV_ISSUE/report.md"
dv 'done' "$DV_ISSUE"
printf '{"type":"turn.completed"}\n'
AGENT
  chmod +x "$DV_CODEX_BIN"
  task_start; task_exec_wait TK-1
}
case_task_empty_files_done() {
  task_content_setup empty
  # Each --case runs setup independently; other sourced cases cannot change it.
  # shellcheck disable=SC2031
  local s="$DV_STATE/TK-1"
  if dv 'done' TK-1 > "$CASE_DIR/done.log" 2>&1; then
    cat "$CASE_DIR/done.log"
    printf 'BUG: done accepted only zero-byte deliverables\n'; return 1
  fi
  grep -F 'task out/ has only empty files' "$CASE_DIR/done.log"
  test ! -e "$s/done.json"
  test ! -e "$s/task-snapshots"
  jq -e '.status!="done" and .exec_status!="done"' "$s/meta"
  jq -se 'all(.[]; .kind!="done")' "$s/events.log"
  test ! -f "$GH_STUB_DIR/calls"
}
case_task_empty_files_land() {
  task_content_setup mixed
  # shellcheck disable=SC2031
  local s="$DV_STATE/TK-1" wt manifest head snapshot
  wt=$(jq -r .worktree "$s/meta")
  : > "$wt/out/nested/payload.bin"
  # Model an internally consistent all-empty snapshot created by older dv.
  # shellcheck source=lib/task.sh
  source "$ROOT/lib/task.sh"
  manifest=$(jq -cn --arg empty "$(task_hash < "$wt/out/empty.txt")" --arg report "$(task_hash < "$s/report.md")" \
    '{files:(["empty.txt","nested/empty.txt","nested/payload.bin"]|map({path:.,sha256:$empty})),report_sha256:$report}')
  head="task-$(printf '%s\n' "$manifest" | task_hash)"
  snapshot="$s/task-snapshots/$head"
  mkdir -p "$snapshot/out"
  cp -R "$wt/out/." "$snapshot/out/"
  cp "$s/report.md" "$snapshot/report.md"
  jq --arg head "$head" '.head=$head' "$s/done.json" > "$CASE_DIR/legacy-done.json"
  mv "$CASE_DIR/legacy-done.json" "$s/done.json"
  if dv land TK-1 --checked "$head" > "$CASE_DIR/land.log" 2>&1; then
    cat "$CASE_DIR/land.log"
    printf 'BUG: land accepted an all-empty legacy snapshot\n'; return 1
  fi
  grep -F 'task out/ has only empty files' "$CASE_DIR/land.log"
  test ! -e "$CASE_DIR/destination/TK-1"
  jq -e '.status=="done" and .landed_path==null' "$s/meta"
  jq -se 'all(.[]; .kind!="landed")' "$s/events.log"
  test ! -f "$GH_STUB_DIR/calls"
}
case_task_mixed_files() {
  task_content_setup mixed
  # shellcheck disable=SC2031
  local s="$DV_STATE/TK-1" wt head snapshot landed
  wt=$(jq -r .worktree "$s/meta")
  head=$(jq -r .head "$s/done.json")
  snapshot="$s/task-snapshots/$head"
  jq -e '.files==3' "$s/done.json"
  mkfifo "$wt/out/nested/pipe"
  if dv 'done' TK-1 > "$CASE_DIR/done.log" 2>&1; then return 1; fi
  grep -F 'task out/ must contain only regular files and directories' "$CASE_DIR/done.log"
  rm "$wt/out/nested/pipe"
  # Valid working output cannot hide an all-empty corrupted snapshot.
  : > "$snapshot/out/nested/payload.bin"
  if dv land TK-1 --checked "$head" > "$CASE_DIR/land.log" 2>&1; then return 1; fi
  grep -F 'task out/ has only empty files' "$CASE_DIR/land.log"
  test ! -e "$CASE_DIR/destination/TK-1"
  cp "$wt/out/nested/payload.bin" "$snapshot/out/nested/payload.bin"
  # Empty auxiliary files still participate in revision integrity checks.
  printf 'changed\n' > "$wt/out/empty.txt"
  if dv land TK-1 --checked "$head" > "$CASE_DIR/land.log" 2>&1; then return 1; fi
  grep -F 'task changed since done' "$CASE_DIR/land.log"
  : > "$wt/out/empty.txt"
  mkdir "$CASE_DIR/destination/TK-1"
  printf 'keep\n' > "$CASE_DIR/destination/TK-1/existing.txt"
  dv land TK-1 --checked "$head"
  landed=$(jq -r .landed_path "$s/meta")
  test "$landed" = "$(cd "$CASE_DIR/destination/TK-1-v2" && pwd -P)"
  test "$(cat "$CASE_DIR/destination/TK-1/existing.txt")" = keep
  test -f "$landed/empty.txt" && test ! -s "$landed/empty.txt"
  test -f "$landed/nested/empty.txt" && test ! -s "$landed/nested/empty.txt"
  cmp "$wt/out/nested/payload.bin" "$landed/nested/payload.bin"
  test ! -f "$GH_STUB_DIR/calls"
}
# shellcheck source=/dev/null
source "$ROOT/tests/capacity.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/status-nonblocking.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/reconcile-recovery.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/heavy.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/process-cleanup.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/process-supervisor.sh"
runner_stub() {
  mkdir -p "$CASE_DIR/runner-bin"
  cat > "$CASE_DIR/runner-bin/bash" <<'STUB'
#!/bin/bash
set -eu
[ "$2" = --case ]
printf '%s\n' "$3" >> "$CASE_DIR/executed"
case "$3" in
  capacity_classifier) exit 77 ;;
  screen_locale_c) exit "${RUNNER_STUB_FAILURE:-0}" ;;
esac
STUB
  chmod +x "$CASE_DIR/runner-bin/bash"
  # Each case has its own process; changes in other cases cannot leak here.
  # shellcheck disable=SC2031
  export PATH="$CASE_DIR/runner-bin:$PATH"
}
case_runner_contract() {
  local shell=$BASH shard bad count
  runner_stub
  "$shell" "$ROOT/tests/run.sh" --list > "$CASE_DIR/all"
  # Listing must not execute even one case or emit a test summary.
  test ! -e "$CASE_DIR/executed"
  test -s "$CASE_DIR/all"
  if grep -vE '^[a-z][a-z0-9_]*$' "$CASE_DIR/all"; then return 1; fi
  test "$(sort "$CASE_DIR/all" | uniq -d | wc -l | tr -d ' ')" = 0
  : > "$CASE_DIR/union"
  for shard in 1 2 3 4 5 6; do
    "$shell" "$ROOT/tests/run.sh" --list --shard "$shard/6" > "$CASE_DIR/shard"
    cat "$CASE_DIR/shard" >> "$CASE_DIR/union"
    : > "$CASE_DIR/executed"
    "$shell" "$ROOT/tests/run.sh" --shard "$shard/6" > "$CASE_DIR/result"
    cmp "$CASE_DIR/shard" "$CASE_DIR/executed"
    grep -E '^pass=[0-9]+ skip=[01] fail=0$' "$CASE_DIR/result"
  done
  sort "$CASE_DIR/all" > "$CASE_DIR/expected"
  sort "$CASE_DIR/union" > "$CASE_DIR/actual"
  cmp "$CASE_DIR/expected" "$CASE_DIR/actual"
  "$shell" "$ROOT/tests/run.sh" --shard 1/1 --list > "$CASE_DIR/single"
  cmp "$CASE_DIR/all" "$CASE_DIR/single"
  for bad in 0/6 7/6 1/0 01/6 1/06 1/2/3 x/6 99999999999999999999/6; do
    if "$shell" "$ROOT/tests/run.sh" --list --shard "$bad"; then return 1; fi
  done
  if "$shell" "$ROOT/tests/run.sh" --shard; then return 1; fi
  if "$shell" "$ROOT/tests/run.sh" --unknown; then return 1; fi
  if "$shell" "$ROOT/tests/run.sh" --case no_such_case; then return 1; fi
  : > "$CASE_DIR/executed"
  if RUNNER_STUB_FAILURE=1 "$shell" "$ROOT/tests/run.sh" --shard 1/1 > "$CASE_DIR/result"; then return 1; fi
  count=$(wc -l < "$CASE_DIR/all" | tr -d ' ')
  grep -Fx "pass=$((count - 2)) skip=1 fail=1" "$CASE_DIR/result"
}
case_runner_selection() {
  local shell=$BASH file shard
  runner_stub
  "$shell" "$ROOT/tests/run.sh" --list > "$CASE_DIR/all"
  printf '%s\0' README.md docs/guide.txt skills/example/tool.sh 'docs/a b.md' > "$CASE_DIR/changes"
  "$shell" "$ROOT/tests/run.sh" --list --changed-files "$CASE_DIR/changes" > "$CASE_DIR/selected"
  test ! -s "$CASE_DIR/selected"
  printf '%s\0' lib/metrics.sh > "$CASE_DIR/changes"
  "$shell" "$ROOT/tests/run.sh" --list --changed-files "$CASE_DIR/changes" > "$CASE_DIR/selected"
  grep -Fx metrics_cli "$CASE_DIR/selected"
  grep -Fx capacity_classifier "$CASE_DIR/selected"
  if grep -Fx qa_landed "$CASE_DIR/selected"; then return 1; fi
  : > "$CASE_DIR/union"
  for shard in 1 2 3 4 5 6; do
    "$shell" "$ROOT/tests/run.sh" --list --shard "$shard/6" --changed-files "$CASE_DIR/changes" >> "$CASE_DIR/union"
  done
  sort "$CASE_DIR/selected" > "$CASE_DIR/expected"
  sort "$CASE_DIR/union" > "$CASE_DIR/actual"
  cmp "$CASE_DIR/expected" "$CASE_DIR/actual"
  printf '%s\0' lib/metrics.sh lib/qa.sh lib/metrics.sh > "$CASE_DIR/changes"
  "$shell" "$ROOT/tests/run.sh" --list --changed-files "$CASE_DIR/changes" > "$CASE_DIR/selected"
  grep -Fx qa_landed "$CASE_DIR/selected"
  test "$(sort "$CASE_DIR/selected" | uniq -d | wc -l | tr -d ' ')" = 0
  for file in bin/dv lib/common.sh lib/not-mapped.sh tests/run.sh tests/fixtures/gh .github/workflows/ci.yml tests/ci-map.json 'unknown path'; do
    printf '%s\0' "$file" > "$CASE_DIR/changes"
    "$shell" "$ROOT/tests/run.sh" --list --changed-files "$CASE_DIR/changes" > "$CASE_DIR/selected"
    cmp "$CASE_DIR/all" "$CASE_DIR/selected"
  done
  # An unavailable/empty diff cannot establish a docs-only change.
  : > "$CASE_DIR/changes"
  "$shell" "$ROOT/tests/run.sh" --list --changed-files "$CASE_DIR/changes" > "$CASE_DIR/selected"
  cmp "$CASE_DIR/all" "$CASE_DIR/selected"
  if "$shell" "$ROOT/tests/run.sh" --list --changed-files "$CASE_DIR/missing"; then return 1; fi
  printf '%s\n' lib/metrics.sh > "$CASE_DIR/changes"
  if "$shell" "$ROOT/tests/run.sh" --list --changed-files "$CASE_DIR/changes"; then return 1; fi
  test ! -e "$CASE_DIR/executed"
}
case_runner_mapping() {
  runner_check_mapping "$ROOT/tests/ci-map.json"
  jq 'del(.libraries["lib/metrics.sh"])' "$ROOT/tests/ci-map.json" > "$CASE_DIR/map.json"
  if runner_check_mapping "$CASE_DIR/map.json"; then return 1; fi
  jq '.libraries["lib/metrics.sh"]=["no_such_case_*"]' "$ROOT/tests/ci-map.json" > "$CASE_DIR/map.json"
  if runner_check_mapping "$CASE_DIR/map.json"; then return 1; fi
}
# shellcheck disable=SC2016
case_readme_startup_guidance() {
  if grep -E '기본 auto는 연결 가능한 App Server를 사용|실행 호스트에 연결 가능한 App Server가 있으면 사용' "$ROOT/README.md"; then return 1; fi
  grep -F 'Codex는 코드 작업과 같은 모드 선택을 사용합니다: 기본 auto와 `DV_CODEX_MODE=appserver`(경고 출력)는 자원 제한을 상속하는 백그라운드 JSON exec로 시작합니다.' "$ROOT/README.md"
  grep -F 'Codex 기본 모드는 `DV_CODEX_MODE=auto`이며, 새 auto/appserver 작업은 자원 격리를 위해 백그라운드 exec로 시작합니다(`DV_CODEX_MODE=appserver`는 경고를 출력하고 exec로 대체하며, App Server thread 제어는 기존 레거시 App Server 작업에만 적용됩니다).' "$ROOT/README.md"
}
# shellcheck disable=SC2016
case_readme_manager_max_wait() {
  local default_wait
  default_wait=$(bash -c 'unset DV_MANAGER_MAX_WAIT; source "$1"; printf "%s" "${DV_MANAGER_MAX_WAIT:-}"' _ "$ROOT/config.example.sh")
  [[ "$default_wait" =~ ^[0-9]+$ ]]
  if grep -E '`DV_MANAGER_MAX_WAIT`\(기본 [0-9]+초' "$ROOT/README.md" | grep -Fv "\`DV_MANAGER_MAX_WAIT\`(기본 ${default_wait}초"; then
    return 1
  fi
  grep -F "관리자 턴이 \`DV_MANAGER_MAX_WAIT\`(기본 ${default_wait}초" "$ROOT/README.md"
  grep -F '더 짧은 대기가 필요하면 `DV_MANAGER_MAX_WAIT`를 더 낮게 설정' "$ROOT/README.md"
}
# shellcheck source=/dev/null
source "$ROOT/tests/job-limits.sh"
# shellcheck source=/dev/null
source "$ROOT/tests/search-scope.sh"
registered_cases() {
  printf '%s\n' dsh_success dsh_restart dsh_followup_restart dsh_fallback dsh_resume dsh_stall dsh_capacity dsh_not_ready dsh_key
  printf '%s\n' dsh_quota dsh_crash_fallback dsh_completion_gate dsh_last_status dsh_jail dsh_jail_plan dsh_jail_nonlinux_log dsh_jail_unavailable dsh_host_sync dsh_host_probe
  printf '%s\n' dsh_delivery dsh_herdr_fallback
  printf '%s\n' dsh_silent_tool dsh_session_activity dsh_session_scope dsh_tool_cap dsh_tool_cap_activity dsh_tool_cap_per_call dsh_tool_cap_disabled
  printf '%s\n' owned_lock_missing_marker owned_unlock_reaper_race owned_unlock_marker_race owned_lock_dead_reaper owned_lock_recovery_race status_cut_utf8_log_bsd status_cut_utf8_pane_bsd status_cut_utf8_native status_cut_utf8_native_locale reconcile_timeout_default
  printf '%s\n' search_defaults search_override search_large search_tmux search_agents job_oom_evidence search_oom_retry search_oom_revive
  printf '%s\n' job_nproc job_failure job_failure_reset job_supervisor_retry job_generic_exit job_auto_exec job_host job_fallback job_launchd job_tasks job_memory job_agent_retry
  printf '%s\n' review_future_deadline review_future_deadline_retried review_near_deadline
  printf '%s\n' \
  learned_percentile learned_active_floor learned_window learned_readonly learned_idle learned_seeds learned_unknown_resources \
  capacity_load capacity_memory capacity_award capacity_start capacity_headroom capacity_task capacity_launch_reservation capacity_probe_cleanup \
  autofill_submit autofill_branch_slug autofill_dependencies autofill_order autofill_alarm autofill_duplicates autofill_errors autofill_brief autofill_missing_brief autofill_manager_alarm autofill_watch autofill_pages autofill_children autofill_shared_hosts autofill_event_cadence autofill_repository_events autofill_slot_release_events autofill_cancel_event autofill_label_event qa_merge_commit_event \
  status_cached_many status_cache_notifications status_cache_missing status_cache_live watch_status_slow watch_status_single recovery_sweep_progress \
  task_tmux_done_failed_status task_herdr_done_failed_status task_tmux_failed_status task_herdr_failed_status code_tmux_failed_status code_herdr_failed_status code_tmux_failed_stall code_herdr_failed_stall \
  config_work_fallback config_work_existing bid_work_unwritable bid_work_paths bid_overload award_error_detail \
  appserver_sender_close \
  metrics_restart_slow_start \
  award_timeout_slow_success \
  capacity_appserver_slow_work \
  question_goal_start_ack \
  exec_send_slow_completion \
  appserver_reader_legacy appserver_reader_preempt appserver_sender_preempt appserver_upgrade_partial appserver_upgrade_timeout appserver_rpc_timeout appserver_proxy_exit kick_pull_checkpoint question_wait_pid_cleanup symlink_send_branch_exec symlink_task_mixed_files teardown_wait_tmux \
  process_cleanup_pass process_cleanup_fail process_cleanup_timeout process_cleanup_term process_cleanup_nested heavy_descendant_slot \
  host_tmp_guard \
  tmp_reap tmp_guards tmp_agent tmp_appserver tmp_default tmp_quota tmp_reap_bash32 tmp_appserver_killed tmp_usage tmp_cache pr_body_delayed_wait \
  review_source_moved review_source_named review_source_numeric review_source_meta review_source_invalid_meta review_source_unknown review_source_start teardown_wait_host_agent \
  appserver_close_unset appserver_daemon_restart appserver_watch_dead_client appserver_daemon_lost_turn appserver_reconnect_stall_clock appserver_disconnect_unknown watcher_teardown_waiter \
  send_branch_appserver send_branch_appserver_reconnect send_branch_exec send_branch_tmux send_branch_herdr send_branch_revive send_branch_guards send_branch_missing send_branch_replaced_repo send_branch_replaced_path \
  heavy_serial heavy_kill heavy_slots heavy_status heavy_command heavy_priority heavy_config heavy_waiter_probe \
  capacity_classifier capacity_backoff capacity_exec_once capacity_exec_timeout capacity_appserver_once capacity_appserver_timeout capacity_appserver_rpc capacity_appserver_unknown capacity_qa_once capacity_qa_native capacity_qa_timeout capacity_claude capacity_devin capacity_omp capacity_omp_screen_text capacity_omp_session capacity_agent_lines capacity_agy capacity_grok capacity_cursor capacity_terminal_exit capacity_terminal_timeout capacity_legacy_terminal \
  land_merged land_merged_recorded_pr land_merged_recorded_done land_merged_mismatch land_merged_base_mismatch land_merged_cleanup_retry land_merged_dirty land_merged_checks land_worker_rule appserver_land_merged_active appserver_land_merged_timeout appserver_land_merged_failed appserver_land_merged_system_error \
  screen_locale_c screen_locale_utf8 \
  appserver_sender_idle appserver_sender_partial appserver_sender_legacy_idle appserver_sender_legacy_partial symlink_task_land symlink_exec_send clean_resume_task_exec clean_resume_code_exec clean_resume_task_tmux clean_resume_code_tmux clean_resume_appserver clean_resume_appserver_unknown stall_working_banner_detection stall_working_banner_resume stall_latest_activity stall_dead stall_dead_launched stall_dead_relaunch stall_dead_capacity_relaunch stall_large_rows stall_capacity stall_resume stall_resume_reset stall_resume_guards stall_resume_transport stall_banner_sequence stall_watch_resume stall_watch_revive stall_remote_resume stall_dead_old_banner stall_recovery_host stall_watch stall_status stall_episodes stall_inactive stall_observation stall_remote stall_tmux stall_failed_race failed_stall_race \
  task_empty_files_done task_empty_files_land task_mixed_files task_tmux_fast_completion code_tmux_fast_completion code_tmux_fast_revival task_tmux_stale_completion code_tmux_stale_completion task_tmux_socket_failed code_tmux_socket_failed task_tmux_session_missing code_tmux_session_missing task_tmux_new_session_failed code_tmux_new_session_failed task_snapshot task_snapshot_done_race task_snapshot_land_race task_appserver task_appserver_guards task_appserver_fallback task_codex_goal task_shellcheck task_tmux_live task_herdr_live task_tmux_failed task_herdr_failed task_tmux_changed task_herdr_changed task_recursive_destination task_start_done task_land task_guards task_revive task_claude task_invalid task_native task_exec_launch_race task_exec_stall task_capacity task_missing_output task_watcher task_land_workspace \
  update_stall_cadence update_cli update_dirty update_landed update_safety update_guard update_offline update_watch_dirty update_host update_managed update_parallel update_timeout update_unrelated update_receipt \
  disk_bid disk_probe disk_trim disk_pressure disk_recovered disk_cache_guard disk_cache_alias_guard disk_cache_canonical disk_cache_newline disk_env_cache_newline disk_home_newline disk_custom_cache disk_go_env_cache disk_separate_filesystems disk_unknown disk_award disk_bsd_stat disk_worktrees disk_host disk_watch disk_start_interval disk_watch_due teardown_wait_client teardown_preserve_live_client \
  stack_unfinished_auto_land stack_auto_done_guard stack_auto_done_merge stack_resume_done_episode stack_waiting_without_head stack_waiting_clock stack_safety_local stack_resume_headless stack_stalled stack_resume_guards stack_resume_failed stack_resume_interrupted stack_land_requeue stack_land_retry stack_remote_safety stack_wait stack_chain stack_diamond stack_parallel stack_local_body stack_dependency_punctuation stack_closed_base stack_api_failure stack_dirty stack_remote stack_reconcile stack_queue_concurrent stack_checks stack_push_retry stack_defer stack_dependencies_present stack_dependencies_present_conflict stack_missing_base stack_squash_base stack_rebase_base \
  appserver_reexec_accepted appserver_reexec_refused appserver_reexec_unknown appserver_legacy_capacity appserver_legacy_budget appserver_legacy_episode appserver_legacy_idle appserver_legacy_done appserver_legacy_inactive appserver_legacy_question appserver_scratch_root appserver_scratch_tmpdir appserver_scratch_long appserver_stale_done_recover appserver_pr_idle_recover appserver_recovery_uncertain appserver_recovery_events appserver_recovery_early_progress appserver_capacity_notification appserver_idle_done appserver_goal_done appserver_idle_blocked appserver_episode appserver_budget appserver_budget_restart appserver_capacity appserver_rate_limit appserver_recovery_guards appserver_start appserver_accepted appserver_refused appserver_unknown appserver_idle_send appserver_states appserver_large_reply appserver_read_partial appserver_status_done_clean appserver_status_done_stopped appserver_status_clean_stopped appserver_status_running_stopped appserver_status_done_communication appserver_status_landed_cheap appserver_failed appserver_retried_error appserver_stall appserver_question appserver_auto appserver_no_goal appserver_clean_guard appserver_reconnect appserver_active_stall appserver_unknown_restart appserver_question_multiple appserver_question_retry appserver_malformed appserver_watch appserver_fallback appserver_exec_override appserver_goal_override appserver_submit_auto appserver_exec appserver_pipeline appserver_pr_pending appserver_preserve_config appserver_detached appserver_detached_fallback appserver_websocket appserver_active_error_send appserver_interrupt_pending appserver_interrupt_timeout appserver_done_refused appserver_done_unknown appserver_land_active \
  qa_match_unlisted qa_match_closed qa_match_pr qa_match_error qa_match_http_failure qa_title_error_object qa_title_second_page qa_title_page_failure qa_title_page_error qa_title_empty_response qa_title_full_last_page qa_finding_format qa_title_rejected \
  qa_crashed_dispatch qa_crashed_receipt qa_dispatch_receipt_guards qa_dispatch_live_runner qa_dispatch_exited_receipt qa_dispatch_completed_receipt qa_dispatch_unawarded qa_crashed_without_pending \
  qa_request_retry qa_empty_reply_retry qa_invalid_reply_retry qa_second_lookup_retry qa_request_blocked qa_empty_reply_blocked qa_base_request_blocked qa_pr_lookup_retry qa_base_lookup_retry qa_pr_lookup_blocked qa_base_lookup_blocked qa_milestone_graphql qa_no_milestone qa_no_milestone_match qa_milestone_blocked qa_milestone_ambiguous qa_landed qa_coalesce qa_optout qa_duplicate qa_new_finding qa_batch qa_restart qa_fresh_codex qa_fresh_claude qa_merged_base qa_repository_ids qa_transport_retry qa_recovered_capacity qa_dead_runner qa_dead_capacity_runner qa_explicit_match qa_config_data qa_unbound_event qa_bound_event \
  metrics_cli metrics_activity metrics_lifecycle metrics_handled metrics_manager metrics_idle metrics_external_merge metrics_agent_counts metrics_remote metrics_timestamp metrics_missing_worktree metrics_queue_activity metrics_terminal metrics_pull_time metrics_queue_corruption metrics_concurrent metrics_nonblocking metrics_collector_restart metrics_exec metrics_exec_events metrics_manager_batch metrics_manager_fallback metrics_timeout_snapshot metrics_stall_overlap \
  review_receipt_ambiguous review_receipt_metadata review_receipt_incomplete review_receipt review_receipt_guards review_receipt_findings review_receipt_wait review_receipt_arrives review_summary_new_findings review_summary_latest_low review_summary_complete_low review_legacy_bot stack_review_update stack_review_recover review_clean_summary review_summary_guards review_summary_api_failure review_other_bot review_ci_first review_badges review_current review_summary review_land_missing review_land_latest review_timeout review_rounds review_e2e review_followup review_followup_no_milestone review_followup_source review_followup_title review_retry_arrives review_done_live review_api_failure review_latest_inline pr_worker_stale_recovery pr_worker_foreground pr_worker_large_comments pr_worker_done_gate pr_worker_red pr_worker_loop pr_worker_cap pr_worker_stale pr_worker_live_checks pr_worker_comments_failure pr_worker_handoff pr_worker_revive pr_worker_revive_policy pr_worker_requires_review pr_worker_revive_exec pr_worker_exit_race pr_worker_exec_missing_pr pr_worker_native_exec \
  exec_cleanup_success exec_cleanup_failure exec_cleanup_signal exec_exhausted_rebids exec_land_running exec_land_github_running exec_land_failed \
  exec_success exec_config_flags exec_warning_items exec_launch_race exec_nonzero exec_capacity exec_rate exec_silence exec_unfinished exec_retry exec_send exec_working exec_fresh exec_partial exec_followup_unfinished exec_no_terminal \
  portable_darwin_resources \
  symlink_paths symlink_claude_stale_server symlink_claude_stale_server_empty symlink_revive_dead symlink_revive_tmux revive_wait_exit claude_bsd_stat_mode host_darwin_shells revive_done_capacity revive_orphan_owner revive_orphan_close_failure revive_stale_marker revive_goal_owned_done revive_report_event revive_orphan_workspace revive_manual_done revive_capacity revive_release_event revive_legacy_idle revive_legacy_unknown revive_capacity_status revive_legacy_busy revive_legacy_uncertain revive_dead revive_live revive_failure revive_goal_failure revive_transport revive_tmux revive_missing_pane revive_missing_pane_live revive_missing_pane_unknown revive_legacy_exit revive_start_failure revive_undetected revive_worktree_guard revive_goal_no_done revive_override revive_tmux_retained revive_tmux_live revive_codex_goal \
  manager_reexec manager_real_conflict manager_real_pending_conflict manager_conflict_restart manager_reserved_collision manager_note_busy watch_stuck_route watch_stuck_bid watch_stack_background_failure watch_stuck_empty watch_stuck_worker manager_collision manager_fallback_collision manager_hash_collision manager_legacy_replay manager_note manager_pool_independent watch_capacity_eight watch_stuck \
  manager_batch manager_batch_order manager_latency manager_busy manager_notice manager_busy_default manager_capacity_restart manager_fallback_restart manager_fallback_serial manager_start manager_identity manager_serial manager_parallel manager_fallback manager_no_id manager_unmanaged manager_local manager_remote_repo manager_remote_repo_failure manager_remote_repo_local_collision manager_stop_pending manager_concurrent_start manager_failed_event manager_restart_queue manager_unmanaged_override manager_unknown_repo manager_reused_issue manager_moved_checkout manager_stale_lock manager_surviving_runner manager_runner_ownership \
  pr_wait_caller_killed pr_wait_caller_fallback pr_wait_caller_delayed pr_late_checks pr_wait_stale pr_wait_killed pr_wait_live pr_wait_detached pr_wait_fallback pr_wait_concurrent pr_wait_head pr_wait_failed_checks pr_wait_conflict watch_retry watch_retry_restart watch_inflight_replay watch_killed reconcile_delivery reconcile_corrected_head status_done_head reconcile_waiter reconcile_waiter_remote \
  codex_allowlist bid_reject_repos codex_persisted_trust codex_trust_conflict codex_trust_duplicate codex_trust_parallel codex_provider_missing codex_provider_env codex_folder_trust codex_folder_after_prompt codex_trust_formats codex_trust_refuse codex_trust_linked codex_trust_clone_bid \
  question_async_ack question_overlap question_claude_overlap question_delivery_retry polish_public_delayed polish_public_during_run polish_public_published question_async question_answered question_during_grace question_claude_answered question_delivery_failure question_stderr question_tmux_off codex_trust_alias claude_trust_alias host_descendant_timeout host_npm_failure host_npm_failure_symlink host_checksum host_path_newline host_auth_override host_npm_origin pr_body_update reconcile_alias award_retry_rejection award_stale_failure bid_schedule_lock_dead_owner award_early_absent bid_clean_capacity submit_local_origin submit_invalid_repo \
  claude_stale_server claude_stale_server_empty claude_profile_onboarding claude_profile_trust claude_profile_create claude_profile_invalid claude_trust_mode claude_trust_acl claude_trust_copy_failure claude_profile_start claude_profile_host bid_order_ties bid_order_fallback bid_order_probes bid_order_reject_input bid_order_early_reject bid_order_early_errors claude_trust_create claude_trust_preserve claude_trust_parallel claude_trust_invalid claude_trust_atomic claude_onboarding claude_start claude_start_tmux claude_start_failed claude_host host_repair host_path_preserve host_real_shells host_source_without_dv_root host_dsh_env_isolation host_check host_codex host_agents host_sync host_sync_darwin host_sync_failure host_path_guard bid_readonly submit_spread submit_failover submit_cancel submit_order submit_order_amd submit_order_amd_go2 submit_timeout submit_forward award_capacity admission_owner submit_scores bid_clone bid_rejections bid_rpc_timeout award_rejected_next award_new_round award_uncertain_round goal_exit_rebids goal_exit_agents award_timeout_lock bid_readonly_no_tmux bid_rejections_no_tmux bid_more_agents submit_route \
  stack_conflict question_codex_record question_record_limit question_record_fallback question_claude_record herdr_cleanup_owner question_pull_replay question_startup question_signal question_claude question_devin question_omp question_agy question_grok question_cursor question_banner_agents question_cli question_cli_off question_episodes question_grace question_exit question_wait_failure polish_success polish_code_missing polish_tilde_missing polish_indented_missing polish_quoted_code polish_inline_missing polish_url_missing polish_empty polish_failure polish_timeout polish_disabled polish_edit_failure polish_remote_edit polish_read_failure polish_pr_url polish_default polish_parallel start_done kick_failure kick_stale_lock local_land pr_land pr_public_body review_loop_rule blocked_event_ids clean parallel install install_linux_watch review watch reconcile reconcile_slow_host reconcile_local kick_local_host kick_pull watch_pull worker_prompt_host agent_cli agent_cli_off agent_cli_more agent_transcripts revive_transcript pr_ready base_merge watch_capacity land_checkout_race herdr_start_clean herdr_send_retry herdr_undetected herdr_goal_retry herdr_goal_timeout herdr_agents_land herdr_more_agents herdr_disabled_legacy herdr_missing herdr_home_no_tmux herdr_failure herdr_clean_safety codex_hook_trust codex_hook_actions codex_hook_modal codex_hook_after_prompt codex_goal_stalled codex_goal_enter codex_goal_enter_stalled codex_goal_screen_working codex_goal_history codex_repo_trust codex_tmux_startup codex_hook_recovered codex_start_recovered codex_done_delivery_status \
  land_squash_only land_merge_only land_rebase_only land_prefer_squash land_prefer_merge land_override_env land_override_repo land_config_stdout land_policy_gh_repo land_policy_pr_url land_override_precedence land_no_methods land_invalid_method land_disallowed_method land_repo_failure land_config_failure land_head_mismatch land_unconfirmed \
  pr_fallback_body pr_fallback_summary pr_fallback_private_paths pr_fallback_private_hosts pr_fallback_public_tokens pr_fallback_missing pr_fallback_bounded pr_fallback_private_only pr_head_title pr_prepared_body pr_legacy_body pr_patch_title pr_patch_body polish_unreachable polish_unreachable_timeout \
  pr_title_format pr_branch_names pr_body_template pr_format_delivery pr_format_legacy pr_format_start pr_format_instructions \
  reconcile_stale_prs reconcile_merged_unverified land_already_merged land_already_merged_guards qa_clean_url park_prerequisites park_repark_blockers park_agent_exit park_exec_exit park_open_pr park_pr_prerequisites park_pr_wait park_pr_stale_send park_pr_wait_resume park_pr_reconcile reconcile_merged_cleanup_retry \
  runner_contract runner_selection runner_mapping readme_startup_guidance readme_manager_max_wait
  printf '%s\n' qa_landed_admission_race \
    qa_scan_batch qa_scan_delayed qa_scan_retry qa_scan_base_event \
    qa_merge_empty_observed qa_merge_whitespace_observed qa_merge_invalid_observed qa_merge_shape_observed qa_merge_multiple_observed \
    qa_merge_empty_pending qa_merge_whitespace_pending qa_merge_invalid_pending qa_merge_shape_pending qa_merge_multiple_pending qa_merge_scan_pending qa_merge_recovery_retry \
    gh_cache_conditional gh_cache_fail_closed gh_cache_immutable review_cache_snapshot review_cache_pass_counts
  printf '%s\n' watch_quiet_events manager_rotate manager_rotate_keep
  printf '%s\n' \
    qa_external_merge qa_merge_debounce qa_merge_disabled qa_merge_untrusted_event qa_merge_catchup qa_merge_api_retry qa_merge_base_membership qa_merge_missing_state qa_merge_startup_catchup qa_merge_legacy_catchup qa_merge_disabled_pending qa_merge_spread qa_merge_event_wake qa_github_event_input qa_github_event_dedup qa_github_event_retry qa_github_not_modified pr_worker_late_waiter \
    pr_worker_idle_review pr_worker_idle_guards pr_worker_idle_concurrent pr_worker_idle_tmux stall_pr_idle stall_pr_remote \
    host_omp_compaction host_omp_compaction_failure host_omp_compaction_missing \
    stall_omp_once stall_omp_patterns stall_omp_forms stall_omp_wip stall_omp_pr stall_omp_unmerged stall_omp_negative stall_omp_guards \
    stall_omp_session stall_omp_transport stall_omp_gap stall_omp_config stall_omp_daily stall_omp_remote
  printf '%s\n' reconcile_closed_issue reconcile_closed_event reconcile_submission_terminal reconcile_closed_guards reconcile_closed_push_retry reconcile_closed_submission_event reconcile_closed_waiter reconcile_closed_appserver reconcile_closed_tmux reconcile_closed_merged_pr
}

runner_error() { printf 'tests/run.sh: %s\n' "$*" >&2; return 2; }
runner_check_mapping() {
  local mapping=$1 libraries patterns pattern name matched
  libraries=$(printf '%s\n' "$ROOT"/lib/*.sh | sed "s|^$ROOT/||" | jq -Rsc 'split("\n")[:-1] | sort')
  jq -e --argjson libraries "$libraries" '
    type == "object" and
    (.libraries | type == "object" and (keys == $libraries)) and
    (.smoke | type == "array" and length > 0) and
    ([.smoke, .libraries[]] | all(.[];
      type == "array" and length > 0 and all(.[]; type == "string" and test("^[a-z0-9_*]+$"))))
  ' "$mapping" >/dev/null || { runner_error 'mapping must cover every lib file with nonempty case patterns'; return 2; }
  patterns=$(jq -r '[.smoke[], .libraries[][]] | unique[]' "$mapping") || return
  while IFS= read -r pattern; do
    matched=false
    while IFS= read -r name; do
      # The mapping deliberately contains shell globs, never shell code.
      # shellcheck disable=SC2053
      if [[ "$name" = $pattern ]]; then matched=true; break; fi
    done < <(registered_cases)
    [ "$matched" = true ] || { runner_error "unmatched case pattern: $pattern"; return 2; }
  done <<< "$patterns"
}
runner_select() {
  local changes=$1 mapping="$ROOT/tests/ci-map.json" path patterns='' mapped name pattern
  local full=false seen=false selected=false
  if [ -z "$changes" ]; then registered_cases; return; fi
  [ -r "$changes" ] || { runner_error "cannot read changed files: $changes"; return 2; }
  runner_check_mapping "$mapping" || return
  # git diff --name-only -z --no-renames preserves spaces/newlines and both
  # sides of a rename. A malformed/unavailable diff must never skip coverage.
  while :; do
    path=''
    if ! IFS= read -r -d '' path; then
      [ -z "$path" ] || { runner_error 'changed files must be NUL-delimited'; return 2; }
      break
    fi
    seen=true
    case "$path" in
      README|README.*|docs/*|skills/*|*.md) continue ;;
    esac
    selected=true
    if mapped=$(jq -er --arg path "$path" '.libraries[$path] | select(. != null) | .[]' "$mapping"); then
      patterns="${patterns}${mapped}"$'\n'
    else
      full=true
    fi
  done < "$changes"
  if [ "$full" = true ] || [ "$seen" = false ]; then registered_cases; return; fi
  [ "$selected" = true ] || return 0
  patterns="${patterns}$(jq -r '.smoke[]' "$mapping")"
  while IFS= read -r name; do
    while IFS= read -r pattern; do
      # shellcheck disable=SC2053
      if [[ "$name" = $pattern ]]; then printf '%s\n' "$name"; break; fi
    done <<< "$patterns"
  done < <(registered_cases)
}
main() {
  local list=false changes='' shard=1 total=1 value names name index=0 result
  local pass=0 skip=0 fail=0 runner_case=''
  if [ "${1:-}" = --case ]; then
    if [ "$#" != 2 ] || ! declare -F "case_$2" >/dev/null; then
      runner_error 'expected --case NAME with a known case'; return 2
    fi
    if [ "${DV_TEST_EXECUTE_CASE:-0}" = 1 ]; then
      unset DV_TEST_EXECUTE_CASE
      setup; "case_$2"; return
    fi
    runner_supervise_case "$2"
  fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --list) list=true; shift ;;
      --shard)
        [ "$#" -ge 2 ] || { runner_error 'expected --shard i/n'; return 2; }
        value=$2
        # Bound digits before arithmetic, including on 32-bit Bash 3.2.
        [[ "$value" =~ ^([1-9][0-9]{0,5})/([1-9][0-9]{0,5})$ ]] || { runner_error 'expected --shard i/n (1 <= i <= n <= 999999)'; return 2; }
        shard=${BASH_REMATCH[1]}; total=${BASH_REMATCH[2]}
        [ "$shard" -le "$total" ] || { runner_error 'shard index exceeds shard count'; return 2; }
        shift 2 ;;
      --changed-files)
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
          runner_error 'expected --changed-files NUL_DELIMITED_FILE'; return 2
        fi
        changes=$2; shift 2 ;;
      *) runner_error "unknown option: $1"; return 2 ;;
    esac
  done
  names=$(runner_select "$changes") || return
  trap 'runner_suite_stop 143' TERM
  trap 'runner_suite_stop 130' INT
  trap 'runner_suite_stop 129' HUP
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    index=$((index + 1))
    [ "$(((index - 1) % total + 1))" = "$shard" ] || continue
    declare -F "case_$name" >/dev/null || { runner_error "unregistered case function: $name"; return 2; }
    if [ "$list" = true ]; then printf '%s\n' "$name"; continue; fi
    bash "$0" --case "$name" 9>&- <&0 &
    # shellcheck disable=SC2031
    runner_case=$!
    if wait "$runner_case"; then
      pass=$((pass + 1)); printf 'PASS %s\n' "$name"
    else
      result=$?
      if [ "$result" = 77 ]; then skip=$((skip + 1)); printf 'SKIP %s (tmux unavailable)\n' "$name"
      else fail=$((fail + 1)); printf 'FAIL %s (exit %s)\n' "$name" "$result"; fi
    fi
    runner_case=''
  done <<< "$names"
  [ "$list" = false ] || return 0
  printf 'pass=%s skip=%s fail=%s\n' "$pass" "$skip" "$fail"
  [ "$fail" -eq 0 ]
}
# shellcheck source=/dev/null
source "$ROOT/tests/review-loop.sh"
main "$@"
