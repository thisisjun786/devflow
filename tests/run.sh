#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export ROOT

setup() {
  CASE_DIR=$(mktemp -d "${DV_TEST_TMP:-${TMPDIR:-/tmp}}/dv-test.XXXXXX")
  export CASE_DIR
  export HOME="$CASE_DIR/agent home"
  export GOCACHE="$HOME/.cache/go-build"
  mkdir -p "$HOME/.claude"
  printf '{"hasCompletedOnboarding":true}\n' > "$HOME/.claude.json"
  printf '{"skipDangerousModePermissionPrompt":true}\n' > "$HOME/.claude/settings.json"
  export DV_CONFIG="$CASE_DIR/config.sh" DV_STATE="$CASE_DIR/state" DV_WORK="$CASE_DIR/work" DV_HOME="$CASE_DIR/home"
  export DV_KICK="$ROOT/bin/dv-kick" DV_AGENT_CMD_codex="$ROOT/tests/fixtures/agent"
  export DV_TMUX_SOCKET="dv-test-$$" DV_REVIEW_WAIT=0 DV_POLL_INTERVAL=1 DV_START_WAIT=5
  export DV_CODEX_BIN="$ROOT/tests/fixtures/codex" DV_HOST=test-host
  export DV_HERDR=0
  export DV_AUTO_UPDATE=0
  export DV_CODEX_MODE=goal DV_APPSERVER_POLL=5 DV_APPSERVER_TIMEOUT=1
  unset DV_MODE
  unset DV_RECOVER_MAX DV_CAPACITY_BACKOFF DV_CAPACITY_MAX_WAIT
  unset CODEX_HOME
  export DV_TRUSTED_REPOS='' DV_CODEX_ENV_FILE="$HOME/.opencodex/codex-auth-env.sh"
  unset DV_AGENT_QUESTIONS DV_AWARD_TOKEN CLAUDE_CONFIG_DIR
  export DV_CODEX_SESSIONS="$CASE_DIR/codex sessions" DV_CLAUDE_SESSIONS="$CASE_DIR/claude projects"
  export DV_POLISH=0 DV_POLISH_TIMEOUT=3 DV_POLISH_CMD="$ROOT/tests/fixtures/polish"
  export GH_STUB_DIR="$CASE_DIR/gh" PATH="$ROOT/tests/fixtures:$ROOT/bin:$PATH"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
  mkdir -p "$GH_STUB_DIR" "$DV_STATE" "$DV_WORK" "$DV_HOME"
  printf '[]\n' > "$GH_STUB_DIR/reviews"
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]\n' > "$GH_STUB_DIR/checks"
  printf '# Test brief\nImplement one file.\n' > "$CASE_DIR/brief"
  trap teardown EXIT
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
teardown() {
  # Failed question assertions must not leave the deliberately held fake agent.
  local pidfile rc=0
  for pidfile in "$CASE_DIR"/heavy/*.pid "$DV_STATE"/*/appserver/client.pid "$DV_STATE"/*/held.pid "$DV_STATE"/*/wrapper.pid "$CASE_DIR"/herdr/wait-*.pid "$DV_HOME/watch.pid"; do
    teardown_stop_pidfile "$pidfile" || rc=1
  done
  if command -v tmux >/dev/null; then tmux -L "$DV_TMUX_SOCKET" kill-server 2>/dev/null || true; fi
  # Shutdown handlers can still publish receipts/exited markers after TERM.
  # Preserve their directory if termination cannot be confirmed.
  if [ "$rc" != 0 ]; then printf 'Retained live fixture: %s\n' "$CASE_DIR" >&2; return 1; fi
  if [ "${DV_TEST_KEEP:-0}" = 1 ]; then printf 'Retained: %s\n' "$CASE_DIR"; else rm -rf "$CASE_DIR"; fi
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
      ! tmux -L "$DV_TMUX_SOCKET" has-session -t "=dv-$1" 2>/dev/null; then return; fi
    sleep 0.1
  done
  cat "$DV_STATE/$1/log" >&2
  return 1
}
needs_tmux() { command -v tmux >/dev/null || exit 77; }
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
  command tmux "$@"
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
  command tmux "$@" || return
  if [ "${1:-}" = -L ] && [ "${3:-}" = new-session ]; then
    local attempt
    # Delay only the launch reply until the synthetic wrapper has exited.
    for attempt in {1..100}; do
      if ! command tmux -L "$DV_TMUX_SOCKET" has-session -t =dv-TF-1 2>/dev/null; then return 0; fi
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
  printf 'Adds the thing.\n\nCloses #41\n' > "$DV_STATE/T-41/pr.md"
  DV_POLISH=0 dv pr T-41
  cmp "$DV_STATE/T-41/pr.md" "$GH_STUB_DIR/live-body"
  if grep -q -- "$DV_STATE" "$GH_STUB_DIR/live-body"; then return 1; fi
}
case_late_review_rule() {
  # A bot re-review after the single review-fix round must not park a green PR
  # waiting for an owner decision; both sides of the hand-off say so.
  grep -Fq '자동 재리뷰가 새 P0·P1을 달면 두 번째 수정을 하지 않고' "$ROOT/templates/rules.md"
  grep -Fq '이것은 차단 사유가 아닙니다' "$ROOT/templates/rules.md"
  grep -Fq '자동 재리뷰가 단 새 P0·P1' "$ROOT/templates/worker-prompt.md"
  grep -Fq '두 번째 수정 요청이나 재리뷰는 보내지 않습니다' "$ROOT/templates/worker-prompt.md"
  # Recovery goes back through the work session so dv done evidence exists.
  grep -Fq 'late-review.sent' "$ROOT/templates/worker-prompt.md"
  grep -F '자동 재리뷰가 단 새 P0·P1' "$ROOT/templates/worker-prompt.md" | grep -Fq 'dv done <ISSUE>'
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
  dv status TK-1 --json | jq -e '.[0] | .alive and .agent_status=="working"'
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
  git -C "$REPO" branch codex/t-9-change
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
  until_lines() { for _ in {1..100}; do [ "$(lines)" = "$1" ] && return 0; sleep 0.1; done; return 1; }
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
  mkdir "$DV_HOME/.kick-lock"
  event P-5 '' >> "$remote_q"
  if dv-kick-pull box 2>> "$CASE_DIR/pull.err"; then return 1; fi
  read -r offset _ < "$DV_HOME/pull-box.offset"; test "$offset" = 4
  rmdir "$DV_HOME/.kick-lock"
  dv-kick-pull box 2>> "$CASE_DIR/pull.err" & until_lines 5; stop_pull
  # A replaced queue (new inode) restarts from its first line.
  event P-6 '' > "$remote_q.new"; mv "$remote_q.new" "$remote_q"
  dv-kick-pull box 2>> "$CASE_DIR/pull.err" & until_lines 6; stop_pull
  jq -se '[.[].issue]==["P-1","P-2","P-3","P-4","P-5","P-6"]' "$DV_HOME/kick.q"
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
  dv pr-wait P-1
  jq -e '(.bot_review|not) and .review_handled and (.review_timed_out|not)' "$DV_STATE/P-1/pr-ready.json"
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
  mkdir -p "$CASE_DIR/herdr"
  touch "$CASE_DIR/herdr/question-mode"
  if [ "${QUESTION_LATE_DETECTION:-0}" = 1 ]; then touch "$CASE_DIR/herdr/late-detection"; fi
  dv start "$REPO" Q-1 questions --agent "${1:-codex}"
  wait_file "$DV_STATE/Q-1/held.pid"
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
  if ! jq -e '.[0] | .alive and .agent_status=="unknown" and .last_log=="plain text: ❯"' "$CASE_DIR/undetected-status.json"; then
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
  repo goal-retry; herdr_setup; export DV_START_WAIT=4
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
  for mode in never-ready never-accepted; do
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
  for tool in bash dirname git jq mkdir date tr basename cat env sleep mktemp mv rmdir sed tail wc grep rm touch awk ln; do
    ln -s "$(command -v "$tool")" "$CASE_DIR/path/$tool"
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

# shellcheck source=tests/codex-startup.sh
source "$ROOT/tests/codex-startup.sh"
# shellcheck source=tests/codex-trust.sh
source "$ROOT/tests/codex-trust.sh"

bidding_hosts() {
  needs_tmux; repo bidding
  export SSH_BIDDING=1 DV_MANAGER_HOST=test-host DV_HOSTS='lina-os go2-linux hx-linux'
  export DV_WORKER_CMD="$ROOT/tests/fixtures/worker" DV_WATCH_INTERVAL=0.1 DV_RECONCILE_INTERVAL=99999
  export DV_BID_TIMEOUT=2 DV_AWARD_TIMEOUT=3
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
  DV_MAX_JOBS='' dv bid --json --repo "$REPO" --agent codex | jq -e '.capacity==([1,(.cores/8|floor)]|max)'
}
case_submit_spread() {
  bidding_hosts
  # Scores on these real local fake hosts differ slightly; manager is always last.
  dv submit "$REPO" BID-1 one --brief "$CASE_DIR/brief"
  dv submit "$REPO" BID-2 two --brief "$CASE_DIR/brief"
  dv submit "$REPO" BID-3 three --brief "$CASE_DIR/brief"
  dv submit "$REPO" BID-4 four --brief "$CASE_DIR/brief"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_task BID-1 working; wait_task BID-2 working; wait_task BID-3 working
  test "$(jq -r .host "$DV_HOME/submissions/BID-3/task.json")" = lina-os
  jq -s -e '[.[].host]|unique|length==3' "$DV_HOME"/submissions/BID-{1,2,3}/task.json
  wait_file "$DV_HOME/submissions/BID-4/bids.json"
  wait_task BID-4 submitted
  # Repeated local ticks never rebid an all-full queue.
  sleep 0.5; cp "$CASE_DIR/ssh.calls" "$CASE_DIR/calls.before"
  sleep 0.5
  # Status and App Server scans may finish asynchronously during these ticks.
  # Only another bid would violate the all-full queue contract.
  grep ' dv bid ' "$CASE_DIR/calls.before" > "$CASE_DIR/bids.before"
  grep ' dv bid ' "$CASE_DIR/ssh.calls" > "$CASE_DIR/bids.after"
  cmp "$CASE_DIR/bids.before" "$CASE_DIR/bids.after"
  host=$(jq -r .host "$DV_HOME/submissions/BID-1/task.json")
  DV_CONFIG="$CASE_DIR/hosts/$host/config" dv 'done' BID-1
  wait_task BID-1 completed; wait_task BID-4 working
  test "$(jq -r .host "$DV_HOME/submissions/BID-4/task.json")" = "$host"
  touch "$DV_HOME/stop"; wait "$watcher"
  dv queue --json | jq -e 'length==4'
  if dv submit "$REPO" BID-1 one --brief "$CASE_DIR/brief"; then return 1; fi
}
case_submit_failover() {
  bidding_hosts
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
    jq -cn --arg issue "$1" --arg repo "$REPO" --argjson deadline "$(( $(date +%s) + 10 ))" \
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
  jq -cn --argjson deadline "$(( $(date +%s) + 10 ))" \
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
  if DV_MAX_JOBS=0 dv bid --json; then return 1; fi
  if DV_BID_TIMEOUT=garbage dv bid --json; then return 1; fi
  mkdir -p "$DV_STATE/UNCERTAIN"
  printf '{"status":"input-required"}\n' > "$DV_STATE/UNCERTAIN/meta"
  DV_MAX_JOBS=1 dv bid --json --repo "$REPO" | jq -e '.status=="rejected" and .active==1'
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
  accept_devin_trust() { :; }
  export DV_AGENT_CMD_codex='' DV_CODEX_BIN="$ROOT/tests/fixtures/goal-exit"
  export DV_CLAUDE_BIN="$ROOT/tests/fixtures/goal-exit" DV_DEVIN_BIN="$ROOT/tests/fixtures/goal-exit"
  for selected in codex claude devin custom; do
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
exec "$(dirname "$0")/dv-real" "$@"
STUB
  chmod +x "$CASE_DIR/tool/bin/dv"
  export DV_ROOT="$CASE_DIR/tool"
  award_request() {
    jq -cn --arg issue "$1" --arg repo "$REPO" --argjson deadline "$(( $(date +%s) + 10 ))" \
      '{issue:$issue,repo:$repo,slug:"timeout",agent:"codex",mode:"goal",base:"",brief:"fake",token:$issue,deadline:$deadline}'
  }
  touch "$CASE_DIR/delay-start"
  if award_request LOCK-1 | bid_limit 1 bid_rpc "$DV_HOST" _award > "$CASE_DIR/timeout.json"; then return 1; fi
  test -f "$CASE_DIR/start-entered"
  test -d "$DV_STATE/.admission-lock"
  cp "$DV_STATE/.awards/LOCK-1/receipt.json" "$CASE_DIR/uncertain-receipt"
  rm "$CASE_DIR/delay-start"
  award_request LOCK-2 | bid_limit 3 bid_rpc "$DV_HOST" _award > "$CASE_DIR/next.json"
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
# shellcheck source=tests/host.sh
source "$ROOT/tests/host.sh"
# shellcheck source=tests/delivery.sh
source "$ROOT/tests/delivery.sh"
# shellcheck source=tests/pr-body.sh
source "$ROOT/tests/pr-body.sh"
# shellcheck source=tests/claude.sh
source "$ROOT/tests/claude.sh"
# shellcheck source=tests/followups.sh
source "$ROOT/tests/followups.sh"
# shellcheck source=tests/watcher.sh
source "$ROOT/tests/watcher.sh"
# shellcheck source=tests/stall.sh
source "$ROOT/tests/stall.sh"
# shellcheck source=tests/screen-locale.sh
source "$ROOT/tests/screen-locale.sh"
# shellcheck source=tests/pr-wait-caller.sh
source "$ROOT/tests/pr-wait-caller.sh"
# shellcheck source=tests/bidding-edge.sh
source "$ROOT/tests/bidding-edge.sh"
# shellcheck source=tests/bidding-order.sh
source "$ROOT/tests/bidding-order.sh"
# shellcheck source=tests/manager.sh
source "$ROOT/tests/manager.sh"
# shellcheck source=tests/revive.sh
source "$ROOT/tests/revive.sh"
# shellcheck source=tests/appserver.sh
source "$ROOT/tests/appserver.sh"
# shellcheck source=tests/codex-exec.sh
source "$ROOT/tests/codex-exec.sh"
# shellcheck source=tests/codex-exec-review.sh
source "$ROOT/tests/codex-exec-review.sh"
# shellcheck source=tests/portability.sh
source "$ROOT/tests/portability.sh"
# shellcheck source=tests/qa.sh
source "$ROOT/tests/qa.sh"
# shellcheck source=tests/metrics.sh
source "$ROOT/tests/metrics.sh"
# shellcheck source=tests/pr-worker.sh
source "$ROOT/tests/pr-worker.sh"
# shellcheck source=tests/self-update.sh
source "$ROOT/tests/self-update.sh"
# shellcheck source=tests/disk.sh
source "$ROOT/tests/disk.sh"
# shellcheck source=tests/stack.sh
source "$ROOT/tests/stack.sh"
# shellcheck source=tests/watcher-stuck.sh
source "$ROOT/tests/watcher-stuck.sh"
# shellcheck source=tests/task.sh
source "$ROOT/tests/task.sh"
# shellcheck source=tests/capacity.sh
source "$ROOT/tests/capacity.sh"
# shellcheck source=tests/heavy.sh
source "$ROOT/tests/heavy.sh"
main() {
if [ "${1:-}" = --case ]; then setup; "case_$2"; exit; fi
pass=0; skip=0; fail=0
for name in appserver_close_unset appserver_daemon_restart appserver_watch_dead_client appserver_daemon_lost_turn appserver_reconnect_stall_clock appserver_disconnect_unknown; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
done
for name in heavy_serial heavy_kill heavy_slots heavy_status heavy_command heavy_priority heavy_config heavy_waiter_probe; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
done
for name in capacity_classifier capacity_backoff capacity_exec_once capacity_exec_timeout capacity_appserver_once capacity_appserver_timeout capacity_appserver_rpc capacity_appserver_unknown capacity_qa_once capacity_qa_native capacity_qa_timeout capacity_claude capacity_devin capacity_terminal_exit capacity_terminal_timeout capacity_legacy_terminal; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else
    result=$?
    if [ "$result" = 77 ]; then skip=$((skip + 1)); printf 'SKIP %s (tmux unavailable)\n' "$name"
    else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
  fi
done
for name in land_merged land_merged_recorded_pr land_merged_recorded_done land_merged_mismatch land_merged_base_mismatch land_merged_cleanup_retry land_merged_dirty land_merged_checks land_worker_rule appserver_land_merged_active appserver_land_merged_timeout appserver_land_merged_failed appserver_land_merged_system_error; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
done
for name in screen_locale_c screen_locale_utf8; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
done
for name in appserver_sender_idle appserver_sender_partial appserver_sender_legacy_idle appserver_sender_legacy_partial symlink_task_land symlink_exec_send clean_resume_task_exec clean_resume_code_exec clean_resume_task_tmux clean_resume_code_tmux clean_resume_appserver clean_resume_appserver_unknown stall_working_banner_detection stall_working_banner_resume stall_latest_activity stall_dead stall_capacity stall_resume stall_resume_reset stall_resume_guards stall_resume_transport stall_banner_sequence stall_watch_resume stall_watch_revive stall_remote_resume stall_dead_old_banner stall_recovery_host stall_watch stall_status stall_episodes stall_inactive stall_observation stall_remote stall_tmux stall_failed_race failed_stall_race; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else
    result=$?
    if [ "$result" = 77 ]; then skip=$((skip + 1)); printf 'SKIP %s (tmux unavailable)\n' "$name"
    else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
  fi
done
for name in task_tmux_fast_completion code_tmux_fast_completion code_tmux_fast_revival task_tmux_stale_completion code_tmux_stale_completion task_tmux_socket_failed code_tmux_socket_failed task_tmux_session_missing code_tmux_session_missing task_tmux_new_session_failed code_tmux_new_session_failed task_snapshot task_snapshot_done_race task_snapshot_land_race task_appserver task_appserver_guards task_appserver_fallback task_codex_goal task_shellcheck task_tmux_live task_herdr_live task_tmux_failed task_herdr_failed task_tmux_changed task_herdr_changed task_recursive_destination task_start_done task_land task_guards task_revive task_claude task_invalid task_native task_exec_launch_race task_exec_stall task_capacity task_missing_output task_watcher task_land_workspace; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else
    result=$?
    if [ "$result" = 77 ]; then skip=$((skip + 1)); printf 'SKIP %s (tmux unavailable)\n' "$name"
    else fail=$((fail + 1)); printf 'FAIL %s (exit %s)\n' "$name" "$result"; fi
  fi
done
for name in update_stall_cadence update_cli update_dirty update_landed update_safety update_guard update_offline update_watch_dirty update_host update_managed update_parallel update_timeout update_unrelated update_receipt; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
done
for name in disk_bid disk_probe disk_trim disk_pressure disk_recovered disk_cache_guard disk_cache_alias_guard disk_cache_canonical disk_cache_newline disk_env_cache_newline disk_home_newline disk_custom_cache disk_go_env_cache disk_separate_filesystems disk_unknown disk_award disk_bsd_stat disk_worktrees disk_host disk_watch disk_start_interval disk_watch_due teardown_wait_client teardown_preserve_live_client; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
done
for name in stack_unfinished_auto_land stack_auto_done_guard stack_auto_done_merge stack_resume_done_episode stack_waiting_without_head stack_waiting_clock stack_safety_local stack_resume_headless stack_stalled stack_resume_guards stack_resume_failed stack_resume_interrupted stack_land_requeue stack_land_retry stack_remote_safety stack_wait stack_chain stack_diamond stack_parallel stack_local_body stack_closed_base stack_api_failure stack_dirty stack_remote stack_reconcile stack_queue_concurrent stack_checks stack_push_retry stack_defer stack_dependencies_present stack_dependencies_present_conflict stack_missing_base stack_squash_base stack_rebase_base; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
done
for name in appserver_reexec_accepted appserver_reexec_refused appserver_reexec_unknown appserver_legacy_capacity appserver_legacy_budget appserver_legacy_episode appserver_legacy_idle appserver_legacy_done appserver_legacy_inactive appserver_legacy_question appserver_scratch_root appserver_scratch_tmpdir appserver_scratch_long appserver_stale_done_recover appserver_pr_idle_recover appserver_recovery_uncertain appserver_recovery_events appserver_recovery_early_progress appserver_capacity_notification appserver_idle_done appserver_goal_done appserver_idle_blocked appserver_episode appserver_budget appserver_budget_restart appserver_capacity appserver_rate_limit appserver_recovery_guards appserver_start appserver_accepted appserver_refused appserver_unknown appserver_idle_send appserver_states appserver_large_reply appserver_read_partial appserver_status_landed_cheap appserver_failed appserver_retried_error appserver_stall appserver_question appserver_auto appserver_no_goal appserver_clean_guard appserver_reconnect appserver_active_stall appserver_unknown_restart appserver_question_multiple appserver_question_retry appserver_malformed appserver_watch appserver_fallback appserver_exec_override appserver_goal_override appserver_submit_auto appserver_exec appserver_pipeline appserver_pr_pending appserver_preserve_config appserver_detached appserver_detached_fallback appserver_websocket appserver_active_error_send appserver_interrupt_pending appserver_interrupt_timeout appserver_done_refused appserver_done_unknown appserver_land_active; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else
    result=$?
    if [ "$result" = 77 ]; then skip=$((skip + 1)); printf 'SKIP %s (tmux unavailable)\n' "$name"
    else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
  fi
done
for name in qa_pr_lookup_retry qa_base_lookup_retry qa_pr_lookup_blocked qa_base_lookup_blocked qa_milestone_graphql qa_no_milestone qa_no_milestone_match qa_milestone_blocked qa_milestone_ambiguous qa_landed qa_coalesce qa_optout qa_duplicate qa_new_finding qa_batch qa_restart qa_fresh_codex qa_fresh_claude qa_merged_base qa_repository_ids qa_transport_retry qa_recovered_capacity qa_explicit_match qa_config_data qa_unbound_event qa_bound_event; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf "PASS %s\n" "$name"
  else fail=$((fail + 1)); printf "FAIL %s\n" "$name"; fi
done
for name in metrics_cli metrics_activity metrics_lifecycle metrics_handled metrics_manager metrics_idle metrics_external_merge metrics_agent_counts metrics_remote metrics_timestamp metrics_missing_worktree metrics_queue_activity metrics_terminal metrics_pull_time metrics_queue_corruption metrics_concurrent metrics_nonblocking metrics_collector_restart metrics_exec metrics_exec_events metrics_manager_batch metrics_manager_fallback metrics_timeout_snapshot metrics_stall_overlap; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
done
for name in pr_worker_stale_recovery pr_worker_foreground pr_worker_large_comments pr_worker_done_gate pr_worker_red pr_worker_loop pr_worker_cap pr_worker_stale pr_worker_live_checks pr_worker_comments_failure pr_worker_handoff pr_worker_revive pr_worker_no_rereview pr_worker_revive_exec pr_worker_exit_race pr_worker_exec_missing_pr pr_worker_native_exec; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
done
for name in exec_cleanup_success exec_cleanup_failure exec_cleanup_signal exec_exhausted_rebids exec_land_running exec_land_github_running exec_land_failed; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
done
for name in exec_success exec_config_flags exec_launch_race exec_nonzero exec_capacity exec_rate exec_silence exec_unfinished exec_retry exec_send exec_working exec_fresh exec_partial exec_followup_unfinished exec_no_terminal; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf "PASS %s\n" "$name"
  else fail=$((fail + 1)); printf "FAIL %s\n" "$name"; fi
done
for name in symlink_paths symlink_claude_stale_server symlink_claude_stale_server_empty symlink_revive_dead symlink_revive_tmux revive_wait_exit claude_bsd_stat_mode host_darwin_shells revive_done_capacity revive_orphan_owner revive_orphan_close_failure revive_stale_marker revive_goal_owned_done revive_report_event revive_orphan_workspace revive_manual_done revive_capacity revive_release_event revive_legacy_idle revive_legacy_unknown revive_capacity_status revive_legacy_busy revive_legacy_uncertain revive_dead revive_live revive_failure revive_goal_failure revive_transport revive_tmux revive_missing_pane revive_missing_pane_live revive_missing_pane_unknown revive_legacy_exit revive_start_failure revive_undetected revive_branch_guard revive_goal_no_done revive_override revive_tmux_retained revive_tmux_live revive_codex_goal; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else
    result=$?
    if [ "$result" = 77 ]; then skip=$((skip + 1)); printf 'SKIP %s (tmux unavailable)\n' "$name"
    else fail=$((fail + 1)); printf 'FAIL %s (exit %s)\n' "$name" "$result"; fi
  fi
done
for name in manager_reexec manager_real_conflict manager_real_pending_conflict manager_conflict_restart manager_reserved_collision manager_note_busy watch_stuck_route watch_stuck_bid watch_stuck_stack watch_stuck_empty watch_stuck_worker manager_collision manager_fallback_collision manager_hash_collision manager_legacy_replay manager_note manager_pool_independent watch_capacity_eight watch_stuck; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf "PASS %s\n" "$name"
  else fail=$((fail + 1)); printf "FAIL %s\n" "$name"; fi
done
for name in manager_batch manager_batch_order manager_latency manager_busy manager_notice manager_busy_default manager_capacity_restart manager_fallback_restart manager_fallback_serial manager_start manager_identity manager_serial manager_parallel manager_fallback manager_no_id manager_unmanaged manager_local manager_stop_pending manager_concurrent_start manager_failed_event manager_restart_queue manager_unmanaged_override manager_unknown_repo manager_reused_issue manager_moved_checkout manager_runner_ownership; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
done
for name in pr_wait_caller_killed pr_wait_caller_fallback pr_wait_caller_delayed pr_late_checks pr_wait_stale pr_wait_killed pr_wait_live pr_wait_detached pr_wait_fallback pr_wait_concurrent pr_wait_head pr_wait_failed_checks watch_retry watch_retry_restart watch_inflight_replay watch_killed reconcile_delivery reconcile_corrected_head status_done_head reconcile_waiter reconcile_waiter_remote; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
done
for name in codex_allowlist codex_persisted_trust codex_trust_conflict codex_trust_duplicate codex_trust_parallel codex_provider_missing codex_provider_env codex_folder_trust codex_folder_after_prompt codex_trust_formats codex_trust_refuse codex_trust_linked codex_trust_clone_bid; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
done
for name in question_async_ack question_overlap question_claude_overlap question_delivery_retry polish_public_delayed polish_public_during_run polish_public_published question_async question_answered question_during_grace question_claude_answered question_delivery_failure question_stderr question_tmux_off codex_trust_alias claude_trust_alias host_descendant_timeout host_npm_failure host_npm_failure_symlink host_checksum host_path_newline host_auth_override host_npm_origin pr_body_update reconcile_alias award_retry_rejection award_stale_failure award_early_absent bid_clean_capacity submit_local_origin; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else
    result=$?
    if [ "$result" = 77 ]; then skip=$((skip + 1)); printf 'SKIP %s (tmux unavailable)\n' "$name"
    else fail=$((fail + 1)); printf 'FAIL %s (exit %s)\n' "$name" "$result"; fi
  fi
done
for name in claude_stale_server claude_stale_server_empty claude_profile_onboarding claude_profile_trust claude_profile_create claude_profile_invalid claude_trust_mode claude_trust_acl claude_trust_copy_failure claude_profile_start claude_profile_host bid_order_ties bid_order_fallback bid_order_probes bid_order_reject_input bid_order_early_reject bid_order_early_errors claude_trust_create claude_trust_preserve claude_trust_parallel claude_trust_invalid claude_trust_atomic claude_onboarding claude_start claude_start_tmux claude_start_failed claude_host host_repair host_path_preserve host_real_shells host_check host_codex host_sync host_sync_failure host_path_guard bid_readonly submit_spread submit_failover submit_cancel submit_order submit_order_amd submit_order_amd_go2 submit_timeout submit_forward award_capacity admission_owner submit_scores bid_clone bid_rejections bid_rpc_timeout award_rejected_next award_new_round award_uncertain_round goal_exit_rebids goal_exit_agents award_timeout_lock bid_readonly_no_tmux bid_rejections_no_tmux; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else
    result=$?
    if [ "$result" = 77 ]; then skip=$((skip + 1)); printf 'SKIP %s (tmux unavailable)\n' "$name"
    else fail=$((fail + 1)); printf 'FAIL %s (exit %s)\n' "$name" "$result"; fi
  fi
done
for name in stack_conflict question_codex_record question_record_limit question_record_fallback question_claude_record herdr_cleanup_owner question_pull_replay question_startup question_signal question_claude question_devin question_cli question_cli_off question_episodes question_grace question_exit question_wait_failure polish_success polish_code_missing polish_tilde_missing polish_indented_missing polish_quoted_code polish_inline_missing polish_url_missing polish_empty polish_failure polish_timeout polish_disabled polish_edit_failure polish_remote_edit polish_read_failure polish_pr_url polish_default polish_parallel start_done kick_failure local_land pr_land pr_public_body late_review_rule blocked_event_ids clean parallel install install_linux_watch review watch reconcile reconcile_slow_host reconcile_local kick_local_host kick_pull watch_pull worker_prompt_host agent_cli agent_cli_off pr_ready base_merge watch_capacity land_checkout_race herdr_start_clean herdr_send_retry herdr_undetected herdr_goal_retry herdr_goal_timeout herdr_agents_land herdr_disabled_legacy herdr_missing herdr_home_no_tmux herdr_failure herdr_clean_safety codex_hook_trust codex_hook_actions codex_hook_modal codex_hook_after_prompt codex_goal_stalled codex_goal_enter codex_goal_enter_stalled codex_goal_screen_working codex_goal_history codex_repo_trust codex_tmux_startup codex_hook_recovered codex_start_recovered codex_done_delivery_status; do
  if bash "$0" --case "$name"; then
    pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else
    result=$?
    if [ "$result" = 77 ]; then skip=$((skip + 1)); printf 'SKIP %s (tmux unavailable)\n' "$name"
    else fail=$((fail + 1)); printf 'FAIL %s (exit %s)\n' "$name" "$result"; fi
  fi
done
for name in land_squash_only land_merge_only land_rebase_only land_prefer_squash land_prefer_merge land_override_env land_override_repo land_config_stdout land_policy_gh_repo land_policy_pr_url land_override_precedence land_no_methods land_invalid_method land_disallowed_method land_repo_failure land_config_failure land_head_mismatch land_unconfirmed; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
done
for name in pr_fallback_body pr_fallback_summary pr_fallback_private_paths pr_fallback_private_hosts pr_fallback_public_tokens pr_fallback_missing pr_fallback_bounded pr_fallback_private_only pr_head_title pr_prepared_body pr_legacy_body pr_patch_title pr_patch_body polish_unreachable polish_unreachable_timeout; do
  if bash "$0" --case "$name"; then pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$name"; fi
done
printf 'pass=%s skip=%s fail=%s\n' "$pass" "$skip" "$fail"
[ "$fail" -eq 0 ]
}
main "$@"
