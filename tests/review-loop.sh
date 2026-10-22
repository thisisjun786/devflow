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
