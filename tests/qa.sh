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
  # Assigned by the shared test harness.
  # shellcheck disable=SC2153
  export DV_QA_COALESCE=0 DV_QA_BASE=main DV_MANAGER_HOST="$DV_HOST" DV_HOSTS="$DV_HOST"
  export DV_MIN_DISK_GB=0 DV_MIN_MEMORY_MB=0 DV_MAX_JOBS=2
  export DV_AGENT_READY_codex=true DV_AGENT_READY_claude=true
  export DV_HERMES_BIN="$ROOT/tests/fixtures/manager-hermes"
  mkdir -p "$CASE_DIR/hermes"
  local registered
  registered="$DV_HOME/managers/$(printf '%s' github.com/test/repo | cksum | awk '{print $1 "-" $2}')"
  mkdir -p "$registered/pending"
  # Assigned by the shared test harness.
  # shellcheck disable=SC2153
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
  printf '[{"number":19,"title":"fix(tui): answer the first message","state":"open","labels":[],"milestone":{"number":1,"title":"M1"}}]\n' > "$GH_STUB_DIR/qa-issues"
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
  # Without a summary field the issue still opens with a Summary section.
  jq -e '.title=="fix(tui): answer the first message" and
    (.body|startswith("## Summary\nReal-use QA found that the steps below do not give the expected result.\n\n## Steps\n"))' "$GH_STUB_DIR/qa-created"
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
case_qa_dead_runner() {
  bidding_functions
  # shellcheck source=lib/qa.sh
  source "$ROOT/lib/qa.sh"
  local issue=QA-dead-runner S="$DV_STATE/QA-dead-runner" qa_dir live pid_file
  # No process can hold this PID on Linux or macOS, so a stale record always
  # looks dead and a later PID reuse cannot make the case flaky.
  local dead=999999999
  mkdir -p "$S" "$DV_STATE/.qa/$issue"
  qa_dir="$DV_STATE/.qa/$issue"
  jq -n --arg issue "$issue" '{issue:$issue,kind:"qa",repo:"test/repo",worktree:"",branch:$issue,
    base:"main",head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",start_head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    host:"test-host",agent:"codex",backend:"qa",status:"running",started:1}' > "$S/meta"
  # A reboot leaves running metadata and stale PID files but no agent.exit.
  printf '%s\n' "$dead" > "$S/agent.pid"
  printf '%s\n' "$dead" > "$qa_dir/runner.pid"
  printf '%s\n' "$dead" > "$qa_dir/child.pid"
  test ! -e "$S/agent.exit"
  test "$(bid_active)" = 0
  dv status "$issue" --json | jq -e '.[0] | .status=="failed" and .alive==false'
  # The scratch checkout outlives the runner until dv clean collects it.
  test -f "$S/meta"
  # A live wrapper, awarded runner, or agent child still holds the slot.
  sleep 30 & live=$!
  for pid_file in "$S/agent.pid" "$qa_dir/runner.pid" "$qa_dir/child.pid"; do
    printf '%s\n' "$dead" > "$S/agent.pid"
    printf '%s\n' "$dead" > "$qa_dir/runner.pid"
    printf '%s\n' "$dead" > "$qa_dir/child.pid"
    printf '%s\n' "$live" > "$pid_file"
    test "$(bid_active)" = 1
    dv status "$issue" --json | jq -e '.[0] | .status=="running" and .alive==true'
  done
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  printf '%s\n' "$dead" > "$S/agent.pid"
  printf '%s\n' "$dead" > "$qa_dir/runner.pid"
  printf '%s\n' "$dead" > "$qa_dir/child.pid"
  test "$(bid_active)" = 0
  dv status "$issue" --json | jq -e '.[0] | .status=="failed" and .alive==false'
}
qa_crashed_dispatch_fixture() {
  qa_merge_fixture
  export DV_QA_COALESCE=0
  qa_scan
  qa_dispatch
  scheduler=$(qa_dir test/repo main)
  old_job=$(jq -r .issue "$scheduler/running.json")
  old_task="$DV_HOME/submissions/$old_job/task.json"
  bid_task_set "${old_task%/task.json}" '.status="working" | .host="test-host" | .token="qa-award"'
  mkdir -p "$DV_STATE/$old_job" "$DV_STATE/.qa/$old_job" "$DV_STATE/.awards/$old_job"
  git clone -q "$CASE_DIR/remote.git" "$CASE_DIR/failed-checkout"
  printf 'unfinished QA evidence\n' >> "$CASE_DIR/failed-checkout/base"
  jq -n --arg issue "$old_job" --arg wt "$CASE_DIR/failed-checkout" \
    '{issue:$issue,kind:"qa",backend:"qa",status:"running",award_token:"qa-award",worktree:$wt,
      host:"test-host",repo:"test/repo",base:"main",started:1}' > "$DV_STATE/$old_job/meta"
  printf '999999999\n' > "$DV_STATE/.qa/$old_job/runner.pid"
  printf '{"status":"working","token":"qa-award"}\n' > "$DV_STATE/.awards/$old_job/receipt.json"
  cp "$DV_STATE/$old_job/meta" "$CASE_DIR/meta.before"
  cp "$DV_STATE/.awards/$old_job/receipt.json" "$CASE_DIR/receipt.before"
  qa_merge_add 8 2026-10-22T00:02:00Z
  qa_scan
  new_job=$(qa_job_id test/repo "$(git -C "$REPO" rev-parse HEAD)")
}
qa_assert_crashed_dispatch() {
  qa_dispatch
  jq -e '.status=="failed" and .token=="qa-award" and .host=="test-host"' "$old_task"
  dv queue --json | jq -e --arg issue "$old_job" 'any(.[]; .issue==$issue and .status=="failed")'
  dv qa status --json | jq -e 'length==1 and .[0].running==false and .[0].pending==true'
  jq -e '.status=="submitted" and .host==null and [.qa.prs[].number]==[8]' "$DV_HOME/submissions/$new_job/task.json"
  jq -e --arg issue "$new_job" '.issue==$issue' "$scheduler/running.json"
  test ! -f "$scheduler/pending.json"
  test ! -f "$DV_STATE/$old_job/agent.exit"
  cmp "$CASE_DIR/meta.before" "$DV_STATE/$old_job/meta"
  cmp "$CASE_DIR/receipt.before" "$DV_STATE/.awards/$old_job/receipt.json"
  grep -Fx 'unfinished QA evidence' "$CASE_DIR/failed-checkout/base"
  cp "$DV_HOME/kick.q" "$CASE_DIR/kicks.before"
  cp "$DV_HOME/submissions/$new_job/task.json" "$CASE_DIR/new.before"
  qa_dispatch
  cmp "$CASE_DIR/kicks.before" "$DV_HOME/kick.q"
  cmp "$CASE_DIR/new.before" "$DV_HOME/submissions/$new_job/task.json"
  test "$(find "$DV_HOME/submissions" -name task.json | wc -l | tr -d ' ')" = 2
}
case_qa_crashed_dispatch() {
  local scheduler old_job old_task new_job
  qa_crashed_dispatch_fixture
  # A remote host confirms exit even though the killed runner wrote no exit file.
  # Invoked indirectly by bid_limit (SC2317 on ShellCheck 0.9, SC2329 on 0.11).
  # shellcheck disable=SC2317,SC2329
  bid_rpc() {
    test "$*" = "test-host _receipt $old_job qa-award" || return 1
    printf '{"status":"failed","token":"qa-award","exited":true}\n'
  }
  qa_assert_crashed_dispatch
}
case_qa_crashed_receipt() {
  local scheduler old_job old_task new_job
  qa_crashed_dispatch_fixture
  dv status "$old_job" --json | jq -e '.[0] | .status=="failed" and .alive==false'
  dv _receipt "$old_job" qa-award | jq -e '.status=="failed" and .exited==true and .token=="qa-award"'
  qa_assert_crashed_dispatch
}
case_qa_dispatch_receipt_guards() {
  local scheduler old_job old_task new_job reply
  qa_crashed_dispatch_fixture
  cp "$old_task" "$CASE_DIR/task.before"
  cp "$scheduler/pending.json" "$CASE_DIR/pending.before"
  # Invoked indirectly by bid_limit.
  # shellcheck disable=SC2317,SC2329
  bid_rpc() { [ "$reply" != unavailable ] || return 1; printf '%s\n' "$reply"; }
  for reply in unavailable invalid '{}' '{"status":"absent"}' \
    '{"status":"working","token":"qa-award","exited":false}' \
    '{"status":"failed","token":"qa-award","exited":false}' \
    '{"status":"failed","token":"other-award","exited":true}'; do
    qa_dispatch
    cmp "$CASE_DIR/task.before" "$old_task"
    cmp "$CASE_DIR/pending.before" "$scheduler/pending.json"
    test ! -d "$DV_HOME/submissions/$new_job"
    dv qa status --json | jq -e '.[0].running and .[0].pending'
  done
}
case_qa_dispatch_live_runner() {
  local scheduler old_job old_task new_job
  qa_crashed_dispatch_fixture
  printf '%s\n' "$$" > "$DV_STATE/.qa/$old_job/child.pid"
  dv _receipt "$old_job" qa-award | jq -e '.status=="working" and .exited==false'
  qa_dispatch
  jq -e '.status=="working"' "$old_task"
  test -f "$scheduler/pending.json"
  test ! -d "$DV_HOME/submissions/$new_job"
  dv qa status --json | jq -e '.[0].running and .[0].pending'
}
case_qa_dispatch_exited_receipt() {
  local scheduler old_job old_task new_job
  qa_crashed_dispatch_fixture
  bid_task_set "${old_task%/task.json}" '.status="input-required"'
  # Older hosts retain the startup status in their terminal receipt.
  # shellcheck disable=SC2317,SC2329
  bid_rpc() { printf '{"status":"working","token":"qa-award","exited":true}\n'; }
  qa_assert_crashed_dispatch
}
case_qa_dispatch_completed_receipt() {
  local scheduler old_job old_task new_job
  qa_crashed_dispatch_fixture
  jq '.status="done"' "$DV_STATE/$old_job/meta" > "$CASE_DIR/done.meta"
  mv "$CASE_DIR/done.meta" "$DV_STATE/$old_job/meta"
  dv _receipt "$old_job" qa-award | jq -e '.status=="completed" and .exited==true'
  qa_dispatch
  jq -e '.status=="completed" and .reason==null' "$old_task"
  test -f "$DV_HOME/submissions/$new_job/task.json"
}
case_qa_dispatch_unawarded() {
  local scheduler old_job old_task new_job
  qa_crashed_dispatch_fixture
  bid_task_set "${old_task%/task.json}" '.status="submitted" | .host=null | del(.token)'
  # shellcheck disable=SC2317,SC2329
  bid_rpc() { touch "$CASE_DIR/unexpected-rpc"; return 1; }
  qa_dispatch
  test ! -f "$CASE_DIR/unexpected-rpc"
  test ! -d "$DV_HOME/submissions/$new_job"
  test -f "$scheduler/pending.json"
  dv qa status --json | jq -e '.[0].running==false and .[0].pending==true'
}
case_qa_crashed_without_pending() {
  local scheduler old_job old_task new_job
  qa_crashed_dispatch_fixture
  mv "$scheduler/pending.json" "$CASE_DIR/later.json"
  qa_dispatch
  jq -e '.status=="failed"' "$old_task"
  dv qa status --json | jq -e '.[0].running==false and .[0].pending==false'
  test ! -d "$DV_HOME/submissions/$new_job"
  mv "$CASE_DIR/later.json" "$scheduler/pending.json"
  qa_assert_crashed_dispatch
}
case_qa_dead_capacity_runner() {
  bidding_functions
  # shellcheck source=lib/qa.sh
  source "$ROOT/lib/qa.sh"
  local issue=QA-dead-capacity S="$DV_STATE/QA-dead-capacity" qa_dir live pid_file
  local dead=999999999
  mkdir -p "$S" "$DV_STATE/.qa/$issue"
  qa_dir="$DV_STATE/.qa/$issue"
  # A provider wait nobody owns must not promise a retry. 2100-01-01 keeps the
  # advertised time in the future for the life of the test.
  jq -n --arg issue "$issue" '{issue:$issue,kind:"qa",repo:"test/repo",worktree:"",branch:$issue,
    base:"main",head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",start_head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    host:"test-host",agent:"codex",backend:"qa",status:"waiting-capacity",started:1,
    capacity:{next_try_at:4102444800,attempt:1,resume_status:"running"}}' > "$S/meta"
  printf '%s\n' "$dead" > "$S/agent.pid"
  printf '%s\n' "$dead" > "$qa_dir/runner.pid"
  printf '%s\n' "$dead" > "$qa_dir/child.pid"
  test ! -e "$S/agent.exit"
  test "$(bid_active)" = 0
  dv status "$issue" --json | jq -e '.[0] |
    .status=="failed" and .agent_status=="failed" and .alive==false and .capacity_retry_at==null'
  # The scratch checkout outlives the runner until dv clean collects it.
  test -f "$S/meta"
  # A live wrapper, awarded runner, or agent child still owns the wait.
  sleep 30 & live=$!
  for pid_file in "$S/agent.pid" "$qa_dir/runner.pid" "$qa_dir/child.pid"; do
    printf '%s\n' "$dead" > "$S/agent.pid"
    printf '%s\n' "$dead" > "$qa_dir/runner.pid"
    printf '%s\n' "$dead" > "$qa_dir/child.pid"
    printf '%s\n' "$live" > "$pid_file"
    test "$(bid_active)" = 1
    dv status "$issue" --json | jq -e '.[0] |
      .status=="waiting-capacity" and .agent_status=="waiting-capacity" and .alive==true and .capacity_retry_at==4102444800'
  done
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
}
case_qa_explicit_match() {
  qa_fixture
  printf '[{"number":19,"title":"fix(tui): answer the first message"},{"number":21,"title":"Conversation input stalls"}]\n' > "$GH_STUB_DIR/qa-issues"
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
  printf '[{"number":19,"title":"fix(tui): answer the first message","milestone":{"number":2,"title":"Existing"}}]\n' > "$GH_STUB_DIR/qa-issues"
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
  jq -n '{kind:"bug",title:"fix(tui): answer the first message",steps:"Type hello",expected:"Response",
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
  jq -n '[range(1;101) | {number:.,title:"fix(tui): answer the first message",state:"open",pull_request:{url:"synthetic"}}]' > "$GH_STUB_DIR/qa-issues"
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
  jq '[. + {title:"FIX(TUI): ANSWER THE FIRST MESSAGE"}]' "$GH_STUB_DIR/qa-issue-158" > "$GH_STUB_DIR/qa-page-2"
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
case_qa_finding_format() {
  qa_title_fixture
  jq '.summary="The first message gets no reply, so a new user cannot start."' "$CASE_DIR/finding.json" > "$CASE_DIR/summary.json"
  mv "$CASE_DIR/summary.json" "$CASE_DIR/finding.json"
  qa_finding_run
  test "$qa_rc" = 0
  # The shared issue format: Summary, bug sections, Done when, then Context.
  jq -e --arg head "$(git -C "$REPO" rev-parse HEAD)" '.title=="fix(tui): answer the first message" and
    (.body|startswith("## Summary\nThe first message gets no reply, so a new user cannot start.\n\n" +
      "## Steps\nType hello\n\n## Expected\nResponse\n\n## Actual\nNo response\n\n" +
      "## Done when\n- [ ] following the steps gives the expected result.\n- [ ] a test covers this case.\n\n" +
      "## Context\nSource: real-use QA at `"+$head+"`, milestone **M1**\nEvidence: Synthetic transcript\n\n<!-- devflow-qa:QA-FINDING:")) and
    (.body|test("<!-- devflow-qa:QA-FINDING:[0-9]+-[0-9]+ -->\n$"))' "$GH_STUB_DIR/qa-created"
}
case_qa_title_rejected() {
  local title
  qa_title_fixture
  for title in 'Cannot start a conversation' 'fix(tui): Answer the first message' 'bug(tui): answer the first message' \
    'fix(tui): follow up on review findings' 'fix(tui): answer what PR #12 broke' 'fix(tui): answer the 2026-10-24 message' \
    "fix(tui): $(printf 'a%.0s' {1..73})"; do
    jq --arg title "$title" '.title=$title' "$CASE_DIR/finding.json" > "$CASE_DIR/title.json"
    mv "$CASE_DIR/title.json" "$CASE_DIR/finding.json"
    qa_finding_run
    qa_finding_no_writes
    grep -F 'type(scope): ' "$CASE_DIR/finding.log"
  done
}
