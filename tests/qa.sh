#!/usr/bin/env bash
qa_teardown() {
  touch "$CASE_DIR/qa-release"
  watcher_teardown
}
qa_fixture() {
  repo qa remote
  watch_fixture
  trap qa_teardown EXIT
  export DV_QA_AGENT_CMD="$ROOT/tests/fixtures/qa-agent" DV_QA=0
  export TMPDIR="$CASE_DIR/tmp"
  mkdir "$TMPDIR"
  printf 'DV_QA=1\n' > "$REPO/.devflow"
  git -C "$REPO" add .devflow
  git -C "$REPO" commit -qm 'enable QA'
  git -C "$REPO" push -q origin main
  mkdir "$DV_STATE/Q-1"
  jq -n --arg repo "$REPO" '{issue:"Q-1",repo:$repo,worktree:$repo,branch:"feature",base:"main",host:"test-host",status:"landed"}' > "$DV_STATE/Q-1/meta"
  printf '{"number":7,"base":{"ref":"main"},"merged_at":"today","milestone":{"number":1,"title":"M1"}}\n' > "$GH_STUB_DIR/qa-pr"
  printf '[]\n' > "$GH_STUB_DIR/qa-issues"
  printf '[]\n' > "$GH_STUB_DIR/qa-comments"
}
qa_event() {
  local head
  head=$(git -C "$REPO" rev-parse HEAD)
  jq --arg head "$head" '.head=$head' "$DV_STATE/Q-1/meta" > "$CASE_DIR/meta.tmp"
  mv "$CASE_DIR/meta.tmp" "$DV_STATE/Q-1/meta"
  dv-kick landed Q-1 landed test-host "$head" "$1"
}
qa_wait_runs() {
  local count=$1
  for _ in {1..200}; do
    if [ -f "$CASE_DIR/qa-runs" ] && [ "$(wc -l < "$CASE_DIR/qa-runs" | tr -d ' ')" = "$count" ]; then return; fi
    sleep 0.1
  done
  cat "$CASE_DIR/watch.log" >&2
  printf 'Expected %s QA agent run(s); no matching run count observed\n' "$count" >&2
  return 1
}
qa_finish() {
  touch "$CASE_DIR/qa-release"
  local record
  for _ in {1..200}; do
    record=$(find "$DV_STATE" -name done.json -print)
    [ -z "$record" ] || break
    sleep 0.1
  done
  test -n "$record"
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
}
case_qa_landed() {
  qa_fixture
  qa_event first; qa_event first
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  qa_wait_runs 1; qa_finish
  test "$(wc -l < "$CASE_DIR/qa-runs" | tr -d ' ')" = 1
  jq -e --arg head "$(git -C "$REPO" rev-parse HEAD)" '.head==$head and .kind=="qa" and .milestone.title=="M1"' "$DV_STATE"/QA-*/meta
  test "$(grep -c 'qa-summary' "$GH_STUB_DIR/qa-actions")" = 1
}
case_qa_coalesce() {
  qa_fixture
  qa_event first
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  qa_wait_runs 1
  printf 'second\n' >> "$REPO/base"; git -C "$REPO" commit -qam second; git -C "$REPO" push -q origin main
  qa_event second
  printf 'third\n' >> "$REPO/base"; git -C "$REPO" commit -qam third; git -C "$REPO" push -q origin main
  qa_event third
  wait_seen 3
  touch "$CASE_DIR/qa-release"
  qa_wait_runs 2
  qa_finish
  test "$(wc -l < "$CASE_DIR/qa-runs" | tr -d ' ')" = 2
  tail -n 1 "$CASE_DIR/qa-runs" | jq -e --arg head "$(git -C "$REPO" rev-parse HEAD)" '.head==$head'
  test ! -f "$CASE_DIR/qa-overlap"
}
case_qa_optout() {
  qa_fixture
  printf 'DV_QA=0\n' > "$REPO/.devflow"
  git -C "$REPO" commit -qam disable; git -C "$REPO" push -q origin main
  qa_event disabled
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_seen 1
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  test ! -e "$CASE_DIR/qa-runs"
}
case_qa_duplicate() {
  qa_fixture
  printf '[{"number":19,"title":"Cannot start a conversation","state":"open","labels":[],"milestone":{"number":1,"title":"M1"}}]\n' > "$GH_STUB_DIR/qa-issues"
  export DV_QA_FINDING=1
  qa_event duplicate
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  qa_wait_runs 1; qa_finish
  grep 'issue-comment 19' "$GH_STUB_DIR/qa-actions"
  if grep -q issue-create "$GH_STUB_DIR/qa-actions"; then return 1; fi
}
case_qa_new_finding() {
  qa_fixture
  export DV_QA_FINDING=1
  qa_event new
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  qa_wait_runs 1; qa_finish
  grep 'issue-create' "$GH_STUB_DIR/qa-actions"
  jq -e '.milestone==1 and (.labels|index("qa")) and (.labels|index("bug")) and (.body|contains("Expected"))' "$GH_STUB_DIR/qa-created"
}
case_qa_batch() {
  qa_fixture
  qa_event before
  printf 'latest\n' >> "$REPO/base"; git -C "$REPO" commit -qam latest; git -C "$REPO" push -q origin main
  qa_event latest
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  qa_wait_runs 1; qa_finish
  test "$(wc -l < "$CASE_DIR/qa-runs" | tr -d ' ')" = 1
  jq -e --arg head "$(git -C "$REPO" rev-parse HEAD)" '.head==$head' "$CASE_DIR/qa-runs"
}
case_qa_restart() {
  qa_fixture
  qa_event first
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  qa_wait_runs 1
  kill -KILL "$watcher"; wait "$watcher" 2>/dev/null || true; watcher=''
  printf 'latest\n' >> "$REPO/base"; git -C "$REPO" commit -qam latest; git -C "$REPO" push -q origin main
  qa_event latest
  dv-watch >> "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_seen 2
  dv qa status --json | jq -e 'length==1 and .[0].pending and .[0].running'
  test "$(wc -l < "$CASE_DIR/qa-runs" | tr -d ' ')" = 1
  touch "$CASE_DIR/qa-release"
  qa_wait_runs 2; qa_finish
  test ! -f "$CASE_DIR/qa-overlap"
}
case_qa_fresh_codex() {
  qa_fixture
  export DV_QA_AGENT_CMD='' DV_CODEX_BIN="$ROOT/tests/fixtures/qa-agent" DV_CODEX_ENV_FILE=''
  qa_event fresh
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  qa_wait_runs 1; qa_finish
  jq -e '(.args|index("exec")) and (.args|index("--json")) and ((.args|index("resume"))==null)' "$CASE_DIR/qa-command"
}
case_qa_fresh_claude() {
  qa_fixture
  export DV_QA_AGENT_CMD='' DV_QA_AGENT=claude DV_CLAUDE_BIN="$ROOT/tests/fixtures/qa-agent"
  qa_event fresh
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  qa_wait_runs 1; qa_finish
  jq -e '(.args|index("--no-session-persistence")) and ((.args|index("--resume"))==null)' "$CASE_DIR/qa-command"
}
case_qa_merged_base() {
  qa_fixture
  # A remote submission need not know the base; the origin default can be a
  # release branch while the merged PR targets the development branch.
  jq '.base=""' "$DV_STATE/Q-1/meta" > "$CASE_DIR/meta.tmp"; mv "$CASE_DIR/meta.tmp" "$DV_STATE/Q-1/meta"
  git -C "$REPO" checkout -qb dev
  printf 'development head\n' >> "$REPO/base"
  git -C "$REPO" commit -qam development; git -C "$REPO" push -q origin dev
  jq '.base.ref="dev"' "$GH_STUB_DIR/qa-pr" > "$CASE_DIR/pr.tmp"; mv "$CASE_DIR/pr.tmp" "$GH_STUB_DIR/qa-pr"
  qa_event development
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  qa_wait_runs 1; qa_finish
  jq -e --arg head "$(git -C "$REPO" rev-parse HEAD)" '.head==$head and .base=="dev"' "$DV_STATE"/QA-*/meta
}
case_qa_repository_ids() {
  bidding_functions
  # shellcheck source=lib/qa.sh
  source "$ROOT/lib/qa.sh"
  local one two three
  one=$(qa_job_id 'owner/app.name' abcdef1234567890)
  two=$(qa_job_id 'owner/app-name' abcdef1234567890)
  three=$(qa_job_id 'owner-app/name' abcdef1234567890)
  valid_issue "$one"; valid_issue "$two"; valid_issue "$three"
  test "$one" != "$two"
  test "$two" != "$three"
}
case_qa_transport_retry() {
  qa_fixture
  bidding_functions
  # shellcheck source=lib/manager.sh
  source "$ROOT/lib/manager.sh"
  # shellcheck source=lib/qa.sh
  source "$ROOT/lib/qa.sh"
  manager_event_repo() { return 1; }
  export DV_HOSTS=remote-host
  mkdir -p "$DV_HOME/submissions/REMOTE-1"
  jq -n --arg repo "$REPO" '{repo:$repo,host:"remote-host",status:"completed",token:"issued",head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' > "$DV_HOME/submissions/REMOTE-1/task.json"
  qa_enqueue '{"host":"remote-host","issue":"REMOTE-1","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","token":"issued"}'
  jq -e '.repository=="test/repo"' "$DV_HOME"/qa/*/pending.json
}
case_qa_recovered_capacity() {
  qa_fixture
  qa_event capacity
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  qa_wait_runs 1
  bidding_functions
  # shellcheck source=lib/qa.sh
  source "$ROOT/lib/qa.sh"
  local active=0 pids=''
  qa_recover
  test "$active" = 1
  # The same runner already tracked as a current child must not count twice.
  pids=$(cat "$DV_HOME"/qa/*/pid); active=1
  qa_recover
  test "$active" = 1
  qa_finish
}
case_qa_explicit_match() {
  qa_fixture
  printf '[{"number":19,"title":"Cannot start a conversation"},{"number":21,"title":"Conversation input stalls"}]\n' > "$GH_STUB_DIR/qa-issues"
  export DV_QA_FINDING=1 DV_QA_MATCH=21
  qa_event explicit
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  qa_wait_runs 1; qa_finish
  grep 'issue-comment 21' "$GH_STUB_DIR/qa-actions"
  if grep -q 'issue-comment 19' "$GH_STUB_DIR/qa-actions"; then return 1; fi
}
case_qa_config_data() {
  qa_fixture
  printf 'touch "%s/config-executed"\nDV_QA=0\n' "$CASE_DIR" > "$REPO/.devflow"
  git -C "$REPO" commit -qam config; git -C "$REPO" push -q origin main
  qa_event config
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_seen 1
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  test ! -e "$CASE_DIR/config-executed"
  test ! -e "$CASE_DIR/qa-runs"
}
case_qa_unbound_event() {
  bidding_functions
  # shellcheck source=lib/qa.sh
  source "$ROOT/lib/qa.sh"
  manager_event_repo() { printf 'https://github.com/attacker/evil.git\n'; }
  export DV_HOSTS=remote-host
  qa_enqueue '{"host":"remote-host","issue":"RCE-1","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","token":"forged"}'
  test ! -d "$DV_HOME/qa"
}
case_qa_bound_event() {
  qa_fixture
  bidding_functions
  # shellcheck source=lib/manager.sh
  source "$ROOT/lib/manager.sh"
  # shellcheck source=lib/qa.sh
  source "$ROOT/lib/qa.sh"
  manager_event_repo() { printf 'https://github.com/attacker/evil.git\n'; }
  mkdir -p "$DV_HOME/submissions/REMOTE-1"
  jq -n --arg repo "$REPO" '{repo:$repo,host:"remote-host",status:"completed",token:"issued",head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' > "$DV_HOME/submissions/REMOTE-1/task.json"
  qa_enqueue '{"host":"remote-host","issue":"REMOTE-1","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","token":"issued"}'
  jq -e '.repository=="test/repo"' "$DV_HOME"/qa/*/pending.json
  rm "$DV_HOME"/qa/*/pending.json
  qa_enqueue '{"host":"remote-host","issue":"REMOTE-1","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","token":"forged"}'
  test ! -f "$DV_HOME"/qa/*/pending.json
  qa_enqueue '{"host":"remote-host","issue":"REMOTE-1","head":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","token":"issued"}'
  test ! -f "$DV_HOME"/qa/*/pending.json
}
