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
