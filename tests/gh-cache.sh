#!/usr/bin/env bash
case_gh_cache_conditional() {
  bidding_functions
  local endpoint=repos/test/repo/issues/1/comments
  printf '[{"body":"cached body"}]\n' > "$GH_STUB_DIR/issue-comments"
  gh_get_cached "$endpoint?per_page=100&page=1" > "$CASE_DIR/first"
  export GH_CACHE_304_EXIT=1
  gh_get_cached "$endpoint?per_page=100&page=1" > "$CASE_DIR/second"
  cmp "$CASE_DIR/first" "$CASE_DIR/second"
  grep 'If-None-Match:' "$GH_STUB_DIR/calls"
  test "$(cat "$GH_STUB_DIR/cache-status")" = "$(printf '200\n304')"
}
case_gh_cache_fail_closed() {
  bidding_functions
  local endpoint='repos/test/repo/issues/1/comments?per_page=100&page=1'
  printf '[{"body":"old"}]\n' > "$GH_STUB_DIR/issue-comments"
  gh_get_cached "$endpoint" > "$CASE_DIR/old"
  touch "$GH_STUB_DIR/cache-fail"
  if gh_get_cached "$endpoint" > "$CASE_DIR/error"; then return 1; fi
  test ! -s "$CASE_DIR/error"
  rm "$GH_STUB_DIR/cache-fail"
  touch "$GH_STUB_DIR/cache-invalid"
  if gh_get_cached "$endpoint" > "$CASE_DIR/error" 2>/dev/null; then return 1; fi
  rm "$GH_STUB_DIR/cache-invalid"
  gh_get_cached "$endpoint" > "$CASE_DIR/restored"
  cmp "$CASE_DIR/old" "$CASE_DIR/restored"
  printf '[{"body":"new"}]\n' > "$GH_STUB_DIR/issue-comments"
  gh_get_cached "$endpoint" | jq -e '.[0].body=="new"'
  # A corrupt local entry is a miss, never a validator without a valid body.
  printf '{invalid\n' > "$DV_HOME"/gh-cache/*.json
  gh_get_cached "$endpoint" 2>/dev/null | jq -e '.[0].body=="new"'
  if tail -n 1 "$GH_STUB_DIR/calls" | grep 'If-None-Match:'; then return 1; fi
}
case_gh_cache_immutable() {
  qa_merge_fixture
  local endpoint='repos/test/repo/compare/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa...bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  gh_get_cached "$endpoint" > "$CASE_DIR/first"
  gh_get_cached "$endpoint" > "$CASE_DIR/second"
  cmp "$CASE_DIR/first" "$CASE_DIR/second"
  test "$(wc -l < "$GH_STUB_DIR/calls" | tr -d ' ')" = 1
  gh_get_cached repos/test/repo/compare/main...feature > /dev/null
  gh_get_cached repos/test/repo/compare/main...feature > /dev/null
  test "$(wc -l < "$GH_STUB_DIR/calls" | tr -d ' ')" = 3
  tail -n 1 "$GH_STUB_DIR/calls" | grep 'If-None-Match:'
}
case_review_cache_pass_counts() {
  review_fixture
  local pass
  for pass in 1 2; do
    : > "$GH_STUB_DIR/calls"
    : > "$GH_STUB_DIR/cache-status"
    dv pr-wait P-1 --foreground --review-handled > "$CASE_DIR/result"
    jq -e '.green and .review.clean and .review_handled' "$CASE_DIR/result"
    printf 'pr-wait pass %s: gh=%s views=%s review GETs=%s 200=%s 304=%s\n' "$pass" \
      "$(wc -l < "$GH_STUB_DIR/calls" | tr -d ' ')" "$(grep -c '^pr view' "$GH_STUB_DIR/calls")" \
      "$(grep -c '^api --include' "$GH_STUB_DIR/calls")" \
      "$(grep -c '^200$' "$GH_STUB_DIR/cache-status" || true)" "$(grep -c '^304$' "$GH_STUB_DIR/cache-status" || true)"
    test "$(grep -c '^api --include' "$GH_STUB_DIR/calls")" = 3
  done
  test "$(grep -c '^304$' "$GH_STUB_DIR/cache-status")" = 3
}
case_review_cache_snapshot() {
  review_fixture
  bidding_functions
  # shellcheck source=lib/pr-review.sh
  source "$ROOT/lib/pr-review.sh"
  local S="$DV_STATE/P-1" pr=https://github.com/test/repo/pull/1 field endpoint calls
  # More than one page on every list, with a full final page on comments.
  jq -n '[range(0;101) | {id:.,body:("summary " + tostring)}]' > "$GH_STUB_DIR/issue-comments"
  jq -n '[range(0;200) | {id:.,body:("inline " + tostring)}]' > "$GH_STUB_DIR/comments"
  jq -n '[range(0;101) | {id:.,body:("review " + tostring)}]' > "$GH_STUB_DIR/reviews"
  printf '{"headRefOid":"test","state":"OPEN"}\n' > "$CASE_DIR/base"
  cp "$CASE_DIR/base" "$CASE_DIR/expected"
  for field in issue_comments reviews inline_comments; do
    case "$field" in
      issue_comments) endpoint=repos/test/repo/issues/1/comments ;;
      reviews) endpoint=repos/test/repo/pulls/1/reviews ;;
      inline_comments) endpoint=repos/test/repo/pulls/1/comments ;;
    esac
    gh api --paginate "$endpoint" | jq -s 'add // []' > "$CASE_DIR/list"
    jq --arg field "$field" --slurpfile list "$CASE_DIR/list" '.[$field]=$list[0]' "$CASE_DIR/expected" > "$CASE_DIR/next"
    mv "$CASE_DIR/next" "$CASE_DIR/expected"
  done
  # Match the established snapshot key order as well as values.
  jq '{headRefOid,state,reviews,inline_comments,issue_comments}' "$CASE_DIR/expected" > "$CASE_DIR/legacy"
  cp "$CASE_DIR/base" "$CASE_DIR/snapshot"
  : > "$GH_STUB_DIR/calls"
  review_snapshot "$pr" "$CASE_DIR/snapshot"
  cmp "$CASE_DIR/legacy" "$CASE_DIR/snapshot"
  jq -e '(.reviews|length)==101 and (.inline_comments|length)==200 and (.issue_comments|length)==101' "$CASE_DIR/snapshot"
  cp "$CASE_DIR/snapshot" "$CASE_DIR/cold"
  review_snapshot "$pr" "$CASE_DIR/snapshot"
  cmp "$CASE_DIR/cold" "$CASE_DIR/snapshot"
  calls=$(wc -l < "$GH_STUB_DIR/calls" | tr -d ' ')
  printf 'review snapshot: two passes, gh calls=%s, 200=%s, 304=%s\n' "$calls" \
    "$(grep -c '^200$' "$GH_STUB_DIR/cache-status" 2>/dev/null || true)" \
    "$(grep -c '^304$' "$GH_STUB_DIR/cache-status" 2>/dev/null || true)"
  test "$(grep -c 'If-None-Match:' "$GH_STUB_DIR/calls")" = 7
  # Revalidate page 2 edits and list shrinkage; no stale trailing comments.
  jq '.[100].body="edited"' "$GH_STUB_DIR/reviews" > "$CASE_DIR/edited"
  mv "$CASE_DIR/edited" "$GH_STUB_DIR/reviews"
  printf '[]\n' > "$GH_STUB_DIR/comments"
  review_snapshot "$pr" "$CASE_DIR/snapshot"
  jq -e '.reviews[100].body=="edited" and .inline_comments==[]' "$CASE_DIR/snapshot"
  cp "$CASE_DIR/snapshot" "$CASE_DIR/last-good"
  touch "$GH_STUB_DIR/comments-fail"
  if review_snapshot "$pr" "$CASE_DIR/snapshot"; then return 1; fi
  cmp "$CASE_DIR/last-good" "$CASE_DIR/snapshot"
}
