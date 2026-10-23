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
  export DV_QA_COALESCE=0 DV_QA_BASE=main DV_MANAGER_HOST="$DV_HOST" DV_HOSTS="$DV_HOST"
  export DV_MIN_DISK_GB=0 DV_MIN_MEMORY_MB=0 DV_MAX_JOBS=2
  export DV_AGENT_READY_codex=true DV_AGENT_READY_claude=true
  export DV_HERMES_BIN="$ROOT/tests/fixtures/manager-hermes"
  mkdir -p "$CASE_DIR/hermes"
  local registered
  registered="$DV_HOME/managers/$(printf '%s' github.com/test/repo | cksum | awk '{print $1 "-" $2}')"
  mkdir -p "$registered/pending"
  jq -n --arg repo "$REPO" '{repo:$repo,identity:"github.com/test/repo",enabled:true,session_id:"qa-manager",agent:"hermes"}' > "$registered/meta.json"
  export GIT_CONFIG_GLOBAL="$CASE_DIR/qa.gitconfig"
  git config --file "$GIT_CONFIG_GLOBAL" url."$CASE_DIR/remote.git".insteadOf https://github.com/test/repo.git
  export TMPDIR="$CASE_DIR/tmp"
  mkdir "$TMPDIR"
  printf 'DV_QA=1\n' > "$REPO/.devflow"
  git -C "$REPO" add .devflow
  git -C "$REPO" commit -qm 'enable QA'
  git -C "$REPO" push -q origin main
  mkdir "$DV_STATE/Q-1"
  jq -n --arg repo "$REPO" '{issue:"Q-1",repo:$repo,worktree:$repo,branch:"feature",base:"main",host:"test-host",status:"landed",started:1,agent:"codex"}' > "$DV_STATE/Q-1/meta"
  printf '{"number":7,"base":{"ref":"main"},"merged_at":"2026-10-22T00:00:00Z","milestone":{"number":1,"title":"M1"}}\n' > "$GH_STUB_DIR/qa-pr"
  printf '[]\n' > "$GH_STUB_DIR/qa-issues"
  printf '[]\n' > "$GH_STUB_DIR/qa-comments"
}
qa_event() {
  local head
  head=$(git -C "$REPO" rev-parse HEAD)
  jq --arg head "$head" '.head=$head' "$DV_STATE/Q-1/meta" > "$CASE_DIR/meta.tmp"
  mv "$CASE_DIR/meta.tmp" "$DV_STATE/Q-1/meta"
  jq --arg head "$head" 'if .merge_commit_sha!=null and .merge_commit_sha!=$head then
    .number+=1 | .merged_at=("2026-10-22T00:00:0"+((.number-7)|tostring)+"Z") else . end | .merge_commit_sha=$head' \
    "$GH_STUB_DIR/qa-pr" > "$CASE_DIR/qa-pr.tmp"
  mv "$CASE_DIR/qa-pr.tmp" "$GH_STUB_DIR/qa-pr"
  dv-kick landed Q-1 landed test-host "$head" "$1"
}
qa_wait_runs() {
  local count=$1
  for _ in {1..200}; do
    if [ -f "$CASE_DIR/qa-runs" ] && [ "$(wc -l < "$CASE_DIR/qa-runs" | tr -d ' ')" = "$count" ]; then return; fi
    sleep 0.1
  done
  local diagnostic
  for diagnostic in "$DV_HOME"/submissions/*/bids.json "$DV_HOME"/submissions/*/dispatch.log "$DV_STATE"/.qa/*/log; do
    [ ! -f "$diagnostic" ] || cat "$diagnostic" >&2
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
  if [ -z "$record" ]; then cat "$DV_STATE"/QA-*/log >&2; return 1; fi
  local qa_record qa_finished
  for _ in {1..200}; do
    qa_finished=true
    for qa_record in "$DV_STATE"/QA-*/meta; do
      [ ! -f "$qa_record" ] || [ -f "${qa_record%/meta}/agent.exit" ] || qa_finished=false
    done
    if [ "$qa_finished" = true ] && dv queue --json | jq -e 'all(.[]; .status=="completed" or .status=="failed")' >/dev/null; then break; fi
    sleep 0.1
  done
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
  qa_wait_events 3
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
  qa_wait_events 1
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
  qa_wait_events 2
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
  qa_fixture; export DV_QA_BASE=dev
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
  export DV_HOSTS=remote-host
  mkdir -p "$DV_HOME/submissions/REMOTE-1"
  jq -n --arg repo "$REPO" '{repo:$repo,host:"remote-host",status:"working",token:"issued",head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' > "$DV_HOME/submissions/REMOTE-1/task.json"
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
  test "$active" = 0
  test "$(bid_active)" = 1
  DV_MAX_JOBS=1 dv bid --kind qa --json --repo "$REPO" | jq -e '.active==1 and .free_slots==0 and .reason=="full"'
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
  qa_wait_events 1
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  test ! -e "$CASE_DIR/config-executed"
  test ! -e "$CASE_DIR/qa-runs"
}
case_qa_unbound_event() {
  bidding_functions
  # shellcheck source=lib/qa.sh
  source "$ROOT/lib/qa.sh"
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

# Exercise the runner synchronously; all remotes, agents and GitHub calls are
# synthetic, including failures before a per-head job can be allocated.
qa_direct_fixture() {
  qa_fixture
  qa_dir="$DV_HOME/qa/direct"
  mkdir -p "$qa_dir"
  printf '%s\n' "$$" > "$qa_dir/pid"
  jq -n --arg remote "$CASE_DIR/remote.git" --arg head "$(git -C "$REPO" rev-parse HEAD)" \
    '{repository:"test/repo",remote:$remote,base:"main",event:{head:$head}}' > "$qa_dir/running.json"
  printf '{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"nodes":[{"number":8,"milestone":{"number":1,"title":"M1"}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}\n' > "$GH_STUB_DIR/qa-graphql"
  touch "$CASE_DIR/qa-release"
  # Keep production retry delays out of these deterministic fixture tests.
  mkdir "$CASE_DIR/qa-bin"
  cat > "$CASE_DIR/qa-bin/sleep" <<'SLEEP'
#!/usr/bin/env bash
if [ "$*" = 5 ]; then printf '%s\n' "$*" >> "$CASE_DIR/qa-delays"; exit 0; fi
exec /bin/sleep "$@"
SLEEP
  chmod +x "$CASE_DIR/qa-bin/sleep"
  export PATH="$CASE_DIR/qa-bin:$PATH"
}
qa_direct_run() {
  qa_rc=0
  dv _qa-run "$qa_dir" > "$qa_dir/log" 2>&1 || qa_rc=$?
  cat "$qa_dir/log"
  printf 'QA runner exit: %s\n' "$qa_rc"
}
qa_without_pr_milestone() {
  jq '.milestone=null' "$GH_STUB_DIR/qa-pr" > "$CASE_DIR/pr.tmp"
  mv "$CASE_DIR/pr.tmp" "$GH_STUB_DIR/qa-pr"
}
case_qa_pr_lookup_retry() {
  qa_direct_fixture
  printf '1\n' > "$GH_STUB_DIR/qa-empty-pulls"
  qa_direct_run
  test "$qa_rc" = 0
  test "$(cat "$GH_STUB_DIR/qa-pull-count")" = 2
  jq -e '.pr==7 and .status=="done"' "$DV_STATE"/QA-*/meta
}
case_qa_base_lookup_retry() {
  qa_direct_fixture
  jq '.base=""' "$qa_dir/running.json" > "$CASE_DIR/request.tmp"
  mv "$CASE_DIR/request.tmp" "$qa_dir/running.json"
  printf '1\n' > "$GH_STUB_DIR/qa-empty-pulls"
  qa_direct_run
  test "$qa_rc" = 0
  jq -e '.base=="main" and .status=="done"' "$DV_STATE"/QA-*/meta
}
case_qa_pr_lookup_blocked() {
  qa_direct_fixture
  printf '99\n' > "$GH_STUB_DIR/qa-empty-pulls"
  qa_direct_run
  test "$qa_rc" = 1
  test "$(cat "$GH_STUB_DIR/qa-pull-count")" = 6
  test ! -f "$CASE_DIR/qa-runs"
  jq -e '.status=="blocked" and (.failure_reason|contains("pr lookup"))' "$DV_STATE"/QA-*/meta
  grep 'QA failed at pr lookup' "$qa_dir/log"
}
case_qa_base_lookup_blocked() {
  qa_direct_fixture
  jq '.base=""' "$qa_dir/running.json" > "$CASE_DIR/request.tmp"
  mv "$CASE_DIR/request.tmp" "$qa_dir/running.json"
  printf '99\n' > "$GH_STUB_DIR/qa-empty-pulls"
  qa_direct_run
  test "$qa_rc" = 1
  test ! -f "$CASE_DIR/qa-runs"
  jq -e '.status=="blocked" and (.failure_reason|contains("pr lookup"))' "$qa_dir/meta"
  grep 'QA failed at pr lookup' "$qa_dir/log"
}
qa_lookup_response_retry() {
  local response=$1 base_lookup=${2:-false} expected_calls=2
  qa_direct_fixture
  if [ "$base_lookup" = true ]; then
    jq '.base=""' "$qa_dir/running.json" > "$CASE_DIR/request.tmp"
    mv "$CASE_DIR/request.tmp" "$qa_dir/running.json"
    # Base discovery succeeds; the second lookup at the checked-out head fails.
    printf 'ok\n' > "$GH_STUB_DIR/qa-pull-responses"
    expected_calls=3
  fi
  printf '%s\n' "$response" >> "$GH_STUB_DIR/qa-pull-responses"
  qa_direct_run
  test "$qa_rc" = 0
  test "$(cat "$GH_STUB_DIR/qa-pull-count")" = "$expected_calls"
  test "$(cat "$CASE_DIR/qa-delays")" = 5
  test "$(wc -l < "$CASE_DIR/qa-runs" | tr -d ' ')" = 1
  jq -e '.pr==7 and .base=="main" and .milestone.title=="M1" and .status=="done"' "$DV_STATE"/QA-*/meta
}
case_qa_request_retry() { qa_lookup_response_retry fail; }
case_qa_empty_reply_retry() { qa_lookup_response_retry empty; }
case_qa_invalid_reply_retry() { qa_lookup_response_retry invalid; }
case_qa_second_lookup_retry() { qa_lookup_response_retry fail true; }
qa_lookup_response_blocked() {
  local response=$1 base_lookup=${2:-false} attempt record
  qa_direct_fixture
  if [ "$base_lookup" = true ]; then
    jq '.base=""' "$qa_dir/running.json" > "$CASE_DIR/request.tmp"
    mv "$CASE_DIR/request.tmp" "$qa_dir/running.json"
  fi
  for attempt in 1 2 3 4 5 6; do
    printf '%s\n' "$response" >> "$GH_STUB_DIR/qa-pull-responses"
  done
  qa_direct_run
  test "$qa_rc" = 1
  test "$(cat "$GH_STUB_DIR/qa-pull-count")" = 6
  test "$(wc -l < "$CASE_DIR/qa-delays" | tr -d ' ')" = 5
  test ! -f "$CASE_DIR/qa-runs"
  if [ "$base_lookup" = true ]; then record="$qa_dir/meta"
  else record=$(find "$DV_STATE" -path '*/QA-*/meta' -print); fi
  jq -e '.status=="blocked" and (.failure_reason|contains("pr lookup"))' "$record"
  test -f "$qa_dir/running.json"
  grep 'QA failed at pr lookup' "$qa_dir/log"
}
case_qa_request_blocked() { qa_lookup_response_blocked fail; }
case_qa_empty_reply_blocked() { qa_lookup_response_blocked empty; }
case_qa_base_request_blocked() { qa_lookup_response_blocked fail true; }
case_qa_milestone_graphql() {
  qa_direct_fixture; qa_without_pr_milestone
  qa_direct_run
  test "$qa_rc" = 0
  jq -e '.milestone=={number:1,title:"M1"} and .status=="done"' "$DV_STATE"/QA-*/meta
  grep 'api graphql' "$GH_STUB_DIR/calls"
  if grep 'pr view.*closingIssuesReferences' "$GH_STUB_DIR/calls"; then return 1; fi
}
qa_no_milestone_fixture() {
  qa_direct_fixture; qa_without_pr_milestone
  # Allow the old CLI path here to isolate absence of milestones from gh 2.46.
  touch "$GH_STUB_DIR/qa-legacy-field"
  jq '.data.repository.pullRequest.closingIssuesReferences.nodes[0].milestone=null' \
    "$GH_STUB_DIR/qa-graphql" > "$CASE_DIR/graphql.tmp"
  mv "$CASE_DIR/graphql.tmp" "$GH_STUB_DIR/qa-graphql"
  export DV_QA_FINDING=1
}
case_qa_no_milestone() {
  qa_no_milestone_fixture
  qa_direct_run
  test "$qa_rc" = 0
  jq -e '.milestone==null and .status=="done"' "$DV_STATE"/QA-*/meta
  grep '^Milestone: none$' "$DV_STATE"/QA-*/brief.md
  jq -e '(has("milestone")|not) and (.labels|index("qa")) and (.body|contains("milestone **none**"))' "$GH_STUB_DIR/qa-created"
}
case_qa_no_milestone_match() {
  qa_no_milestone_fixture
  printf '[{"number":19,"title":"Cannot start a conversation","milestone":{"number":2,"title":"Existing"}}]\n' > "$GH_STUB_DIR/qa-issues"
  qa_direct_run
  test "$qa_rc" = 0
  grep 'issue edit 19.*--add-label qa,bug' "$GH_STUB_DIR/calls"
  if grep 'issue edit.*--milestone' "$GH_STUB_DIR/calls"; then return 1; fi
  grep 'issue-comment 19' "$GH_STUB_DIR/qa-actions"
}
case_qa_milestone_blocked() {
  qa_direct_fixture; qa_without_pr_milestone
  touch "$GH_STUB_DIR/qa-graphql-fail"
  qa_direct_run
  test "$qa_rc" = 1
  test ! -f "$CASE_DIR/qa-runs"
  jq -e '.status=="blocked" and (.failure_reason|contains("milestone"))' "$DV_STATE"/QA-*/meta
  grep 'QA failed at milestone' "$qa_dir/log"
}
case_qa_milestone_ambiguous() {
  qa_direct_fixture; qa_without_pr_milestone
  # A second GraphQL page must participate in ambiguity detection.
  jq '.data.repository.pullRequest.closingIssuesReferences.nodes[0].milestone={number:2,title:"M2"}' \
    "$GH_STUB_DIR/qa-graphql" > "$CASE_DIR/page2"
  cat "$CASE_DIR/page2" >> "$GH_STUB_DIR/qa-graphql"
  qa_direct_run
  test "$qa_rc" = 1
  test ! -f "$CASE_DIR/qa-runs"
  grep 'multiple distinct milestones' "$qa_dir/log"
  jq -e '.status=="blocked" and (.failure_reason|contains("milestone"))' "$DV_STATE"/QA-*/meta
}

# Test finding publication directly, without starting a watcher or agent.
qa_finding_fixture() {
  repo finding remote
  mkdir "$DV_STATE/QA-FINDING"
  jq -n --arg repo "$REPO" --arg head "$(git -C "$REPO" rev-parse HEAD)" \
    '{issue:"QA-FINDING",kind:"qa",repo:$repo,worktree:$repo,branch:"main",base:"main",
      repository:"test/repo",head:$head,milestone:{number:1,title:"M1"}}' > "$DV_STATE/QA-FINDING/meta"
  printf '{}\n' > "$GH_STUB_DIR/qa-pr"
  printf '[]\n' > "$GH_STUB_DIR/qa-issues"
  printf '[]\n' > "$GH_STUB_DIR/qa-comments"
  printf '{"number":158,"title":"Conversation input stalls","state":"open"}\n' > "$GH_STUB_DIR/qa-issue-158"
  jq -n '{kind:"bug",title:"Cannot start a conversation",steps:"Type hello",expected:"Response",
    actual:"No response",evidence:"Synthetic transcript",match:158}' > "$CASE_DIR/finding.json"
}
qa_finding_run() {
  qa_rc=0
  dv qa finding QA-FINDING "$CASE_DIR/finding.json" > "$CASE_DIR/finding.log" 2>&1 || qa_rc=$?
  cat "$CASE_DIR/finding.log"
  printf 'QA finding exit: %s\n' "$qa_rc"
}
qa_finding_no_writes() {
  test "$qa_rc" != 0
  test ! -s "$GH_STUB_DIR/qa-actions"
  test ! -e "$GH_STUB_DIR/qa-created"
  test ! -e "$DV_STATE/QA-FINDING/findings.jsonl"
  if grep -E '^(label create|issue (edit|comment)|api --method POST) ' "$GH_STUB_DIR/calls"; then return 1; fi
}
qa_title_fixture() {
  qa_finding_fixture
  jq 'del(.match)' "$CASE_DIR/finding.json" > "$CASE_DIR/title.json"
  mv "$CASE_DIR/title.json" "$CASE_DIR/finding.json"
}
qa_full_page() {
  # PRs count toward the page size, even though they cannot match a finding.
  jq -n '[range(1;101) | {number:.,title:"Cannot start a conversation",state:"open",pull_request:{url:"synthetic"}}]' > "$GH_STUB_DIR/qa-issues"
}
case_qa_match_unlisted() {
  qa_finding_fixture
  qa_finding_run
  test "$qa_rc" = 0
  grep 'issue-comment 158' "$GH_STUB_DIR/qa-actions"
  grep -Fx 'api repos/test/repo/issues/158' "$GH_STUB_DIR/calls"
  if grep -E '(state=open|issue-create)' "$GH_STUB_DIR/calls" "$GH_STUB_DIR/qa-actions"; then return 1; fi
  jq -e '.action=="commented"' "$DV_STATE/QA-FINDING/findings.jsonl"
}
qa_rejected_match() {
  qa_finding_fixture
  # A stale list must not override the direct issue's state or type.
  jq -s . "$GH_STUB_DIR/qa-issue-158" > "$GH_STUB_DIR/qa-issues"
  jq "$1" "$GH_STUB_DIR/qa-issue-158" > "$CASE_DIR/issue.tmp"
  mv "$CASE_DIR/issue.tmp" "$GH_STUB_DIR/qa-issue-158"
  qa_finding_run
  qa_finding_no_writes
}
case_qa_match_closed() { qa_rejected_match '.state="closed"'; }
case_qa_match_pr() { qa_rejected_match '.pull_request={url:"synthetic"}'; }
case_qa_match_error() { qa_rejected_match '{message:"Not Found"}'; }
case_qa_match_http_failure() {
  qa_finding_fixture
  jq -s . "$GH_STUB_DIR/qa-issue-158" > "$GH_STUB_DIR/qa-issues"
  touch "$GH_STUB_DIR/qa-issue-158-fail"
  qa_finding_run
  qa_finding_no_writes
}
case_qa_title_error_object() {
  qa_title_fixture
  printf '{"message":"Service Unavailable"}\n' > "$GH_STUB_DIR/qa-issues"
  qa_finding_run
  qa_finding_no_writes
}
case_qa_title_second_page() {
  qa_title_fixture
  qa_full_page
  jq '[. + {title:"CANNOT START A CONVERSATION"}]' "$GH_STUB_DIR/qa-issue-158" > "$GH_STUB_DIR/qa-page-2"
  qa_finding_run
  test "$qa_rc" = 0
  grep 'issue-comment 158' "$GH_STUB_DIR/qa-actions"
  if grep -q issue-create "$GH_STUB_DIR/qa-actions"; then return 1; fi
}
case_qa_title_page_failure() {
  qa_title_fixture
  qa_full_page
  # Even an exact match on page one must wait for later page validation.
  jq '.[0] |= del(.pull_request)' "$GH_STUB_DIR/qa-issues" > "$CASE_DIR/page.tmp"
  mv "$CASE_DIR/page.tmp" "$GH_STUB_DIR/qa-issues"
  touch "$GH_STUB_DIR/qa-page-2-fail"
  qa_finding_run
  qa_finding_no_writes
}
case_qa_title_page_error() {
  qa_title_fixture
  qa_full_page
  printf '{"message":"Service Unavailable"}\n' > "$GH_STUB_DIR/qa-page-2"
  qa_finding_run
  qa_finding_no_writes
}
case_qa_title_empty_response() {
  qa_title_fixture
  : > "$GH_STUB_DIR/qa-issues"
  qa_finding_run
  qa_finding_no_writes
}
case_qa_title_full_last_page() {
  qa_title_fixture
  qa_full_page
  qa_finding_run
  test "$qa_rc" = 0
  grep -Fx 'api repos/test/repo/issues?state=open&per_page=100&page=2' "$GH_STUB_DIR/calls"
  test "$(grep -c issue-create "$GH_STUB_DIR/qa-actions")" = 1
}
