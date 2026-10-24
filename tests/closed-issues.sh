#!/usr/bin/env bash
# Closed-issue reconciliation uses local bare remotes and the fake exec agent.
closed_issue_fixture() {
  exec_setup hold remote
  dv start "$REPO" CI-373 closed --mode exec
  wait_file "$DV_STATE/CI-373/stub-runs.jsonl"
  CLOSED_WT=$(jq -r .worktree "$DV_STATE/CI-373/meta")
  git -C "$CLOSED_WT" commit --allow-empty -qm 'fix(fixture): retain work'
  printf 'unfinished\n' > "$CLOSED_WT/dirty"
  printf '{"state":"closed"}\n' > "$GH_STUB_DIR/issue-373.json"
}
closed_issue_assert() {
  local branch
  jq -e '.status=="closed" and .reason=="issue closed" and .closed_at!=null' "$DV_STATE/CI-373/meta"
  dv status CI-373 --json | jq -e '.[0].alive==false'
  branch=$(jq -r .branch "$DV_STATE/CI-373/meta")
  test "$(git --git-dir="$CASE_DIR/remote.git" rev-parse "refs/heads/$branch")" = "$(git -C "$CLOSED_WT" rev-parse HEAD)"
  test "$(cat "$CLOSED_WT/dirty")" = unfinished
  test "$(event_count CI-373 closed)" = 1
  bidding_functions
  test "$(bid_active)" = 0
}
case_reconcile_closed_issue() {
  closed_issue_fixture
  dv _pr-reconcile-sweep
  closed_issue_assert
  dv _pr-reconcile-sweep
  test "$(event_count CI-373 closed)" = 1
}
case_reconcile_closed_event() {
  closed_issue_fixture
  watch_fixture
  export DV_RECONCILE_INTERVAL=3600 DV_STALL_SCAN_INTERVAL=3600 DV_APPSERVER_POLL=3600
  # Suppress the periodic scan: only the issue-closed event can wake this pass.
  local dir
  dir="$DV_HOME/reconcile/$(printf '%s' "$DV_HOST" | cksum | awk '{print $1 "-" $2}')"
  mkdir -p "$dir"
  date +%s > "$dir/status-at"
  date +%s > "$dir/recovery-at"
  dv kick issue-closed CI-373 https://github.com/test/repo/issues/373
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  for _ in {1..100}; do
    if jq -e '.status=="closed"' "$DV_STATE/CI-373/meta" >/dev/null; then break; fi
    sleep 0.1
  done
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  pr_sweep_wait
  closed_issue_assert
}
case_reconcile_submission_terminal() {
  repo submissions
  export DV_MANAGER_HOST="$DV_HOST"
  local issue status token
  for status in closed failed landed; do
    issue="Q-$status"
    running_job "$issue"
    mkdir -p "$DV_HOME/submissions/$issue"
    jq -n --arg issue "$issue" --arg host "$DV_HOST" \
      '{issue:$issue,status:"working",host:$host,token:"current",submitted_at:1,attempts:[{token:"current"}]}' > "$DV_HOME/submissions/$issue/task.json"
    jq --arg status "$status" '.status=$status | .award_token="current" | .reason="issue closed"' "$DV_STATE/$issue/meta" > "$CASE_DIR/meta"
    mv "$CASE_DIR/meta" "$DV_STATE/$issue/meta"
  done
  # Neither another host nor an old award may retire the current assignment.
  for token in old other; do
    issue="Q-$token"
    running_job "$issue"
    mkdir -p "$DV_HOME/submissions/$issue"
    jq -n --arg issue "$issue" --arg host "$DV_HOST" --arg token "$token" \
      '{issue:$issue,status:"working",host:(if $token=="other" then "another-host" else $host end),token:"current",submitted_at:1}' > "$DV_HOME/submissions/$issue/task.json"
    jq --arg token "$token" '.status="closed" | .award_token=$token' "$DV_STATE/$issue/meta" > "$CASE_DIR/meta"
    mv "$CASE_DIR/meta" "$DV_STATE/$issue/meta"
  done
  mkdir -p "$DV_HOME/reconcile/$(printf '%s' "$DV_HOST" | cksum | awk '{print $1 "-" $2}')"
  dv _reconcile-host "$DV_HOST" 60 1 0
  dv queue --json > "$CASE_DIR/queue.json"
  jq -e 'map(select(.issue=="Q-closed" or .issue=="Q-failed" or .issue=="Q-landed")) | length==3 and all(.[]; .status!="working" and .attempts==[{token:"current"}])' "$CASE_DIR/queue.json"
  jq -e 'map(select(.issue=="Q-old" or .issue=="Q-other")) | length==2 and all(.[]; .status=="working")' "$CASE_DIR/queue.json"
}
case_reconcile_closed_guards() {
  closed_issue_fixture
  local body
  printf '{"state":"open"}\n' > "$GH_STUB_DIR/issue-373.json"
  dv _issue-reconcile CI-373
  printf '{"state":"closed"}\n' > "$GH_STUB_DIR/issue-373.json"
  for body in 'Closes #373' 'Fixes test/repo#373' 'Resolves https://github.com/TEST/repo/issues/373'; do
    jq -n --arg body "$body" '[{body:$body}]' > "$GH_STUB_DIR/open-prs"
    dv _issue-reconcile CI-373
    dv status CI-373 --json | jq -e '.[0].alive and .[0].status=="running"'
  done
  touch "$GH_STUB_DIR/open-prs-fail"
  if dv _issue-reconcile CI-373; then return 1; fi
  rm "$GH_STUB_DIR/open-prs-fail"
  printf '[{"body":23}]\n' > "$GH_STUB_DIR/open-prs"
  if dv _issue-reconcile CI-373; then return 1; fi
  # Explicit issue metadata takes precedence over a numeric job suffix.
  jq '.source_issue=374' "$DV_STATE/CI-373/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/CI-373/meta"
  printf '{"state":"open"}\n' > "$GH_STUB_DIR/issue-374.json"
  dv _issue-reconcile CI-373
  dv status CI-373 --json | jq -e '.[0].alive and .[0].status=="running"'
  test ! -f "$DV_STATE/CI-373/events.log"
  printf '{"state":"closed"}\n' > "$GH_STUB_DIR/issue-374.json"
  # Other repos, other numbers, and prose mentions are not closing links.
  printf '[{"body":"Closes other/repo#374; Closes #3740; related #374"}]\n' > "$GH_STUB_DIR/open-prs"
  dv _issue-reconcile CI-373
  closed_issue_assert
}
case_reconcile_closed_push_retry() {
  closed_issue_fixture
  cat > "$CASE_DIR/remote.git/hooks/pre-receive" <<'HOOK'
#!/bin/sh
exit 1
HOOK
  chmod +x "$CASE_DIR/remote.git/hooks/pre-receive"
  if dv _issue-reconcile CI-373; then return 1; fi
  jq -e '.status=="running"' "$DV_STATE/CI-373/meta"
  test -f "$CLOSED_WT/dirty"
  test ! -f "$DV_STATE/CI-373/events.log"
  rm "$CASE_DIR/remote.git/hooks/pre-receive"
  dv _issue-reconcile CI-373
  closed_issue_assert
}
case_reconcile_closed_submission_event() {
  bidding_functions
  export DV_MANAGER_HOST="$DV_HOST"
  mkdir -p "$DV_HOME/submissions/CI-373"
  jq -n --arg host "$DV_HOST" '{issue:"CI-373",status:"working",host:$host,token:"current",submitted_at:1}' > "$DV_HOME/submissions/CI-373/task.json"
  bid_event "$(event_json closed CI-373 'issue closed' "$DV_HOST" saved '' current)"
  jq -e '.status=="canceled" and .reason=="issue closed"' "$DV_HOME/submissions/CI-373/task.json"
}
case_reconcile_closed_waiter() {
  repo closed_waiter remote
  stale_job CI-373 pr 1
  printf '{"state":"closed"}\n' > "$GH_STUB_DIR/issue-373.json"
  dv _issue-reconcile CI-373
  dv pr-wait CI-373 --foreground
  jq -e '.status=="closed"' "$DV_STATE/CI-373/meta"
  test ! -f "$DV_STATE/CI-373/pr-ready.json"
}
case_reconcile_closed_appserver() {
  appserver_setup remote
  printf '{"state":"closed"}\n' > "$GH_STUB_DIR/issue-1.json"
  dv _issue-reconcile AS-1
  dv status AS-1 --json | jq -e '.[0].status=="closed" and (.[0].alive|not)'
  jq -se 'any(.[]; .method=="turn/interrupt")' "$CASE_DIR/server/requests"
  test -d "$(jq -r .worktree "$DV_STATE/AS-1/meta")"
}
case_reconcile_closed_tmux() {
  needs_tmux
  repo closed_tmux remote
  cat > "$CASE_DIR/held-agent" <<'AGENT'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$DV_STATE/$DV_ISSUE/held.pid"
while :; do sleep 0.1; done
AGENT
  chmod +x "$CASE_DIR/held-agent"
  export DV_AGENT_CMD_codex="$CASE_DIR/held-agent"
  start CI-373
  wait_file "$DV_STATE/CI-373/held.pid"
  printf '{"state":"closed"}\n' > "$GH_STUB_DIR/issue-373.json"
  dv _issue-reconcile CI-373
  dv status CI-373 --json | jq -e '.[0].status=="closed" and (.[0].alive|not)'
  if kill -0 "$(cat "$DV_STATE/CI-373/held.pid")" 2>/dev/null; then return 1; fi
}
case_reconcile_closed_merged_pr() {
  repo closed_merged remote
  stale_job CM-373 ready 11
  printf '{"state":"closed"}\n' > "$GH_STUB_DIR/issue-373.json"
  printf '{"11":"MERGED"}\n' > "$GH_STUB_DIR/pr-states"
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]\n' > "$GH_STUB_DIR/checks"
  dv _pr-reconcile-sweep
  jq -e '.status=="ready"' "$DV_STATE/CM-373/meta"
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]\n' > "$GH_STUB_DIR/checks"
  dv _pr-reconcile-sweep
  jq -e '.status=="landed"' "$DV_STATE/CM-373/meta"
  test "$(event_count CM-373 landed)" = 1
  test "$(event_count CM-373 closed)" = 0
}
