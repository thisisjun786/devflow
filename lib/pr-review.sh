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
  if ! gh_get_cached_pages "${endpoint%/pulls/*}/issues/${endpoint##*/}/comments" > "$summaries" ||
    ! gh_get_cached_pages "$endpoint/reviews" > "$reviews" ||
    ! gh_get_cached_pages "$endpoint/comments" > "$comments"; then
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
    def finding_line: test("P[0-3] Badge|\\[P[0-3]\\]|^[[:space:]#*_-]*P[0-3][[:space:]]*:";"i");
    # Detail: the first paragraph after a finding line, before the next finding.
    def detail: map(select(test("^[[:space:]]*Useful\\? React with")|not)) |
      until(length==0 or (.[0]|finding_line) or (.[0]|test("[^[:space:]]")); .[1:]) |
      reduce .[] as $line ({stop:false,text:[]};
        if .stop or ($line|finding_line) or ($line|test("[^[:space:]]")|not) then .stop=true
        else .text+=[$line] end) | .text | join(" ");
    def findings($source): . as $item | (.body // "" | split("\n")) as $lines |
      range(0; $lines|length) as $index | $lines[$index] as $line |
      [$line | match("P[0-3] Badge|\\[P[0-3]\\]|^[[:space:]#*_-]*P[0-3][[:space:]]*:";"ig") |
        .string | capture("(?<severity>P[0-3])";"i").severity | ascii_upcase] | unique[] |
      {severity:.,path:($item.path // "review"),line:($item.line // $item.original_line // "summary"),
       body:$line,detail:($lines[$index+1:] | detail),id:$item.id,source:$source};
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
review_source_issue() {
  local pr=$1 repository=$2 number references
  number=$(jq -r '.source_issue // empty | tostring' "$S/meta")
  if [[ "$number" =~ ^[1-9][0-9]*$ ]]; then printf '%s\n' "$number"; return; fi
  # Older gh versions do not expose closingIssuesReferences via pr view.
  # Read all pages and exclude cross-repository references before deduping.
  if references=$(gh api graphql --paginate -f owner="${repository%%/*}" -f name="${repository#*/}" \
    -F number="${pr##*/}" -f query='
      query($owner:String!, $name:String!, $number:Int!, $endCursor:String) {
        repository(owner:$owner, name:$name) {
          pullRequest(number:$number) {
            closingIssuesReferences(first:100, after:$endCursor) {
              nodes { number repository { nameWithOwner } }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
      }'); then
    number=$(jq -sr --arg repository "$repository" '
      if length==0 or any(.[]; (.errors|length)>0 or
        (.data.repository.pullRequest.closingIssuesReferences.nodes|type)!="array") then empty
      else [.[].data.repository.pullRequest.closingIssuesReferences.nodes[] |
        select((.repository.nameWithOwner|ascii_downcase)==($repository|ascii_downcase)) |
        .number | tostring | select(test("^[1-9][0-9]*$"))] | unique |
        if length==1 then .[0] else empty end end' <<< "$references") || number=''
    if [ -n "$number" ]; then printf '%s\n' "$number"; return; fi
  fi
  number=${ISSUE##*-}
  if [[ "$number" =~ ^[1-9][0-9]*$ ]]; then printf '%s\n' "$number"; fi
  return 0
}
review_followup_issue() {
  local result=$1 pr=$2 number=$3 marker=$4
  # Follow the shared issue format in docs/issue-format.md: a conventional
  # title from the first finding and Summary/Done when/Context sections.
  jq --arg pr "$pr" --arg number "$number" --arg marker "$marker" '
    def clean: gsub("<!--.*?-->";"") | gsub("!\\[[^\\]]*\\]\\([^)]*\\)";"") | gsub("<[^>]*>";"") |
      gsub("[[:space:]]+";" ") | sub("^ ";"") | sub(" $";"");
    def stop: if test("[.!?]$") then . else .+"." end;
    def headline: clean | ((capture("\\*\\*(?<text>.+?)\\*\\*").text) //
        (gsub("\\[P[0-3]\\]|P[0-3] Badge";"";"i") | sub("^[[:space:]#*_-]*(P[0-3][[:space:]]*:)?";"";"i"))) |
      clean | sub("[[:space:]*_.:;,]+$";"") | if .=="" then "address the remaining review findings" else . end;
    def sentence: clean | ((capture("^(?<text>.*?[.!?])( |$)").text) // .) | if .=="" then . else stop end;
    def lower_first: if test("^[A-Z][A-Z0-9]") then . else (.[0:1]|ascii_downcase)+.[1:] end;
    def cut($size): if length>$size then .[0:$size-1] | sub("[[:space:]]+$";"") | .+"\u2026" else . end;
    # Scope: the parent directory, or the file stem for generic directories.
    def scope: if .source!="inline" then "" else (.path | split("/")) as $parts |
      (if ($parts|length)>1 then $parts[-2]|ascii_downcase else "" end) as $dir |
      (if $dir=="" or ($dir|IN("lib","src","internal","cmd","scripts","docs","tests","test","pkg","app","core","bin"))
       then $parts[-1] | (sub("\\.[^.]*$";"") | if .=="" then null else . end) // $parts[-1] else $dir end) |
      ascii_downcase | gsub("[^a-z0-9-]+";"-") | sub("^-+";"") | .[0:32] | sub("-+$";"") end;
    def location: if .source=="inline" then .path+(if (.line|type)=="number" then ":\(.line)" else "" end)
      else "review summary" end;
    .low as $low | ($low[0] | scope) as $scope |
    ("fix"+(if $scope=="" then "" else "("+$scope+")" end)+": ") as $prefix |
    (if ($low|length)>1 then " (+\(($low|length)-1) more)" else "" end) as $suffix |
    ($low[0].body | headline | lower_first | cut(72)) as $phrase |
    {title:($prefix+($phrase | cut(90-($prefix|length)-($suffix|length)))+$suffix),
     body:("## Summary\nP2/P3 findings left after the review of #\($pr|split("/")|last).\n\n" +
       ([$low[] | (.detail // "" | sentence) as $detail |
         "- \(.severity) \(location) \u2014 \(.body | headline | stop)"+(if $detail=="" then "" else " "+$detail end)] | join("\n")) +
       "\n\n## Done when\n- [ ] each finding fixed, or answered here with the reason it stays.\n\n## Context\n" +
       (if $number=="" then "" else "Depends on #\($number)\n" end) +
       "Source: Codex review of \($pr)\n\($marker)\n")}' "$result"
}
review_followup() {
  local pr=$1 result=$2 endpoint repository number marker issues existing draft payload response milestone link tmp remote_body warning
  jq -e '.clean and (.low|length)>0' "$result" >/dev/null || return 0
  endpoint=$(review_endpoint "$pr"); repository=${endpoint%/pulls/*}
  number=$(review_source_issue "$pr" "${repository#repos/}")
  if [ -z "$number" ]; then
    warning="Warning: cannot resolve the source GitHub issue for $pr; creating the review follow-up without Depends on or milestone."
    if ! grep -Fq "$warning" "$S/report.md" 2>/dev/null; then printf '\n%s\n' "$warning" >> "$S/report.md"; fi
  fi
  marker="<!-- devflow-review-followup: $pr -->"
  issues=$(mktemp "$S/.followup-issues.XXXXXX")
  gh api --paginate "$repository/issues?state=all&per_page=100" | jq -s 'add // []' > "$issues"
  existing=$(jq -r --arg marker "$marker" '[.[] | select(.pull_request==null and ((.body // "")|contains($marker)))] | first | .number // empty' "$issues")
  rm "$issues"
  draft=$(mktemp "$S/.followup-draft.XXXXXX")
  review_followup_issue "$result" "$pr" "$number" "$marker" > "$draft"
  payload=$(mktemp "$S/.followup-payload.XXXXXX")
  milestone=''
  if [ -n "$number" ]; then milestone=$(gh api "$repository/issues/$number" --jq '.milestone.number // null'); fi
  # gh --jq renders JSON null as empty output; --argjson needs literal null.
  jq --argjson milestone "${milestone:-null}" '. + {milestone:$milestone}' "$draft" > "$payload"
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
  rm "$draft" "$payload" "$remote_body"
}
