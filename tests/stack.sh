#!/usr/bin/env bash
# Real disposable Git branches; only the GitHub API and agent transport are fake.
stack_fixture() {
  repo stack remote
  export REPO
  git -C "$REPO" checkout -qb dev
  git -C "$REPO" push -qu origin dev
  mkdir "$CASE_DIR/stack-bin"
  # Assigned by the shared test harness.
  # shellcheck disable=SC2153
  ln -s "$ROOT/tests/fixtures/stack-gh" "$CASE_DIR/stack-bin/gh"
  ln -s "$ROOT/tests/fixtures/stack-agent" "$CASE_DIR/stack-bin/herdr"
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
    '{issue:$issue,repo:$repo,worktree:$wt,branch:$branch,base:"dev",status:"ready",host:"test-host",agent:"codex",backend:"herdr",herdr_pane:$issue,started:1,head:$head,start_head:$head,done_at:2}' > "$DV_STATE/S-$number/meta"
  jq -n --arg head "$head" '{head:$head,done_at:2,checks:"green",review:"handled"}' > "$DV_STATE/S-$number/done.json"
  printf '{"url":"https://github.com/test/repo/pull/%s"}\n' "$number" > "$DV_STATE/S-$number/pr.json"
  jq -n --arg body "$body" --arg head "$head" --slurpfile checks "$GH_STUB_DIR/checks" \
    '{body:$body,state:"OPEN",baseRefName:"dev",checked_head:$head,reviews:[{id:1,user:{login:"chatgpt-codex-connector[bot]"},commit_id:$head,state:"COMMENTED",body:"Looks good"}],statusCheckRollup:$checks[0]}' > "$GH_STUB_DIR/pr-$number.json"
  jq -n --arg head "$head" '{initial_head:$head,review_head:$head,review_handled:true,reviewed_heads:[$head],failed_heads:[],requests:{}}' > "$DV_STATE/S-$number/pr-loop.json"
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
  local file="$GH_STUB_DIR/pr-$1.json" head n pushed=false
  local resumed=false wt="$DV_WORK/stack-$1" meta="$DV_STATE/S-$1/meta"
  if jq -e '.status=="running" and .stack_resume.status=="sent"' "$meta" >/dev/null; then
    resumed=true
    grep 'rerun the required checks' "$DV_STATE/S-$1/sent-input"
    grep "dv done S-$1" "$DV_STATE/S-$1/sent-input"
    # The fake worker performs the requested continuation in the temp repo.
    git -C "$wt" fetch -q origin dev
    git -C "$wt" merge --no-edit origin/dev
    test -f "$wt/file-$1"
    git -C "$wt" push -q origin "stack-$1"
    jq --arg head "$(git -C "$wt" rev-parse HEAD)" '.head=$head | .status="pr"' "$meta" > "$meta.tmp"
    mv "$meta.tmp" "$meta"
  fi
  # Update metadata is persisted before push, so it alone cannot publish CI.
  for n in {1..200}; do
    head=$(git --git-dir="$CASE_DIR/remote.git" rev-parse "stack-$1")
    if [ "$head" = "$(git -C "$DV_WORK/stack-$1" rev-parse HEAD)" ]; then pushed=true; break; fi
    sleep 0.05
  done
  [ "$pushed" = true ] || return 1
  jq --arg head "$head" '.checked_head=$head' "$file" > "$file.tmp"; mv "$file.tmp" "$file"
  if [ ! -f "$GH_STUB_DIR/explicit-review-$1" ]; then
    jq --arg head "$head" '.reviews=[{id:2,user:{login:"chatgpt-codex-connector[bot]"},commit_id:$head,state:"COMMENTED",body:"Looks good"}]' "$file" > "$file.review"
    mv "$file.review" "$file"
  fi
  if [ "$resumed" = true ]; then
    dv pr-wait "S-$1" --foreground > "$CASE_DIR/ready-$1.json"
    dv pr-wait "S-$1" --foreground --review-handled > "$CASE_DIR/handled-$1.json"
    dv 'done' "S-$1"
  fi
}
# Shared fixture state and intentionally unused polling counters/results.
# shellcheck disable=SC2034
stack_await() {
  local issue=$1 expression=$2 n
  for n in {1..200}; do
    jq -e "$expression" "$DV_STATE/S-$issue/meta" >/dev/null && return 0
    sleep 0.1
  done
  cat "$DV_STATE/S-$issue/meta" "$DV_STATE/S-$issue/stack-resume.log" "$DV_HOME/stack.log" "$DV_HOME/watch.log" "$CASE_DIR/watch.log" "$DV_HOME"/workers/*.log >&2 2>/dev/null || true
  return 1
}
stack_watch() { dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!; }
stack_stop() { touch "$DV_HOME/stop"; wait "$watcher"; watcher=''; rm "$DV_HOME/stop"; }
case_stack_chain() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'; stack_pr 3 stack-2 'Depends on #2'
  stack_waiting 2; stack_waiting 3
  dv land S-1
  stack_watch
  stack_await 2 '.stack_resume.status=="sent"'
  test "$(cat "$GH_STUB_DIR/order")" = 1
  # Old successful checks cannot merge the freshly updated branch.
  sleep 1.2
  test "$(cat "$GH_STUB_DIR/order")" = 1
  stack_green 2
  stack_await 2 '.status=="landed"'
  stack_await 3 '.stack_resume.status=="sent"'
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
  stack_await 3 '.stack_resume.status=="sent"'
  stack_green 3; stack_await 3 '.status=="landed"'; stack_stop
  test "$(tr '\n' ' ' < "$GH_STUB_DIR/order")" = '1 2 3 '
  test "$(wc -l < "$DV_STATE/S-3/sent-input" | tr -d ' ')" = 1
  git -C "$REPO" cat-file -e origin/dev:file-1
  git -C "$REPO" cat-file -e origin/dev:file-2
  git -C "$REPO" cat-file -e origin/dev:file-3
}
case_stack_parallel() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'; stack_pr 3 stack-1 'Depends on #1'
  stack_waiting 2; stack_waiting 3; dv land S-1
  export DV_MAX_WORKERS=2
  stack_watch
  stack_await 2 '.stack_resume.status=="sent"'; stack_await 3 '.stack_resume.status=="sent"'
  # The second stack must finish while the first stack's CI is still pending.
  stack_green 3; stack_await 3 '.status=="landed"'
  test "$(tr '\n' ' ' < "$GH_STUB_DIR/order")" = '1 3 '
  stack_stop
  # Durable retries survive a watcher restart, including a newly advanced base.
  stack_watch
  stack_green 2; stack_await 2 '.status=="landed"'; stack_stop
  test "$(wc -l < "$DV_STATE/S-2/sent-input" | tr -d ' ')" = 1
}
case_stack_local_body() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1
  printf 'Depends on #1\n' > "$DV_STATE/S-2/pr.md"
  stack_waiting 2
  test ! -f "$GH_STUB_DIR/order"
}
case_stack_dependency_punctuation() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1.'
  # A trailing period must not hide the dependency from the land gate.
  stack_waiting 2
  jq -e '.stack_dependencies==["1"]' "$DV_STATE/S-2/meta"
  test ! -f "$GH_STUB_DIR/order"
  # Several dependencies may share one line with trailing punctuation.
  stack_pr 3 dev 'Depends on #1, #2;'
  stack_waiting 3
  jq -e '.stack_dependencies==["1","2"]' "$DV_STATE/S-3/meta"
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
  if dv land S-2; then return 1; fi
  jq -e '.status=="ready" and .stack_head!=null' "$DV_STATE/S-2/meta"
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
  jq '.backend="tmux"' "$DV_STATE/S-2/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/S-2/meta"
  tmux -L "$DV_TMUX_SOCKET" new-session -d -s dv-S-2 'sleep 60'
  dv land S-1
  if dv land S-2; then return 1; fi
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
  dv land S-2
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
  stack_await 2 '.stack_resume.status=="sent"'
  stack_green 2; stack_await 2 '.status=="landed"'; stack_stop
  test "$(tr '\n' ' ' < "$GH_STUB_DIR/order")" = '1 2 '
}
case_stack_reconcile() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  stack_waiting 2; dv land S-1
  # Lost landed delivery: the existing status safety net finds waiting stacks.
  : > "$DV_HOME/kick.q"
  export DV_HOSTS="$DV_HOST" DV_RECONCILE_INTERVAL=1
  stack_watch; stack_await 2 '.stack_resume.status=="sent"'
  stack_green 2; stack_await 2 '.status=="landed"'; stack_stop
}
case_stack_queue_concurrent() {
  # Reconciliation and a landed scan may publish the same stack slot at once:
  # exactly one slot, no shared temp file, and no recreation once seen.
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  stack_waiting 2
  local rows; rows=$(dv status --json)
  touch "$DV_HOME/seen"
  ROWS=$rows DV_ENTRY="$ROOT/bin/dv" bash -s <<'CONCURRENT'
set -euo pipefail
source "$ROOT/lib/common.sh"
source "$ROOT/lib/stack.sh"
mkdir -p "$DV_HOME/pending"
pids=""; for _ in 1 2 3 4 5 6 7 8; do stack_queue_host test-host "$ROWS" & pids="$pids $!"; done
for p in $pids; do wait "$p"; done # every producer must succeed
test "$(find "$DV_HOME/pending" -name 'stack-*.json' | wc -l | tr -d ' ')" = 1
test "$(find "$DV_HOME/pending" -name 'stack-*.json.*' | wc -l | tr -d ' ')" = 0
slot=$(find "$DV_HOME/pending" -name 'stack-*.json'); id=$(jq -r .id "$slot")
rm "$slot"; printf '%s\n' "$id" >> "$DV_HOME/seen"
stack_queue_host test-host "$ROWS"
test "$(find "$DV_HOME/pending" -name 'stack-*.json' | wc -l | tr -d ' ')" = 0
CONCURRENT
}
case_stack_checks() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  stack_waiting 2; dv land S-1
  if dv land S-2; then return 1; fi
  stack_green 2 # Finish the resumed worker before exercising land-only CI guards.
  local checks
  for checks in '[]' \
    '[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null}]' \
    '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]' \
    '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"}]'; do
    jq --argjson checks "$checks" '.statusCheckRollup=$checks' "$GH_STUB_DIR/pr-2.json" > "$CASE_DIR/checks"
    mv "$CASE_DIR/checks" "$GH_STUB_DIR/pr-2.json"
    stack_green 2
    if dv land S-2; then return 1; fi
    jq -e '.status=="ready"' "$DV_STATE/S-2/meta"
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
case_stack_dependencies_present() {
  # A PR that already contains its merged dependencies lands as is. Merging a
  # busy base on every attempt resets CI and the PR never lands.
  stack_fixture; stack_pr 1 dev; dv land S-1
  stack_pr 2 dev 'Depends on #1'
  local before; before=$(git --git-dir="$CASE_DIR/remote.git" rev-parse stack-2)
  printf 'unrelated\n' > "$REPO/unrelated"
  git -C "$REPO" add unrelated; git -C "$REPO" commit -qm 'advance base'
  git -C "$REPO" push -q origin dev
  dv land S-2
  test "$(tr '\n' ' ' < "$GH_STUB_DIR/order")" = '1 2 '
  test "$(git --git-dir="$CASE_DIR/remote.git" rev-parse stack-2)" = "$before"
}
case_stack_dependencies_present_conflict() {
  # Dependencies already present, but the base now conflicts: the conflict must
  # still reach the agent instead of an unmergeable PR waiting forever.
  needs_tmux
  stack_fixture; stack_pr 1 dev; dv land S-1
  stack_pr 2 dev 'Depends on #1'
  printf 'base edit\n' > "$REPO/base"
  git -C "$REPO" commit -qam 'advance base'
  git -C "$REPO" push -q origin dev
  printf 'child edit\n' > "$DV_WORK/stack-2/base"
  git -C "$DV_WORK/stack-2" commit -qam 'conflicting child'
  git -C "$DV_WORK/stack-2" push -q origin stack-2
  local head; head=$(git -C "$DV_WORK/stack-2" rev-parse HEAD)
  jq --arg head "$head" '.head=$head' "$DV_STATE/S-2/meta" > "$CASE_DIR/meta"; mv "$CASE_DIR/meta" "$DV_STATE/S-2/meta"
  jq --arg head "$head" '.head=$head' "$DV_STATE/S-2/done.json" > "$CASE_DIR/done"; mv "$CASE_DIR/done" "$DV_STATE/S-2/done.json"
  stack_green 2
  jq '.backend="tmux"' "$DV_STATE/S-2/meta" > "$CASE_DIR/meta"; mv "$CASE_DIR/meta" "$DV_STATE/S-2/meta"
  tmux -L "$DV_TMUX_SOCKET" new-session -d -s dv-S-2 'sleep 60'
  if dv land S-2; then return 1; fi
  wait_file "$DV_STATE/S-2/stack-conflict.sent"
  git -C "$DV_WORK/stack-2" rev-parse --verify MERGE_HEAD
  test "$(cat "$GH_STUB_DIR/order")" = 1
}
case_stack_defer() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 dev; stack_pr 3 stack-1 $'Depends on #1\nDepends on #2'
  stack_waiting 3; dv land S-1; stack_watch
  # A fixed sleep can inspect the initial enqueue before the worker has run.
  # Wait for an actual stack attempt and its removal by the reaper instead.
  local record prompt attempt attempted=false pending=true
  for attempt in {1..200}; do
    for prompt in "$DV_HOME"/workers/*.prompt.md; do
      [ -f "$prompt" ] || continue
      if grep -Fq '"kind":"stack-resume"' "$prompt" && [ -f "${prompt%.prompt.md}.log" ]; then attempted=true; fi
    done
    pending=false
    for record in "$DV_HOME"/pending/stack-*.json; do [ ! -f "$record" ] || pending=true; done
    if [ "$attempted" = true ] && [ "$pending" = false ]; then break; fi
    sleep 0.1
  done
  test "$attempted" = true
  for record in "$DV_HOME"/pending/stack-*.json; do
    if [ -f "$record" ]; then
      printf 'BUG: unmerged dependency keeps a stack in the retry queue\n'; return 1
    fi
  done
  # A deferred attempt is not terminal: B's later landed event must requeue C.
  if [ -f "$DV_HOME/seen" ] && grep -Eq ':stack-(land|resume):' "$DV_HOME/seen"; then return 1; fi
  dv land S-2
  stack_await 3 '.stack_resume.status=="sent"'
  stack_green 3; stack_await 3 '.status=="landed"'; stack_stop
}
case_stack_missing_base() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  # GitHub says merged, but the merge result belongs to another target branch.
  jq --arg head "$(git -C "$DV_WORK/stack-1" rev-parse HEAD)" \
    '.state="MERGED" | .baseRefName="release" | .mergeCommit={oid:$head}' "$GH_STUB_DIR/pr-1.json" > "$CASE_DIR/merged-elsewhere"
  mv "$CASE_DIR/merged-elsewhere" "$GH_STUB_DIR/pr-1.json"
  stack_waiting 2
  test ! -f "$GH_STUB_DIR/order"
}
stack_rewritten_base() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  printf 'advance\n' > "$REPO/advance"
  git -C "$REPO" add advance; git -C "$REPO" commit -qm advance
  git -C "$REPO" push -q origin dev
  local original
  original=$(git -C "$DV_WORK/stack-1" rev-parse HEAD)
  STACK_TEST_METHOD=$1 dv land S-1
  if git -C "$REPO" merge-base --is-ancestor "$original" origin/dev; then return 1; fi
  # The original dependency head is absent, but its merge result is present.
  if dv land S-2; then return 1; fi # New merge has no CI yet.
  stack_green 2; dv land S-2
  test "$(tr '\n' ' ' < "$GH_STUB_DIR/order")" = '1 2 '
}
case_stack_squash_base() { stack_rewritten_base squash; }
case_stack_rebase_base() { stack_rewritten_base rebase; }

# Each case starts with setup in a fresh process.
# shellcheck disable=SC2031
case_stack_waiting_without_head() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  stack_waiting 2
  # Older/manual waiting-base records need recovery without land authorization.
  jq 'del(.stack_head)' "$DV_STATE/S-2/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/S-2/meta"
  (
    DV_ENTRY="$ROOT/bin/dv"
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/stack.sh"
    mkdir -p "$DV_HOME/pending"
    touch "$DV_HOME/seen"
    stack_queue_host "$DV_HOST" "$(dv status --json)"
  )
  if ! jq -se 'any(.[]; .issue=="S-2")' "$DV_HOME"/pending/stack-*.json; then
    printf 'BUG: waiting-base job without stack_head was not queued\n'
    return 1
  fi
}

# Each case starts with setup in a fresh process.
# shellcheck disable=SC2031
case_stack_waiting_clock() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  local before stamp
  before=$(date +%s)
  stack_waiting 2
  stamp=$(jq -er --argjson before "$before" '.stack_waiting_since | select(. >= $before)' "$DV_STATE/S-2/meta")
  stack_waiting 2
  test "$(jq -r .stack_waiting_since "$DV_STATE/S-2/meta")" = "$stamp"
}

# Each case starts with setup in a fresh process.
# shellcheck disable=SC2031
case_stack_safety_local() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  stack_waiting 2; dv land S-1
  : > "$DV_HOME/kick.q"
  # No configured remote hosts: the watcher must still reconcile itself.
  export DV_RECONCILE_INTERVAL=1
  stack_watch
  stack_await 2 '.stack_update_head!=null or .stack_resume!=null'
  stack_stop
}

# Each case starts with setup in a fresh process.
# shellcheck disable=SC2031
stack_legacy_waiting() {
  local number=$1
  jq '.status="waiting-base" | .stack_dependencies=["1"] | del(.stack_head,.stack_waiting_since)' \
    "$DV_STATE/S-$number/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/S-$number/meta"
}
# Each case starts with setup in a fresh process.
# shellcheck disable=SC2031
case_stack_resume_headless() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  # The base lands before the job enters waiting-base, with no delivered event.
  dv land S-1; : > "$DV_HOME/kick.q"
  stack_legacy_waiting 2
  printf 'review already handled\n' > "$DV_STATE/S-2/review-fix.sent"
  export DV_RECONCILE_INTERVAL=1
  stack_watch; stack_await 2 '.stack_resume.status=="sent"'
  stack_green 2
  stack_stop
  jq -e '.status=="ready" and .stack_head==null' "$DV_STATE/S-2/meta"
  jq -e '.checks=="green" and .review=="handled"' "$DV_STATE/S-2/done.json"
  jq -se 'all(.[]; .kind!="stalled")' "$DV_STATE/S-2/events.log"
  test "$(cat "$GH_STUB_DIR/order")" = 1
  test "$(cat "$DV_STATE/S-2/review-fix.sent")" = 'review already handled'
  # A restart/replayed landed event cannot duplicate the acknowledged resume.
  dv kick landed S-1 replay
  stack_watch; sleep 1.5; stack_stop
  test "$(wc -l < "$DV_STATE/S-2/sent-input" | tr -d ' ')" = 1
}
# Each case starts with setup in a fresh process.
# shellcheck disable=SC2031
case_stack_stalled() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  stack_waiting 2
  jq --argjson since "$(( $(date +%s) - 100 ))" '.stack_waiting_since=$since' \
    "$DV_STATE/S-2/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/S-2/meta"
  export DV_STALL_AFTER=10 DV_RECONCILE_INTERVAL=1
  stack_watch; sleep 1.5; stack_stop
  test ! -f "$DV_STATE/S-2/sent-input"
  if [ -f "$DV_STATE/S-2/events.log" ]; then
    jq -se 'all(.[]; .kind!="stalled")' "$DV_STATE/S-2/events.log"
  fi
  dv land S-1
  stack_watch; stack_await 2 '.stack_resume.status=="sent"'; stack_stop
  jq -se '[.[] | select(.kind=="stalled" and .message=="bases-merged")]|length==1' "$DV_STATE/S-2/events.log"
  stack_watch; sleep 1.5; stack_stop
  test "$(wc -l < "$DV_STATE/S-2/sent-input" | tr -d ' ')" = 1
}
case_stack_resume_lock() (
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  stack_waiting 2; dv land S-1
  DV_ENTRY="$ROOT/bin/dv"
  source "$ROOT/lib/common.sh"
  source "$ROOT/lib/stack.sh"
  local key resume_rc=0
  key=$(stack_resume_key < "$DV_STATE/S-2/meta")
  cat > "$CASE_DIR/resume-lock-env" <<'ENV'
rmdir() {
  env rmdir "$@" || return
  if [ "$*" = "$DV_STATE/S-2/.operation" ] &&
    [ ! -f "$DV_STATE/S-2/sent-input" ] &&
    jq -e '.stack_resume.status=="sending"' "$DV_STATE/S-2/meta" >/dev/null; then
    # A reconciler can claim the lock between the reservation and dv send.
    env mkdir "$DV_STATE/S-2/.operation"
    touch "$CASE_DIR/resume-lock-stolen"
  fi
}
ENV
  BASH_ENV="$CASE_DIR/resume-lock-env" dv _stack-resume S-2 "$key" || resume_rc=$?
  cat "$DV_STATE/S-2/stack-resume.log"
  printf 'stack resume exit=%s\n' "$resume_rc"
  test "$resume_rc" = 0
  test ! -e "$CASE_DIR/resume-lock-stolen"
  test ! -d "$DV_STATE/S-2/.operation"
  jq -e '.stack_resume.status=="sent"' "$DV_STATE/S-2/meta"
  test "$(wc -l < "$DV_STATE/S-2/sent-input" | tr -d ' ')" = 1
)
case_stack_resume_guards() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  stack_waiting 2
  dv land S-1
  (
    DV_ENTRY="$ROOT/bin/dv"
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/stack.sh"
    key=$(stack_resume_key < "$DV_STATE/S-2/meta")
    touch "$GH_STUB_DIR/fail-1"
    if dv _stack-resume S-2 "$key"; then exit 1; fi
    rm "$GH_STUB_DIR/fail-1"
    jq --arg commit "$(git -C "$DV_WORK/stack-2" rev-parse HEAD)" '.mergeCommit.oid=$commit' \
      "$GH_STUB_DIR/pr-1.json" > "$CASE_DIR/pr"
    mv "$CASE_DIR/pr" "$GH_STUB_DIR/pr-1.json"
    if dv _stack-resume S-2 "$key"; then exit 1; fi
    test ! -f "$DV_STATE/S-2/sent-input"
    # Stale queue episodes and terminal jobs cannot authorize any send.
    dv _stack-resume S-2 stale
    jq '.status="cancelled"' "$DV_STATE/S-2/meta" > "$CASE_DIR/meta"
    mv "$CASE_DIR/meta" "$DV_STATE/S-2/meta"
    dv _stack-resume S-2 "$key"
    test ! -f "$DV_STATE/S-2/sent-input"
  )
}
# Each case starts with setup in a fresh process.
# shellcheck disable=SC2031
case_stack_resume_failed() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  stack_waiting 2; dv land S-1
  touch "$CASE_DIR/send-failed"
  export DV_RECONCILE_INTERVAL=1
  stack_watch; stack_await 2 '.stack_resume.status=="failed"'; stack_stop
  test ! -f "$DV_STATE/S-2/sent-input"
  jq -se 'any(.[]; .kind=="blocked")' "$DV_STATE/S-2/events.log"
  # Delivery failures remain inspectable and cannot trigger duplicate sends.
  rm "$CASE_DIR/send-failed"
  stack_watch; sleep 1.5; stack_stop
  test ! -f "$DV_STATE/S-2/sent-input"
}
# Each case starts with setup in a fresh process.
# shellcheck disable=SC2031
case_stack_remote_safety() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  dv land S-1; : > "$DV_HOME/kick.q"
  stack_legacy_waiting 2
  mkdir -p "$CASE_DIR/remote-home" "$CASE_DIR/watcher-state"
  printf 'DV_STATE=%q\nDV_HOME=%q\nDV_HOST=remote-host\n' "$DV_STATE" "$DV_HOME" > "$CASE_DIR/remote-home/config.sh"
  export SSH_FIXTURE_EXEC=1 DV_RECONCILE_INTERVAL=1
  DV_STATE="$CASE_DIR/watcher-state" DV_HOST=watch-host DV_HOSTS=remote-host dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  stack_await 2 '.stack_resume.status=="sent"'; stack_stop
  test "$(wc -l < "$DV_STATE/S-2/sent-input" | tr -d ' ')" = 1
  test "$(cat "$GH_STUB_DIR/order")" = 1
}

case_stack_resume_interrupted() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  stack_waiting 2; dv land S-1
  (
    DV_ENTRY="$ROOT/bin/dv"
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/stack.sh"
    key=$(stack_resume_key < "$DV_STATE/S-2/meta")
    # A dead worker reserved a send but could not record the acknowledgement.
    jq --arg key "$key" '.stack_resume={key:$key,status:"sending"}' "$DV_STATE/S-2/meta" > "$CASE_DIR/meta"
    mv "$CASE_DIR/meta" "$DV_STATE/S-2/meta"
    dv _stack-resume S-2 "$key" || test "$?" = 75
    test ! -f "$DV_STATE/S-2/sent-input"
    jq -se 'any(.[]; .kind=="blocked")' "$DV_STATE/S-2/events.log"
  )
}

case_stack_land_requeue() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  stack_waiting 2
  (
    DV_ENTRY="$ROOT/bin/dv"
    source "$ROOT/lib/common.sh"
    source "$ROOT/lib/stack.sh"
    mkdir -p "$DV_HOME/pending"
    # An old watcher consumed the pre-resume land attempt for this approval.
    head=$(jq -r .stack_head "$DV_STATE/S-2/meta")
    printf '%s:S-2:stack-land:%s\n' "$DV_HOST" "$head" > "$DV_HOME/seen"
    jq '.status="ready" | .done_at=123 | .stack_resume={status:"sent"}' "$DV_STATE/S-2/meta" > "$CASE_DIR/meta"
    mv "$CASE_DIR/meta" "$DV_STATE/S-2/meta"
    stack_queue_host "$DV_HOST" "$(dv status --json)"
    jq -se 'any(.[]; .kind=="stack-land" and .issue=="S-2")' "$DV_HOME"/pending/stack-*.json
  )
}

# Each case starts with setup in a fresh process.
# shellcheck disable=SC2031
case_stack_land_retry() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  stack_waiting 2; dv land S-1
  touch "$GH_STUB_DIR/fail-merge-2"
  stack_watch; stack_await 2 '.stack_resume.status=="sent"'
  stack_green 2
  wait_file "$GH_STUB_DIR/merge-failed-2"
  stack_stop
  jq -e '.status=="ready"' "$DV_STATE/S-2/meta"
  test "$(wc -l < "$DV_STATE/S-2/sent-input" | tr -d ' ')" = 1
  rm "$GH_STUB_DIR/fail-merge-2"
  stack_watch; stack_await 2 '.status=="landed"'; stack_stop
  test "$(wc -l < "$DV_STATE/S-2/sent-input" | tr -d ' ')" = 1
  test "$(tr '\n' ' ' < "$GH_STUB_DIR/order")" = '1 2 '
}

# Each case starts with setup in a fresh process.
# shellcheck disable=SC2031
case_stack_unfinished_auto_land() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  dv land S-1
  rm -f "$DV_STATE/S-2/done.json"
  local status
  for status in pr running waiting-base; do
    jq --arg status "$status" '.status=$status' "$DV_STATE/S-2/meta" > "$CASE_DIR/meta"
    mv "$CASE_DIR/meta" "$DV_STATE/S-2/meta"
    if dv land S-2; then return 1; fi
    test "$(jq -r .status "$DV_STATE/S-2/meta")" = "$status"
  done
  # Even an old, incorrectly ready record cannot authorize automatic landing.
  jq '.status="ready"' "$DV_STATE/S-2/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/S-2/meta"
  stack_green 2
  dv _stack-land S-2 "$(jq -r .stack_head "$DV_STATE/S-2/meta")"
  test ! -f "$DV_STATE/S-2/done.json"
  test -d "$DV_WORK/stack-2"
  test "$(cat "$GH_STUB_DIR/order")" = 1
}
# Each case starts with setup in a fresh process.
# shellcheck disable=SC2031
case_stack_auto_done_guard() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  dv land S-1
  if dv land S-2; then return 1; fi
  stack_green 2
  local head approved variant
  head=$(jq -r .head "$DV_STATE/S-2/meta")
  approved=$(jq -r .stack_head "$DV_STATE/S-2/meta")
  for variant in missing stale episode; do
    jq '.status="ready" | .done_episode="current"' "$DV_STATE/S-2/meta" > "$CASE_DIR/meta"
    mv "$CASE_DIR/meta" "$DV_STATE/S-2/meta"
    case "$variant" in
      missing) rm -f "$DV_STATE/S-2/done.json" ;;
      stale) jq -n --arg head "$(git -C "$REPO" rev-parse main)" '{head:$head,episode:"current"}' > "$DV_STATE/S-2/done.json" ;;
      episode) jq -n --arg head "$head" '{head:$head,episode:"previous"}' > "$DV_STATE/S-2/done.json" ;;
    esac
    dv _stack-land S-2 "$approved"
    test -d "$DV_WORK/stack-2"
    test "$(cat "$GH_STUB_DIR/order")" = 1
  done
  # A manually pushed worker commit cannot inherit an older matching meta head.
  printf 'unfinished\n' > "$DV_WORK/stack-2/unfinished"
  git -C "$DV_WORK/stack-2" add unfinished
  git -C "$DV_WORK/stack-2" commit -qm 'unfinished worker change'
  git -C "$DV_WORK/stack-2" push -q origin stack-2
  jq -n --arg head "$head" '{head:$head,episode:"current"}' > "$DV_STATE/S-2/done.json"
  dv _stack-land S-2 "$approved"
  test -d "$DV_WORK/stack-2"
  test "$(cat "$GH_STUB_DIR/order")" = 1
  # Current-episode completion restores the normal automatic path.
  head=$(git -C "$DV_WORK/stack-2" rev-parse HEAD)
  jq --arg head "$head" '.head=$head' "$DV_STATE/S-2/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/S-2/meta"
  jq -n --arg head "$head" '{head:$head,episode:"current"}' > "$DV_STATE/S-2/done.json"
  stack_green 2
  dv _stack-land S-2 "$approved"
  jq -e '.status=="landed"' "$DV_STATE/S-2/meta"
}
# Each case starts with setup in a fresh process.
# shellcheck disable=SC2031
case_stack_auto_done_merge() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  local completed approved
  completed=$(git -C "$DV_WORK/stack-2" rev-parse HEAD)
  jq -n --arg head "$completed" '{head:$head}' > "$DV_STATE/S-2/done.json"
  dv land S-1
  if dv land S-2; then return 1; fi
  approved=$(jq -r .stack_head "$DV_STATE/S-2/meta")
  jq -e --arg head "$completed" '.stack_update_from==$head and .stack_update_head==.head and .head!=$head' "$DV_STATE/S-2/meta"
  # Once resumed for review, the worker owns further base changes. The
  # automatic land queue cannot reuse completion from the earlier episode.
  printf 'advance\n' > "$REPO/advance"
  git -C "$REPO" add advance; git -C "$REPO" commit -qm advance
  git -C "$REPO" push -q origin dev
  local updated; updated=$(git -C "$DV_WORK/stack-2" rev-parse HEAD)
  dv _stack-land S-2 "$approved"
  test "$(git -C "$DV_WORK/stack-2" rev-parse HEAD)" = "$updated"
  jq -e --arg head "$completed" '.stack_update_from==$head' "$DV_STATE/S-2/meta"
  stack_green 2
  dv _stack-land S-2 "$approved"
  jq -e '.status=="landed"' "$DV_STATE/S-2/meta"
}
# Each case starts with setup in a fresh process.
# shellcheck disable=SC2031
case_stack_resume_done_episode() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  local head
  head=$(jq -r .head "$DV_STATE/S-2/meta")
  jq -n --arg head "$head" '{head:$head}' > "$DV_STATE/S-2/done.json"
  stack_waiting 2; dv land S-1
  stack_watch; stack_await 2 '.stack_resume.status=="sent"'; stack_stop
  # The earlier completion must not satisfy the new resume episode.
  jq -e '(.done_episode | type=="string" and length>0)' "$DV_STATE/S-2/meta"
  if dv land S-2; then return 1; fi
  jq -e '.status=="running"' "$DV_STATE/S-2/meta"
  stack_green 2
  jq -e --slurpfile meta "$DV_STATE/S-2/meta" '.episode==$meta[0].done_episode' "$DV_STATE/S-2/done.json"
  dv _stack-land S-2 "$(jq -r .stack_head "$DV_STATE/S-2/meta")"
  jq -e '.status=="landed"' "$DV_STATE/S-2/meta"
}
