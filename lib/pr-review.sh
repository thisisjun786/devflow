#!/usr/bin/env bash
# Codex review data is never evaluated as shell or worker instructions.
# shellcheck disable=SC2016
review_endpoint() {
  if [[ "$1" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)$ ]]; then
    printf 'repos/%s/%s/pulls/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  else fail 'invalid PR URL'; fi
}
review_snapshot() {
  local pr=$1 file=$2 endpoint reviews comments tmp
  endpoint=$(review_endpoint "$pr")
  reviews=$(mktemp "$S/.reviews.XXXXXX"); comments=$(mktemp "$S/.comments.XXXXXX")
  if ! gh api --paginate "$endpoint/reviews" | jq -se 'add // [] | select(type=="array")' > "$reviews" ||
    ! gh api --paginate "$endpoint/comments" | jq -se 'add // [] | select(type=="array")' > "$comments"; then
    rm -f "$reviews" "$comments"; return 1
  fi
  tmp=$(mktemp "$S/.review-snapshot.XXXXXX")
  jq --slurpfile reviews "$reviews" --slurpfile comments "$comments" \
    '. + {reviews:$reviews[0],inline_comments:$comments[0]}' "$file" > "$tmp"
  rm "$reviews" "$comments"
  mv "$tmp" "$file"
}
review_parse() {
  local file=$1 head=$2
  jq --arg head "$head" --arg bots "$DV_REVIEW_BOTS" '
    def bot: . as $login | ($bots|split(",")) | any(.[]; . as $pattern | $pattern!="" and ($login|test($pattern;"i")));
    def findings($source): . as $item | (.body // "" | split("\n")[]) as $line |
      [$line | match("P[0-3] Badge|\\[P[0-3]\\]|^[[:space:]#*_-]*P[0-3][[:space:]]*:";"ig") |
        .string | capture("(?<severity>P[0-3])";"i").severity | ascii_upcase] | unique[] |
      {severity:.,path:($item.path // "review"),line:($item.line // $item.original_line // "summary"),
       body:$line,id:$item.id,source:$source};
    . as $snapshot |
    [.reviews[]? | select((.user.login // "" | bot) and .commit_id==$head and
      (.state=="COMMENTED" or .state=="APPROVED" or .state=="CHANGES_REQUESTED"))] |
    sort_by(.submitted_at,.id) | last as $review |
    [($review | select(.!=null) | findings("summary")),
     ($snapshot.inline_comments[]? | select($review!=null and .commit_id==$head and .pull_request_review_id==$review.id and
       .user.login==$review.user.login) | findings("inline"))] as $findings |
    {id:($review.id // null),head:$head,exists:($review!=null),summary:($review.body // ""),findings:$findings,
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
review_followup() {
  local pr=$1 result=$2 endpoint repository number marker issues existing body payload response milestone link tmp remote_body
  jq -e '.clean and (.low|length)>0' "$result" >/dev/null || return 0
  endpoint=$(review_endpoint "$pr"); repository=${endpoint%/pulls/*}
  number=${ISSUE##*-}
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
