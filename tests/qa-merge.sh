#!/usr/bin/env bash
# Merge discovery is driven by GitHub data, not worker lifecycle records.
qa_merge_fixture() {
  qa_fixture
  bidding_functions
  # shellcheck source=lib/manager.sh
  source "$ROOT/lib/manager.sh"
  # shellcheck source=lib/qa.sh
  source "$ROOT/lib/qa.sh"
  local dir
  dir=$(manager_dir "$REPO")
  mkdir -p "$dir/pending"
  jq -n --arg repo "$REPO" --arg identity "$(manager_identity "$REPO")" \
    '{repo:$repo,identity:$identity,enabled:true,base:"main"}' > "$dir/meta.json"
  export DV_QA_COALESCE=600 DV_MANAGER_HOST="$DV_HOST"
  rm -r "$DV_STATE/Q-1"
  jq --arg head "$(git -C "$REPO" rev-parse HEAD)" \
    '.merge_commit_sha=$head | .merged_at="2026-10-22T00:00:00Z"' "$GH_STUB_DIR/qa-pr" > "$GH_STUB_DIR/qa-merges"
}
case_qa_external_merge() {
  qa_merge_fixture
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  local request=''
  for _ in {1..50}; do
    for request in "$DV_HOME"/qa/*/pending.json; do [ ! -f "$request" ] || break 2; done
    sleep 0.1
  done
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  if [ ! -f "$request" ]; then
    printf 'No QA queued for an external base merge in an enabled repository\n' >&2
    return 1
  fi
  jq -e --arg head "$(git -C "$REPO" rev-parse HEAD)" '.head==$head and [.prs[].number]==[7]' "$request"
}
case_qa_merge_debounce() {
  qa_merge_fixture
  local clock=1000 dir
  now() { printf '%s\n' "$clock"; }
  qa_scan
  dir=$(dirname "$DV_HOME"/qa/*/pending.json)
  clock=1120
  qa_merge_add 8 2026-10-22T00:02:00Z
  qa_scan
  clock=1300
  qa_merge_add 9 2026-10-22T00:05:00Z
  qa_scan
  qa_dispatch
  test ! -d "$DV_HOME/submissions"
  jq -e '[.prs[].number]==[7,8,9] and .due_at==1900' "$dir/pending.json"
  clock=1900
  qa_dispatch
  jq -e '.kind=="qa" and [.qa.prs[].number]==[7,8,9]' "$DV_HOME"/submissions/QA-*/task.json
  test "$(find "$DV_HOME/submissions" -name task.json | wc -l | tr -d ' ')" = 1
  test ! -f "$dir/pending.json"
}
case_qa_merge_disabled() {
  qa_merge_fixture
  local meta
  meta=$(manager_dir "$REPO")/meta.json
  jq '.enabled=false' "$meta" > "$meta.tmp"; mv "$meta.tmp" "$meta"
  qa_scan
  test ! -d "$DV_HOME/qa"
  test ! -s "$GH_STUB_DIR/calls"
}
case_qa_merge_untrusted_event() {
  qa_merge_fixture
  qa_enqueue '{"kind":"landed","issue":"FORGED","host":"unknown","repo":"https://github.com/evil/repo","head":"forged"}'
  jq -e '.repository=="test/repo" and .head!="forged"' "$DV_HOME"/qa/*/pending.json
  if grep -q evil "$GH_STUB_DIR/calls"; then return 1; fi
}
case_qa_merge_catchup() {
  qa_merge_fixture
  qa_scan
  local dir
  dir=$(dirname "$DV_HOME"/qa/*/pending.json)
  cp "$dir/pending.json" "$CASE_DIR/before.json"
  qa_scan
  cmp "$dir/pending.json" "$CASE_DIR/before.json"
  qa_scan
  cmp "$dir/pending.json" "$CASE_DIR/before.json"
}
qa_wait_events() {
  local count=$1
  for _ in {1..200}; do
    if [ -f "$DV_HOME/cursor" ] && [ "$(cat "$DV_HOME/cursor")" -ge "$count" ] &&
      [ "$(cat "$DV_HOME/cursor")" -ge "$(wc -l < "$DV_HOME/kick.q")" ]; then return; fi
    sleep 0.1
  done
  return 1
}
case_qa_merge_api_retry() {
  qa_merge_fixture
  touch "$GH_STUB_DIR/qa-api-fail"
  qa_scan
  test ! -f "$DV_HOME"/qa/*/observed.json
  rm "$GH_STUB_DIR/qa-api-fail"
  qa_scan
  jq -e '.prs|length==1' "$DV_HOME"/qa/*/pending.json
}
case_qa_merge_base_membership() {
  qa_merge_fixture
  touch "$GH_STUB_DIR/qa-diverged"
  qa_scan
  test ! -f "$DV_HOME"/qa/*/pending.json
  test ! -f "$DV_HOME"/qa/*/observed.json
  rm "$GH_STUB_DIR/qa-diverged"
  qa_scan
  jq -e '.base=="main"' "$DV_HOME"/qa/*/pending.json
}
case_qa_merge_missing_state() {
  qa_direct_fixture
  rm -r "$DV_STATE"
  qa_direct_run
  test "$qa_rc" = 0
  jq -e '.status=="done"' "$DV_STATE"/QA-*/meta
}
qa_merge_add() {
  local number=$1 timestamp=$2
  printf '%s\n' "$number" >> "$REPO/base"
  git -C "$REPO" commit -qam "merge PR $number"
  git -C "$REPO" push -q origin main
  jq --argjson number "$number" --arg timestamp "$timestamp" --arg head "$(git -C "$REPO" rev-parse HEAD)" \
    '.number=$number | .merged_at=$timestamp | .merge_commit_sha=$head' "$GH_STUB_DIR/qa-pr" >> "$GH_STUB_DIR/qa-merges"
}
case_qa_merge_startup_catchup() {
  qa_merge_fixture
  qa_scan
  local dir request
  dir=$(dirname "$DV_HOME"/qa/*/pending.json)
  mv "$dir/pending.json" "$CASE_DIR/previous-qa.json"
  qa_merge_add 8 2026-10-22T00:02:00Z
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  request="$dir/pending.json"
  wait_file "$request"
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  jq -e --arg head "$(git -C "$REPO" rev-parse HEAD)" '.head==$head and [.prs[].number]==[8]' "$request"
}
case_qa_merge_legacy_catchup() {
  qa_merge_fixture
  mkdir "$DV_STATE/QA-old"
  jq -n --arg head "$(git -C "$REPO" rev-parse HEAD)" \
    '{repository:"test/repo",base:"main",head:$head,status:"done",done_at:1}' > "$DV_STATE/QA-old/meta"
  qa_merge_add 8 2026-10-22T00:02:00Z
  qa_scan
  jq -e '[.prs[].number]==[8]' "$DV_HOME"/qa/*/pending.json
}
case_qa_merge_disabled_pending() {
  qa_merge_fixture
  export DV_QA_COALESCE=0
  qa_scan
  printf 'DV_QA=0\n' > "$REPO/.devflow"
  qa_dispatch
  test ! -d "$DV_HOME/submissions"
  test -f "$DV_HOME"/qa/*/pending.json
}
qa_spread_teardown() {
  touch "$CASE_DIR/qa-release"
  local pidfile
  for pidfile in "$CASE_DIR"/hosts/*/state/.qa/*/runner.pid; do
    teardown_stop_pidfile "$pidfile"
  done
  qa_teardown
}
case_qa_merge_spread() {
  qa_merge_fixture
  trap qa_spread_teardown EXIT
  export SSH_BIDDING=1 DV_HOSTS='hx-linux go2-linux' DV_AWARD_TIMEOUT=10 DV_BID_TIMEOUT=5
  local host repository issue request dir
  git config --file "$GIT_CONFIG_GLOBAL" url."$CASE_DIR/remote.git".insteadOf https://github.com/test/repo.git
  git config --file "$GIT_CONFIG_GLOBAL" --add url."$CASE_DIR/remote.git".insteadOf https://github.com/test/other.git
  for host in hx-linux go2-linux; do
    mkdir -p "$CASE_DIR/hosts/$host"
    cat > "$CASE_DIR/hosts/$host/config" <<CONFIG
DV_HOST=$host
DV_STATE='$CASE_DIR/hosts/$host/state'
DV_WORK='$CASE_DIR/hosts/$host/work'
DV_MAX_JOBS=1
CONFIG
  done
  for repository in test/repo test/other; do
    issue=$(qa_job_id "$repository" "$(git -C "$REPO" rev-parse HEAD)")
    request=$(jq -cn --arg issue "$issue" --arg repository "$repository" --arg head "$(git -C "$REPO" rev-parse HEAD)" \
      --slurpfile prs "$GH_STUB_DIR/qa-merges" \
      '{kind:"qa",issue:$issue,repo:("https://github.com/"+$repository+".git"),slug:"qa",agent:"codex",mode:"exec",base:"main",brief:"Synthetic QA",
        qa:{repository:$repository,remote:("https://github.com/"+$repository+".git"),base:"main",head:$head,agent:"codex",prs:$prs}}')
    printf '%s\n' "$request" | dv _submit
    dir="$DV_HOME/submissions/$issue"
    bid_schedule_one "$dir"
    jq '{status,host,reason}' "$dir/task.json"
    cat "$dir/dispatch.log"
    jq -e '.status=="working"' "$dir/task.json"
  done
  qa_wait_runs 2
  jq -se '[.[].host]|sort==["go2-linux","hx-linux"]' "$DV_HOME"/submissions/QA-*/task.json
  for host in hx-linux go2-linux; do
    bid_rpc "$host" bid --kind qa --json --repo https://github.com/test/repo.git | jq -e '.active==1 and .free_slots==0 and .reason=="full"'
  done
  touch "$CASE_DIR/qa-release"
  for host in hx-linux go2-linux; do
    for dir in "$CASE_DIR/hosts/$host/state"/QA-*; do wait_file "$dir/agent.exit"; test "$(cat "$dir/agent.exit")" = 0; done
  done
  test ! -f "$CASE_DIR/qa-overlap"
}
case_qa_merge_event_wake() {
  qa_merge_fixture
  export DV_RECONCILE_INTERVAL=99999 DV_STALL_AFTER=1
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  local request kind count
  request="$(qa_dir test/repo main)/pending.json"
  wait_file "$request"
  qa_merge_add 8 2026-10-22T00:02:00Z
  # The fast status safety tick must not poll GitHub for QA.
  sleep 2
  jq -e '[.prs[].number]==[7]' "$request"
  count=$(grep -c 'pulls?state=closed' "$GH_STUB_DIR/calls")
  for kind in merged done landed failed submitted bid-changed issue-opened issue-closed; do
    dv-kick "$kind" WAKE "$kind" test-host '' "qa-$kind"
    for _ in {1..100}; do
      if [ "$(grep -c 'pulls?state=closed' "$GH_STUB_DIR/calls")" -gt "$count" ]; then break; fi
      sleep 0.1
    done
    test "$(grep -c 'pulls?state=closed' "$GH_STUB_DIR/calls")" -gt "$count"
    count=$(grep -c 'pulls?state=closed' "$GH_STUB_DIR/calls")
  done
  jq -e '[.prs[].number]==[7,8]' "$request"
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
}
