#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export ROOT

setup() {
  CASE_DIR=$(mktemp -d "${DV_TEST_TMP:-${TMPDIR:-/tmp}}/dv-test.XXXXXX")
  export CASE_DIR
  export DV_CONFIG="$CASE_DIR/config.sh" DV_STATE="$CASE_DIR/state" DV_WORK="$CASE_DIR/work" DV_HOME="$CASE_DIR/home"
  export DV_KICK="$ROOT/bin/dv-kick" DV_AGENT_CMD_codex="$ROOT/tests/fixtures/agent"
  export DV_TMUX_SOCKET="dv-test-$$" DV_REVIEW_WAIT=0 DV_POLL_INTERVAL=1 DV_START_WAIT=5
  export DV_CODEX_BIN="$ROOT/tests/fixtures/codex" DV_HOST=test-host
  export GH_STUB_DIR="$CASE_DIR/gh" PATH="$ROOT/tests/fixtures:$ROOT/bin:$PATH"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
  mkdir -p "$GH_STUB_DIR" "$DV_STATE" "$DV_WORK" "$DV_HOME"
  printf '[]\n' > "$GH_STUB_DIR/reviews"
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]\n' > "$GH_STUB_DIR/checks"
  printf '# Test brief\nImplement one file.\n' > "$CASE_DIR/brief"
  trap teardown EXIT
}
teardown() {
  if command -v tmux >/dev/null; then tmux -L "$DV_TMUX_SOCKET" kill-server 2>/dev/null || true; fi
  if [ -f "$DV_HOME/watch.pid" ]; then kill "$(cat "$DV_HOME/watch.pid")" 2>/dev/null || true; fi
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
case_start_done() {
  needs_tmux; repo remote remote; start T-1; wait_done T-1
  jq -e '.status=="done" and .agent=="codex" and .host=="test-host"' "$DV_STATE/T-1/meta"
  jq -e '.files==1 and (.head|length)==40 and (.report|endswith("report.md"))' "$DV_STATE/T-1/done.json"
  jq -e '.kind=="done" and .issue=="T-1"' "$DV_HOME/kick.q"
  test -s "$DV_STATE/T-1/brief.md"
  dv status --json | jq -e 'length==1 and .[0].issue=="T-1"'
  dv status T-1 | grep 'done'
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
case_parallel() {
  needs_tmux; repo parallel
  start T-6 & p1=$!
  start T-7 & p2=$!
  wait "$p1"; wait "$p2"; wait_done T-6; wait_done T-7
  wt1=$(jq -r .worktree "$DV_STATE/T-6/meta")
  wt2=$(jq -r .worktree "$DV_STATE/T-7/meta")
  test -f "$wt1/T-6.txt"; test ! -f "$wt1/T-7.txt"
  test -f "$wt2/T-7.txt"; test ! -f "$wt2/T-6.txt"
  test "$(jq -r .branch "$DV_STATE/T-6/meta")" != "$(jq -r .branch "$DV_STATE/T-7/meta")"
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

wait_file() {
  local path=$1
  for _ in {1..100}; do [ ! -f "$path" ] || return 0; sleep 0.1; done
  printf 'Timed out waiting for %s\n' "$path" >&2
  return 1
}
wait_pr_ready() {
  for _ in {1..100}; do
    if [ -s "$DV_STATE/$1/pr-ready.json" ] && [ ! -d "$DV_STATE/$1/.pr-wait" ]; then return; fi
    sleep 0.1
  done
  printf 'Timed out waiting for PR waiter to finish: %s\n' "$1" >&2
  return 1
}
case_agent_cli() {
  needs_tmux; repo cli
  export DV_AGENT_CMD_codex='' DV_CODEX_BIN="$ROOT/tests/fixtures/interactive"
  export DV_CLAUDE_BIN="$ROOT/tests/fixtures/interactive" DV_DEVIN_BIN="$ROOT/tests/fixtures/interactive"
  dv start "$REPO" C-1 goal --brief "$CASE_DIR/brief"
  wait_file "$DV_STATE/C-1/events.log"
  grep '^/goal .*brief.md' "$DV_STATE/C-1/goal-input"
  jq -e 'index("gpt-6-astra")!=null and index("hooks")!=null and index("plugins.\"crw@crw\".enabled=false")!=null and any(.[]; contains("trust_level=\"trusted\""))' "$DV_STATE/C-1/args.json"
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
  dv start "$REPO" C-3 claude --agent claude
  wait_file "$DV_STATE/C-3/events.log"
  jq -e 'index("opus")!=null and index("xhigh")!=null and index("--dangerously-skip-permissions")!=null' "$DV_STATE/C-3/args.json"
  dv start "$REPO" C-4 devin --agent devin
  wait_file "$DV_STATE/C-4/events.log"
  test -f "$DV_STATE/C-4/trust-enter"
  jq -e 'index("fusion-gpt-6-astra-xhigh-sidekick-swe-2-high")!=null and index("dangerous")!=null and index("--")!=null' "$DV_STATE/C-4/args.json"
}
case_pr_ready() {
  needs_tmux; repo ready remote; start P-1; wait_done P-1
  head=$(git -C "$(jq -r .worktree "$DV_STATE/P-1/meta")" rev-parse HEAD)
  jq -n --arg head "$head" '[{author:{login:"devin-ai-integration[bot]"},commit:{oid:$head}},{author:{login:"chatgpt-codex-connector[bot]"},commit:{oid:$head}}]' > "$GH_STUB_DIR/reviews"
  dv pr P-1
  wait_pr_ready P-1
  jq -e '.green and .bot_review and (.review_timed_out|not)' "$DV_STATE/P-1/pr-ready.json"
  for _ in {1..100}; do
    jq -se 'any(.[]; .kind=="pr-ready")' "$DV_HOME/kick.q" >/dev/null && break
    sleep 0.1
  done
  jq -se 'any(.[]; .kind=="pr-ready")' "$DV_HOME/kick.q"
  dv 'done' P-1
  jq -e '.status=="ready"' "$DV_STATE/P-1/meta"
  test "$(grep -c 'pr create' "$GH_STUB_DIR/calls")" = 1
  jq '.[0:1]' "$GH_STUB_DIR/reviews" > "$GH_STUB_DIR/reviews.one"
  mv "$GH_STUB_DIR/reviews.one" "$GH_STUB_DIR/reviews"
  dv pr-wait P-1
  jq -e '(.bot_review|not) and .review_timed_out' "$DV_STATE/P-1/pr-ready.json"
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
  test "$(cat "$DV_HOME/cursor")" = 4
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

if [ "${1:-}" = --case ]; then setup; "case_$2"; exit; fi
pass=0; skip=0; fail=0
for name in start_done kick_failure local_land pr_land clean parallel install review watch reconcile agent_cli pr_ready base_merge watch_capacity land_checkout_race; do
  if bash "$0" --case "$name"; then
    pass=$((pass + 1)); printf 'PASS %s\n' "$name"
  else
    result=$?
    if [ "$result" = 77 ]; then skip=$((skip + 1)); printf 'SKIP %s (tmux unavailable)\n' "$name"
    else fail=$((fail + 1)); printf 'FAIL %s (exit %s)\n' "$name" "$result"; fi
  fi
done
printf 'pass=%s skip=%s fail=%s\n' "$pass" "$skip" "$fail"
[ "$fail" -eq 0 ]
