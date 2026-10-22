#!/usr/bin/env bash
# Codex review data is never evaluated as shell or worker instructions.
# shellcheck disable=SC2016
review_endpoint() {
  if [[ "$1" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)$ ]]; then
    printf 'repos/%s/%s/pulls/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  else fail 'invalid PR URL'; fi
}
review_snapshot() {
  local pr=$1 file=$2 endpoint reviews comments summaries tmp
  endpoint=$(review_endpoint "$pr")
  reviews=$(mktemp "$S/.reviews.XXXXXX"); comments=$(mktemp "$S/.comments.XXXXXX")
  summaries=$(mktemp "$S/.summaries.XXXXXX")
  # Read the summary first: a newly submitted REST review can supersede an
  # older running summary. Security-only activity never satisfies code review.
  if ! gh api --paginate "${endpoint%/pulls/*}/issues/${endpoint##*/}/comments" | jq -se 'add // [] | select(type=="array")' > "$summaries" ||
    ! gh api --paginate "$endpoint/reviews" | jq -se 'add // [] | select(type=="array")' > "$reviews" ||
    ! gh api --paginate "$endpoint/comments" | jq -se 'add // [] | select(type=="array")' > "$comments"; then
    rm -f "$reviews" "$comments" "$summaries"; return 1
  fi
  tmp=$(mktemp "$S/.review-snapshot.XXXXXX")
  jq --slurpfile reviews "$reviews" --slurpfile comments "$comments" --slurpfile summaries "$summaries" \
    '. + {reviews:$reviews[0],inline_comments:$comments[0],issue_comments:$summaries[0]}' "$file" > "$tmp"
  rm "$reviews" "$comments" "$summaries"
  mv "$tmp" "$file"
}
review_parse() {
  local file=$1 head=$2 sha resolved prefixes='[]'
  local receipt_pattern='^\*\*Reviewed commit:\*\*[[:blank:]]+`(?<sha>[0-9a-fA-F]{7,40})`[[:space:]]*$'
  # Bind abbreviations to Git objects, not just matching text: two distinct
  # commits can share seven digits. Unknown or ambiguous prefixes fail closed.
  while IFS= read -r sha; do
    resolved=$(git rev-parse --disambiguate="$sha" 2>/dev/null) || continue
    [ "$resolved" = "$head" ] || continue
    prefixes=$(printf '%s\n' "$prefixes" | jq --arg sha "$sha" '.+[$sha]')
  done < <(jq -r --arg pattern "$receipt_pattern" '[.issue_comments[]? | .body // "" | split("\n")[] |
    capture($pattern).sha | ascii_downcase | select(length<40)] | unique[]' "$file")
  jq --arg head "$head" --arg bots "$DV_REVIEW_BOTS" --arg pattern "$receipt_pattern" --argjson prefixes "$prefixes" '
    # The legacy setting may still include Devin. It can never replace Codex.
    def bot: . as $login | (test("codex";"i") and endswith("[bot]")) and
      (($bots|split(",")) | any(.[]; . as $pattern | $pattern!="" and ($login|test($pattern;"i"))));
    def findings($source): . as $item | (.body // "" | split("\n")[]) as $line |
      [$line | match("P[0-3] Badge|\\[P[0-3]\\]|^[[:space:]#*_-]*P[0-3][[:space:]]*:";"ig") |
        .string | capture("(?<severity>P[0-3])";"i").severity | ascii_upcase] | unique[] |
      {severity:.,path:($item.path // "review"),line:($item.line // $item.original_line // "summary"),
       body:$line,id:$item.id,source:$source};
    def review_findings($review):
      [($review | select(.!=null) | findings("summary")),
       (.inline_comments[]? | select($review!=null and .commit_id==$head and .pull_request_review_id==$review.id and
         .user.login==$review.user.login) | findings("inline"))];
    . as $snapshot |
    [.reviews[]? | select((.user.login // "" | bot) and .commit_id==$head and
      (.state=="COMMENTED" or .state=="APPROVED" or .state=="CHANGES_REQUESTED"))] |
    sort_by(.submitted_at,.id) | last as $rest |
    [$snapshot.issue_comments[]? | select((.user.login // "" | bot) and
      ((.body // "")|contains("<!-- codex-pull-request-review-summary -->"))) | . as $comment |
      (try ((.body | capture("<!-- codex-review-state:v1 (?<json>.*?) -->";"s").json | fromjson).code_review) catch empty) as $state |
      select($state!=null and $state.commit_sha==$head) | {comment:$comment,state:$state}] |
    sort_by(.comment.updated_at,.comment.id) | last as $summary |
    [$snapshot.issue_comments[]? | select((.user.login // "" | bot) and
      ((.body // "") | contains("<!-- codex-review-receipt:v1 -->") and
        contains("Codex Review: Didn\u0027t find any major issues"))) |
      . as $comment | (.body | split("\n")[] | capture($pattern).sha | ascii_downcase) as $sha |
      select(($head | startswith($sha)) and (($sha|length)==40 or ($prefixes|index($sha))!=null)) |
      $comment | select((.updated_at // .created_at // "")!="" and ([findings("receipt")]|length)==0)] |
    sort_by((.updated_at // .created_at),.id) | last as $receipt |
    ($summary!=null and ($rest==null or ($summary.comment.updated_at // "")>=($rest.submitted_at // ""))) as $fresh |
    (if $fresh and $summary.state.status=="completed" and $summary.state.has_any_findings==true and
       ($summary.state.has_unresolved_findings|type)=="boolean" then
       [$summary.comment | findings("summary")] else [] end) as $summary_findings |
    # A completed finding-bearing summary supplies its own findings. Use
    # those instead of borrowing findings from an older REST receipt.
    (if ($summary_findings|length)>0 then
       $summary.comment + {id:("summary-"+($summary.comment.id|tostring)),source:"summary"}
     elif $fresh and $summary.state.status=="completed" and $summary.state.has_any_findings==false and
        $summary.state.has_unresolved_findings==false then
       $summary.comment + {id:("summary-"+($summary.comment.id|tostring)),source:"summary"}
     elif $fresh and ($summary.state.status!="completed" or
       ($summary.state.has_any_findings|type)!="boolean" or ($summary.state.has_unresolved_findings|type)!="boolean" or
       ($summary.state.has_any_findings==false and $summary.state.has_unresolved_findings!=false)) then null
     else $rest end) as $review |
    ($snapshot | review_findings($review)) as $findings |
    # A completed metadata-only summary may be published after the receipt,
    # carrying old-head flags. Its edit time cannot invalidate a clean review.
    # Running/incomplete summaries and actual current-head findings still gate it.
    (if $receipt!=null and ($findings|length)==0 and
        ($receipt.updated_at // $receipt.created_at)>($rest.submitted_at // "") and
        (($receipt.updated_at // $receipt.created_at)>($summary.comment.updated_at // "") or
         ($summary.state.status=="completed" and $summary.state.has_any_findings==true and
          ($summary.state.has_unresolved_findings|type)=="boolean" and ($summary_findings|length)==0)) then
       # An incomplete summary may have hidden the REST review above. A
       # receipt cannot erase its findings just because selection returned null.
       if $review==null and ($snapshot | review_findings($rest) | length)>0 then $rest
       else $receipt + {id:("receipt-"+($receipt.id|tostring)),source:"receipt"} end
     else $review end) as $review |
    ($snapshot | review_findings($review)) as $findings |
    {id:($review.id // null),head:$head,
     exists:($review!=null and
       ($review.source=="receipt" or
         (($fresh and $summary.state.has_any_findings==true and ($findings|length)==0)|not))),
     source:($review.source // "review"),summary:($review.body // $summary.comment.body // ""),findings:$findings,
     high:[$findings[] | select(.severity=="P0" or .severity=="P1")],
     low:[$findings[] | select(.severity=="P2" or .severity=="P3")]} |
    .clean=(.exists and (.high|length)==0)
  ' "$file"
}
review_require_clean() (
  local pr=$1 file=$2 head=$3 result
  cd "$WT" || exit
  until pr_wait_lock; do sleep "$DV_POLL_INTERVAL"; done
  trap pr_wait_unlock EXIT
  review_snapshot "$pr" "$file" || return 1
  result=$(mktemp "$S/.review-gate.XXXXXX")
  review_parse "$file" "$head" > "$result"
  if ! jq -e '.clean' "$result" >/dev/null; then
    cat "$result" >&2; rm "$result"
    fail 'current head requires a clean Codex review (no P0/P1)'
  fi
  review_followup "$pr" "$result"
  rm "$result"
)
# The issue a PR closes is the follow-up's dependency. A moved job keeps its
# key with a suffix (LN-214M), so the key's tail is not always a number:
# prefer the PR body's Closes line, then the key's leading digits.
review_source_issue() {
  local number=''
  [ ! -f "$S/pr.md" ] || number=$(grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' "$S/pr.md" | head -1 | grep -oE '[0-9]+$')
  [ -n "$number" ] || number=$(printf '%s\n' "${ISSUE##*-}" | grep -oE '^[0-9]+' || true)
  printf '%s\n' "$number"
}
review_followup() {
  local pr=$1 result=$2 endpoint repository number marker issues existing body payload response milestone link tmp remote_body
  jq -e '.clean and (.low|length)>0' "$result" >/dev/null || return 0
  endpoint=$(review_endpoint "$pr"); repository=${endpoint%/pulls/*}
  number=$(review_source_issue)
  [[ "$number" =~ ^[0-9]+$ ]] || fail 'cannot identify the source issue for review follow-up'
  marker="<!-- devflow-review-followup: $pr -->"
  issues=$(mktemp "$S/.followup-issues.XXXXXX")
  gh api --paginate "$repository/issues?state=all&per_page=100" | jq -s 'add // []' > "$issues"
  existing=$(jq -r --arg marker "$marker" '[.[] | select(.pull_request==null and ((.body // "")|contains($marker)))] | first | .number // empty' "$issues")
  rm "$issues"
  body=$(mktemp "$S/.followup-body.XXXXXX")
  {
    printf '%s\n\nDepends on #%s\n\nP2/P3 findings from the final Codex review of %s:\n\n' "$marker" "$number" "$pr"
    jq -r '.low[] | "- \(.severity) \(.path):\(.line): \(.body | gsub("[\\r\\n]";" "))"' "$result"
  } > "$body"
  payload=$(mktemp "$S/.followup-payload.XXXXXX")
  milestone=$(gh api "$repository/issues/$number" --jq '.milestone.number // null')
  jq -n --rawfile body "$body" --arg title "Follow up on Codex review of PR #${pr##*/}" --argjson milestone "$milestone" \
    '{title:$title,body:$body,milestone:$milestone}' > "$payload"
  response=$(mktemp "$S/.followup-response.XXXXXX")
  if [ -n "$existing" ]; then
    gh api --method PATCH "$repository/issues/$existing" --input "$payload" > "$response"
  else
    gh api --method POST "$repository/issues" --input "$payload" > "$response"
  fi
  jq -e '.number and .html_url' "$response" >/dev/null
  mv "$response" "$S/pr-review-followup.json"
  existing=$(jq -r .number "$S/pr-review-followup.json")
  link="Review follow-up: #$existing ($(jq -r .html_url "$S/pr-review-followup.json"))."
  # Append to worker-owned prose; never replace its report or prepared PR body.
  if ! grep -Fq "$link" "$S/report.md" 2>/dev/null; then printf '\n%s\n' "$link" >> "$S/report.md"; fi
  remote_body=$(mktemp "$S/.followup-pr.XXXXXX")
  gh api "$endpoint" --jq '.body // ""' > "$remote_body"
  if ! grep -Fq "$link" "$remote_body"; then
    printf '\n%s\n' "$link" >> "$remote_body"
    gh api --method PATCH "$endpoint" -F "body=@$remote_body" >/dev/null
  fi
  if [ -f "$S/pr.md" ]; then
    if ! grep -Fq "$link" "$S/pr.md"; then printf '\n%s\n' "$link" >> "$S/pr.md"; fi
  else
    tmp=$(mktemp "$S/.followup-public.XXXXXX"); cp "$remote_body" "$tmp"; mv "$tmp" "$S/pr.md"
  fi
  rm "$body" "$payload" "$remote_body"
}
