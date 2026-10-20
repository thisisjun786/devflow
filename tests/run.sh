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
  export DV_HERDR=0
  unset DV_AGENT_QUESTIONS
  export DV_POLISH=0 DV_POLISH_TIMEOUT=3 DV_POLISH_CMD="$ROOT/tests/fixtures/polish"
  export GH_STUB_DIR="$CASE_DIR/gh" PATH="$ROOT/tests/fixtures:$ROOT/bin:$PATH"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
  mkdir -p "$GH_STUB_DIR" "$DV_STATE" "$DV_WORK" "$DV_HOME"
  printf '[]\n' > "$GH_STUB_DIR/reviews"
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]\n' > "$GH_STUB_DIR/checks"
  printf '# Test brief\nImplement one file.\n' > "$CASE_DIR/brief"
  trap teardown EXIT
}
teardown() {
  # Failed question assertions must not leave the deliberately held fake agent.
  local pidfile
  for pidfile in "$DV_STATE"/*/held.pid "$DV_STATE"/*/wrapper.pid "$CASE_DIR"/herdr/wait-*.pid; do
    [ ! -f "$pidfile" ] || kill "$(cat "$pidfile")" 2>/dev/null || true
  done
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
  DV_HOME="$CASE_DIR/rq" DV_QUESTION_EPISODE='w1:p1:123:1' dv-kick question Q-1 first box same-head
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
    '($source|map(.id)) as $ids | map(.id)==($ids+$ids) and (map(.id)|unique|length)==2' "$DV_HOME/kick.q"
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
  for _ in {1..100}; do
    if [ -s "$DV_STATE/$1/pr-ready.json" ] && [ ! -d "$DV_STATE/$1/.pr-wait" ]; then return; fi
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
  local issue=$1 agent=$2
  if [ "$agent" = codex ]; then
    jq -e --arg mode "${DV_AGENT_QUESTIONS:-sion}" '
      index("tools.experimental_request_user_input.enabled=false") as $i |
      if $mode=="off" then $i!=null and .[$i-1]=="-c" else $i==null end
    ' "$DV_STATE/$issue/args.json"
  else
    jq -e --arg mode "${DV_AGENT_QUESTIONS:-sion}" '
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

herdr_setup() {
  export DV_HERDR=1 DV_AGENT_CMD_codex='' DV_CODEX_BIN="$ROOT/tests/fixtures/herdr-agent"
  export DV_CLAUDE_BIN="$ROOT/tests/fixtures/herdr-agent" DV_DEVIN_BIN="$ROOT/tests/fixtures/herdr-agent"
}
wait_native() {
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
  question_state blocked
  question_finish
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
  export DV_HERDR=1 DV_AGENT_CMD_codex='printf "plain text: ❯"'
  dv start "$REPO" HU-1 native --mode goal
  wait_file "$CASE_DIR/herdr/w-HU-1/exit"
  test "$(cat "$CASE_DIR/herdr/w-HU-1/exit")" = 0
  dv status HU-1 --json > "$CASE_DIR/undetected-status.json"
  if ! jq -e '.[0] | .alive and .agent_status=="unknown" and .last_log=="plain text: ❯"' "$CASE_DIR/undetected-status.json"; then
    cat "$CASE_DIR/undetected-status.json" "$CASE_DIR/herdr/w-HU-1/output"
    return 1
  fi
  if dv send HU-1 hello > "$CASE_DIR/send.out" 2> "$CASE_DIR/send.err"; then return 1; fi
  grep -F agent_not_found "$CASE_DIR/send.err"
  test ! -s "$CASE_DIR/send.out"
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
  jq -e 'index("exec")!=null and index("hooks")==null' "$DV_STATE/H-5/args.json"
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
  for tool in bash dirname git jq mkdir date tr basename cat env sleep mktemp mv rmdir sed tail wc grep rm touch awk; do
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
  grep -F 'api --method PATCH repos/test/repo/pulls/1 -F body=@' "$GH_STUB_DIR/calls"
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
  if grep -F 'api --method PATCH ' "$GH_STUB_DIR/calls"; then return 1; fi
  grep -F 'live PR body changed; edit skipped' "$DV_STATE/POL-1/polish.log"
}
case_polish_read_failure() {
  polish_setup
  touch "$GH_STUB_DIR/read-fail"
  dv polish POL-1
  cmp "$CASE_DIR/original" "$DV_STATE/POL-1/pr-body.md"
  cmp "$CASE_DIR/original" "$GH_STUB_DIR/live-body"
  test ! -f "$GH_STUB_DIR/edited-body"
  if grep -F 'api --method PATCH ' "$GH_STUB_DIR/calls"; then return 1; fi
  grep -F 'gh api read failed; edit skipped' "$DV_STATE/POL-1/polish.log"
}
case_polish_pr_url() {
  polish_setup
  printf '{"url":"https://github.com/another-owner/another.repo/pull/37"}\n' > "$DV_STATE/POL-1/pr.json"
  export GH_STUB_PR_ENDPOINT=repos/another-owner/another.repo/pulls/37
  dv polish POL-1
  test -f "$GH_STUB_DIR/edited-body"
  grep -Fx 'api repos/another-owner/another.repo/pulls/37' "$GH_STUB_DIR/calls"
  grep -F 'api --method PATCH repos/another-owner/another.repo/pulls/37 -F body=@' "$GH_STUB_DIR/calls"
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
if [ "${1:-}" = --case ]; then setup; "case_$2"; exit; fi
pass=0; skip=0; fail=0
for name in herdr_cleanup_owner question_pull_replay question_startup question_signal question_claude question_devin question_cli question_cli_off question_episodes question_grace question_exit question_wait_failure polish_success polish_code_missing polish_tilde_missing polish_indented_missing polish_quoted_code polish_inline_missing polish_url_missing polish_empty polish_failure polish_timeout polish_disabled polish_edit_failure polish_remote_edit polish_read_failure polish_pr_url polish_default polish_parallel start_done kick_failure local_land pr_land clean parallel install install_linux_watch review watch reconcile reconcile_local kick_local_host kick_pull watch_pull worker_prompt_host agent_cli agent_cli_off pr_ready base_merge watch_capacity land_checkout_race herdr_start_clean herdr_send_retry herdr_undetected herdr_goal_retry herdr_goal_timeout herdr_agents_land herdr_disabled_legacy herdr_missing herdr_home_no_tmux herdr_failure herdr_clean_safety codex_hook_trust codex_hook_actions codex_hook_modal codex_hook_after_prompt codex_goal_stalled codex_goal_enter codex_goal_enter_stalled codex_goal_screen_working codex_goal_history codex_repo_trust codex_tmux_startup codex_hook_recovered codex_start_recovered codex_done_delivery_status; do
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
