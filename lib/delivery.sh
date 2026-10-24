#!/usr/bin/env bash
# jq filters and Markdown are literal strings, not shell substitutions.
# shellcheck disable=SC2016
# shellcheck source=lib/pr-review.sh
source "$DV_ROOT/lib/pr-review.sh"
pr_report_summary() {
  # Use the first prose paragraph, bounded in size. Never copy the brief or
  # publish local paths or configured hosts. Pass configuration explicitly:
  # shell config values need not be exported, and awk -v interprets backslashes.
  if [ -f "$S/report.md" ]; then
    DV_PR_HOME="$HOME" DV_PR_WT="$WT" DV_PR_REPO="$REPO" DV_PR_STATE="$DV_STATE" \
      DV_PR_HOSTS="$DV_HOSTS $DV_PULL_HOSTS $DV_HOST" awk '
      BEGIN {
        paths[1]=ENVIRON["DV_PR_HOME"]; paths[2]=ENVIRON["DV_PR_WT"]
        paths[3]=ENVIRON["DV_PR_REPO"]; paths[4]=ENVIRON["DV_PR_STATE"]
        host_count=split(ENVIRON["DV_PR_HOSTS"],hosts,/[[:space:]]+/)
      }
      function private_line(line, i, count, tokens, token) {
        for (i in paths) if (paths[i]!="" && index(line,paths[i])) return 1
        for (i=1;i<=host_count;i++) if (hosts[i]!="" && index(line,hosts[i])) return 1
        if (line ~ /\$\{?(HOME|WT|REPO|DV_STATE|S)([^[:alnum:]_]|$)/) return 1
        if (line ~ /\.local\/state\/devflow/) return 1
        # Markdown, shell quotes and assignments can delimit path tokens too.
        gsub(/[][{}()<>=,;\047"`]/," ",line)
        count=split(line,tokens,/[[:space:]]+/)
        for (i=1;i<=count;i++) {
          token=tokens[i]
          # Keep public URL paths; file:/// still leaves an absolute path.
          sub(/^[[:alpha:]][[:alnum:]+.-]*:\/\//,"",token)
          if (token ~ /^[\/~]/ || token ~ /:[\/~]/) return 1
        }
        return 0
      }
      private_line($0) { next }
      /^[[:space:]]*#/ { if (lines) exit; next }
      /^[[:space:]]*$/ { if (lines) exit; next }
      {
        remaining=999-chars
        if (remaining<=0 || lines>=10) exit
        line=substr($0,1,remaining)
        print line; chars+=length(line)+1; lines++
      }
      END { if (!lines) print "Implementation report is not available." }
    ' "$S/report.md"
  else
    printf 'Implementation report is not available.\n'
  fi
}
pr_title_check() {
  # The title is the HEAD commit subject. The worker fixes it; dv never rewrites it.
  local title=$1 problem pattern="^($CHANGE_TYPES)(\\([^()[:space:]]+\\))?!?: [^[:space:]]" key='^[A-Za-z][A-Za-z0-9]*-[0-9]+([^0-9]|$)'
  if [[ "$title" =~ $key ]]; then problem='starts with an issue key'
  elif ! [[ "$title" =~ $pattern ]]; then problem='does not start with type(scope): subject'
  else return 0; fi
  fail "PR title \"$title\" $problem. The HEAD commit subject is the PR title: type(scope): subject in English without the issue key, type one of ${CHANGE_TYPES//|/ } (e.g. fix(tui): keep the progress card after restart). Reword the commit subject (git commit --amend while it is unpushed) and rerun dv pr."
}
pr_body_check() {
  local body=$1 heading missing=''
  for heading in Summary Verification Checklist; do
    grep -Eq "^#{1,6}[[:space:]]+${heading}[[:space:]]*\$" "$body" || missing="$missing, ## $heading"
  done
  grep -Eqi '(^|[^[:alnum:]_])closes #[1-9][0-9]*' "$body" || missing="$missing, Closes #<n>"
  [ -z "$missing" ] || fail "pr.md must follow .github/PULL_REQUEST_TEMPLATE.md; missing: ${missing#, }"
}
pr_formatted_branch() {
  # dv names new branches <type>/<n>-<slug>. Jobs started earlier keep their
  # <agent>/<key>-<slug> branch, and their PRs stay as they are.
  local pattern="^($CHANGE_TYPES)/"
  [[ "$BRANCH" =~ $pattern ]]
}
cmd_pr() {
  [ "$#" -eq 1 ] || fail 'usage: dv pr ISSUE'
  load_issue "$1"; issue_lock; require_worktree; require_clean "$WT"
  is_github || fail 'dv pr requires a GitHub origin'
  cd "$WT" || exit
  [ "$BRANCH" != "$BASE" ] || fail 'cannot push the base branch'
  local head pr title endpoint body_file public_source='' public_body='' edit_args created=0
  title=$(git log -1 --format=%s)
  if [ -f "$S/pr.md" ]; then
    public_source="$S/pr.md"
  elif [ ! -f "$S/pr.json" ] && [ -f "$S/pr-body.md" ]; then
    # Older workers prepared this filename before the first publication.
    public_source="$S/pr-body.md"
  fi
  if pr_formatted_branch; then
    # Check before push, so a rejected subject is still unpushed and amendable.
    pr_title_check "$title"
    [ -n "$public_source" ] || [ -f "$S/pr.json" ] ||
      fail "write the public PR body to $S/pr.md following .github/PULL_REQUEST_TEMPLATE.md (## Summary, Closes #<n>, ## Verification, ## Checklist), then rerun dv pr"
  fi
  if [ -n "$public_source" ]; then
    # Coordinate with an older in-flight polish before publishing exact prose.
    mkdir "$S/.polish" 2>/dev/null || fail 'PR polish is still running; retry dv pr when it finishes'
    trap 'rm -f "$S/.polish/public-body"; rmdir "$S/.polish" "$S/.operation" 2>/dev/null || true' EXIT
    public_body="$S/.polish/public-body"
    cp "$public_source" "$public_body"
    if pr_formatted_branch; then pr_body_check "$public_body"; fi
  fi
  head=$(git rev-parse HEAD)
  git push -u origin "$BRANCH:refs/heads/$BRANCH"
  if [ -f "$S/pr.json" ]; then
    pr=$(jq -er .url "$S/pr.json")
    if [[ "$pr" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)$ ]]; then
      endpoint="repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/pulls/${BASH_REMATCH[3]}"
    else fail 'invalid PR URL'; fi
    edit_args=(-f "title=$title")
    if [ -n "$public_body" ] && ! cmp -s "$public_body" "$S/pr-body.md"; then
      edit_args+=(-F "body=@$public_body")
    fi
    gh api -X PATCH "$endpoint" "${edit_args[@]}" > /dev/null
    if [ -n "$public_body" ]; then
      mv "$public_body" "$S/pr-body.md"
    fi
  else
    if [ -n "$public_body" ]; then
      # Worker-written public body: no brief, internal report or state paths.
      body_file=$public_body
    else
      body_file="$S/pr-body.generated.md"
      pr_report_summary > "$body_file"
    fi
    pr=$(gh pr create --base "$BASE" --head "$BRANCH" --title "$title" --body-file "$body_file")
    jq -n --arg url "$pr" '{url:$url}' > "$S/pr.json"
    created=1
    cp "$body_file" "$S/pr-body.md"
    if [ -z "$public_body" ]; then
      nohup "$DV_ROOT/bin/dv" polish "$ISSUE" >> "$S/polish.log" 2>&1 < /dev/null &
    fi
  fi
  if [ -n "$public_body" ]; then
    # Persist ownership even if pr.md is later removed before a queued polish.
    touch "$S/pr-public.sent"
    rm -f "$public_body"
    rmdir "$S/.polish"
    trap 'rmdir "$S/.operation" 2>/dev/null || true' EXIT
  fi
  meta_set --arg head "$head" --arg pr "$pr" '.status="pr" | .head=$head | .pr=$pr'
  if [ "$created" = 1 ]; then cmd_kick pr-opened "$ISSUE" "$pr"; fi
  pr_wait_start
  printf '%s\n' "$pr"
}
pr_wait_alive() {
  local marker holder found=false
  for marker in "$S/.pr-wait"/pid-*; do
    [ -f "$marker" ] || continue
    found=true; holder=${marker##*/pid-}
    [[ "$holder" =~ ^[1-9][0-9]*$ ]] || continue
    if kill -0 "$holder" 2>/dev/null; then return 0; fi
  done
  # Older versions only recorded the background PID outside the empty lock.
  if [ "$found" = false ] && [ -d "$S/.pr-wait" ] && [ -f "$S/pr-wait.pid" ]; then
    holder=$(cat "$S/pr-wait.pid")
    if [[ "$holder" =~ ^[1-9][0-9]*$ ]] && kill -0 "$holder" 2>/dev/null; then return 0; fi
  fi
  return 1
}
pr_wait_lock() {
  local marker holder candidate nested tries=0
  while [ "$tries" -lt 10 ]; do
    pr_wait_alive && return 1
    for marker in "$S/.pr-wait"/pid-* "$S/.pr-wait"/.pr-wait.*/pid-*; do
      [ -f "$marker" ] || continue
      holder=${marker##*/pid-}
      [[ "$holder" =~ ^[1-9][0-9]*$ ]] || continue
      if ! kill -0 "$holder" 2>/dev/null && rm "$marker" 2>/dev/null; then
        rmdir "$(dirname "$marker")" 2>/dev/null || true
      fi
    done
    rmdir "$S/.pr-wait" 2>/dev/null || true
    # Publish a nonempty directory atomically, so an acquiring lock can never
    # be mistaken for an old ownerless directory. A competing mv nests its
    # candidate inside the winner's directory; it removes only that candidate.
    candidate=$(mktemp -d "$S/.pr-wait.XXXXXX")
    : > "$candidate/pid-$$"
    if mv "$candidate" "$S/.pr-wait" 2>/dev/null && [ -f "$S/.pr-wait/pid-$$" ]; then
      printf '%s\n' "$$" > "$S/pr-wait.pid"
      return 0
    fi
    nested="$S/.pr-wait/${candidate##*/}"
    rm -f "$candidate/pid-$$" "$nested/pid-$$"
    rmdir "$candidate" "$nested" 2>/dev/null || true
    tries=$((tries + 1))
  done
  return 1
}
pr_wait_unlock() {
  if rm "$S/.pr-wait/pid-$$" 2>/dev/null; then
    rmdir "$S/.pr-wait" 2>/dev/null || true
  fi
}
pr_wait_start() {
  pr_wait_alive && return 0
  if command -v setsid >/dev/null; then
    # Job control assigns a separate group before this subshell returns. It
    # protects even a delayed setsid from cleanup of the caller's group.
    (set -m; nohup setsid "$DV_ROOT/bin/dv" pr-wait "$ISSUE" >> "$S/pr-wait.log" 2>&1 < /dev/null &)
  else
    # macOS has no setsid by default. Job control gives the waiter its own
    # process group, and nohup protects it when the launching shell exits.
    (set -m; nohup "$DV_ROOT/bin/dv" pr-wait "$ISSUE" >> "$S/pr-wait.log" 2>&1 < /dev/null &)
  fi
}
cmd_pr_wait_start() {
  [ "$#" -eq 1 ] || fail 'usage: dv _pr-wait-start ISSUE'
  load_issue "$1"; require_worktree
  [ "$(jq -r .status "$S/meta")" = pr ] || return 0
  pr_wait_start
}
pr_reconcile_blocked() {
  # One blocked event per PR head and reason; later passes stay quiet.
  [ "$(cat "$S/pr-reconcile.blocked" 2>/dev/null)" != "$1" ] || return 0
  cmd_kick blocked "$ISSUE" "$2"
  printf '%s\n' "$1" > "$S/pr-reconcile.blocked"
}
cmd_pr_reconcile() {
  # The watcher's safety net, on the issue's host: a PR merged or closed
  # outside dv land must not leave its job open (#253).
  [ "$#" -eq 1 ] || fail 'usage: dv _pr-reconcile ISSUE'
  load_issue "$1"
  local status pr context=$REPO rc=0 reason
  status=$(jq -r .status "$S/meta")
  case "$status" in
    pr|ready|waiting-base|parked) ;;
    # Recorded as landed, but cleanup or the landed event did not finish.
    landed) jq -e '.pr_reconcile_pending==true' "$S/meta" >/dev/null || return 0 ;;
    *) return 0 ;;
  esac
  if [ "$KIND" != code ] || [ ! -f "$S/pr.json" ] || ! is_github; then return 0; fi
  # A live waiter already polls this PR and exits once it is no longer open.
  if [ "$status" = pr ] && pr_wait_alive; then return 0; fi
  # land, pr and send hold the operation lock; the next pass retries.
  mkdir "$S/.operation" 2>/dev/null || return 0
  trap 'rmdir "$S/.operation" 2>/dev/null || true' EXIT
  pr=$(jq -er .url "$S/pr.json")
  [ ! -d "$WT" ] || context=$WT
  (cd "$context" && gh pr view "$pr" --json headRefOid,baseRefName,statusCheckRollup,state) > "$S/pr-reconcile.json"
  case "$(jq -r .state "$S/pr-reconcile.json")" in
    MERGED)
      cp "$S/pr-reconcile.json" "$S/land-checks.json"
      # The same gates as dv land on a PR merged elsewhere (#116). Keep errexit
      # in the subshell (an || list would disable it): any failed step counts.
      set +e
      (
        set -e
        head=''
        if [ -d "$WT" ]; then require_worktree; require_clean "$WT"; head=$(git -C "$WT" rev-parse HEAD); fi
        github_land_reconcile "$head"
      ) 2> "$S/pr-reconcile.log"
      rc=$?
      set -e
      if [ "$rc" = 0 ]; then
        if jq -e '.pr_reconcile_pending' "$S/meta" >/dev/null; then meta_set 'del(.pr_reconcile_pending)'; fi
        return 0
      fi
      # Status can already be landed (cleanup refused, such as a live worker);
      # keep the job on later passes until cleanup and the landed event finish.
      if jq -e '.status=="landed"' "$S/meta" >/dev/null; then meta_set '.pr_reconcile_pending=true'; fi
      reason=$(sed -n 's/^dv: //p' "$S/pr-reconcile.log" | tail -n 1)
      pr_reconcile_blocked "MERGED:$(jq -r .headRefOid "$S/pr-reconcile.json"):$reason" \
        "PR merged outside dv land but not recorded as landed: ${reason:-see pr-reconcile.log}"
      return 1 ;;
    CLOSED)
      meta_set --argjson time "$(now)" '.status="closed" | .closed_at=$time'
      cmd_kick closed "$ISSUE" 'PR closed without merge; worktree and branch retained' ;;
  esac
}
# Open PR jobs, and landings whose cleanup or landed event did not finish.
pr_reconcile_filter='((.status=="pr" or .status=="ready" or .status=="waiting-base" or .status=="parked") and .pr!=null) or .pr_reconcile_pending==true'
cmd_pr_reconcile_start() {
  # The watcher's host pass is killed at its deadline. Detach the sweep, like
  # a PR waiter, so GitHub queries and cleanup never lose the issue lock.
  [ "$#" -eq 0 ] || fail 'usage: dv _pr-reconcile-start'
  local holder
  holder=$(cat "$DV_STATE/.pr-reconcile/owner" 2>/dev/null) || holder=''
  if [[ "$holder" =~ ^[1-9][0-9]*$ ]] && kill -0 "$holder" 2>/dev/null; then return 0; fi
  if command -v setsid >/dev/null; then
    (set -m; nohup setsid "$DV_ROOT/bin/dv" _pr-reconcile-sweep >> "$DV_STATE/.pr-reconcile.log" 2>&1 < /dev/null &)
  else
    (set -m; nohup "$DV_ROOT/bin/dv" _pr-reconcile-sweep >> "$DV_STATE/.pr-reconcile.log" 2>&1 < /dev/null &)
  fi
}
cmd_pr_reconcile_sweep() {
  [ "$#" -eq 0 ] || fail 'usage: dv _pr-reconcile-sweep'
  local meta
  # One sweep per host covers every job; a dead owner's lock is reclaimed.
  owned_lock "$DV_STATE/.pr-reconcile" "$$" || return 0
  trap 'owned_unlock "$DV_STATE/.pr-reconcile" "$$"' EXIT
  for meta in "$DV_STATE"/*/meta; do
    jq -e "$pr_reconcile_filter" "$meta" >/dev/null 2>&1 || continue
    "$DV_ROOT/bin/dv" _pr-reconcile "$(basename "$(dirname "$meta")")" || true
  done
}
already_merged_verify() {
  # Work delivered by another PR: its commit is on the base, and this branch
  # adds nothing the base lacks. Prints the delivery record.
  local ref=$1 base_ref number='' other='' slug commit='' snapshot tree
  local pr_pattern='^#?([1-9][0-9]{0,8})$' url_pattern='^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)$'
  # Digits alone name a PR; pass a longer or hexadecimal SHA for a commit.
  if [[ "$ref" =~ $pr_pattern ]]; then number=${BASH_REMATCH[1]}
  elif [[ "$ref" =~ $url_pattern ]]; then other=${BASH_REMATCH[1]}; number=${BASH_REMATCH[2]}
  elif ! [[ "$ref" =~ ^[0-9a-fA-F]{7,64}$ ]]; then fail 'expected a PR number, PR URL or commit for --already-merged'; fi
  if git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
    git -C "$WT" fetch -q origin "$BASE:refs/remotes/origin/$BASE" || fail "could not fetch origin/$BASE"
    base_ref="refs/remotes/origin/$BASE"
  else base_ref="refs/heads/$BASE"; fi
  if [ -n "$number" ]; then
    is_github || fail 'PR references require a GitHub origin'
    slug=$(manager_identity "$REPO"); slug=${slug#github.com/}
    if [ -n "$other" ] && [ "$(printf '%s' "$other" | tr '[:upper:]' '[:lower:]')" != "$slug" ]; then
      fail "PR $ref belongs to another repository"
    fi
    snapshot=$(cd "$WT" && gh pr view "https://github.com/$slug/pull/$number" --json state,baseRefName,mergeCommit) ||
      fail "could not read PR #$number"
    printf '%s\n' "$snapshot" | jq -e '.state=="MERGED"' >/dev/null || fail "PR #$number is not merged"
    printf '%s\n' "$snapshot" | jq -e --arg base "$BASE" '.baseRefName==$base' >/dev/null || fail "PR #$number was not merged into $BASE"
    commit=$(printf '%s\n' "$snapshot" | jq -er '.mergeCommit.oid | select(type=="string" and test("^[0-9a-f]{40,64}$"))') ||
      fail "PR #$number has no merge commit"
  else
    commit=$(git -C "$WT" rev-parse --verify --quiet "$ref^{commit}") || fail "unknown commit $ref"
  fi
  git -C "$WT" merge-base --is-ancestor "$commit" "$base_ref" 2>/dev/null || fail "commit $commit is not on $BASE"
  # Equal trees after a merge: patch-equivalent or empty branch changes pass.
  tree=$(git -C "$WT" merge-tree --write-tree "$base_ref" HEAD 2>/dev/null) ||
    fail "this branch conflicts with $BASE; deliver its changes with dv pr instead"
  [ "${tree%%[[:space:]]*}" = "$(git -C "$WT" rev-parse "$base_ref^{tree}")" ] ||
    fail "this branch has changes that are not on $BASE; deliver them with dv pr instead"
  jq -cn --arg commit "$commit" --arg pr "$number" --arg base "$BASE" --arg base_head "$(git -C "$WT" rev-parse "$base_ref")" \
    '{commit:$commit,pr:(if $pr=="" then null else ($pr|tonumber) end),base:$base,base_head:$base_head}'
}
already_merged_own_pr() {
  local pr state
  [ -f "$S/pr.json" ] || return 0
  pr=$(jq -er .url "$S/pr.json") || fail 'invalid PR record'
  state=$(cd "$WT" && gh pr view "$pr" --json state | jq -r .state) || fail "could not read this job's own PR $pr"
  [ "$state" != OPEN ] || fail "this job's own PR is still open ($pr); close it or deliver it instead"
}
already_merged_land() {
  # dv done --already-merged recorded the delivery; recheck it, then close the job.
  local head
  head=$(jq -r .head "$S/done.json")
  if [ "$(jq -r .status "$S/meta")" != landed ]; then
    require_worktree; require_clean "$WT"
    [ "$(git -C "$WT" rev-parse HEAD)" = "$head" ] || fail 'worktree changed after dv done --already-merged; run dv done again'
    case "$BACKEND" in
      appserver) appserver_require_idle ;;
      exec) ! codex_exec_alive "$S" || fail 'exec is still running; cannot land' ;;
    esac
    already_merged_verify "$(jq -r .merged_via.commit "$S/done.json")" > /dev/null
    metrics_note merged "$head"
    meta_set --slurpfile completion "$S/done.json" --argjson time "$(now)" \
      '.status="landed" | .landed_at=$time | .merged_via=$completion[0].merged_via'
  fi
  clean_worktree
  if ! jq -se 'any(.[]; .kind=="landed")' "$S/events.log" >/dev/null 2>&1; then
    cmd_kick landed "$ISSUE" "Landed through $(jq -r 'if .merged_via.pr then "#\(.merged_via.pr)" else .merged_via.commit end' "$S/done.json")"
  fi
}
cmd_park() {
  # A job blocked on open prerequisite issues releases its slot instead of
  # idling: its branch is pushed and its GitHub issue says what it waits for.
  [ "$#" -ge 1 ] || fail 'usage: dv park ISSUE --on N[,N...] [--note TEXT]'
  load_issue "$1"; shift
  local on='' note='' list='' n number slug state head marker body refs exists status
  local on_pattern='^[1-9][0-9]*(,[1-9][0-9]*)*$'
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || fail "missing value for $1"
    case "$1" in --on) on=$2 ;; --note) note=$2 ;; *) fail "unknown option: $1" ;; esac
    shift 2
  done
  [[ "$on" =~ $on_pattern ]] || fail 'usage: dv park ISSUE --on N[,N...] [--note TEXT]'
  [ "$KIND" = code ] || fail 'only code jobs can be parked'
  issue_lock
  status=$(jq -r .status "$S/meta")
  case "$status" in running|pr) ;; *) fail "only a running or PR job can be parked (status: $status)" ;; esac
  require_worktree; require_clean "$WT"
  is_github || fail 'dv park requires a GitHub origin'
  [ "$BRANCH" != "$BASE" ] || fail 'cannot push the base branch'
  slug=$(manager_identity "$REPO"); slug=${slug#github.com/}
  number=$(jq -r '.source_issue // empty | tostring' "$S/meta")
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || number=${ISSUE##*-}
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || fail "cannot resolve the GitHub issue of $ISSUE"
  list=$(printf '%s\n' "$on" | tr ',' '\n' | awk '!seen[$0]++')
  while IFS= read -r n; do
    [ "$n" != "$number" ] || fail "a job cannot wait for its own issue #$n"
    state=$(gh api "repos/$slug/issues/$n" | jq -r .state) || fail "could not read prerequisite #$n"
    [ "$state" = open ] || fail "prerequisite #$n is not open; continue the work instead"
  done <<< "$list"
  refs=$(printf '%s\n' "$list" | sed 's/^/#/' | paste -sd, - | sed 's/,/, /g')
  head=$(git -C "$WT" rev-parse HEAD)
  git -C "$WT" push -u origin "$BRANCH:refs/heads/$BRANCH"
  marker="<!-- devflow-park:$ISSUE:$head -->"
  exists=$(gh api --paginate "repos/$slug/issues/$number/comments" |
    jq -s --arg marker "$marker" 'add // [] | any(.[]; (.body // "") | contains($marker))') || fail 'could not read issue comments'
  if [ "$exists" != true ]; then
    body=$(mktemp "$S/.park-comment.XXXXXX")
    {
      printf '%s\n\n' "$marker"
      printf 'Parked: waiting for %s to close. Work so far is pushed to `%s` at `%s`.\n' "$refs" "$BRANCH" "$head"
      [ -z "$note" ] || printf '\n%s\n' "$note"
    } > "$body"
    gh api --method POST "repos/$slug/issues/$number/comments" -F "body=@$body" > /dev/null
    rm "$body"
  fi
  meta_set --argjson on "$(printf '%s\n' "$list" | jq -sc .)" --argjson issue "$number" --arg head "$head" --argjson time "$(now)" \
    '.status="parked" | .head=$head | .parked={on:$on,issue:$issue,head:$head,at:$time}'
  metrics_note parked "$head"
  cmd_kick parked "$ISSUE" "Parked until $refs close${note:+: $note}"
  printf 'dv: parked %s until %s close; %s is pushed\n' "$ISSUE" "$refs" "$BRANCH"
}
checks_green() {
  jq -e '.statusCheckRollup | length>0 and all(.[ ];
    if .__typename=="CheckRun" then .status=="COMPLETED" and .conclusion=="SUCCESS"
    elif .__typename=="StatusContext" then .state=="SUCCESS" else false end)' "$1" >/dev/null
}
checks_finished() {
  jq -e '.statusCheckRollup | length>0 and all(.[];
    if .__typename=="CheckRun" then .status=="COMPLETED"
    elif .__typename=="StatusContext" then (.state=="SUCCESS" or .state=="FAILURE" or .state=="ERROR")
    else false end)' "$1" >/dev/null
}
pr_conflicting() {
  # True only when GitHub has computed the merge and reports a conflict for
  # this head. UNKNOWN (still computing) keeps the ordinary checks wait.
  local pr=$1 head=$2 tmp
  tmp=$(mktemp "$S/.pr-snapshot.XXXXXX")
  if ! gh pr view "$pr" --json headRefOid,baseRefName,statusCheckRollup,reviews,state,mergeable > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  if jq -e --arg head "$head" '.state=="OPEN" and .headRefOid==$head and .mergeable=="CONFLICTING"' "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$S/pr-snapshot.json"; return 0
  fi
  rm -f "$tmp"; return 1
}
pr_wait_conflict_ready() {
  # A conflict is not a CI or review round and needs no manager: the worker
  # merges the base and pushes, which starts CI on the new head.
  local head=$1 loop=$2 tmp
  tmp=$(mktemp "$S/.pr-loop.XXXXXX"); printf '%s\n' "$loop" | jq '.review_handled=false' > "$tmp"; mv "$tmp" "$S/pr-loop.json"
  tmp=$(mktemp "$S/.pr-ready.XXXXXX")
  jq -n --arg head "$head" --argjson loop "$loop" --slurpfile snapshot "$S/pr-snapshot.json" \
    '{head:$head,checks_exit:null,green:false,merge_conflict:true,bot_review:false,review:null,review_handled:false,review_timed_out:false,
      review_rounds:($loop.reviewed_heads|length),ci_rounds:($loop.failed_heads|length),blocked:false,reason:"merge-conflict",snapshot:$snapshot[0]}' > "$tmp"
  mv "$tmp" "$S/pr-ready.json"
}
pr_wait_recover() (
  # The caller released ownership BEFORE this observes the worker: a
  # later exit can then start a successor. If its wrapper already observed our
  # lock, agent.exit was published first; wait for that wrapper to finish its
  # handoff instead.
  local head=$1 recovery_episode=$2 message=$3 pid live=false reason tmp
  case "$BACKEND" in exec|appserver) return 0 ;; esac
  pid=$(cat "$S/agent.pid" 2>/dev/null) || pid=''
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
    if [ -f "$S/agent.exit" ]; then
      while kill -0 "$pid" 2>/dev/null; do
        [ "$(jq -r .status "$S/meta")" != parked ] || return 0
        sleep "$DV_POLL_INTERVAL"
      done
    else live=true; fi
  fi
  [ "$(jq -r '.head // empty' "$S/meta")" = "$head" ] || return 0
  [ "$(jq -r .status "$S/meta")" != parked ] || return 0
  if jq -e --arg head "$head" '.head==$head and .checks=="green" and .review=="handled"' "$S/done.json" >/dev/null 2>&1; then return 0; fi
  # Preserve the existing one-shot revival, including its exit handoff guards.
  if [ "$live" = false ] && agent_gone; then
    DV_PR_RECOVERY_HEAD="$head" DV_PR_RECOVERY_EPISODE="$recovery_episode" "$DV_ROOT/bin/dv" send "$ISSUE" "$message"
    return
  fi
  # A surviving wrapper alone does not prove that its terminal still exists.
  cmd_status "$ISSUE" --json | jq -e '.[0] | .alive==true and .agent_dead!=true' >/dev/null || return 0
  # Serialize with other waiters so their snapshots cannot overwrite a send
  # reservation. Reserve before delivery: uncertain input must not be repeated.
  pr_wait_lock || return 0
  trap pr_wait_unlock EXIT
  jq -e --arg head "$head" '.status=="pr" and .head==$head' "$S/meta" >/dev/null || return 0
  reason=$(jq -er --arg head "$head" 'select(.head==$head and .blocked==false and .merge_conflict!=true) |
    if .green==false then "ci-failed"
    elif (.review.high|length)>0 then "review-findings" else empty end' "$S/pr-ready.json") || return 0
  if jq -e --arg key "$head:$reason" '.recovery_sends[$key]' "$S/pr-loop.json" >/dev/null; then return 0; fi
  tmp=$(mktemp "$S/.pr-loop.XXXXXX")
  jq --arg key "$head:$reason" '.recovery_sends[$key]=true' "$S/pr-loop.json" > "$tmp"
  mv "$tmp" "$S/pr-loop.json"
  # The live worker can immediately enter its own foreground wait after input.
  pr_wait_unlock; trap - EXIT
  DV_PR_RECOVERY_HEAD="$head" DV_PR_RECOVERY_EPISODE="$recovery_episode" "$DV_ROOT/bin/dv" send "$ISSUE" "$message"
)
cmd_pr_wait() {
  [ "$#" -ge 1 ] || fail 'usage: dv pr-wait ISSUE [--foreground [--review-handled]]'
  load_issue "$1"; shift; require_worktree; cd "$WT" || exit
  local foreground=false handled=false arg
  for arg in "$@"; do
    case "$arg" in --foreground) foreground=true ;; --review-handled) handled=true ;; *) fail "unknown option: $arg" ;; esac
  done
  [ "$handled:$foreground" != true:false ] || fail '--review-handled requires --foreground'
  [[ "$DV_REVIEW_ROUNDS" =~ ^[1-9][0-9]*$ ]] || fail 'DV_REVIEW_ROUNDS must be a positive integer'
  local pr head rc=0 tmp current green=false loop review deadline max_deadline retry reason='' reviewed=false rounds=0 conflict=false
  local recovery_episode
  # Park is an explicit pause, including for a waiter already in flight. Do
  # not reset its review counters or let it submit automatic recovery input.
  [ "$(jq -r .status "$S/meta")" != parked ] || return 0
  pr=$(jq -er .url "$S/pr.json")
  if jq -e '.status=="running" and .unparked_at!=null' "$S/meta" >/dev/null; then
    # send resumes in running; waiting on its existing PR restores ownership.
    # Serialize with park so an earlier status observation cannot undo it.
    (issue_lock; meta_set 'if .status=="running" and .unparked_at!=null then .status="pr" else . end')
  fi
  until pr_wait_lock; do
    [ "$(jq -r .status "$S/meta")" != parked ] || return 0
    [ "$foreground" = true ] || return 0
    sleep "$DV_POLL_INTERVAL"
  done
  trap pr_wait_unlock EXIT
  trap 'exit 0' INT TERM
  loop='{"failed_heads":[],"reviewed_heads":[],"requests":{}}'
  [ ! -f "$S/pr-loop.json" ] || loop=$(cat "$S/pr-loop.json")
  loop=$(printf '%s\n' "$loop" | jq '.reviewed_heads //= [] | .requests //= {} | .review_handled=false')
  review=$(mktemp "$S/.review-result.XXXXXX")
  while :; do
    [ "$(jq -r .status "$S/meta")" != parked ] || { rm "$review"; return 0; }
    head=$(jq -r '.head // empty' "$S/meta"); [ -n "$head" ] || head=$(git rev-parse HEAD)
    loop=$(printf '%s\n' "$loop" | jq --arg head "$head" '.initial_head //= (.review_head // $head)')
    rc=0
    # GitHub runs no CI on a PR that conflicts with its base, so a checks
    # watch would wait forever. Hand the conflict back to the worker instead.
    if pr_conflicting "$pr" "$head"; then conflict=true; break; fi
    gh pr checks "$pr" --watch --interval "${DV_CHECKS_INTERVAL:-60}" > "$S/checks.log" 2>&1 || rc=$?
    [ "$(jq -r .status "$S/meta")" != parked ] || { rm "$review"; return 0; }
    tmp=$(mktemp "$S/.pr-snapshot.XXXXXX")
    gh pr view "$pr" --json headRefOid,baseRefName,statusCheckRollup,reviews,state,mergeable > "$tmp"
    mv "$tmp" "$S/pr-snapshot.json"
    [ "$(jq -r .status "$S/meta")" != parked ] || { rm "$review"; return 0; }
    if [ "$(jq -r .state "$S/pr-snapshot.json")" != OPEN ]; then
      [ "$foreground" != true ] || fail 'PR is no longer open'
      rm "$review"
      # Hand a merged or closed PR straight to reconciliation (#253).
      pr_wait_unlock; trap - EXIT
      "$DV_ROOT/bin/dv" _pr-reconcile "$ISSUE" || true
      return 0
    fi
    current=$(jq -r '.head // empty' "$S/meta")
    if [ -n "$current" ] && [ "$current" != "$head" ]; then continue; fi
    if [ "$(jq -r .headRefOid "$S/pr-snapshot.json")" != "$head" ] || ! checks_finished "$S/pr-snapshot.json"; then
      if jq -e --arg head "$head" '.headRefOid==$head and .mergeable=="CONFLICTING"' "$S/pr-snapshot.json" >/dev/null; then
        conflict=true; break
      fi
      sleep "$DV_POLL_INTERVAL"; continue
    fi
    review_snapshot "$pr" "$S/pr-snapshot.json" || { rm "$review"; return 1; }
    [ "$(jq -r .status "$S/meta")" != parked ] || { rm "$review"; return 0; }
    review_parse "$S/pr-snapshot.json" "$head" > "$review"
    green=false; checks_green "$S/pr-snapshot.json" && green=true
    # CI failures return to the worker immediately; review waiting starts only
    # after green CI. Old --review-handled receipts cannot waive this gate.
    if [ "$green" = false ]; then
      loop=$(printf '%s\n' "$loop" | jq --arg head "$head" '.failed_heads |= (. + [$head] | unique)')
      break
    fi
    if jq -e '.exists' "$review" >/dev/null; then
      reviewed=true
      loop=$(printf '%s\n' "$loop" | jq --arg head "$head" '.reviewed_heads |= (. + [$head] | unique)')
      break
    fi
    deadline=$(printf '%s\n' "$loop" | jq -r --arg head "$head" '.requests[$head].deadline // empty')
    max_deadline=$(( $(now) + DV_REVIEW_WAIT ))
    if [ -z "$deadline" ]; then
      # PR-open triggers the initial review. Every later head gets one explicit
      # request, persisted under the waiter lock so foreground/background agree.
      if [ "$(printf '%s\n' "$loop" | jq -r .initial_head)" != "$head" ]; then
        gh pr comment "$pr" --body '@codex review' >/dev/null
        deadline=$(( $(now) + DV_REVIEW_WAIT ))
        loop=$(printf '%s\n' "$loop" | jq --arg head "$head" --argjson deadline "$deadline" '.requests[$head]={deadline:$deadline,retried:false}')
        tmp=$(mktemp "$S/.pr-loop.XXXXXX"); printf '%s\n' "$loop" > "$tmp"; mv "$tmp" "$S/pr-loop.json"
        continue
      fi
      deadline=$(( $(now) + DV_REVIEW_WAIT ))
      loop=$(printf '%s\n' "$loop" | jq --arg head "$head" --argjson deadline "$deadline" '.requests[$head]={deadline:$deadline,retried:false}')
    elif [ "$deadline" -gt "$max_deadline" ]; then
      deadline=$max_deadline
      loop=$(printf '%s\n' "$loop" | jq --arg head "$head" --argjson deadline "$deadline" '.requests[$head].deadline=$deadline')
    fi
    if [ "$(now)" -ge "$deadline" ]; then
      retry=$(printf '%s\n' "$loop" | jq -r --arg head "$head" '.requests[$head].retried')
      if [ "$retry" = true ]; then reason='review-timeout'; break; fi
      gh pr comment "$pr" --body '@codex review' >/dev/null
      deadline=$(( $(now) + DV_REVIEW_WAIT ))
      loop=$(printf '%s\n' "$loop" | jq --arg head "$head" --argjson deadline "$deadline" '.requests[$head]={deadline:$deadline,retried:true}')
    fi
    tmp=$(mktemp "$S/.pr-loop.XXXXXX"); printf '%s\n' "$loop" > "$tmp"; mv "$tmp" "$S/pr-loop.json"
    sleep "$DV_POLL_INTERVAL"
  done
  [ "$(jq -r .status "$S/meta")" != parked ] || { rm "$review"; return 0; }
  if [ "$conflict" = true ]; then
    pr_wait_conflict_ready "$head" "$loop"
    rm "$review"
    [ "$foreground" != true ] || { cat "$S/pr-ready.json"; return 1; }
    recovery_episode=$(cat "$S/revive/id" 2>/dev/null) || recovery_episode=''
    pr_wait_unlock; trap - EXIT
    pr_wait_recover "$head" "$recovery_episode" "Your PR conflicts with origin/$BASE, so GitHub runs no CI on it. In the same worktree: git fetch origin && git merge origin/$BASE, resolve every conflict keeping both sides' intent (the base is newer; adapt this branch to it), run the related tests, commit, dv pr $ISSUE, then dv pr-wait $ISSUE --foreground. If the base already contains this change, finish with dv done $ISSUE --already-merged <PR> instead. Never force push. Preserve pr-loop.json round counts. Only run dv done $ISSUE after green CI and a clean current-head review."
    return 0
  fi
  rounds=$(printf '%s\n' "$loop" | jq '.reviewed_heads|length')
  if [ "$green" = false ] && [ "$(printf '%s\n' "$loop" | jq '.failed_heads|length')" -ge 3 ]; then reason=ci-rounds; fi
  if [ "$green" = true ] && [ "$rounds" -ge "$DV_REVIEW_ROUNDS" ] && jq -e '.high|length>0' "$review" >/dev/null; then reason='review-rounds'; fi
  loop=$(printf '%s\n' "$loop" | jq --arg head "$head" --slurpfile review "$review" \
    '.review_handled=$review[0].clean | .review_head=$head | .review_id=$review[0].id')
  tmp=$(mktemp "$S/.pr-loop.XXXXXX"); printf '%s\n' "$loop" > "$tmp"; mv "$tmp" "$S/pr-loop.json"
  tmp=$(mktemp "$S/.pr-ready.XXXXXX")
  jq -n --arg head "$head" --argjson checks_exit "$rc" --argjson green "$green" --argjson reviewed "$reviewed" \
    --argjson loop "$loop" --arg reason "$reason" --slurpfile review "$review" --slurpfile snapshot "$S/pr-snapshot.json" \
    '{head:$head,checks_exit:$checks_exit,green:$green,bot_review:$reviewed,review:$review[0],
      review_handled:$loop.review_handled,review_timed_out:($reason=="review-timeout"),review_rounds:($loop.reviewed_heads|length),
      ci_rounds:($loop.failed_heads|length),blocked:($reason!=""),reason:$reason,snapshot:$snapshot[0]}' > "$tmp"
  mv "$tmp" "$S/pr-ready.json"
  if [ -n "$reason" ]; then
    if ! printf '%s\n' "$loop" | jq -e --arg key "$head:$reason" '.blocked_events[$key]' >/dev/null; then
      cmd_kick blocked "$ISSUE" "$reason: $(jq -c '{head,high}' "$review")"
      tmp=$(mktemp "$S/.pr-loop.XXXXXX")
      printf '%s\n' "$loop" | jq --arg key "$head:$reason" '.blocked_events[$key]=true' > "$tmp"; mv "$tmp" "$S/pr-loop.json"
    fi
    rm "$review"
    [ "$foreground" != true ] || cat "$S/pr-ready.json"
    return 1
  fi
  if [ "$foreground" = true ]; then
    if [ "$green" = true ]; then review_followup "$pr" "$review"; fi
    rm "$review"
    cat "$S/pr-ready.json"
    [ "$handled" = false ] || jq -e '.review_handled' "$S/pr-ready.json" >/dev/null
    return
  fi
  rm "$review"
  recovery_episode=$(cat "$S/revive/id" 2>/dev/null) || recovery_episode=''
  pr_wait_unlock; trap - EXIT
  pr_wait_recover "$head" "$recovery_episode" "Continue owning this PR in the same worktree. Read $S/pr-ready.json and $S/pr-snapshot.json for CI and the current-head Codex findings. Fix P0/P1, test, commit, dv pr $ISSUE, and dv pr-wait $ISSUE --foreground. Each new head needs a fresh Codex review; devflow requests it after green CI. Preserve pr-loop.json round counts. Only run dv done $ISSUE after green CI and a clean current-head review."
}
pr_done_check() {
  local head=$1 pr tmp
  [ -f "$S/pr.json" ] || fail 'GitHub completion requires dv pr and a green PR'
  jq -e '.review_handled==true' "$S/pr-loop.json" >/dev/null 2>&1 || fail 'wait for a clean current-head Codex review with pr-wait --foreground'
  jq -e --arg head "$head" '.head==$head and .green and .review_handled' "$S/pr-ready.json" >/dev/null 2>&1 || fail 'wait for the current PR head before done'
  require_clean "$WT"
  pr=$(jq -er .url "$S/pr.json")
  tmp=$(mktemp "$S/.done-checks.XXXXXX")
  (cd "$WT" && gh pr view "$pr" --json headRefOid,baseRefName,statusCheckRollup,state) > "$tmp"
  mv "$tmp" "$S/done-checks.json"
  jq -e --arg head "$head" --arg base "$BASE" '.headRefOid==$head and .baseRefName==$base and .state=="OPEN"' "$S/done-checks.json" >/dev/null || fail 'PR head/base/state mismatch'
  checks_green "$S/done-checks.json" || fail 'current PR checks must be green before done'
  review_require_clean "$pr" "$S/done-checks.json" "$head"
}
cmd_review() {
  [ "$#" -eq 1 ] || fail 'usage: dv review ISSUE'
  load_issue "$1"; issue_lock; require_worktree
  is_github && fail 'GitHub repositories use PR bot reviews'
  local count=0 rc=0 args=("$DV_CODEX_BIN")
  [ ! -f "$S/review.count" ] || count=$(cat "$S/review.count")
  count=$((count + 1)); printf '%s\n' "$count" > "$S/review.count"
  [ "$DV_CODEX_DISABLE_HOOKS" != 1 ] || args+=(--disable hooks)
  [ "$DV_CODEX_DISABLE_CRW" != 1 ] || args+=(-c 'plugins."crw@crw".enabled=false')
  (cd "$WT" && "${args[@]}" review --base "$BASE") > "$S/review-$count.log" 2>&1 || rc=$?
  cat "$S/review-$count.log"
  printf '%s\n' "$rc" > "$S/review-$count.exit"
  return "$rc"
}
github_land_method() (
  # Isolate repository configuration from the caller's head/base and cleanup.
  local override=${DV_LAND_METHOD:-} method settings pr repository
  cd "$WT" || exit
  if [ -f .devflow ]; then
    # Repository-owned shell configuration is trusted, as with local land.
    # shellcheck source=/dev/null
    source ./.devflow >&2 || fail 'could not load repository land configuration'
  fi
  method=${override:-${DV_LAND_METHOD:-}}
  pr=$(jq -er .url "$S/pr.json") || fail 'could not read PR URL'
  if [[ "$pr" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)$ ]]; then
    repository="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  else fail 'invalid PR URL'; fi
  settings=$(gh api "repos/$repository") || fail 'could not read repository merge methods'
  case "$method" in
    '')
      method=$(printf '%s\n' "$settings" | jq -r '
        if .allow_squash_merge==true then "squash"
        elif .allow_merge_commit==true then "merge"
        elif .allow_rebase_merge==true then "rebase" else empty end') || fail 'invalid repository merge methods'
      [ -n "$method" ] || fail 'repository allows no PR merge method' ;;
    squash|merge|rebase) ;;
    *) fail 'DV_LAND_METHOD must be squash, merge or rebase' ;;
  esac
  printf '%s\n' "$settings" | jq -e --arg method "$method" '
    if $method=="merge" then .allow_merge_commit==true
    elif $method=="squash" then .allow_squash_merge==true
    else .allow_rebase_merge==true end' >/dev/null || fail "repository does not allow $method"
  printf '%s\n' "$method"
)
github_land_reconcile() {
  local head=$1 recorded done_head='' tmp
  recorded=$(jq -r '.head // empty' "$S/meta")
  if [ -f "$S/done.json" ]; then done_head=$(jq -r '.head // empty' "$S/done.json"); fi
  jq -e --arg head "$head" --arg recorded "$recorded" --arg done_head "$done_head" --arg base "$BASE" '
    .state=="MERGED" and .baseRefName==$base and
    (.headRefOid | type=="string" and test("^[0-9a-f]{40,64}$")) and
    (.headRefOid==$head or .headRefOid==$recorded or .headRefOid==$done_head)
  ' "$S/land-checks.json" >/dev/null || fail 'PR head/base/state mismatch'
  checks_green "$S/land-checks.json" || fail 'all PR checks must be successful (empty, skipped, pending and failed checks refuse land)'
  head=$(jq -r .headRefOid "$S/land-checks.json")
  tmp=$(mktemp "$S/.land-result.XXXXXX")
  cp "$S/land-checks.json" "$tmp"; mv "$tmp" "$S/land-result.json"
  if [ "$(jq -r .status "$S/meta")" != landed ]; then metrics_note merged "$head"; fi
  meta_set --arg head "$head" --argjson time "$(now)" \
    '.status="landed" | .head=$head | .landed_at=(.landed_at // $time)'
  # Only a verified merge may bypass the App Server idle guard. Cleanup can
  # be retried after interruption, including after the worktree was removed.
  if ! jq -se --arg head "$head" 'any(.[]; .kind=="landed" and .head==$head)' "$S/events.log" >/dev/null 2>&1; then
    cmd_kick landed "$ISSUE" 'Landed'
  fi
  clean_worktree merged-pr
}
cmd_land() {
  [ "$#" -eq 1 ] || fail 'usage: dv land ISSUE'
  load_issue "$1"; issue_lock
  local pr head='' method rc context=$WT
  if jq -e '.merged_via.commit | type=="string"' "$S/done.json" >/dev/null 2>&1; then already_merged_land; return; fi
  if [ -d "$WT" ] || [ "$(jq -r .status "$S/meta")" != landed ]; then
    require_worktree; require_clean "$WT"
    head=$(git -C "$WT" rev-parse HEAD)
  else context=$REPO; fi
  if is_github; then
    pr=$(jq -er .url "$S/pr.json")
    (cd "$context" && gh pr view "$pr" --json headRefOid,baseRefName,statusCheckRollup,state) > "$S/land-checks.json"
    if [ "$(jq -r .state "$S/land-checks.json")" = MERGED ]; then
      github_land_reconcile "$head"
      return
    fi
  fi
  require_worktree
  [ "$BACKEND" != appserver ] || appserver_require_idle
  if [ "$BACKEND" = exec ]; then
    ! codex_exec_alive "$S" || fail 'exec is still running; cannot land'
    # dv done can precede a later CLI error or retry. Only the supervisor's
    # successful terminal state permits either local or GitHub merging.
    if [ ! -f "$S/agent.exit" ] || [ "$(cat "$S/agent.exit")" != 0 ] ||
      ! jq -e '.exec_status=="done"' "$S/meta" >/dev/null; then
      fail 'exec has not completed successfully; cannot land'
    fi
  fi
  if is_github; then
    pr=$(jq -er .url "$S/pr.json"); head=$(git -C "$WT" rev-parse HEAD)
    stack_land_gate "$pr" "$head" || { rc=$?; stack_conflict_send; stack_review_send || return $?; return "$rc"; }
    head=$(git -C "$WT" rev-parse HEAD)
    (cd "$WT" && gh pr view "$pr" --json headRefOid,baseRefName,statusCheckRollup,state) > "$S/land-checks.json"
    jq -e --arg head "$head" --arg base "$BASE" '.headRefOid==$head and .baseRefName==$base and .state=="OPEN"' "$S/land-checks.json" >/dev/null || fail 'PR head/base/state mismatch'
    checks_green "$S/land-checks.json" || fail 'all PR checks must be successful (empty, skipped, pending and failed checks refuse land)'
    review_require_clean "$pr" "$S/land-checks.json" "$head"
    # Optional operator gate (e.g. "did the PR do what its issue asks").
    # Called as: $DV_LAND_CHECK <owner/repo> <pr-number> <head>; non-zero refuses land.
    if [ -n "${DV_LAND_CHECK:-}" ]; then
      local land_repo=${pr#https://github.com/}; land_repo=${land_repo%/pull/*}
      "$DV_LAND_CHECK" "$land_repo" "${pr##*/}" "$head" || fail 'land check refused this PR; see the PR comment'
    fi
    method=$(github_land_method) || return 1
    (cd "$WT" && gh pr merge "$pr" "--$method" --match-head-commit "$head")
    (cd "$WT" && gh pr view "$pr" --json state,headRefOid) > "$S/land-result.json"
    jq -e --arg head "$head" '.state=="MERGED" and .headRefOid==$head' "$S/land-result.json" >/dev/null || fail 'merge not confirmed; worktree retained'
  else
    local_land
  fi
  metrics_note merged "$(git -C "$WT" rev-parse HEAD)"
  meta_set --argjson time "$(now)" '.status="landed" | .landed_at=$time'
  cmd_kick landed "$ISSUE" 'Landed'
  clean_worktree
}
local_land() {
  local test_cmd=$DV_TEST_CMD mode=$DV_LAND_MODE before target candidate result merged
  if [ -f "$WT/.devflow" ]; then
    # Repository-owned shell configuration is trusted like its test command.
    # shellcheck source=/dev/null
    source "$WT/.devflow"
    test_cmd=${test_cmd:-$DV_TEST_CMD}; mode=$DV_LAND_MODE
  fi
  [ -n "$test_cmd" ] || fail 'set DV_TEST_CMD or define it in .devflow before local land'
  case "$mode" in ff|merge) ;; *) fail 'DV_LAND_MODE must be ff or merge' ;; esac
  before=$(git -C "$REPO" rev-parse "refs/heads/$BASE")
  target=$(git -C "$REPO" worktree list --porcelain | awk -v branch="refs/heads/$BASE" '/^worktree / {p=substr($0,10)} /^branch / && substr($0,8)==branch {print p}')
  [ -z "$target" ] || require_clean "$target"
  candidate=$(mktemp -d "$DV_WORK/.land-$ISSUE.XXXXXX")
  git -C "$REPO" worktree add --detach "$candidate" "$before" >/dev/null
  result=0
  if [ "$mode" = ff ]; then git -C "$candidate" merge --ff-only "$BRANCH" > "$S/land.log" 2>&1 || result=$?
  else git -C "$candidate" -c user.name=devflow -c user.email=devflow@localhost merge --no-ff -m "$ISSUE: merge $BRANCH" "$BRANCH" > "$S/land.log" 2>&1 || result=$?; fi
  if [ "$result" -eq 0 ]; then (cd "$candidate" && bash -c "$test_cmd") >> "$S/land.log" 2>&1 || result=$?; fi
  if ! git -C "$candidate" diff --quiet HEAD --; then result=1; fi
  merged=$(git -C "$candidate" rev-parse HEAD)
  # This disposable worktree belongs only to this invocation, including test outputs.
  git -C "$REPO" worktree remove --force "$candidate"
  [ "$result" -eq 0 ] || fail "merge/test failed; base unchanged (see $S/land.log)"
  [ "$(git -C "$REPO" rev-parse "refs/heads/$BASE")" = "$before" ] || fail 'base changed during test; retry land'
  if [ -n "$target" ]; then
    require_clean "$target"
    [ "$(git -C "$target" symbolic-ref -q HEAD)" = "refs/heads/$BASE" ] || fail 'base worktree changed branches during test; retry land'
    git -C "$target" merge --ff-only "$merged"
  else git -C "$REPO" update-ref "refs/heads/$BASE" "$merged" "$before"; fi
}
