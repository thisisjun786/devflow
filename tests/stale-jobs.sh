#!/usr/bin/env bash
# Stale-job reconciliation (#253): disposable repositories, the gh stub and
# synthetic job records stand in for agents, GitHub and remote hosts.
stale_job() {
  # A PR job as dv pr leaves it, without a live agent or waiter.
  local issue=$1 status=$2 number=$3 wt="$DV_WORK/$1" lower
  lower=$(printf '%s' "$issue" | tr '[:upper:]' '[:lower:]')
  git -C "$REPO" worktree add -qb "codex/$lower" "$wt"
  git -C "$wt" commit --allow-empty -qm "$issue: change"
  mkdir -p "$DV_STATE/$issue"
  jq -n --arg issue "$issue" --arg repo "$REPO" --arg wt "$wt" --arg branch "codex/$lower" --arg status "$status" \
    --arg head "$(git -C "$wt" rev-parse HEAD)" --arg pr "https://github.com/test/repo/pull/$number" \
    '{issue:$issue,repo:$repo,worktree:$wt,branch:$branch,base:"main",host:"test-host",agent:"codex",
      started:1,status:$status,head:$head,start_head:$head,pr:$pr}' > "$DV_STATE/$issue/meta"
  jq -n --arg url "https://github.com/test/repo/pull/$number" '{url:$url}' > "$DV_STATE/$issue/pr.json"
}
running_job() {
  # A running job whose agent is not attached; its worktree starts at main.
  local issue=$1 wt="$DV_WORK/$1" lower start=${2:-main}
  lower=$(printf '%s' "$issue" | tr '[:upper:]' '[:lower:]')
  git -C "$REPO" worktree add -qb "codex/$lower" "$wt" "$start"
  mkdir -p "$DV_STATE/$issue"
  jq -n --arg issue "$issue" --arg repo "$REPO" --arg wt "$wt" --arg branch "codex/$lower" \
    --arg head "$(git -C "$wt" rev-parse HEAD)" \
    '{issue:$issue,repo:$repo,worktree:$wt,branch:$branch,base:"main",host:"test-host",agent:"codex",
      mode:"goal",started:1,status:"running",start_head:$head}' > "$DV_STATE/$issue/meta"
}
pr_sweep_wait() {
  # The job host's PR sweep is detached from the watcher; let it finish.
  local holder
  sleep 0.3
  for _ in {1..100}; do
    holder=$(cat "$DV_STATE/.pr-reconcile/owner" 2>/dev/null) || return 0
    kill -0 "$holder" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}
event_count() { jq -se --arg kind "$2" '[.[]|select(.kind==$kind)]|length' "$DV_STATE/$1/events.log" 2>/dev/null || printf '0\n'; }
case_reconcile_stale_prs() {
  # One watcher pass closes merged PRs (ready or still pr), marks a PR closed
  # without merge, and leaves an open PR alone.
  repo stale remote; watch_fixture
  export DV_HOSTS="$DV_HOST" DV_RECONCILE_INTERVAL=1
  stale_job R-1 ready 11; stale_job R-2 pr 12; stale_job R-3 pr 13; stale_job R-4 ready 14
  printf '{"11":"MERGED","12":"MERGED","13":"CLOSED","14":"OPEN"}\n' > "$GH_STUB_DIR/pr-states"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  for _ in {1..100}; do
    jq -e '.status=="landed"' "$DV_STATE/R-1/meta" >/dev/null && jq -e '.status=="landed"' "$DV_STATE/R-2/meta" >/dev/null &&
      jq -e '.status=="closed"' "$DV_STATE/R-3/meta" >/dev/null && break
    sleep 0.1
  done
  # Later passes must not repeat the landing or the closing.
  sleep 2.5
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  pr_sweep_wait
  cat "$CASE_DIR/watch.log" "$DV_HOME/reconcile.log" 2>/dev/null || true
  for issue in R-1 R-2; do
    jq -e '.status=="landed" and .landed_at!=null' "$DV_STATE/$issue/meta"
    test ! -d "$DV_WORK/$issue"
    test "$(event_count "$issue" landed)" = 1
    jq -se --arg issue "$issue" '[.[]|select(.kind=="landed" and .issue==$issue)]|length==1' "$DV_HOME/kick.q"
  done
  jq -e '.status=="closed" and .closed_at!=null' "$DV_STATE/R-3/meta"
  test -d "$DV_WORK/R-3"
  test "$(event_count R-3 closed)" = 1
  test "$(event_count R-3 landed)" = 0
  jq -e '.status=="ready"' "$DV_STATE/R-4/meta"
  test -d "$DV_WORK/R-4"
  test ! -f "$DV_STATE/R-4/events.log"
  if grep '^pr merge ' "$GH_STUB_DIR/calls"; then return 1; fi
}
case_reconcile_merged_unverified() {
  # A merged PR keeps the dv land gates (#116): failing checks or a dirty
  # worktree are reported once to the manager, and nothing is removed.
  repo unverified remote
  stale_job U-1 ready 21
  printf '{"21":"MERGED"}\n' > "$GH_STUB_DIR/pr-states"
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]\n' > "$GH_STUB_DIR/checks"
  if dv _pr-reconcile U-1; then return 1; fi
  if dv _pr-reconcile U-1; then return 1; fi
  jq -e '.status=="ready"' "$DV_STATE/U-1/meta"
  test -d "$DV_WORK/U-1"
  test "$(event_count U-1 blocked)" = 1
  jq -se '[.[]|select(.kind=="blocked")][0].message|contains("all PR checks must be successful")' "$DV_STATE/U-1/events.log"
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]\n' > "$GH_STUB_DIR/checks"
  printf 'keep me\n' > "$DV_WORK/U-1/uncommitted"
  if dv _pr-reconcile U-1; then return 1; fi
  jq -e '.status=="ready"' "$DV_STATE/U-1/meta"
  test -f "$DV_WORK/U-1/uncommitted"
  test "$(event_count U-1 blocked)" = 2
  rm "$DV_WORK/U-1/uncommitted"
  dv _pr-reconcile U-1
  jq -e '.status=="landed"' "$DV_STATE/U-1/meta"
  test ! -d "$DV_WORK/U-1"
  test "$(event_count U-1 landed)" = 1
}
already_merged_fixture() {
  # Another PR (#423) merged the same fix into origin/main after AM-1 began.
  repo merged remote
  local start
  start=$(git -C "$REPO" rev-parse HEAD)
  running_job AM-1 "$start"
  git -C "$REPO" checkout -qb other
  printf 'fix\n' > "$REPO/fix"
  git -C "$REPO" add fix; git -C "$REPO" commit -qm 'Other: fix'
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge -q --no-ff -m 'Merge pull request #423' other
  git -C "$REPO" push -q origin main
  MERGE=$(git -C "$REPO" rev-parse HEAD)
  printf '{"423":"MERGED","424":"OPEN","425":"MERGED"}\n' > "$GH_STUB_DIR/pr-states"
  printf '{"425":"release"}\n' > "$GH_STUB_DIR/pr-bases"
  jq -n --arg merge "$MERGE" '{"423":$merge,"425":$merge}' > "$GH_STUB_DIR/merge-commits"
  AM_WT="$DV_WORK/AM-1"
  printf 'fix\n' > "$AM_WT/fix"
  git -C "$AM_WT" add fix; git -C "$AM_WT" commit -qm 'AM-1: same fix'
}
done_refused() {
  if dv 'done' AM-1 --already-merged "$1" > "$CASE_DIR/done.out" 2>&1; then
    cat "$CASE_DIR/done.out"; return 1
  fi
  cat "$CASE_DIR/done.out"
  grep -F -- "$2" "$CASE_DIR/done.out"
  test ! -f "$DV_STATE/AM-1/done.json"
  jq -e '.status=="running"' "$DV_STATE/AM-1/meta"
}
case_land_already_merged() {
  already_merged_fixture
  local head
  head=$(git -C "$AM_WT" rev-parse HEAD)
  dv 'done' AM-1 --already-merged 423 --note 'fixed by #423'
  jq -e --arg merge "$MERGE" --arg head "$head" \
    '.head==$head and .merged_via.commit==$merge and .merged_via.pr==423 and .merged_via.base=="main" and .checks==null' "$DV_STATE/AM-1/done.json"
  jq -e --arg head "$head" '.status=="ready" and .head==$head and .done_at!=null' "$DV_STATE/AM-1/meta"
  jq -se '[.[]|select(.kind=="done")]|length==1 and (.[0].message|contains("already-merged=") and contains("#423") and contains("fixed by #423"))' "$DV_HOME/kick.q"
  # A later plain completion (the exec wrapper) keeps the recorded delivery.
  dv 'done' AM-1
  jq -e --arg merge "$MERGE" '.merged_via.commit==$merge' "$DV_STATE/AM-1/done.json"
  dv land AM-1
  jq -e --arg merge "$MERGE" '.status=="landed" and .landed_at!=null and .merged_via.commit==$merge' "$DV_STATE/AM-1/meta"
  test ! -d "$AM_WT"
  dv land AM-1
  test "$(event_count AM-1 landed)" = 1
  if grep -E '^pr (merge|create) ' "$GH_STUB_DIR/calls"; then return 1; fi
  # The same verification accepts the merge commit itself.
  running_job AM-2 "$MERGE"
  dv 'done' AM-2 --already-merged "$MERGE"
  jq -e --arg merge "$MERGE" '.merged_via.commit==$merge and .merged_via.pr==null' "$DV_STATE/AM-2/done.json"
}
case_land_already_merged_guards() {
  already_merged_fixture
  local stray
  done_refused 424 'is not merged'
  done_refused 425 'not merged into main'
  stray=$(git -C "$REPO" commit-tree -p "$MERGE" -m stray "$(git -C "$REPO" rev-parse "$MERGE^{tree}")")
  done_refused "$stray" "is not on main"
  done_refused not-a-ref 'expected a PR number, PR URL or commit'
  printf 'more\n' > "$AM_WT/more"
  git -C "$AM_WT" add more; git -C "$AM_WT" commit -qm 'AM-1: more'
  done_refused 423 'changes that are not on main'
  git -C "$AM_WT" reset -q --hard HEAD~1
  # The job's own open PR must be closed or delivered instead.
  printf '{"url":"https://github.com/test/repo/pull/424"}\n' > "$DV_STATE/AM-1/pr.json"
  done_refused 423 "own PR is still open"
  rm "$DV_STATE/AM-1/pr.json"
  dv 'done' AM-1 --already-merged 423
  # A changed worktree after completion cannot be landed on that record.
  git -C "$AM_WT" commit --allow-empty -qm 'AM-1: later'
  if dv land AM-1; then return 1; fi
  test -d "$AM_WT"
  jq -e '.status=="ready"' "$DV_STATE/AM-1/meta"
}
case_qa_clean_url() {
  # A blocked QA job records its repository as a URL. Its scratch predates
  # owner markers, so only dv clean can release it.
  local record scratch issue
  qa_direct_fixture
  for _ in 1 2 3 4 5 6; do printf 'fail\n' >> "$GH_STUB_DIR/qa-pull-responses"; done
  qa_direct_run
  test "$qa_rc" = 1
  record=$(find "$DV_STATE" -path '*/QA-*/meta' -print)
  issue=$(jq -r .issue "$record"); scratch=$(jq -r .scratch "$record")
  rm "$scratch/owner.pid"
  jq -e '.status=="blocked" and (.repo|startswith("https://github.com/"))' "$record"
  test -d "$scratch/source"
  printf 'evidence\n' > "$scratch/source/untracked"
  if dv clean "$issue"; then return 1; fi
  test -f "$scratch/source/untracked"
  jq -e '.cleaned_at==null' "$record"
  rm "$scratch/source/untracked"
  dv clean "$issue"
  test ! -e "$scratch"
  jq -e '.cleaned_at!=null and .status=="blocked"' "$record"
  dv clean "$issue"
}
park_fixture() {
  repo park remote
  running_job PK-7
  printf 'wip\n' > "$DV_WORK/PK-7/wip"
  git -C "$DV_WORK/PK-7" add wip; git -C "$DV_WORK/PK-7" commit -qm 'PK-7: WIP'
  printf '{"number":12,"state":"open"}\n' > "$GH_STUB_DIR/issue-12.json"
  printf '{"number":13,"state":"open"}\n' > "$GH_STUB_DIR/issue-13.json"
  printf '{"number":14,"state":"closed"}\n' > "$GH_STUB_DIR/issue-14.json"
}
park_refused() {
  if dv park PK-7 "$@" > "$CASE_DIR/park.out" 2>&1; then cat "$CASE_DIR/park.out"; return 1; fi
  cat "$CASE_DIR/park.out"
  jq -e --arg status "${park_status:-running}" '.status==$status and .parked==null' "$DV_STATE/PK-7/meta"
  if git -C "$CASE_DIR/remote.git" show-ref --verify --quiet refs/heads/codex/pk-7; then return 1; fi
  test ! -f "$GH_STUB_DIR/issue-7-comments"
}
case_park_prerequisites() {
  park_fixture
  local head park_status=${1:-running}
  jq --arg status "$park_status" '.status=$status' "$DV_STATE/PK-7/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/PK-7/meta"
  head=$(git -C "$DV_WORK/PK-7" rev-parse HEAD)
  park_refused --on 12,14
  grep -F 'prerequisite #14 is not open' "$CASE_DIR/park.out"
  park_refused --on 7
  park_refused --note 'no prerequisites'
  printf 'unsaved\n' > "$DV_WORK/PK-7/unsaved"
  park_refused --on 12
  grep -F 'uncommitted files' "$CASE_DIR/park.out"
  rm "$DV_WORK/PK-7/unsaved"
  dv park PK-7 --on 12,13 --note 'needs the API from #12'
  jq -e --arg head "$head" '.status=="parked" and .head==$head and .parked.on==[12,13] and
    .parked.head==$head and .parked.issue==7 and .parked.at!=null' "$DV_STATE/PK-7/meta"
  test "$(git -C "$CASE_DIR/remote.git" rev-parse refs/heads/codex/pk-7)" = "$head"
  jq -e --arg head "$head" 'length==1 and (.[0].body | contains("<!-- devflow-park:PK-7:"+$head+" -->") and
    contains("#12") and contains("#13") and contains("codex/pk-7") and contains("needs the API from #12"))' "$GH_STUB_DIR/issue-7-comments"
  jq -se '[.[]|select(.kind=="parked" and .issue=="PK-7")]|length==1 and (.[0].message|contains("#12, #13"))' "$DV_HOME/kick.q"
  # The parked job no longer holds a scheduling slot or a stall recovery.
  bidding_functions
  test "$(bid_active)" = 0
  dv _stall-recover PK-7 any '' > "$CASE_DIR/stall.out" 2>&1
  test ! -f "$DV_STATE/PK-7/stall-recovery.json"
  # Parking twice is refused; the comment is not repeated.
  if dv park PK-7 --on 12; then return 1; fi
  jq -e 'length==1' "$GH_STUB_DIR/issue-7-comments"
}
case_park_repark_blockers() {
  # A second park at the same head must reach the manager with its new
  # prerequisites (devflow#344): the first parked event ID was already seen.
  needs_tmux; park_fixture
  local state="$DV_STATE/PK-7" head
  cat > "$CASE_DIR/repark-agent" <<'AGENT'
#!/usr/bin/env bash
pwd > "$DV_STATE/$DV_ISSUE/resumed"
while [ ! -f "$DV_STATE/$DV_ISSUE/resume-release" ]; do sleep 0.05; done
AGENT
  chmod +x "$CASE_DIR/repark-agent"
  export DV_AGENT_CMD_codex="$CASE_DIR/repark-agent"
  head=$(git -C "$DV_WORK/PK-7" rev-parse HEAD)
  dv park PK-7 --on 12 --note 'first-blocker'
  dv send PK-7 'continue work after the first dependency'
  wait_file "$state/resumed"
  dv park PK-7 --on 13 --note 'second-blocker'
  jq -se --arg head "$head" '[.[]|select(.kind=="parked" and .issue=="PK-7")] |
    length==2 and (.[0].id != .[1].id) and (.[1].message|contains("#13")) and
    all(.[]; .head==$head)' "$DV_HOME/kick.q"
  # Re-emitting the same episode keeps its ID, so a retry is still deduplicated.
  dv kick parked PK-7 'retransmit'
  jq -se '[.[]|select(.kind=="parked" and .issue=="PK-7")] |
    length==3 and (.[2].id == .[1].id)' "$DV_HOME/kick.q"
  jq -e --arg head "$head" '.status=="parked" and .parked.on==[13] and .head==$head' "$state/meta"
  touch "$state/resume-release"
  wait_done PK-7
}
case_park_pr_prerequisites() { case_park_prerequisites pr; }
case_park_agent_exit() {
  # The agent parks itself and exits: no failure event, and dv send resumes
  # the same worktree.
  needs_tmux; repo parkexit remote
  printf '{"number":12,"state":"open"}\n' > "$GH_STUB_DIR/issue-12.json"
  cat > "$CASE_DIR/park-agent" <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail
if [ -f "$DV_STATE/$DV_ISSUE/revive/id" ]; then touch "$DV_STATE/$DV_ISSUE/resumed"; exit 0; fi
printf 'wip\n' > wip.txt
git add wip.txt; git commit -qm "$DV_ISSUE: WIP"
dv park "$DV_ISSUE" --on 12 --note 'waiting for #12'
AGENT
  chmod +x "$CASE_DIR/park-agent"
  export DV_AGENT_CMD_codex="$CASE_DIR/park-agent"
  dv start "$REPO" PK-8 park --brief "$CASE_DIR/brief"
  wait_done PK-8
  jq -e '.status=="parked"' "$DV_STATE/PK-8/meta"
  test "$(event_count PK-8 failed)" = 0
  test "$(event_count PK-8 parked)" = 1
  dv send PK-8 'Prerequisite #12 is closed; resume the brief.'
  wait_file "$DV_STATE/PK-8/resumed"
  jq -e '.status=="running" and .unparked_at!=null' "$DV_STATE/PK-8/meta"
}
case_park_exec_exit() {
  # A native exec worker that parks itself is neither retried nor failed.
  exec_setup park remote
  printf '{"number":12,"state":"open"}\n' > "$GH_STUB_DIR/issue-12.json"
  dv start "$REPO" PK-9 park
  exec_wait PK-9
  jq -e '.status=="parked" and .exec_status=="parked" and .failure_reason==null' "$DV_STATE/PK-9/meta"
  test "$(cat "$DV_STATE/PK-9/stub-count")" = 1
  test ! -f "$DV_STATE/PK-9/exec-retry.used"
  test "$(event_count PK-9 parked)" = 1
  test "$(event_count PK-9 failed)" = 0
  test "$(event_count PK-9 blocked)" = 0
}
case_reconcile_merged_cleanup_retry() {
  # Cleanup can fail after the merged PR is recorded as landed (for example
  # while the worker still runs). Publish the confirmed merge immediately;
  # later passes finish cleanup without sending landed a second time.
  repo cleanup remote
  stale_job C-1 ready 31
  printf '{"31":"MERGED"}\n' > "$GH_STUB_DIR/pr-states"
  cat > "$CASE_DIR/cleanup-failure" <<'ENV'
git() {
  if [ "${1:-} ${2:-}" = 'worktree remove' ]; then return 1; fi
  command git "$@"
}
ENV
  if BASH_ENV="$CASE_DIR/cleanup-failure" dv _pr-reconcile C-1; then return 1; fi
  jq -e '.status=="landed" and .pr_reconcile_pending==true' "$DV_STATE/C-1/meta"
  test -d "$DV_WORK/C-1"
  test "$(event_count C-1 landed)" = 1
  test "$(event_count C-1 blocked)" = 1
  watch_fixture
  export DV_HOSTS="$DV_HOST" DV_RECONCILE_INTERVAL=1
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  for _ in {1..100}; do [ -d "$DV_WORK/C-1" ] || break; sleep 0.1; done
  sleep 1.5
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  pr_sweep_wait
  jq -e '.status=="landed" and .pr_reconcile_pending==null' "$DV_STATE/C-1/meta"
  test ! -d "$DV_WORK/C-1"
  test "$(event_count C-1 landed)" = 1
}

park_pr_fixture() {
  repo parkpr remote
  stale_job PK-7 pr 1
  cp "$CASE_DIR/brief" "$DV_STATE/PK-7/brief.md"
  jq '.mode="goal"' "$DV_STATE/PK-7/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/PK-7/meta"
  printf '{"number":12,"state":"open"}\n' > "$GH_STUB_DIR/issue-12.json"
  printf '{"failed_heads":["earlier-ci"],"reviewed_heads":["earlier-review"],"requests":{"earlier-review":{"deadline":1,"retried":true}}}\n' > "$DV_STATE/PK-7/pr-loop.json"
  cp "$DV_STATE/PK-7/pr-loop.json" "$CASE_DIR/previous-loop"
  cat > "$CASE_DIR/resume-agent" <<'AGENT'
#!/usr/bin/env bash
pwd > "$DV_STATE/$DV_ISSUE/resumed"
while [ ! -f "$DV_STATE/$DV_ISSUE/resume-release" ]; do sleep 0.05; done
AGENT
  chmod +x "$CASE_DIR/resume-agent"
  export DV_AGENT_CMD_codex="$CASE_DIR/resume-agent"
}
case_park_open_pr() {
  needs_tmux; park_pr_fixture
  local head state="$DV_STATE/PK-7"
  head=$(git -C "$DV_WORK/PK-7" rev-parse HEAD)
  bidding_functions
  test "$(bid_active)" = 1
  dv park PK-7 --on 12 --note 'waiting for the API'
  jq -e --arg head "$head" '.status=="parked" and .head==$head and .parked.on==[12] and .pr=="https://github.com/test/repo/pull/1"' "$state/meta"
  test "$(git -C "$CASE_DIR/remote.git" rev-parse refs/heads/codex/pk-7)" = "$head"
  test "$(bid_active)" = 0
  test "$(event_count PK-7 parked)" = 1
  dv _pr-wait-start PK-7
  test ! -f "$state/pr-wait.pid"
  dv _stall-recover PK-7 stale-episode ''
  test ! -f "$state/stall-recovery.json"
  test ! -d "$state/revive"
  cmp "$CASE_DIR/previous-loop" "$state/pr-loop.json"
  dv send PK-7 'Prerequisite closed; continue.'
  wait_file "$state/resumed"
  jq -e --arg wt "$DV_WORK/PK-7" '.status=="running" and .unparked_at!=null and .worktree==$wt' "$state/meta"
  test "$(cat "$state/resumed")" = "$DV_WORK/PK-7"
  cmp "$CASE_DIR/previous-loop" "$state/pr-loop.json"
  dv pr PK-7
  wait_pr_ready PK-7
  jq -e '.status=="pr"' "$state/meta"
  jq -e --slurpfile previous "$CASE_DIR/previous-loop" '.failed_heads==$previous[0].failed_heads and .requests==$previous[0].requests and (.reviewed_heads|index("earlier-review"))!=null and (.reviewed_heads|length)==2' "$state/pr-loop.json"
  # Same-head parking after resumption does not repeat the public comment.
  dv park PK-7 --on 12
  touch "$state/resume-release"
  wait_done PK-7
  jq -e --arg head "$head" 'length==1 and (.[0].body|contains("<!-- devflow-park:PK-7:"+$head+" -->"))' "$GH_STUB_DIR/issue-7-comments"
}
case_park_pr_wait() {
  # An already running waiter must discard its result when the job is parked
  # during a GitHub request. No review rounds, requests or recovery are added.
  park_pr_fixture
  local state="$DV_STATE/PK-7" pid
  cat > "$CASE_DIR/hold-checks" <<'ENV'
gh() {
  if [ "$1 $2" = 'pr checks' ]; then
    touch "$CASE_DIR/checks-started"
    while [ ! -f "$CASE_DIR/checks-release" ]; do sleep 0.05; done
  fi
  command gh "$@"
}
ENV
  BASH_ENV="$CASE_DIR/hold-checks" dv pr-wait PK-7 > "$CASE_DIR/waiter.log" 2>&1 & pid=$!
  wait_file "$CASE_DIR/checks-started"
  jq '.status="parked"' "$state/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$state/meta"
  touch "$CASE_DIR/checks-release"
  wait "$pid"
  cmp "$CASE_DIR/previous-loop" "$state/pr-loop.json"
  test ! -d "$state/.pr-wait"
  test ! -f "$state/pr-ready.json"
  test ! -d "$state/revive"
  test ! -s "$state/events.log"
  cp "$GH_STUB_DIR/calls" "$CASE_DIR/previous-calls"
  dv pr-wait PK-7
  dv pr-wait PK-7 --foreground
  dv _pr-wait-start PK-7
  cmp "$GH_STUB_DIR/calls" "$CASE_DIR/previous-calls"
  cmp "$CASE_DIR/previous-loop" "$state/pr-loop.json"
}
case_park_pr_stale_send() {
  # The waiter may have already decided to send before park takes the operation
  # lock. Its automatic handoff must recheck status under the same lock.
  needs_tmux; park_pr_fixture
  local state="$DV_STATE/PK-7" head
  head=$(git -C "$DV_WORK/PK-7" rev-parse HEAD)
  jq '.status="parked"' "$state/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$state/meta"
  DV_PR_RECOVERY_HEAD="$head" DV_PR_RECOVERY_EPISODE='' dv send PK-7 'stale PR recovery'
  jq -e '.status=="parked" and .unparked_at==null' "$state/meta"
  test ! -d "$state/revive"
  cmp "$CASE_DIR/previous-loop" "$state/pr-loop.json"
}
case_park_pr_wait_resume() {
  # After send has resumed work, foreground waiting can restore PR ownership
  # without pushing an unchanged head or resetting the historical counters.
  park_pr_fixture
  local state="$DV_STATE/PK-7"
  jq '.status="running" | .unparked_at=1' "$state/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$state/meta"
  dv pr-wait PK-7 --foreground > "$CASE_DIR/result"
  jq -e '.status=="pr"' "$state/meta"
  jq -e '.ci_rounds==1 and .review_rounds==2 and .review_handled' "$CASE_DIR/result"
  jq -e --slurpfile previous "$CASE_DIR/previous-loop" '.requests==$previous[0].requests' "$state/pr-loop.json"
  # The default waiter restores the same ownership without extra rounds too.
  printf '%s\n' "$$" > "$state/agent.pid"
  jq '.status="running"' "$state/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$state/meta"
  dv pr-wait PK-7
  jq -e '.status=="pr"' "$state/meta"
  jq -e '.ci_rounds==1 and .review_rounds==2 and .review_handled' "$state/pr-ready.json"
}
case_park_pr_reconcile() {
  repo parked-reconcile remote; watch_fixture
  stale_job PK-1 parked 31; stale_job PK-2 parked 32; stale_job PK-3 parked 33
  printf '{"31":"MERGED","32":"CLOSED","33":"OPEN"}\n' > "$GH_STUB_DIR/pr-states"
  export DV_HOSTS="$DV_HOST" DV_RECONCILE_INTERVAL=1
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  for _ in {1..100}; do
    if jq -e '.status=="landed"' "$DV_STATE/PK-1/meta" >/dev/null &&
      jq -e '.status=="closed"' "$DV_STATE/PK-2/meta" >/dev/null; then break; fi
    sleep 0.1
  done
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  pr_sweep_wait
  dv _pr-reconcile-sweep
  jq -e '.status=="landed"' "$DV_STATE/PK-1/meta"
  test ! -d "$DV_WORK/PK-1"
  test "$(event_count PK-1 landed)" = 1
  jq -e '.status=="closed"' "$DV_STATE/PK-2/meta"
  test -d "$DV_WORK/PK-2"
  test "$(event_count PK-2 closed)" = 1
  jq -e '.status=="parked"' "$DV_STATE/PK-3/meta"
  test -d "$DV_WORK/PK-3"
  test ! -f "$DV_STATE/PK-3/pr-wait.pid"
  test ! -f "$DV_STATE/PK-3/events.log"
  test ! -d "$DV_STATE/PK-3/revive"
}
