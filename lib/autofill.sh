#!/usr/bin/env bash
# The existing watcher owns filling. GitHub text and brief templates are data.
# shellcheck disable=SC2016
# A repo key includes owner; validate before indirect shell-variable expansion.
autofill_key() { printf '%s' "$1" | tr '[:upper:]/.-' '[:lower:]___'; }
autofill_cache_key() { printf '%s-%s' "$(autofill_key "$1")" "$(printf '%s' "$1" | cksum | awk '{print $1}')"; }
autofill_id() {
  printf 'AF-%s-%s-%s\n' "$(printf '%s' "$1" | tr '/' '-')" "$(printf '%s' "$1" | cksum | awk '{print $1}')" "$2"
}
autofill_api() (
  # A fast reply can cancel bid_limit's timer before its child initializes.
  # Do not let that child inherit the scan owner's EXIT cleanup.
  trap - EXIT
  bid_limit "$DV_BID_TIMEOUT" gh "$@"
)
autofill_prs() {
  local repo=$1 target=$2 owner name number
  owner=${repo%/*}; name=${repo#*/}
  autofill_api api graphql --paginate -f owner="$owner" -f name="$name" -f query='
    query($owner:String!,$name:String!,$endCursor:String) {
      repository(owner:$owner,name:$name) {
        pullRequests(first:100,states:OPEN,after:$endCursor) {
          nodes { number url closingIssuesReferences(first:100) {
            nodes { number repository { nameWithOwner } } pageInfo { hasNextPage }
          } } pageInfo { hasNextPage endCursor }
        }
      }
    }' > "$target.pages" || return 1
  jq -es 'if all(.[]; .errors==null and (.data.repository.pullRequests.nodes|type=="array")) then
    [.[] | .data.repository.pullRequests.nodes[]] else error("incomplete open PR references") end' \
    "$target.pages" > "$target.nodes" || return 1
  # gh paginates the outer connection. Large closing-reference connections
  # need their own cursor so issue 101 cannot be submitted twice.
  while IFS= read -r number; do
    autofill_api api graphql --paginate -f owner="$owner" -f name="$name" -F number="$number" -f query='
      query($owner:String!,$name:String!,$number:Int!,$endCursor:String) {
        repository(owner:$owner,name:$name) { pullRequest(number:$number) {
          closingIssuesReferences(first:100,after:$endCursor) {
            nodes { number repository { nameWithOwner } } pageInfo { hasNextPage endCursor }
          }
        } }
      }' > "$target.refs.pages" || return 1
    jq -es 'if all(.[]; .errors==null and (.data.repository.pullRequest.closingIssuesReferences.nodes|type=="array")) then
      [.[]|.data.repository.pullRequest.closingIssuesReferences.nodes[]] else error("incomplete PR issues") end' \
      "$target.refs.pages" > "$target.refs" || return 1
    jq --argjson n "$number" --slurpfile refs "$target.refs" \
      'map(if .number==$n then .closingIssuesReferences.nodes=$refs[0] else . end)' "$target.nodes" > "$target.next" || return 1
    mv "$target.next" "$target.nodes"
  done < <(jq -r '.[]|select(.closingIssuesReferences.pageInfo.hasNextPage)|.number' "$target.nodes")
  jq --arg repo "$repo" '[.[] | . as $pr | .closingIssuesReferences.nodes[] |
    select((.repository.nameWithOwner|ascii_downcase)==$repo) |
    {issue:.number,number:$pr.number,url:$pr.url}]' "$target.nodes" > "$target"
}
autofill_dependencies() {
  # Same-repo #N, owner/repo#N and full GitHub issue URLs on Depends on lines.
  jq -c --arg repo "$1" '[.body // "" | split("\n")[] |
    select(test("^[ \\t]*(-[ \\t]+)?Depends on[ :\\t]";"i")) |
    scan("(?:https://github.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/issues/|([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#)([1-9][0-9]*)") |
    {repo:((.[0] // .[1] // $repo)|ascii_downcase),number:(.[2]|tonumber)}] | unique'
}
autofill_queued() {
  local repo=$1 number=$2 path identity
  for path in "$DV_HOME"/submissions/*/task.json; do
    [ -f "$path" ] || continue
    identity=$(manager_identity "$(jq -r .repo "$path")") || continue
    [ "$identity" = "github.com/$repo" ] || continue
    # Legacy manual IDs (APP-42) have no GitHub fields. Match only within repo.
    jq -c --argjson n "$number" 'select(.github_issue==$n or
      (.github_issue==null and ((.issue|split("-")|last)==($n|tostring))))' "$path"
  done | jq -s '.[0] // null'
}
autofill_repo() {
  local repo=$1 work=$2 key issues prs row number children deps dep dep_repo dep_n state pr queued reason stack item
  key=$(autofill_cache_key "$repo"); issues="$work/$key.issues"; prs="$work/$key.prs"
  autofill_api api --paginate "repos/$repo/issues?state=open&per_page=100" > "$issues.pages" || return 1
  jq -es 'if all(.[]; type=="array") then add | map(select(.pull_request==null and .state=="open")) else error("invalid issues") end' \
    "$issues.pages" > "$issues" || return 1
  [ -f "$prs" ] || autofill_prs "$repo" "$prs" || return 1
  while IFS= read -r row; do
    number=$(jq -er '.number | select(type=="number")' <<< "$row") || return 1
    jq -e 'any(.labels[]?; (.name|ascii_downcase)=="needs-owner")' <<< "$row" >/dev/null && continue
    jq -e --argjson n "$number" 'any(.[]; .issue==$n)' "$prs" >/dev/null && continue
    queued=$(autofill_queued "$repo" "$number") || return 1
    if [ "$queued" != null ]; then
      jq -e '.status=="submitted" and .host==null' <<< "$queued" >/dev/null || continue
    fi
    if jq -e '.sub_issues_summary.total!=null and .sub_issues_summary.completed!=null' <<< "$row" >/dev/null; then
      jq -e '.sub_issues_summary.total==.sub_issues_summary.completed' <<< "$row" >/dev/null || continue
    else
      children=$(autofill_api api --paginate "repos/$repo/issues/$number/sub_issues?per_page=100") || return 1
      jq -es 'all(.[]; type=="array" and all(.[]; .state=="closed"))' <<< "$children" >/dev/null || continue
    fi
    deps=$(autofill_dependencies "$repo" <<< "$row") || return 1
    reason=''; stack='[]'
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      dep_repo=$(jq -r .repo <<< "$dep"); dep_n=$(jq -r .number <<< "$dep")
      state=$(autofill_api api "repos/$dep_repo/issues/$dep_n") || return 1
      if jq -e '.state=="closed"' <<< "$state" >/dev/null; then continue; fi
      jq -e '.state=="open"' <<< "$state" >/dev/null || return 1
      pr="$work/$(autofill_cache_key "$dep_repo").prs"
      [ -f "$pr" ] || autofill_prs "$dep_repo" "$pr" || return 1
      item=$(jq -c --argjson n "$dep_n" '[.[]|select(.issue==$n)] | first // null' "$pr") || return 1
      if [ "$item" = null ]; then reason=dependency; break; fi
      stack=$(jq -c --argjson pr "$item" --arg repo "$dep_repo" '.+[$pr+{repo:$repo}]' <<< "$stack") || return 1
    done < <(jq -c '.[]' <<< "$deps")
    [ -z "$reason" ] || continue
    jq -cn --arg repo "$repo" --argjson row "$row" --argjson queued "$queued" --argjson stack "$stack" \
      '{repo:$repo,number:$row.number,title:$row.title,url:$row.html_url,
        milestone:(if $row.milestone.state=="open" then $row.milestone.number else null end),
        qa:any($row.labels[]?; (.name|ascii_downcase)=="qa"),queued:($queued.issue // null),stack:$stack,
        reason:($queued.reason // "awaiting submission")}'
  done < <(jq -c '.[]' "$issues")
}
autofill_bids() {
  local repo host reply
  for repo in ${DV_AUTOFILL_REPOS:--}; do
    repo=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')
    for host in $(bid_hosts | awk '!seen[$0]++'); do
      [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
      local remote="https://github.com/$repo.git"
      [ "$repo" != - ] || remote=''
      if reply=$(bid_limit "$DV_BID_TIMEOUT" bid_rpc "$host" bid --json --repo "$remote" --agent "$DV_AGENT" < /dev/null) &&
        jq -e '.status=="submitted" or .status=="rejected"' <<< "$reply" >/dev/null; then
        jq -c --arg host "$host" --arg repo "$repo" '.+{host:$host,repository:$repo}' <<< "$reply"
      else
        jq -cn --arg host "$host" --arg repo "$repo" \
          '{host:$host,repository:$repo,status:"rejected",capacity:0,effective_slots:0,active:0,free_slots:0,reason:"bid unavailable"}'
      fi
    done
  done | jq -s .
}
autofill_collect() {
  local work=$1 repo key keys=' '
  : > "$work/ready.rows"; : > "$work/errors.rows"
  for repo in $DV_AUTOFILL_REPOS; do
    repo=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')
    if ! [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ ]]; then
      jq -cn --arg repo "$repo" '{repo:$repo,reason:"invalid enabled repository"}' >> "$work/errors.rows"; continue
    fi
    key=$(autofill_cache_key "$repo")
    case "$keys" in *" $key "*) continue ;; esac
    keys="$keys$key "
    if autofill_repo "$repo" "$work" > "$work/$key.ready"; then
      cat "$work/$key.ready" >> "$work/ready.rows"
    else
      jq -cn --arg repo "$repo" '{repo:$repo,reason:"GitHub readiness lookup failed or incomplete"}' >> "$work/errors.rows"
    fi
  done
  jq -s 'sort_by((.milestone // 1e15), (if .qa then 0 else 1 end), .repo, .number)' "$work/ready.rows" > "$work/ready.json"
  jq -s . "$work/errors.rows" > "$work/errors.json"
  autofill_bids > "$work/bids.json"
}
autofill_snapshot() {
  local work=$1
  jq -n --slurpfile ready "$work/ready.json" --slurpfile bids "$work/bids.json" --slurpfile errors "$work/errors.json" --argjson at "$(now)" '
    ($bids[0] | group_by(.host) | map({host:.[0].host,
      effective_slots:(map(.effective_slots // .capacity)|max),running:(map(.active)|max),
      free_slots:([.[]|select(.status=="submitted")|.free_slots]|max // 0),
      reasons:([.[]|select(.reason!="")|.reason]|unique)})) as $hosts |
    {observed_at:$at,hosts:$hosts,effective_slots:([$hosts[].effective_slots]|add // 0),
      running:([$hosts[].running]|add // 0),free_slots:([$hosts[].free_slots]|add // 0),
      ready_not_started:($ready[0]|length),ready:$ready[0],errors:$errors[0],
      reason:(if ($errors[0]|length)>0 then "readiness lookup incomplete"
        elif ($ready[0]|length)==0 then ""
        elif ([$hosts[].free_slots]|add // 0)==0 then "no eligible host slots"
        else "ready work awaiting submission or host admission; see per-issue reasons" end)}'
}
autofill_brief() {
  local row=$1 target=$2 repo key variable template pr
  repo=$(jq -r .repo <<< "$row"); key=$(autofill_key "$repo")
  variable="DV_AUTOFILL_BRIEF_$key"; template=${!variable:-}
  if [ -n "$template" ]; then cat "$template" > "$target" || return 1
  else autofill_api api -H 'Accept:application/vnd.github.raw+json' "repos/$repo/contents/.devflow/brief.md" > "$target" || return 1; fi
  printf '\nGitHub issue: %s\nRead the issue and all comments: gh issue view %s -R %s --comments\n' \
    "$(jq -r .url <<< "$row")" "$(jq -r .number <<< "$row")" "$repo" >> "$target"
  printf 'Read AGENTS.md and POLICY.md first. Complete this issue, keep the change focused, and use synthetic tests.\n' >> "$target"
  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    printf '\nStacked dependency: %s (issue #%s). Before implementation, fetch and merge this open PR head into the work branch. Keep the default PR base; do not force push.\n' \
      "$(jq -r .url <<< "$pr")" "$(jq -r .issue <<< "$pr")" >> "$target"
    if [ "$(jq -r .repo <<< "$pr")" = "$repo" ]; then
      printf 'Include the following line in the PR body so landing waits for the dependency:\nDepends on #%s\n' "$(jq -r .number <<< "$pr")" >> "$target"
    fi
  done < <(jq -c '.stack[]' <<< "$row")
  printf '\nInclude Closes #%s in the PR body. Finish with dv done %s.\n' \
    "$(jq -r .number <<< "$row")" "$(autofill_id "$repo" "$(jq -r .number <<< "$row")")" >> "$target"
}
autofill_alarm() {
  local snapshot=$1 dir="$DV_HOME/autofill" since time event manager repo notice
  time=$(now)
  if ! jq -e '.ready_not_started>0 and .free_slots>0' "$snapshot" >/dev/null; then
    rm -f "$dir/underused-since" "$dir/alarm.json"; return 0
  fi
  if [ ! -f "$dir/underused-since" ]; then printf '%s\n' "$time" > "$dir/underused-since"; fi
  since=$(cat "$dir/underused-since")
  [ $((time-since)) -gt 600 ] || return 0
  [ ! -f "$dir/alarm.json" ] || return 0
  event=$(jq -cn --argjson time "$time" --argjson since "$since" --arg host "$DV_HOST" \
    '{id:($host+":fleet-underused:"+($since|tostring)),host:$host,issue:"FLEET",kind:"stalled",reason:"fleet-underused",audience:"manager",time:$time,since:$since,
      text:"fleet-underused: ready issues and free slots for more than 10 minutes. Inspect dv queue --summary; resolve scheduling on the manager, do not escalate to the owner."}') || return 1
  # Manager notices bypass owner/question/fallback delivery entirely. Keep an
  # alarm receipt even if no repository manager is enabled yet.
  for repo in $DV_AUTOFILL_REPOS; do
    manager=$(manager_dir "https://github.com/$repo.git") || continue
    # A manager started later must still receive the pending alarm.
    mkdir -p "$manager/notices"
    notice="$manager/notices/fleet-underused-$since.json"
    if [ ! -f "$notice" ]; then printf '%s\n' "$event" > "$notice.tmp"; mv "$notice.tmp" "$notice"; fi
  done
  printf '%s\n' "$event" >> "$dir/events.log"
  printf '%s\n' "$event" > "$dir/alarm.json"
}
autofill_tick() (
  [ "$DV_HOST" = "$DV_MANAGER_HOST" ] && [ -n "$DV_AUTOFILL_REPOS" ] || return 0
  local work row repo number issue dir reason free pending
  mkdir -p "$DV_HOME/autofill"
  owned_lock "$DV_HOME/autofill/lock" "$$" || return 1
  trap 'owned_unlock "$DV_HOME/autofill/lock" "$$"' EXIT
  work=$(mktemp -d "$DV_HOME/autofill/.scan.XXXXXX") || return 1
  trap 'rm -rf "$work"; owned_unlock "$DV_HOME/autofill/lock" "$$"' EXIT
  autofill_collect "$work" || return 1
  if ! owned_lock "$DV_HOME/.schedule-lock" "$$"; then
    jq 'map(.reason="scheduler busy")' "$work/ready.json" > "$work/next" || return 1
    mv "$work/next" "$work/ready.json"
    autofill_snapshot "$work" > "$work/summary.json" || return 1
    mv "$work/summary.json" "$DV_HOME/autofill/summary.json"
    autofill_alarm "$DV_HOME/autofill/summary.json"
    return
  fi
  trap 'owned_unlock "$DV_HOME/.schedule-lock" "$$"; rm -rf "$work"; owned_unlock "$DV_HOME/autofill/lock" "$$"' EXIT
  while IFS= read -r row; do
    repo=$(jq -r .repo <<< "$row"); number=$(jq -r .number <<< "$row")
    jq -e --arg repo "$repo" 'any(.[]; .repository==$repo and .status=="submitted" and .free_slots>0)' "$work/bids.json" >/dev/null || continue
    issue=$(jq -r '.queued // empty' <<< "$row")
    reason=''
    if [ -z "$issue" ]; then
      free=$(jq --arg repo "$repo" '[.[]|select(.repository==$repo and .status=="submitted")|.free_slots] | add // 0' "$work/bids.json")
      pending=$(jq --arg repo "$repo" '[.[]|select(.repo==$repo and .queued!=null)]|length' "$work/ready.json")
      # Rejected awards still occupy queue reservations. A new tick must not
      # turn two available slots into an unbounded backlog of submissions.
      # Reservations in an unavailable repo cannot starve another ready repo.
      [ "$pending" -lt "$free" ] || continue
      issue=$(autofill_id "$repo" "$number")
      if ! autofill_brief "$row" "$work/brief"; then reason='brief unavailable'
      elif [ -d "$DV_HOME/submissions/$issue" ]; then reason='submission already exists'
      elif cmd_submit "https://github.com/$repo.git" "$issue" "issue-$number" --brief "$work/brief" >&2; then
        bid_task_set "$DV_HOME/submissions/$issue" --arg repo "$repo" --argjson number "$number" '.github_repo=$repo | .github_issue=$number'
      else reason='submission failed'; fi
    fi
    dir="$DV_HOME/submissions/$issue"
    if [ -z "$reason" ]; then
      bid_schedule_one "$dir" >&2 || reason='host admission failed'
      if jq -e '.status=="working" or .status=="completed"' "$dir/task.json" >/dev/null; then
        jq --arg repo "$repo" --argjson n "$number" 'map(select(.repo!=$repo or .number!=$n))' "$work/ready.json" > "$work/next"
      else
        reason=$(jq -r '.reason // "awaiting host admission"' "$dir/task.json")
        jq --arg repo "$repo" --argjson n "$number" --arg reason "$reason" --arg issue "$issue" \
          'map(if .repo==$repo and .number==$n then .+{reason:$reason,queued:$issue} else . end)' "$work/ready.json" > "$work/next"
      fi
    else
      jq --arg repo "$repo" --argjson n "$number" --arg reason "$reason" \
        'map(if .repo==$repo and .number==$n then .+{reason:$reason} else . end)' "$work/ready.json" > "$work/next"
    fi
    mv "$work/next" "$work/ready.json"
    autofill_bids > "$work/bids.json"
  done < <(jq -c '.[]' "$work/ready.json")
  autofill_snapshot "$work" > "$work/summary.json" || return 1
  mv "$work/summary.json" "$DV_HOME/autofill/summary.json"
  autofill_alarm "$DV_HOME/autofill/summary.json"
)
autofill_event() {
  case "$(jq -r .kind <<< "$1")" in
    done|landed|failed|bid-changed|issue-opened|issue-closed|issue-reopened|issue-edited|pr-opened|pr-closed)
      autofill_tick ;;
  esac
}
autofill_summary() (
  local work
  mkdir -p "$DV_HOME/autofill"
  work=$(mktemp -d "$DV_HOME/autofill/.summary.XXXXXX") || return 1
  trap 'rm -rf "$work"' EXIT
  autofill_collect "$work" || return 1
  autofill_snapshot "$work" > "$work/summary.json" || return 1
  if [ -f "$DV_HOME/autofill/summary.json" ]; then
    jq --slurpfile last "$DV_HOME/autofill/summary.json" '
      .ready |= map(. as $current | .last_attempt_reason=([$last[0].ready[] |
        select(.repo==$current.repo and .number==$current.number) | .reason] | first // null))' \
      "$work/summary.json" > "$work/next" || return 1
    mv "$work/next" "$work/summary.json"
  fi
  if [ "${1:-}" = --json ]; then cat "$work/summary.json"
  else jq -r '"HOST\tEFFECTIVE SLOTS\tRUNNING\tFREE\tREASON",
    (.hosts[]|[.host,.effective_slots,.running,.free_slots,(.reasons|join("; "))]|@tsv),
    "ready-but-not-started=\(.ready_not_started) free=\(.free_slots) reason=\(.reason)",
    (.ready[] | "\(.repo)#\(.number): \(.reason); last attempt: \(.last_attempt_reason // "none")"),
    (.errors[]|"\(.repo): \(.reason)")' "$work/summary.json"; fi
)
