#!/usr/bin/env bash
# Synthetic GitHub responses, host bids and awards; no real agents or network.
# shellcheck disable=SC2016
autofill_fixture() {
  repo autofill
  bidding_functions
  # shellcheck source=lib/manager.sh
  source "$ROOT/lib/manager.sh"
  # shellcheck source=lib/autofill.sh
  source "$ROOT/lib/autofill.sh"
  export DV_MANAGER_HOST="$DV_HOST" DV_HOSTS='worker-a worker-b'
  export DV_AUTOFILL_REPOS='test/repo' DV_AUTOFILL_BRIEF_test_repo="$CASE_DIR/brief"
  mkdir -p "$CASE_DIR/autofill"
  printf '[]\n' > "$CASE_DIR/autofill/issues"
  printf '{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}\n' > "$CASE_DIR/autofill/prs"
  printf '2\n' > "$CASE_DIR/autofill/free"
  gh() {
    printf '%s\n' "$*" >> "$CASE_DIR/autofill/calls"
    case "$*" in
      'api --paginate repos/test/'*'/issues?state=open&per_page=100') cat "$CASE_DIR/autofill/issues" ;;
      'api graphql '*pullRequest\(number*) cat "$CASE_DIR/autofill/pr-refs" ;;
      'api graphql '*) cat "$CASE_DIR/autofill/prs" ;;
      'api --paginate repos/test/repo/issues/'*'/sub_issues?per_page=100') cat "$CASE_DIR/autofill/children" ;;
      'api repos/test/repo/issues/'*)
        local number=${2##*/}
        if [ -f "$CASE_DIR/autofill/issue-$number" ]; then cat "$CASE_DIR/autofill/issue-$number"
        else jq -e --argjson n "$number" '.[] | select(.number==$n)' "$CASE_DIR/autofill/issues"; fi ;;
      'api -H Accept:application/vnd.github.raw+json repos/test/'*'/contents/.devflow/brief.md') cat "$CASE_DIR/brief" ;;
      *) printf 'Unexpected autofill gh: %s\n' "$*" >&2; return 1 ;;
    esac
  }
  bid_rpc() {
    local host=$1 action=$2 free
    case "$action" in
      bid)
        free=$(cat "$CASE_DIR/autofill/free")
        [ "$host" != worker-b ] || free=0
        jq -cn --arg host "$host" --argjson free "$free" \
          '{host:$host,status:(if $free>0 then "submitted" else "rejected" end),capacity:2,effective_slots:2,active:(2-$free),free_slots:$free,score:100,reason:(if $free>0 then "" else "full" end)}' ;;
      _award)
        local request
        request=$(cat)
        if [ -f "$CASE_DIR/autofill/reject" ]; then printf '{"status":"rejected","reason":"full"}\n'; return; fi
        jq -r .issue <<< "$request" >> "$CASE_DIR/autofill/awards"
        free=$(cat "$CASE_DIR/autofill/free"); printf '%s\n' "$((free-1))" > "$CASE_DIR/autofill/free"
        jq '{token,status:"working",head:"fake-head"}' <<< "$request" ;;
      _submit) cmd__submit ;;
      *) return 1 ;;
    esac
  }
}
autofill_issues() {
  jq -cn '[range(1;6) | {number:.,title:("Issue "+tostring),body:"",state:"open",html_url:("https://github.com/test/repo/issues/"+tostring),labels:[],milestone:{number:1,state:"open"},sub_issues_summary:{total:0,completed:0}}]' > "$CASE_DIR/autofill/issues"
}
case_autofill_submit() {
  autofill_fixture; autofill_issues
  autofill_tick
  test "$(wc -l < "$CASE_DIR/autofill/awards" | tr -d ' ')" = 2
  jq -se 'length==2 and all(.status=="working")' "$DV_HOME"/submissions/*/task.json
  autofill_tick
  test "$(wc -l < "$CASE_DIR/autofill/awards" | tr -d ' ')" = 2
  autofill_summary --json | jq -e '.free_slots==0 and .ready_not_started==3 and (.hosts|length)==2 and (.reason|length)>0'
}
case_autofill_branch_slug() {
  # Autofilled jobs get <type>/<n>-<slug> branches from the issue title and
  # label, never the issue number twice.
  autofill_fixture; autofill_issues
  jq '.[0].title="Fix login crash after restart" | .[0].labels=[{name:"bug"}] |
      .[1].title="Explain: the PR format!" | .[1].labels=[{name:"Documentation"}]' \
    "$CASE_DIR/autofill/issues" > "$CASE_DIR/autofill/next"
  mv "$CASE_DIR/autofill/next" "$CASE_DIR/autofill/issues"
  autofill_tick
  jq -se 'map({(.github_issue|tostring):.slug}) | add == {"1":"fix-login-crash-after-restart","2":"docs-explain-the-pr-format"}' \
    "$DV_HOME"/submissions/*/task.json
  # shellcheck source=lib/commands.sh
  source "$ROOT/lib/commands.sh"
  test "$(issue_branch "$(autofill_id test/repo 1)" fix-login-crash-after-restart)" = fix/1-login-crash-after-restart
  test "$(issue_branch "$(autofill_id test/repo 2)" docs-explain-the-pr-format)" = docs/2-explain-the-pr-format
}
case_autofill_dependencies() {
  autofill_fixture; autofill_issues
  jq '.[0].body="Depends on #90" | .[1].body="Depends on #91" | .[2].body="Depends on #92" |
      .[3].labels=[{name:"needs-owner"}] | .[4].sub_issues_summary={total:2,completed:1}' \
    "$CASE_DIR/autofill/issues" > "$CASE_DIR/autofill/next"
  mv "$CASE_DIR/autofill/next" "$CASE_DIR/autofill/issues"
  printf '{"state":"open"}\n' > "$CASE_DIR/autofill/issue-90"
  printf '{"state":"closed"}\n' > "$CASE_DIR/autofill/issue-91"
  printf '{"state":"open"}\n' > "$CASE_DIR/autofill/issue-92"
  jq '.data.repository.pullRequests.nodes=[{number:101,url:"https://github.com/test/repo/pull/101",closingIssuesReferences:{nodes:[{number:92,repository:{nameWithOwner:"test/repo"}}],pageInfo:{hasNextPage:false}}}]' \
    "$CASE_DIR/autofill/prs" > "$CASE_DIR/autofill/next"
  mv "$CASE_DIR/autofill/next" "$CASE_DIR/autofill/prs"
  autofill_tick
  jq -se 'map(.github_issue)|sort==[2,3]' "$DV_HOME"/submissions/*/task.json
  jq -se 'any(.[]; .github_issue==3 and (.brief|contains("Depends on #101")))' "$DV_HOME"/submissions/*/task.json
}
case_autofill_order() {
  autofill_fixture; autofill_issues
  jq '.[0].milestone.number=2 | .[1].labels=[{name:"qa"}] | .[2].milestone=null |
      .[3].milestone.number=2 | .[3].labels=[{name:"qa"}]' "$CASE_DIR/autofill/issues" > "$CASE_DIR/autofill/next"
  mv "$CASE_DIR/autofill/next" "$CASE_DIR/autofill/issues"
  autofill_tick
  test "$(sed -n '1p' "$CASE_DIR/autofill/awards" | sed 's/.*-//')" = 2
  test "$(sed -n '2p' "$CASE_DIR/autofill/awards" | sed 's/.*-//')" = 5
  printf '2\n' > "$CASE_DIR/autofill/free"
  autofill_tick
  test "$(sed -n '3p' "$CASE_DIR/autofill/awards" | sed 's/.*-//')" = 4
  test "$(sed -n '4p' "$CASE_DIR/autofill/awards" | sed 's/.*-//')" = 1
}
case_autofill_alarm() {
  autofill_fixture; autofill_issues
  touch "$CASE_DIR/autofill/reject"
  now() { cat "$CASE_DIR/autofill/clock"; }
  printf '1000\n' > "$CASE_DIR/autofill/clock"
  autofill_tick
  jq -se 'length==2' "$DV_HOME"/submissions/*/task.json
  printf '1600\n' > "$CASE_DIR/autofill/clock"
  autofill_tick
  test ! -f "$DV_HOME/autofill/alarm.json"
  printf '1601\n' > "$CASE_DIR/autofill/clock"
  autofill_tick
  jq -e '.kind=="stalled" and .reason=="fleet-underused" and .audience=="manager"' "$DV_HOME/autofill/alarm.json"
  autofill_tick
  test "$(wc -l < "$DV_HOME/autofill/events.log" | tr -d ' ')" = 1
  autofill_summary --json | jq -e '.ready_not_started==5 and .free_slots==2 and (.reason|length)>0'
}
case_autofill_duplicates() {
  autofill_fixture; autofill_issues
  # A legacy manual submission must suppress the same GitHub issue.
  mkdir -p "$DV_HOME/submissions/APP-1"
  printf '{"repo":"git@github.com:test/repo.git","issue":"APP-1","status":"working"}\n' > "$DV_HOME/submissions/APP-1/task.json"
  jq '.data.repository.pullRequests.nodes=[{number:100,url:"https://github.com/test/repo/pull/100",closingIssuesReferences:{nodes:[{number:2,repository:{nameWithOwner:"test/repo"}}],pageInfo:{hasNextPage:false}}}]' \
    "$CASE_DIR/autofill/prs" > "$CASE_DIR/autofill/next"
  mv "$CASE_DIR/autofill/next" "$CASE_DIR/autofill/prs"
  autofill_tick
  test "$(sed -n '1p' "$CASE_DIR/autofill/awards" | sed 's/.*-//')" = 3
  test "$(sed -n '2p' "$CASE_DIR/autofill/awards" | sed 's/.*-//')" = 4
}
case_autofill_errors() {
  autofill_fixture; autofill_issues
  printf '{"message":"rate limit"}\n' > "$CASE_DIR/autofill/prs"
  autofill_tick
  test ! -f "$CASE_DIR/autofill/awards"
  autofill_summary --json | jq -e '(.errors|length)==1 and .reason=="readiness lookup incomplete"'
  DV_AUTOFILL_REPOS=''
  : > "$CASE_DIR/autofill/calls"
  autofill_tick
  test ! -s "$CASE_DIR/autofill/calls"
}
case_autofill_brief() {
  autofill_fixture; autofill_issues
  unset DV_AUTOFILL_BRIEF_test_repo
  autofill_tick
  grep -F 'contents/.devflow/brief.md' "$CASE_DIR/autofill/calls"
  jq -se 'all(.brief|contains("Implement one file.") and contains("Closes #") and contains("--comments"))' "$DV_HOME"/submissions/*/task.json
}
case_autofill_missing_brief() {
  autofill_fixture; autofill_issues
  DV_AUTOFILL_BRIEF_test_repo="$CASE_DIR/missing"
  autofill_tick
  test ! -f "$CASE_DIR/autofill/awards"
  jq -e '.ready_not_started==5 and all(.ready[]; .reason=="brief unavailable")' "$DV_HOME/autofill/summary.json"
}
case_autofill_manager_alarm() {
  autofill_fixture; autofill_issues
  local dir
  dir=$(manager_dir https://github.com/test/repo.git)
  mkdir -p "$dir"
  printf '{"identity":"github.com/test/repo","enabled":true}\n' > "$dir/meta.json"
  touch "$CASE_DIR/autofill/reject"
  now() { cat "$CASE_DIR/autofill/clock"; }
  printf '1000\n' > "$CASE_DIR/autofill/clock"
  autofill_tick
  printf '1601\n' > "$CASE_DIR/autofill/clock"
  autofill_tick
  jq -e '.reason=="fleet-underused" and .audience=="manager"' "$dir"/notices/*.json
  # The alarm cannot enter the owner or ordinary worker event path.
  jq -se 'all(.kind=="submitted" or .kind=="bid-changed")' "$DV_HOME/kick.q"
  printf '0\n' > "$CASE_DIR/autofill/free"
  autofill_tick
  test ! -f "$DV_HOME/autofill/underused-since"
}
case_autofill_watch() {
  autofill_fixture; autofill_issues
  # Run the real watcher with executable gh/SSH stubs, no in-process shortcuts.
  mkdir -p "$CASE_DIR/autofill/bin"
  cat > "$CASE_DIR/autofill/bin/gh" <<'STUB'
#!/usr/bin/env bash
exec "$ROOT/tests/fixtures/autofill-host" gh "$@"
STUB
  cat > "$CASE_DIR/autofill/bin/ssh" <<'STUB'
#!/usr/bin/env bash
exec "$ROOT/tests/fixtures/autofill-host" ssh "$@"
STUB
  chmod +x "$CASE_DIR/autofill/bin/gh" "$CASE_DIR/autofill/bin/ssh"
  export PATH="$CASE_DIR/autofill/bin:$PATH" DV_HOSTS=worker-a DV_PULL_HOSTS=''
  export DV_WORKER_CMD="$ROOT/tests/fixtures/worker" DV_WATCH_INTERVAL=0.1
  # The manager's own CLI _submit uses the real durable submission path.
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & local watcher=$!
  local attempt count
  for attempt in {1..200}; do
    if [ -f "$CASE_DIR/autofill/awards" ] && [ "$(wc -l < "$CASE_DIR/autofill/awards" | tr -d ' ')" = 2 ]; then break; fi
    sleep 0.1
  done
  test "$(wc -l < "$CASE_DIR/autofill/awards" | tr -d ' ')" = 2
  dv queue --summary --json | jq -e '.ready_not_started==3 and .free_slots==0 and .running==2'
  for attempt in {1..200}; do
    if [ -f "$DV_HOME/autofill/hosts/worker-a.json" ] &&
      jq -e '.free_slots==0' "$DV_HOME/autofill/hosts/worker-a.json" >/dev/null &&
      [ "$(cat "$DV_HOME/cursor")" = "$(wc -l < "$DV_HOME/kick.q" | tr -d ' ')" ]; then break; fi
    sleep 0.1
  done
  count=$(wc -l < "$CASE_DIR/autofill/calls")
  local samples
  samples=$(wc -l < "$DV_STATE/.host-capacity/samples.jsonl")
  sleep 0.5
  test "$(wc -l < "$CASE_DIR/autofill/calls")" = "$count"
  test "$(wc -l < "$DV_STATE/.host-capacity/samples.jsonl")" -gt "$samples"
  # No process restart or external fill script: an event frees and fills a slot.
  printf '1\n' > "$CASE_DIR/autofill/free"
  dv-kick 'done' "$(head -n 1 "$CASE_DIR/autofill/awards")" 'fake completion' worker-a fake-head
  for attempt in {1..200}; do
    if [ "$(wc -l < "$CASE_DIR/autofill/awards" | tr -d ' ')" = 3 ]; then break; fi
    sleep 0.1
  done
  touch "$DV_HOME/stop"; wait "$watcher"
  cat "$CASE_DIR/watch.log"
  test "$(wc -l < "$CASE_DIR/autofill/awards" | tr -d ' ')" = 3
}
case_autofill_pages() {
  autofill_fixture; autofill_issues
  # REST and both GraphQL connections can return multiple JSON pages.
  cat "$CASE_DIR/autofill/issues" > "$CASE_DIR/autofill/next"
  printf '[]\n' >> "$CASE_DIR/autofill/next"
  mv "$CASE_DIR/autofill/next" "$CASE_DIR/autofill/issues"
  jq '.data.repository.pullRequests.nodes=[{number:100,url:"https://github.com/test/repo/pull/100",closingIssuesReferences:{nodes:[],pageInfo:{hasNextPage:true}}}]' \
    "$CASE_DIR/autofill/prs" > "$CASE_DIR/autofill/next"
  mv "$CASE_DIR/autofill/next" "$CASE_DIR/autofill/prs"
  printf '{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"nodes":[{"number":1,"repository":{"nameWithOwner":"test/repo"}}]}}}}}\n' > "$CASE_DIR/autofill/pr-refs"
  printf '{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"nodes":[{"number":2,"repository":{"nameWithOwner":"test/repo"}}]}}}}}\n' >> "$CASE_DIR/autofill/pr-refs"
  autofill_tick
  test "$(sed -n '1p' "$CASE_DIR/autofill/awards" | sed 's/.*-//')" = 3
  test "$(sed -n '2p' "$CASE_DIR/autofill/awards" | sed 's/.*-//')" = 4
}
case_autofill_children() {
  autofill_fixture; autofill_issues
  jq 'map(del(.sub_issues_summary))' "$CASE_DIR/autofill/issues" > "$CASE_DIR/autofill/next"
  mv "$CASE_DIR/autofill/next" "$CASE_DIR/autofill/issues"
  printf '[{"state":"closed"}]\n[{"state":"open"}]\n' > "$CASE_DIR/autofill/children"
  autofill_tick
  test ! -f "$CASE_DIR/autofill/awards"
  printf '[{"state":"closed"}]\n[]\n' > "$CASE_DIR/autofill/children"
  autofill_tick
  test "$(wc -l < "$CASE_DIR/autofill/awards" | tr -d ' ')" = 2
}
case_autofill_shared_hosts() {
  autofill_fixture; autofill_issues
  DV_AUTOFILL_REPOS='test/repo test/other'
  autofill_tick
  test "$(wc -l < "$CASE_DIR/autofill/awards" | tr -d ' ')" = 2
  autofill_summary --json | jq -e '.effective_slots==4 and .running==4 and .free_slots==0 and (.hosts|length)==2 and .ready_not_started==8'
}
case_autofill_event_cadence() {
  autofill_fixture; autofill_issues
  local count
  # No per-check timer: only an explicit event or the existing slow sweep.
  autofill_event '{"kind":"issue-opened"}'
  test "$(wc -l < "$CASE_DIR/autofill/awards" | tr -d ' ')" = 2
  count=$(wc -l < "$CASE_DIR/autofill/calls")
  autofill_event '{"kind":"question"}'
  test "$(wc -l < "$CASE_DIR/autofill/calls")" = "$count"
  printf '1\n' > "$CASE_DIR/autofill/free"
  autofill_event '{"kind":"bid-changed"}'
  test "$(wc -l < "$CASE_DIR/autofill/awards" | tr -d ' ')" = 3
  printf '1\n' > "$CASE_DIR/autofill/free"
  autofill_event '{"kind":"issue-closed"}'
  test "$(wc -l < "$CASE_DIR/autofill/awards" | tr -d ' ')" = 4
}
case_autofill_repository_events() {
  autofill_fixture; autofill_issues
  # The shared GitHub feed wakes both QA and autofill after repository changes.
  autofill_event '{"kind":"qa-repository"}'
  test "$(wc -l < "$CASE_DIR/autofill/awards" | tr -d ' ')" = 2
  printf '1\n' > "$CASE_DIR/autofill/free"
  autofill_event '{"kind":"merged"}'
  test "$(wc -l < "$CASE_DIR/autofill/awards" | tr -d ' ')" = 3
}
case_autofill_slot_release_events() {
  autofill_fixture; autofill_issues
  autofill_event '{"kind":"parked"}'
  test "$(wc -l < "$CASE_DIR/autofill/awards" | tr -d ' ')" = 2
  printf '1\n' > "$CASE_DIR/autofill/free"
  autofill_event '{"kind":"closed"}'
  test "$(wc -l < "$CASE_DIR/autofill/awards" | tr -d ' ')" = 3
}
case_autofill_cancel_event() {
  autofill_fixture; autofill_issues
  touch "$CASE_DIR/autofill/reject"
  autofill_tick
  local issue
  issue=$(autofill_id test/repo 1)
  cmd_cancel "$issue"
  jq -se --arg issue "$issue" '.[-1].kind=="canceled" and .[-1].issue==$issue' "$DV_HOME/kick.q"
  rm "$CASE_DIR/autofill/reject"
  autofill_event "$(tail -n 1 "$DV_HOME/kick.q")"
  test "$(wc -l < "$CASE_DIR/autofill/awards" | tr -d ' ')" = 2
  if grep -Fx "$issue" "$CASE_DIR/autofill/awards"; then return 1; fi
}
case_autofill_label_event() {
  autofill_fixture; autofill_issues
  autofill_event '{"kind":"issue-labeled"}'
  test "$(wc -l < "$CASE_DIR/autofill/awards" | tr -d ' ')" = 2
}
case_qa_merge_commit_event() {
  land_setup true true true
  touch "$GH_STUB_DIR/merged"
  # A merged PR is authoritative even if backend cleanup must be retried.
  bidding_functions
  # shellcheck source=lib/delivery.sh
  source "$ROOT/lib/delivery.sh"
  load_issue LAND-1
  cp "$GH_STUB_DIR/checks" "$CASE_DIR/checks"
  (cd "$LAND_WT" && gh pr view 1 --json state,headRefOid,baseRefName,statusCheckRollup) > "$S/land-checks.json"
  clean_worktree() { return 1; }
  if (github_land_reconcile "$(git -C "$LAND_WT" rev-parse HEAD)"); then return 1; fi
  jq -se 'any(.[]; .kind=="landed")' "$DV_STATE/LAND-1/events.log"
}
