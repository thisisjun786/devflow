#!/usr/bin/env bash
# All reviews, requests, issues and merges below are synthetic gh responses.
review_fixture() {
  pr_fixture
  export DV_REVIEW_BOTS=codex DV_REVIEW_ROUNDS=4
  review_set 1 ''
}
review_set() {
  local id=$1 severity=$2 head
  head=$(git -C "$REPO" rev-parse HEAD)
  jq -n --arg head "$head" --argjson id "$id" \
    '[{id:$id,user:{login:"chatgpt-codex-connector[bot]"},commit_id:$head,state:"COMMENTED",submitted_at:("2026-10-22T00:00:0"+($id|tostring)+"Z"),body:"Codex review"}]' > "$GH_STUB_DIR/reviews"
  jq -n --arg head "$head" --argjson id "$id" --arg severity "$severity" \
    'if $severity=="" then [] else [{id:($id+100),pull_request_review_id:$id,user:{login:"chatgpt-codex-connector[bot]"},commit_id:$head,path:"lib/example.sh",line:12,body:("!["+$severity+" Badge](https://img.shields.io/badge/"+$severity+"-orange) **Preserve the current value**\n\nDetails here.")}] end' > "$GH_STUB_DIR/comments"
}
review_push() {
  git -C "$REPO" commit --allow-empty -qm "P-1: fix review round $1"
  dv pr P-1 >/dev/null
  wait_pr_ready P-1
}
case_review_badges() {
  review_fixture
  local p
  for p in P0 P1 P2 P3; do
    review_set 1 "$p"
    dv pr-wait P-1 --foreground > "$CASE_DIR/result"
    jq -e --arg p "$p" '.review.findings[0] | .severity==$p and .path=="lib/example.sh" and .line==12' "$CASE_DIR/result"
  done
}
case_review_current() {
  review_fixture
  review_set 1 P1
  git -C "$REPO" commit --allow-empty -qm 'new head'
  review_set 2 ''
  # Keep old-head findings, including a misleading same-review comment.
  jq --arg head "$(git -C "$REPO" rev-parse HEAD^)" '.[0].commit_id=$head | .[0].body="[P0] old summary"' "$GH_STUB_DIR/reviews" > "$CASE_DIR/old-review"
  jq -s '.[0]+.[1]' "$CASE_DIR/old-review" "$GH_STUB_DIR/reviews" > "$CASE_DIR/reviews"
  mv "$CASE_DIR/reviews" "$GH_STUB_DIR/reviews"
  jq -n --arg head "$(git -C "$REPO" rev-parse HEAD^)" '[{pull_request_review_id:2,commit_id:$head,user:{login:"chatgpt-codex-connector[bot]"},body:"[P1] stale",path:"old",line:1}]' > "$GH_STUB_DIR/comments"
  jq --arg head "$(git -C "$REPO" rev-parse HEAD)" '.head=$head' "$DV_STATE/P-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/P-1/meta"
  dv pr-wait P-1 --foreground > "$CASE_DIR/result"
  jq -e '.review.clean and .review.findings==[] and .review.id==2' "$CASE_DIR/result"
}
case_review_summary() {
  review_fixture
  jq '.[0].body="### [P1] Retain the lock\nDetails\n### [P3] Improve naming"' "$GH_STUB_DIR/reviews" > "$CASE_DIR/reviews"
  mv "$CASE_DIR/reviews" "$GH_STUB_DIR/reviews"
  dv pr-wait P-1 --foreground > "$CASE_DIR/result"
  jq -e '.review.high|length==1' "$CASE_DIR/result"
  jq -e '.review.low|length==1' "$CASE_DIR/result"
  if dv pr-wait P-1 --foreground --review-handled > /dev/null; then return 1; fi
  if dv 'done' P-1; then return 1; fi
}
case_review_land_missing() {
  land_setup true true true
  printf '[]\n' > "$GH_STUB_DIR/reviews"
  land_failure 'current head requires a clean Codex review'
  land_not_merged
}
case_review_land_latest() {
  land_setup true true true
  local head
  head=$(git -C "$LAND_WT" rev-parse HEAD)
  jq -n --arg head "$head" '[{id:1,user:{login:"chatgpt-codex-connector[bot]"},commit_id:$head,state:"COMMENTED",submitted_at:"2026-10-22T01:00:00Z",body:"Looks good"},{id:2,user:{login:"chatgpt-codex-connector[bot]"},commit_id:$head,state:"COMMENTED",submitted_at:"2026-10-22T02:00:00Z",body:"[P1] Fix the lock"}]' > "$GH_STUB_DIR/reviews"
  land_failure 'current head requires a clean Codex review'
  land_not_merged
}
case_review_timeout() {
  review_fixture
  printf '[]\n' > "$GH_STUB_DIR/reviews"
  if dv pr-wait P-1 --foreground > "$CASE_DIR/result"; then return 1; fi
  if dv pr-wait P-1 --foreground > "$CASE_DIR/result"; then return 1; fi
  jq -e '.blocked and .reason=="review-timeout" and (.review_handled|not)' "$CASE_DIR/result"
  test "$(grep -c '^pr comment .*@codex review' "$GH_STUB_DIR/calls")" = 1
  jq -se 'length==1 and .[0].kind=="blocked" and (.[0].message|contains("review-timeout"))' "$DV_HOME/kick.q"
}
case_review_rounds() {
  review_fixture
  local n
  for n in 1 2 3 4; do
    review_set "$n" P1
    if [ "$n" -lt 4 ]; then
      dv pr-wait P-1 --foreground > "$CASE_DIR/result"
      dv pr-wait P-1 --foreground > "$CASE_DIR/result"
      jq -e --argjson n "$n" '.review_rounds==$n and (.blocked|not)' "$CASE_DIR/result"
      git -C "$REPO" commit --allow-empty -qm "P-1: round $n"
      jq --arg head "$(git -C "$REPO" rev-parse HEAD)" '.head=$head' "$DV_STATE/P-1/meta" > "$CASE_DIR/meta"
      mv "$CASE_DIR/meta" "$DV_STATE/P-1/meta"
    else
      if dv pr-wait P-1 --foreground > "$CASE_DIR/result"; then return 1; fi
      jq -e '.blocked and .reason=="review-rounds" and .review_rounds==4 and (.review.high|length)==1' "$CASE_DIR/result"
    fi
  done
}
case_review_e2e() {
  review_fixture
  review_set 1 P1
  dv pr-wait P-1 --foreground > "$CASE_DIR/first"
  jq -e '(.review.high|length)==1 and (.review_handled|not)' "$CASE_DIR/first"
  if dv 'done' P-1; then return 1; fi
  # The fake gh publishes the new-head review only after the request arrives.
  touch "$GH_STUB_DIR/review-on-request"
  review_push 1
  dv pr-wait P-1 --foreground > "$CASE_DIR/result"
  jq -e '.review.clean and .review_handled and .review_rounds==2' "$CASE_DIR/result"
  test "$(grep -c '^pr comment .*@codex review' "$GH_STUB_DIR/calls")" = 1
  dv 'done' P-1
  # pr_fixture uses the repository itself; give land a disposable worktree.
  git -C "$REPO" checkout -qb fixture-base
  git -C "$REPO" worktree add -q "$DV_WORK/land" feature
  jq --arg wt "$DV_WORK/land" '.worktree=$wt' "$DV_STATE/P-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/P-1/meta"
  dv land P-1
  test -f "$GH_STUB_DIR/merged"
}
case_review_followup() {
  review_fixture
  review_set 1 P2
  printf 'Original report\n' > "$DV_STATE/P-1/report.md"
  printf 'Original PR\n\nCloses #1\n' > "$DV_STATE/P-1/pr.md"
  cp "$DV_STATE/P-1/pr.md" "$GH_STUB_DIR/live-body"
  dv pr-wait P-1 --foreground > "$CASE_DIR/result"
  dv pr-wait P-1 --foreground > "$CASE_DIR/result"
  jq -e '.review.clean and .review_handled and (.blocked|not)' "$CASE_DIR/result"
  jq -e '.milestone==7 and (.body|contains("Depends on #1")) and (.body|contains("lib/example.sh:12"))' "$GH_STUB_DIR/followup"
  test "$(grep -c '^api --method POST repos/test/repo/issues ' "$GH_STUB_DIR/calls")" = 1
  grep -F 'Review follow-up: #20' "$GH_STUB_DIR/live-body" "$DV_STATE/P-1/pr.md" "$DV_STATE/P-1/report.md"
  grep -Fx 'Original report' "$DV_STATE/P-1/report.md"
  grep -Fx 'Original PR' "$GH_STUB_DIR/live-body"
  # Report/state loss still discovers the issue by its public PR marker.
  rm "$DV_STATE/P-1/pr-review-followup.json"
  dv pr-wait P-1 --foreground >/dev/null
  test "$(grep -c '^api --method POST repos/test/repo/issues ' "$GH_STUB_DIR/calls")" = 1
  dv 'done' P-1
}
case_review_followup_no_milestone() {
  review_fixture
  touch "$GH_STUB_DIR/no-milestone"
  review_set 1 P2
  dv pr-wait P-1 --foreground > "$CASE_DIR/result"
  jq -e '.review.clean and .review_handled and (.blocked|not)' "$CASE_DIR/result"
  jq -e '.milestone==null and (.body|contains("Depends on #1")) and (.body|contains("P2 lib/example.sh:12"))' "$GH_STUB_DIR/followup"
  # A later review updates the same issue without assigning a milestone.
  review_set 2 P3
  dv pr-wait P-1 --foreground > "$CASE_DIR/result"
  jq -e '.milestone==null and (.body|contains("P3 lib/example.sh:12")) and (.body|contains("P2 lib/example.sh:12")|not)' "$GH_STUB_DIR/followup"
  test "$(grep -c '^api --method POST repos/test/repo/issues ' "$GH_STUB_DIR/calls")" = 1
  test "$(grep -c '^api --method PATCH repos/test/repo/issues/20 ' "$GH_STUB_DIR/calls")" = 1
  grep -F 'Review follow-up: #20' "$GH_STUB_DIR/live-body" "$DV_STATE/P-1/report.md"
  dv 'done' P-1
  # Land rechecks the follow-up using a disposable worktree and the gh stub.
  git -C "$REPO" checkout -qb fixture-base
  git -C "$REPO" worktree add -q "$DV_WORK/land" feature
  jq --arg wt "$DV_WORK/land" '.worktree=$wt' "$DV_STATE/P-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/P-1/meta"
  dv land P-1
  test -f "$GH_STUB_DIR/merged"
  jq -e '.milestone==null' "$GH_STUB_DIR/followup"
  jq -e '.state=="MERGED"' "$DV_STATE/P-1/land-result.json"
}
review_source_fixture() {
  review_fixture
  local issue=$1
  mv "$DV_STATE/P-1" "$DV_STATE/$issue"
  jq --arg issue "$issue" '.issue=$issue' "$DV_STATE/$issue/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/$issue/meta"
  review_set 1 P2
  printf 'Original report\n' > "$DV_STATE/$issue/report.md"
  printf '{"1":7,"73":9,"214":11}\n' > "$GH_STUB_DIR/source-milestones"
}
review_closing_issues() {
  jq -n --argjson nodes "$1" '{data:{repository:{pullRequest:{closingIssuesReferences:{nodes:$nodes}}}}}'
}
review_source_check() {
  local issue=$1 number=$2 milestone=$3
  dv pr-wait "$issue" --foreground > "$CASE_DIR/result"
  jq -e '.green and .review.clean and .review_handled and (.blocked|not)' "$CASE_DIR/result"
  jq -e --arg number "$number" --argjson milestone "$milestone" \
    '.milestone==$milestone and (.body|contains("Depends on #"+$number+"\n")) and (.body|contains("P2 lib/example.sh:12"))' "$GH_STUB_DIR/followup"
  # Dedupe must survive lost local receipts and a later P3-only review.
  rm "$DV_STATE/$issue/pr-review-followup.json"
  review_set 2 P3
  dv pr-wait "$issue" --foreground > "$CASE_DIR/result"
  jq -e '.body|contains("P3 lib/example.sh:12")' "$GH_STUB_DIR/followup"
  test "$(grep -c '^api --method POST repos/test/repo/issues ' "$GH_STUB_DIR/calls")" = 1
  grep -Fx 'Original report' "$DV_STATE/$issue/report.md"
  dv 'done' "$issue"
}
case_review_source_moved() {
  review_source_fixture LN-214M
  review_closing_issues '[{"number":214,"repository":{"nameWithOwner":"test/repo"}}]' > "$GH_STUB_DIR/closing-issues"
  review_source_check LN-214M 214 11
  git -C "$REPO" checkout -qb fixture-base
  git -C "$REPO" worktree add -q "$DV_WORK/land" feature
  jq --arg wt "$DV_WORK/land" '.worktree=$wt' "$DV_STATE/LN-214M/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/LN-214M/meta"
  dv land LN-214M
  test -f "$GH_STUB_DIR/merged"
}
case_review_source_named() {
  review_source_fixture fix-login
  # Read every page, ignore other repositories, and dedupe repeated references.
  review_closing_issues '[{"number":1,"repository":{"nameWithOwner":"other/repo"}}]' > "$GH_STUB_DIR/closing-issues"
  review_closing_issues '[{"number":73,"repository":{"nameWithOwner":"test/repo"}},{"number":73,"repository":{"nameWithOwner":"test/repo"}}]' >> "$GH_STUB_DIR/closing-issues"
  review_source_check fix-login 73 9
}
case_review_source_numeric() {
  review_source_fixture JOB-1
  review_closing_issues '[{"number":73,"repository":{"nameWithOwner":"test/repo"}}]' > "$GH_STUB_DIR/closing-issues"
  review_source_check JOB-1 73 9
}
case_review_source_meta() {
  review_source_fixture LN-214M
  jq '.source_issue=73' "$DV_STATE/LN-214M/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/LN-214M/meta"
  review_closing_issues '[{"number":214,"repository":{"nameWithOwner":"test/repo"}}]' > "$GH_STUB_DIR/closing-issues"
  review_source_check LN-214M 73 9
  ! grep -q '^api graphql ' "$GH_STUB_DIR/calls"
}
case_review_source_invalid_meta() {
  review_source_fixture LN-214M
  jq '.source_issue="73junk"' "$DV_STATE/LN-214M/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/LN-214M/meta"
  review_closing_issues '[{"number":214,"repository":{"nameWithOwner":"test/repo"}}]' > "$GH_STUB_DIR/closing-issues"
  review_source_check LN-214M 214 11
}
case_review_source_unknown() {
  review_source_fixture fix-login
  dv pr-wait fix-login --foreground > "$CASE_DIR/result"
  jq -e '.green and .review_handled and (.blocked|not)' "$CASE_DIR/result"
  jq -e '.milestone==null and (.body|contains("Depends on")|not) and (.body|contains("P2 lib/example.sh:12"))' "$GH_STUB_DIR/followup"
  # An unavailable API is also unresolved, not a P2/P3 delivery blocker.
  touch "$GH_STUB_DIR/closing-issues-fail"
  dv pr-wait fix-login --foreground > "$CASE_DIR/result"
  dv 'done' fix-login
  test "$(grep -c '^api --method POST repos/test/repo/issues ' "$GH_STUB_DIR/calls")" = 1
  test "$(grep -c '^Warning: cannot resolve the source GitHub issue' "$DV_STATE/fix-login/report.md")" = 1
  grep -Fx 'Original report' "$DV_STATE/fix-login/report.md"
  ! grep -q '^api repos/test/repo/issues/' "$GH_STUB_DIR/calls"
}
case_review_source_start() {
  repo source-header; herdr_setup
  printf '# other-job = GitHub issue #1\n# LN-214M = GitHub issue #214 in test/repo\n' > "$CASE_DIR/brief"
  dv start "$REPO" LN-214M source --brief "$CASE_DIR/brief"
  wait_native LN-214M
  jq -e '.source_issue==214' "$DV_STATE/LN-214M/meta"
  printf '# fix-login = GitHub issue #73junk\n' > "$CASE_DIR/brief"
  dv start "$REPO" fix-login source --brief "$CASE_DIR/brief"
  wait_native fix-login
  jq -e 'has("source_issue")|not' "$DV_STATE/fix-login/meta"
}
case_review_retry_arrives() {
  review_fixture
  # The automatic review did not arrive; the single retry produces a review.
  jq '.[0].commit_id="old"' "$GH_STUB_DIR/reviews" > "$CASE_DIR/reviews"
  mv "$CASE_DIR/reviews" "$GH_STUB_DIR/reviews"
  touch "$GH_STUB_DIR/review-on-request"
  dv pr-wait P-1 --foreground > "$CASE_DIR/result"
  jq -e '.review.clean and (.review_timed_out|not)' "$CASE_DIR/result"
  test "$(grep -c '^pr comment .*@codex review' "$GH_STUB_DIR/calls")" = 1
}
review_deadline_fixture() {
  review_fixture
  local offset=$1 retried=$2 initial head expected
  initial=$(git -C "$REPO" rev-parse HEAD)
  git -C "$REPO" commit --allow-empty -qm 'P-1: new review head'
  head=$(git -C "$REPO" rev-parse HEAD)
  jq --arg head "$head" '.head=$head' "$DV_STATE/P-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/P-1/meta"
  # Only disposable fixture state is seeded; retain the old-head review.
  jq -n --arg initial "$initial" --arg head "$head" --argjson deadline "$((1000 + offset))" --argjson retried "$retried" \
    '{initial_head:$initial,failed_heads:[],reviewed_heads:[$initial],requests:{($head):{deadline:$deadline,retried:$retried}}}' > "$DV_STATE/P-1/pr-loop.json"
  export DV_REVIEW_WAIT=2
  printf '1000\n' > "$CASE_DIR/review-clock"
  touch "$GH_STUB_DIR/review-on-request"
  cat > "$DV_CONFIG" <<'CONFIG'
date() {
  if [ "$*" = +%s ]; then cat "$CASE_DIR/review-clock"; else command date "$@"; fi
}
sleep() {
  if [ "${FUNCNAME[1]:-}" != cmd_pr_wait ]; then command sleep "$@"; return; fi
  local tick
  tick=$(cat "$CASE_DIR/review-clock")
  if [ "$tick" = 1000 ]; then cp "$DV_STATE/P-1/pr-loop.json" "$CASE_DIR/first-persisted"; fi
  if grep -q '^pr comment .*@codex review' "$GH_STUB_DIR/calls"; then
    printf '%s\n' "$tick" > "$CASE_DIR/review-request-at"
  elif [ "$tick" -ge 1002 ]; then
    printf 'BUG: no @codex review within DV_REVIEW_WAIT=2; persisted deadline remains in the future\n' >&2
    exit 1
  fi
  [ "$tick" -lt 1003 ] || exit 1
  printf '%s\n' "$((tick + 1))" > "$CASE_DIR/review-clock"
}
CONFIG
  if dv pr-wait P-1 --foreground > "$CASE_DIR/result"; then
    test "$retried" = false
  else
    test "$retried" = true
  fi
  expected=$((1000 + offset)); [ "$expected" -le 1002 ] || expected=1002
  jq -e --arg head "$head" --arg initial "$initial" --argjson deadline "$expected" --argjson retried "$retried" \
    '.requests[$head]=={deadline:$deadline,retried:$retried} and .initial_head==$initial and .reviewed_heads==[$initial]' "$CASE_DIR/first-persisted"
  if [ "$retried" = false ]; then
    test "$(cat "$CASE_DIR/review-request-at")" = "$expected"
    test "$(grep -c '^pr comment .*@codex review' "$GH_STUB_DIR/calls")" = 1
    jq -e '.review.clean and .review_handled and (.review_timed_out|not)' "$CASE_DIR/result"
    printf 'Review requested at synthetic time %s (wait budget ends at 1002)\n' "$expected"
  else
    ! grep -q '^pr comment .*@codex review' "$GH_STUB_DIR/calls"
    jq -e '.blocked and .reason=="review-timeout" and (.review_handled|not)' "$CASE_DIR/result"
  fi
}
case_review_future_deadline() { review_deadline_fixture 604800 false; }
case_review_future_deadline_retried() { review_deadline_fixture 604800 true; }
case_review_near_deadline() { review_deadline_fixture 1 false; }
case_review_done_live() {
  review_fixture
  dv pr-wait P-1 --foreground >/dev/null
  review_set 2 P1
  if dv 'done' P-1 > "$CASE_DIR/refused" 2>&1; then return 1; fi
  grep -F 'current head requires a clean Codex review' "$CASE_DIR/refused"
  test ! -f "$DV_STATE/P-1/done.json"
}
case_review_api_failure() {
  review_fixture
  touch "$GH_STUB_DIR/reviews-fail"
  if dv pr-wait P-1 --foreground; then return 1; fi
  test ! -f "$DV_STATE/P-1/pr-ready.json"
}
case_review_latest_inline() {
  review_fixture
  review_set 1 P0
  cp "$GH_STUB_DIR/comments" "$CASE_DIR/old-comments"
  cp "$GH_STUB_DIR/reviews" "$CASE_DIR/old-reviews"
  review_set 2 ''
  cp "$CASE_DIR/old-comments" "$GH_STUB_DIR/comments"
  jq -s '.[0]+.[1]' "$GH_STUB_DIR/reviews" "$CASE_DIR/old-reviews" > "$CASE_DIR/reviews"
  mv "$CASE_DIR/reviews" "$GH_STUB_DIR/reviews"
  dv pr-wait P-1 --foreground > "$CASE_DIR/result"
  jq -e '.review.clean and .review.id==2 and .review.findings==[]' "$CASE_DIR/result"
}
case_review_other_bot() {
  review_fixture
  review_set 1 P1
  jq '. + [.[0] | .id=2 | .submitted_at="2026-10-22T02:00:00Z" | .user.login="devin-ai-integration[bot]" | .body="Looks good"]' "$GH_STUB_DIR/reviews" > "$CASE_DIR/reviews"
  mv "$CASE_DIR/reviews" "$GH_STUB_DIR/reviews"
  dv pr-wait P-1 --foreground > "$CASE_DIR/result"
  jq -e '.review.id==1 and (.review.high|length)==1 and (.review.clean|not)' "$CASE_DIR/result"
}
case_review_ci_first() {
  review_fixture
  printf '[]\n' > "$GH_STUB_DIR/reviews"
  printf '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]\n' > "$GH_STUB_DIR/checks"
  dv pr-wait P-1 --foreground > "$CASE_DIR/result"
  jq -e '(.green|not) and .ci_rounds==1 and .review_rounds==0 and (.review_timed_out|not)' "$CASE_DIR/result"
  ! grep -q '^pr comment ' "$GH_STUB_DIR/calls"
}
case_review_legacy_bot() {
  # Existing config files are preserved by install and override env defaults.
  printf 'DV_REVIEW_BOTS=devin,codex\n' > "$DV_CONFIG"
  case_review_other_bot
}
case_stack_review_update() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  touch "$GH_STUB_DIR/explicit-review-2"
  local original
  original=$(git -C "$DV_WORK/stack-2" rev-parse HEAD)
  stack_waiting 2; dv land S-1
  if dv land S-2; then return 1; fi
  jq -e '.stack_resume.status=="sent" and .status=="running"' "$DV_STATE/S-2/meta"
  grep -F 'clean current-head Codex review' "$DV_STATE/S-2/sent-input"
  test "$(git -C "$DV_WORK/stack-2" rev-parse HEAD)" != "$original"
  # The old review cannot satisfy the new head. Fake review service responds
  # only once the resumed worker has green CI and explicitly requests review.
  stack_green 2
  grep -Fx 'pr comment https://github.com/test/repo/pull/2 --body @codex review' "$GH_STUB_DIR/calls"
  jq -e --arg old "$original" '.head!=$old and .green and .review.clean' "$DV_STATE/S-2/pr-ready.json"
  dv land S-2
  test "$(tr '\n' ' ' < "$GH_STUB_DIR/order")" = '1 2 '
}
review_summary_set() {
  local head=$1 status=$2 any=$3 login=${4:-chatgpt-codex-connector[bot]}
  jq -n --arg head "$head" --arg status "$status" --argjson any "$any" --arg login "$login" \
    '[{id:10,user:{login:$login},updated_at:"2026-10-22T03:00:00Z",body:("<!-- codex-pull-request-review-summary -->\n<!-- codex-review-state:v1 "+({code_review:{commit_sha:$head,status:$status,has_any_findings:$any,has_unresolved_findings:$any}}|tojson)+" -->\n## Codex Review Summary")}]' > "$GH_STUB_DIR/issue-comments"
}
case_review_clean_summary() {
  review_fixture
  # A newer review with no suggestions may be delivered only as a summary;
  # the REST review and inline P1 here belong to the older review on this head.
  review_set 1 P1
  review_summary_set "$(git -C "$REPO" rev-parse HEAD)" completed false
  dv pr-wait P-1 --foreground > "$CASE_DIR/result"
  jq -e '.review.clean and .review.source=="summary" and .review.high==[]' "$CASE_DIR/result"
  dv 'done' P-1
}
case_review_summary_guards() {
  review_fixture
  local head variant
  head=$(git -C "$REPO" rev-parse HEAD)
  printf '[]\n' > "$GH_STUB_DIR/reviews"
  for variant in running old unknown findings human security; do
    review_summary_set "$head" completed false
    case "$variant" in
      running) review_summary_set "$head" running null ;;
      old) review_summary_set old completed false ;;
      unknown) review_summary_set "$head" completed null ;;
      findings) review_summary_set "$head" completed true ;;
      human) review_summary_set "$head" completed false codex-user ;;
      security) sed 's/code_review/security_review/g' "$GH_STUB_DIR/issue-comments" > "$CASE_DIR/security"; mv "$CASE_DIR/security" "$GH_STUB_DIR/issue-comments" ;;
    esac
    jq -n --slurpfile reviews "$GH_STUB_DIR/reviews" --slurpfile comments "$GH_STUB_DIR/issue-comments" \
      '{reviews:$reviews[0],issue_comments:$comments[0],inline_comments:[]}' > "$CASE_DIR/snapshot"
    (
      DV_ENTRY="$ROOT/bin/dv"
      source "$ROOT/lib/common.sh"
      source "$ROOT/lib/pr-review.sh"
      review_parse "$CASE_DIR/snapshot" "$head"
    ) > "$CASE_DIR/result"
    jq -e '(.clean|not) and (.exists|not)' "$CASE_DIR/result"
  done
  # A new running code review also invalidates an older clean receipt.
  review_set 1 ''
  review_summary_set "$head" running null
  if dv pr-wait P-1 --foreground > "$CASE_DIR/result"; then return 1; fi
  jq -e '.review_timed_out and (.review_handled|not)' "$CASE_DIR/result"
}
case_review_summary_api_failure() {
  review_fixture
  touch "$GH_STUB_DIR/issue-comments-fail"
  if dv pr-wait P-1 --foreground; then return 1; fi
  test ! -f "$DV_STATE/P-1/pr-ready.json"
}
case_stack_review_recover() {
  stack_fixture; stack_pr 1 dev; stack_pr 2 stack-1 'Depends on #1'
  touch "$GH_STUB_DIR/explicit-review-2"
  local original head
  original=$(git -C "$DV_WORK/stack-2" rev-parse HEAD)
  stack_waiting 2; dv land S-1
  # Simulate termination after the owned merge/push, before worker handoff.
  git -C "$DV_WORK/stack-2" fetch -q origin dev
  git -C "$DV_WORK/stack-2" merge --no-edit origin/dev
  git -C "$DV_WORK/stack-2" push -q origin stack-2
  head=$(git -C "$DV_WORK/stack-2" rev-parse HEAD)
  jq --arg head "$head" --arg original "$original" '.head=$head | .status="ready" | .stack_update_head=$head | .stack_update_from=$original' "$DV_STATE/S-2/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/S-2/meta"
  if dv land S-2; then return 1; fi
  jq -e '.stack_resume.status=="sent" and .status=="running"' "$DV_STATE/S-2/meta"
  stack_green 2
  grep -Fx 'pr comment https://github.com/test/repo/pull/2 --body @codex review' "$GH_STUB_DIR/calls"
  dv land S-2
  test "$(tr '\n' ' ' < "$GH_STUB_DIR/order")" = '1 2 '
}
case_review_summary_new_findings() {
  review_fixture
  review_set 1 P2
  review_summary_set "$(git -C "$REPO" rev-parse HEAD)" completed true
  jq '.[0].body+="\n### [P1] Newer review found a blocker"' "$GH_STUB_DIR/issue-comments" > "$CASE_DIR/summary"
  mv "$CASE_DIR/summary" "$GH_STUB_DIR/issue-comments"
  dv pr-wait P-1 --foreground > "$CASE_DIR/result"
  jq -e '(.review.clean|not) and (.review.high|length)==1 and .review.high[0].severity=="P1"' "$CASE_DIR/result"
  test ! -f "$GH_STUB_DIR/followup"
  if dv 'done' P-1; then return 1; fi
}
case_review_summary_latest_low() {
  review_fixture
  review_set 1 P2
  review_summary_set "$(git -C "$REPO" rev-parse HEAD)" completed true
  jq '.[0].body+="\n### [P2] Preserve the newer finding"' "$GH_STUB_DIR/issue-comments" > "$CASE_DIR/summary"
  mv "$CASE_DIR/summary" "$GH_STUB_DIR/issue-comments"
  dv pr-wait P-1 --foreground > "$CASE_DIR/result"
  jq -e '.review.clean and .review.source=="summary" and (.review.low|length)==1 and (.review.low[0].body|contains("newer finding"))' "$CASE_DIR/result"
  # A later REST receipt supersedes this summary without blocking P2.
  review_set 2 P2
  jq '.[0].submitted_at="2026-10-22T04:00:00Z"' "$GH_STUB_DIR/reviews" > "$CASE_DIR/reviews"
  mv "$CASE_DIR/reviews" "$GH_STUB_DIR/reviews"
  dv pr-wait P-1 --foreground > "$CASE_DIR/result"
  jq -e '.review.clean and .review.id==2 and (.review.low|length)==1' "$CASE_DIR/result"
}
case_review_summary_complete_low() {
  review_fixture
  review_set 1 P2
  # Real Codex metadata describes its REST review; it is not an independent
  # finding-bearing summary and its later publication time is expected.
  review_summary_set "$(git -C "$REPO" rev-parse HEAD)" completed true
  dv pr-wait P-1 --foreground > "$CASE_DIR/result"
  jq -e '.review.clean and .review.id==1 and (.review.low|length)==1' "$CASE_DIR/result"
  test -f "$GH_STUB_DIR/followup"
}

review_receipt_set() {
  local head=$1
  jq -n --arg head "$head" '[{id:20,user:{login:"chatgpt-codex-connector[bot]"},
    created_at:"2026-10-22T04:00:00Z",updated_at:"2026-10-22T04:00:00Z",
    body:("<!-- codex-review-receipt:v1 -->\nCodex Review: Didn\u0027t find any major issues.\n\n**Reviewed commit:** `"+$head+"`")} ]' > "$GH_STUB_DIR/receipt"
}
review_receipt_parse() (
  local head=$1
  cd "$REPO" || exit
  jq -n --slurpfile reviews "$GH_STUB_DIR/reviews" --slurpfile comments "$GH_STUB_DIR/issue-comments" \
    --slurpfile inline "$GH_STUB_DIR/comments" \
    '{reviews:$reviews[0],issue_comments:$comments[0],inline_comments:$inline[0]}' > "$CASE_DIR/snapshot"
  DV_REVIEW_BOTS=codex
  source "$ROOT/lib/pr-review.sh"
  review_parse "$CASE_DIR/snapshot" "$head" > "$CASE_DIR/result"
  cat "$CASE_DIR/result"
)
case_review_receipt() {
  # Synthetic version of the receipt-only PR #188 at head 2a4c2d9.
  repo receipt
  local head length
  head=$(git -C "$REPO" rev-parse HEAD)
  printf '[]\n' > "$GH_STUB_DIR/reviews"
  printf '[]\n' > "$GH_STUB_DIR/comments"
  for length in 7 10 40; do
    review_receipt_set "${head:0:length}"
    cp "$GH_STUB_DIR/receipt" "$GH_STUB_DIR/issue-comments"
    review_receipt_parse "$head"
    jq -e '.exists and .clean and .source=="receipt" and .high==[]' "$CASE_DIR/result"
    # Unresolved flags and inline comments carried from an older head cannot
    # hide a newer clean receipt for this head.
    review_summary_set "$head" completed true
    jq -s 'add' "$GH_STUB_DIR/issue-comments" "$GH_STUB_DIR/receipt" > "$CASE_DIR/comments"
    mv "$CASE_DIR/comments" "$GH_STUB_DIR/issue-comments"
    printf '[{"id":101,"commit_id":"old-head","pull_request_review_id":1,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"[P1] Old head"}]\n' > "$GH_STUB_DIR/comments"
    review_receipt_parse "$head"
    jq -e '.exists and .clean and .source=="receipt" and .findings==[]' "$CASE_DIR/result"
  done
}
case_review_receipt_guards() {
  repo receipt-guards
  local head variant
  head=$(git -C "$REPO" rev-parse HEAD)
  printf '[]\n' > "$GH_STUB_DIR/reviews"
  printf '[]\n' > "$GH_STUB_DIR/comments"
  for variant in old short long suffix human other_bot marker message commit timestamp finding; do
    review_receipt_set "${head:0:7}"
    case "$variant" in
      old) review_receipt_set deadbee ;;
      short) review_receipt_set "${head:0:6}" ;;
      long) review_receipt_set "${head}0" ;;
      suffix) review_receipt_set "${head:0:7}z" ;;
      human) jq '.[0].user.login="codex-user"' "$GH_STUB_DIR/receipt" > "$CASE_DIR/receipt" ;;
      other_bot) jq '.[0].user.login="devin-ai-integration[bot]"' "$GH_STUB_DIR/receipt" > "$CASE_DIR/receipt" ;;
      marker) jq '.[0].body|=sub("codex-review-receipt:v1";"unrelated")' "$GH_STUB_DIR/receipt" > "$CASE_DIR/receipt" ;;
      message) jq '.[0].body|=sub("major issues";"review completed")' "$GH_STUB_DIR/receipt" > "$CASE_DIR/receipt" ;;
      commit) jq '.[0].body|=sub("Reviewed commit";"Previous commit")' "$GH_STUB_DIR/receipt" > "$CASE_DIR/receipt" ;;
      timestamp) jq '.[0]|=del(.created_at,.updated_at)' "$GH_STUB_DIR/receipt" > "$CASE_DIR/receipt" ;;
      finding) jq '.[0].body+="\n[P1] Unresolved blocker"' "$GH_STUB_DIR/receipt" > "$CASE_DIR/receipt" ;;
    esac
    if [ -f "$CASE_DIR/receipt" ]; then mv "$CASE_DIR/receipt" "$GH_STUB_DIR/receipt"; fi
    cp "$GH_STUB_DIR/receipt" "$GH_STUB_DIR/issue-comments"
    review_receipt_parse "$head"
    jq -e '(.exists|not) and (.clean|not)' "$CASE_DIR/result"
  done
}
case_review_receipt_findings() {
  review_fixture
  local head source severity time
  head=$(git -C "$REPO" rev-parse HEAD)
  for source in rest inline summary; do
    for severity in P0 P1; do
      # Real current-head findings remain visible even with a newer receipt.
      for time in 2026-10-22T02:00:00Z 2026-10-22T05:00:00Z; do
        review_set 1 ''
        review_summary_set "$head" completed true
        case "$source" in
          rest) jq --arg p "$severity" '.[0].body="["+$p+"] Current head blocker"' "$GH_STUB_DIR/reviews" > "$CASE_DIR/reviews"; mv "$CASE_DIR/reviews" "$GH_STUB_DIR/reviews" ;;
          inline) review_set 1 "$severity" ;;
          summary) jq --arg p "$severity" '.[0].body+="\n["+$p+"] Current head blocker"' "$GH_STUB_DIR/issue-comments" > "$CASE_DIR/comments"; mv "$CASE_DIR/comments" "$GH_STUB_DIR/issue-comments" ;;
        esac
        jq '.[0].submitted_at="2026-10-22T03:00:00Z"' "$GH_STUB_DIR/reviews" > "$CASE_DIR/reviews"
        mv "$CASE_DIR/reviews" "$GH_STUB_DIR/reviews"
        review_receipt_set "${head:0:7}"
        jq --arg time "$time" '.[0].created_at=$time | .[0].updated_at=$time' "$GH_STUB_DIR/receipt" > "$CASE_DIR/receipt"
        jq -s 'add' "$GH_STUB_DIR/issue-comments" "$CASE_DIR/receipt" > "$CASE_DIR/comments"
        mv "$CASE_DIR/comments" "$GH_STUB_DIR/issue-comments"
        review_receipt_parse "$head"
        jq -e --arg p "$severity" '.exists and (.clean|not) and .high[0].severity==$p' "$CASE_DIR/result"
      done
    done
  done
  # A newer running or invalid summary cannot be satisfied by an old receipt.
  printf '[]\n' > "$GH_STUB_DIR/reviews"
  printf '[]\n' > "$GH_STUB_DIR/comments"
  for source in unknown running; do
    review_summary_set "$head" "$source" true
    if [ "$source" = unknown ]; then review_summary_set "$head" completed null; fi
    review_receipt_set "${head:0:7}"
    jq '.[0] |= (.created_at="2026-10-22T02:00:00Z" | .updated_at=.created_at)' "$GH_STUB_DIR/receipt" > "$CASE_DIR/receipt"
    jq -s 'add' "$GH_STUB_DIR/issue-comments" "$CASE_DIR/receipt" > "$CASE_DIR/comments"
    mv "$CASE_DIR/comments" "$GH_STUB_DIR/issue-comments"
    review_receipt_parse "$head"
    jq -e '(.exists|not) and (.clean|not)' "$CASE_DIR/result"
  done
}
case_review_receipt_wait() {
  review_fixture
  local head
  head=$(git -C "$REPO" rev-parse HEAD)
  printf '[]\n' > "$GH_STUB_DIR/reviews"
  review_summary_set "$head" completed true
  review_receipt_set "${head:0:7}"
  jq -s 'add' "$GH_STUB_DIR/issue-comments" "$GH_STUB_DIR/receipt" > "$CASE_DIR/comments"
  mv "$CASE_DIR/comments" "$GH_STUB_DIR/issue-comments"
  dv pr-wait P-1 --foreground > "$CASE_DIR/result" || { cat "$CASE_DIR/result"; return 1; }
  jq -e '.green and .review.clean and .review_handled and (.review_timed_out|not) and (.blocked|not)' "$CASE_DIR/result"
  ! grep -q '^pr comment ' "$GH_STUB_DIR/calls"
  dv 'done' P-1
  jq -e '.checks=="green" and .review=="handled"' "$DV_STATE/P-1/done.json"
}
case_review_receipt_arrives() {
  review_fixture
  local head waiter attempt
  head=$(git -C "$REPO" rev-parse HEAD)
  printf '[]\n' > "$GH_STUB_DIR/reviews"
  review_summary_set "$head" completed true
  DV_REVIEW_WAIT=30 dv pr-wait P-1 --foreground > "$CASE_DIR/result" & waiter=$!
  # Publish only after the waiter has observed the missing review and persisted
  # its first deadline. An atomic rename keeps the gh snapshot well-formed.
  for attempt in {1..100}; do
    if [ -s "$DV_STATE/P-1/pr-loop.json" ]; then break; fi
    sleep 0.1
  done
  review_receipt_set "${head:0:7}"
  jq -s 'add' "$GH_STUB_DIR/issue-comments" "$GH_STUB_DIR/receipt" > "$CASE_DIR/comments"
  mv "$CASE_DIR/comments" "$GH_STUB_DIR/issue-comments"
  wait "$waiter" || { cat "$CASE_DIR/result"; return 1; }
  jq -e --arg head "$head" '.requests[$head].retried==false and .review_handled' "$DV_STATE/P-1/pr-loop.json"
  jq -e '.green and .review.clean and (.review_timed_out|not) and (.blocked|not)' "$CASE_DIR/result"
  ! grep -q '^pr comment ' "$GH_STUB_DIR/calls"
}

case_review_receipt_incomplete() {
  review_fixture
  local head source severity status
  head=$(git -C "$REPO" rev-parse HEAD)
  for source in rest inline; do
    for severity in P0 P1; do
      for status in running unknown inconsistent; do
        review_set 1 "$severity"
        if [ "$source" = rest ]; then
          jq --arg p "$severity" '.[0].body="["+$p+"] Current head blocker"' "$GH_STUB_DIR/reviews" > "$CASE_DIR/reviews"
          mv "$CASE_DIR/reviews" "$GH_STUB_DIR/reviews"
          printf '[]\n' > "$GH_STUB_DIR/comments"
        fi
        case "$status" in
          running) review_summary_set "$head" running null ;;
          unknown) review_summary_set "$head" completed null ;;
          inconsistent)
            review_summary_set "$head" completed false
            jq '.[0].body|=sub("has_unresolved_findings\\\":false";"has_unresolved_findings\":true")' "$GH_STUB_DIR/issue-comments" > "$CASE_DIR/comments"
            mv "$CASE_DIR/comments" "$GH_STUB_DIR/issue-comments" ;;
        esac
        review_receipt_set "${head:0:7}"
        jq -s 'add' "$GH_STUB_DIR/issue-comments" "$GH_STUB_DIR/receipt" > "$CASE_DIR/comments"
        mv "$CASE_DIR/comments" "$GH_STUB_DIR/issue-comments"
        review_receipt_parse "$head"
        jq -e --arg p "$severity" '.exists and (.clean|not) and .high[0].severity==$p' "$CASE_DIR/result"
      done
    done
  done
}

case_review_receipt_metadata() {
  repo receipt-metadata
  local head time
  head=$(git -C "$REPO" rev-parse HEAD)
  printf '[]\n' > "$GH_STUB_DIR/reviews"
  printf '[{"id":101,"commit_id":"old-head","pull_request_review_id":1,"user":{"login":"chatgpt-codex-connector[bot]"},"body":"[P1] Old head"}]\n' > "$GH_STUB_DIR/comments"
  review_receipt_set "${head:0:10}"
  # PR #188 publishes the metadata-only completed summary three seconds after
  # its clean receipt. Later security activity can edit that comment again.
  for time in 2026-10-22T04:00:00Z 2026-10-22T04:00:03Z 2026-10-22T05:00:00Z; do
    review_summary_set "$head" completed true
    jq --arg time "$time" '.[0].updated_at=$time' "$GH_STUB_DIR/issue-comments" > "$CASE_DIR/summary"
    jq -s 'add' "$CASE_DIR/summary" "$GH_STUB_DIR/receipt" > "$GH_STUB_DIR/issue-comments"
    review_receipt_parse "$head"
    jq -e '.exists and .clean and .source=="receipt" and .findings==[]' "$CASE_DIR/result"
  done
}

case_review_receipt_ambiguous() {
  repo receipt-collision
  local nonce old head
  # Two precomputed commit objects share seven hex digits. No brute force runs
  # in the test: the old clean receipt must not authorize the distinct head.
  git -C "$REPO" mktree < /dev/null > /dev/null
  for nonce in 21043 27714; do
    printf 'tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor Test <test@example.invalid> 0 +0000\ncommitter Test <test@example.invalid> 0 +0000\n\nreceipt collision %s\n' "$nonce" |
      git -C "$REPO" hash-object -w -t commit --stdin
  done > "$CASE_DIR/commits"
  old=$(head -n 1 "$CASE_DIR/commits"); head=$(tail -n 1 "$CASE_DIR/commits")
  test "$old" != "$head"
  test "${old:0:7}" = "${head:0:7}"
  printf '[]\n' > "$GH_STUB_DIR/reviews"
  printf '[]\n' > "$GH_STUB_DIR/comments"
  review_receipt_set "${old:0:7}"
  cp "$GH_STUB_DIR/receipt" "$GH_STUB_DIR/issue-comments"
  review_receipt_parse "$head"
  jq -e '(.exists|not) and (.clean|not)' "$CASE_DIR/result"
  # A longer unique abbreviation still works with both colliding objects.
  review_receipt_set "${head:0:10}"
  cp "$GH_STUB_DIR/receipt" "$GH_STUB_DIR/issue-comments"
  review_receipt_parse "$head"
  jq -e '.exists and .clean' "$CASE_DIR/result"
  # Missing local objects cannot establish a short receipt's commit binding.
  head=ffffffffffffffffffffffffffffffffffffffff
  review_receipt_set "${head:0:7}"
  cp "$GH_STUB_DIR/receipt" "$GH_STUB_DIR/issue-comments"
  review_receipt_parse "$head"
  jq -e '(.exists|not) and (.clean|not)' "$CASE_DIR/result"
}

case_review_followup_source() {
  # Retain the moved-job regression using authoritative closing references.
  review_fixture
  export S="$DV_STATE/P-1"
  local pr='https://github.com/test/repo/pull/1'
  # shellcheck source=/dev/null
  source "$ROOT/lib/pr-review.sh"
  ISSUE=LN-214M
  review_closing_issues '[{"number":214,"repository":{"nameWithOwner":"test/repo"}}]' > "$GH_STUB_DIR/closing-issues"
  test "$(review_source_issue "$pr" test/repo)" = 214
  review_closing_issues '[]' > "$GH_STUB_DIR/closing-issues"
  # A suffixed key alone must not invent a source issue number.
  test -z "$(review_source_issue "$pr" test/repo)"
  ISSUE=P-7
  test "$(review_source_issue "$pr" test/repo)" = 7
  ISSUE=LN-212M
  review_closing_issues '[{"number":300,"repository":{"nameWithOwner":"test/repo"}}]' > "$GH_STUB_DIR/closing-issues"
  test "$(review_source_issue "$pr" test/repo)" = 300
}
