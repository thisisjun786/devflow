#!/usr/bin/env bash
# Real disposable Git branches; only the GitHub API and agent transport are fake.
stack_fixture() {
  repo stack remote
  export REPO
  git -C "$REPO" checkout -qb dev
  git -C "$REPO" push -qu origin dev
  mkdir "$CASE_DIR/stack-bin"
  ln -s "$ROOT/tests/fixtures/stack-gh" "$CASE_DIR/stack-bin/gh"
  export PATH="$CASE_DIR/stack-bin:$PATH"
  export DV_HOSTS='' DV_PULL_HOSTS='' DV_RECONCILE_INTERVAL=9999999999
  watch_fixture
}
stack_pr() {
  local number=$1 from=$2 body=${3:-} wt="$DV_WORK/stack-$1" head
  git -C "$REPO" worktree add -qb "stack-$number" "$wt" "$from"
  printf '%s\n' "$number" > "$wt/file-$number"
  git -C "$wt" add .; git -C "$wt" commit -qm "stack $number"
  git -C "$wt" push -qu origin "stack-$number"
  head=$(git -C "$wt" rev-parse HEAD)
  mkdir "$DV_STATE/S-$number"
  jq -n --arg issue "S-$number" --arg repo "$REPO" --arg wt "$wt" --arg branch "stack-$number" --arg head "$head" \
    '{issue:$issue,repo:$repo,worktree:$wt,branch:$branch,base:"dev",status:"ready",host:"test-host",agent:"codex",started:1,head:$head,start_head:$head}' > "$DV_STATE/S-$number/meta"
  printf '{"url":"https://github.com/test/repo/pull/%s"}\n' "$number" > "$DV_STATE/S-$number/pr.json"
  jq -n --arg body "$body" --arg head "$head" --slurpfile checks "$GH_STUB_DIR/checks" \
    '{body:$body,state:"OPEN",baseRefName:"dev",checked_head:$head,statusCheckRollup:$checks[0]}' > "$GH_STUB_DIR/pr-$number.json"
}
stack_waiting() {
  if dv land "S-$1" > "$CASE_DIR/land-$1.log" 2>&1; then
    printf 'BUG: stacked PR #%s landed before its base\n' "$1"; return 1
  fi
  cat "$CASE_DIR/land-$1.log"
  jq -e '.status=="waiting-base"' "$DV_STATE/S-$1/meta"
  test -d "$DV_WORK/stack-$1"
}
case_stack_wait() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  stack_waiting 2
  test ! -f "$GH_STUB_DIR/order"
}
stack_green() {
  local file="$GH_STUB_DIR/pr-$1.json" head
  head=$(git --git-dir="$CASE_DIR/remote.git" rev-parse "stack-$1")
  jq --arg head "$head" '.checked_head=$head' "$file" > "$file.tmp"; mv "$file.tmp" "$file"
}
stack_await() {
  local issue=$1 expression=$2 n
  for n in {1..200}; do
    jq -e "$expression" "$DV_STATE/S-$issue/meta" >/dev/null && return 0
    sleep 0.1
  done
  cat "$DV_HOME/stack.log" "$DV_HOME/watch.log" "$CASE_DIR/watch.log" "$DV_HOME"/workers/*.log >&2 2>/dev/null || true
  return 1
}
stack_watch() { dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!; }
stack_stop() { touch "$DV_HOME/stop"; wait "$watcher"; watcher=''; rm "$DV_HOME/stop"; }
case_stack_chain() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'; stack_pr 3 stack-2 'Depends on #2'
  stack_waiting 2; stack_waiting 3
  dv land S-1
  stack_watch
  stack_await 2 '.stack_update_head!=null'
  test "$(cat "$GH_STUB_DIR/order")" = 1
  # Old successful checks cannot merge the freshly updated branch.
  sleep 1.2
  test "$(cat "$GH_STUB_DIR/order")" = 1
  git -C "$DV_WORK/stack-2" merge-base --is-ancestor origin/dev HEAD
  stack_green 2
  stack_await 2 '.status=="landed"'
  stack_await 3 '.stack_update_head!=null'
  stack_green 3
  stack_await 3 '.status=="landed"'
  stack_stop
  test "$(tr '\n' ' ' < "$GH_STUB_DIR/order")" = '1 2 3 '
  git --git-dir="$CASE_DIR/remote.git" show-ref --verify refs/heads/stack-2
  test ! -d "$DV_WORK/stack-2"
}
case_stack_diamond() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 dev; stack_pr 3 stack-1 $'Depends on #1\nDepends on #2'
  stack_waiting 3
  dv land S-1; stack_watch
  sleep 1.5
  test "$(cat "$GH_STUB_DIR/order")" = 1
  test "$(jq -r .stack_update_head "$DV_STATE/S-3/meta")" = null
  dv land S-2
  stack_await 3 '.stack_update_head!=null'
  stack_green 3; stack_await 3 '.status=="landed"'; stack_stop
  test "$(tr '\n' ' ' < "$GH_STUB_DIR/order")" = '1 2 3 '
  git -C "$REPO" cat-file -e origin/dev:file-1
  git -C "$REPO" cat-file -e origin/dev:file-2
  git -C "$REPO" cat-file -e origin/dev:file-3
}
case_stack_parallel() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'; stack_pr 3 stack-1 'Depends on #1'
  stack_waiting 2; stack_waiting 3; dv land S-1
  export DV_MAX_WORKERS=2
  stack_watch
  stack_await 2 '.stack_update_head!=null'; stack_await 3 '.stack_update_head!=null'
  # The second stack must finish while the first stack's CI is still pending.
  stack_green 3; stack_await 3 '.status=="landed"'
  test "$(tr '\n' ' ' < "$GH_STUB_DIR/order")" = '1 3 '
  stack_stop
  # Durable retries survive a watcher restart, including a newly advanced base.
  stack_watch
  for _ in {1..200}; do
    if git -C "$DV_WORK/stack-2" merge-base --is-ancestor origin/dev HEAD; then break; fi
    sleep 0.1
  done
  stack_green 2; stack_await 2 '.status=="landed"'; stack_stop
}
case_stack_local_body() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1
  printf 'Depends on #1\n' > "$DV_STATE/S-2/pr.md"
  stack_waiting 2
  test ! -f "$GH_STUB_DIR/order"
}
case_stack_closed_base() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  jq '.state="CLOSED"' "$GH_STUB_DIR/pr-1.json" > "$CASE_DIR/closed"
  mv "$CASE_DIR/closed" "$GH_STUB_DIR/pr-1.json"
  stack_waiting 2
  test ! -f "$GH_STUB_DIR/order"
}
case_stack_api_failure() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  touch "$GH_STUB_DIR/fail-1"
  stack_waiting 2
  test ! -f "$GH_STUB_DIR/order"
}
case_stack_conflict() {
  needs_tmux
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  printf 'base edit\n' > "$REPO/base"
  git -C "$REPO" commit -qam 'advance base'
  git -C "$REPO" push -q origin dev
  printf 'child edit\n' > "$DV_WORK/stack-2/base"
  git -C "$DV_WORK/stack-2" commit -qam 'conflicting child'
  git -C "$DV_WORK/stack-2" push -q origin stack-2
  stack_green 2; stack_waiting 2
  # A harmless terminal receives dv send; no real agent is launched.
  tmux -L "$DV_TMUX_SOCKET" new-session -d -s dv-S-2 'sleep 60'
  dv land S-1
  stack_watch
  wait_file "$DV_STATE/S-2/stack-conflict.sent"
  sleep 1.5
  git -C "$DV_WORK/stack-2" rev-parse --verify MERGE_HEAD
  test -s "$DV_STATE/S-2/stack-conflict.sent"
  test ! -f "$DV_STATE/S-2/stack-conflict.pending"
  test "$(cat "$GH_STUB_DIR/order")" = 1
  test ! -s "$DV_STATE/S-2/stack-conflict.log"
  cp "$DV_STATE/S-2/stack-conflict.sent" "$CASE_DIR/sent"
  # Simulate the agent resolving and pushing the existing merge.
  printf 'resolved\n' > "$DV_WORK/stack-2/base"
  git -C "$DV_WORK/stack-2" add base
  git -C "$DV_WORK/stack-2" commit --no-edit
  git -C "$DV_WORK/stack-2" push -q origin stack-2
  stack_green 2
  stack_await 2 '.status=="landed"'; stack_stop
  cmp "$CASE_DIR/sent" "$DV_STATE/S-2/stack-conflict.sent"
}
case_stack_dirty() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  stack_waiting 2; dv land S-1
  printf 'user work\n' > "$DV_WORK/stack-2/dirty"
  if dv land S-2; then return 1; fi
  test "$(cat "$DV_WORK/stack-2/dirty")" = 'user work'
  test "$(cat "$GH_STUB_DIR/order")" = 1
}
case_stack_remote() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  stack_waiting 2; dv land S-1
  mkdir -p "$CASE_DIR/remote-home" "$CASE_DIR/watcher-state"
  {
    printf 'DV_STATE=%q\nDV_HOME=%q\nDV_HOST=remote-host\n' "$DV_STATE" "$DV_HOME"
  } > "$CASE_DIR/remote-home/config.sh"
  export SSH_FIXTURE_EXEC=1
  DV_STATE="$CASE_DIR/watcher-state" DV_HOST=watch-host DV_HOSTS=remote-host dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  stack_await 2 '.stack_update_head!=null'
  stack_green 2; stack_await 2 '.status=="landed"'; stack_stop
  test "$(tr '\n' ' ' < "$GH_STUB_DIR/order")" = '1 2 '
}
case_stack_reconcile() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  stack_waiting 2; dv land S-1
  # Lost landed delivery: the existing status safety net finds waiting stacks.
  : > "$DV_HOME/kick.q"
  export DV_HOSTS="$DV_HOST" DV_RECONCILE_INTERVAL=1
  stack_watch; stack_await 2 '.stack_update_head!=null'
  stack_green 2; stack_await 2 '.status=="landed"'; stack_stop
}
case_stack_checks() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  stack_waiting 2; dv land S-1
  if dv land S-2; then return 1; fi
  local checks
  for checks in '[]' \
    '[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null}]' \
    '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]' \
    '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"}]'; do
    jq --argjson checks "$checks" '.statusCheckRollup=$checks' "$GH_STUB_DIR/pr-2.json" > "$CASE_DIR/checks"
    mv "$CASE_DIR/checks" "$GH_STUB_DIR/pr-2.json"
    stack_green 2
    if dv land S-2; then return 1; fi
    test "$(cat "$GH_STUB_DIR/order")" = 1
    test -d "$DV_WORK/stack-2"
  done
}
case_stack_push_retry() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  stack_waiting 2; dv land S-1
  printf '#!/usr/bin/env bash\nexit 1\n' > "$CASE_DIR/remote.git/hooks/pre-receive"
  chmod +x "$CASE_DIR/remote.git/hooks/pre-receive"
  if dv land S-2; then return 1; fi
  test "$(cat "$GH_STUB_DIR/order")" = 1
  rm "$CASE_DIR/remote.git/hooks/pre-receive"
  if dv land S-2; then return 1; fi # Push recovers, but new-head CI is absent.
  test "$(git -C "$DV_WORK/stack-2" rev-parse HEAD)" = "$(git --git-dir="$CASE_DIR/remote.git" rev-parse stack-2)"
  stack_green 2; dv land S-2
}
