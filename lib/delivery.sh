#!/usr/bin/env bash
# jq filters and Markdown are literal strings, not shell substitutions.
# shellcheck disable=SC2016
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
cmd_pr() {
  [ "$#" -eq 1 ] || fail 'usage: dv pr ISSUE'
  load_issue "$1"; issue_lock; require_worktree; require_clean "$WT"
  is_github || fail 'dv pr requires a GitHub origin'
  cd "$WT" || exit
  [ "$BRANCH" != "$BASE" ] || fail 'cannot push the base branch'
  local head pr title endpoint body_file public_source='' public_body='' edit_args
  if [ -f "$S/pr.md" ]; then
    public_source="$S/pr.md"
  elif [ ! -f "$S/pr.json" ] && [ -f "$S/pr-body.md" ]; then
    # Older workers prepared this filename before the first publication.
    public_source="$S/pr-body.md"
  fi
  if [ -n "$public_source" ]; then
    # Coordinate with an older in-flight polish before publishing exact prose.
    mkdir "$S/.polish" 2>/dev/null || fail 'PR polish is still running; retry dv pr when it finishes'
    trap 'rm -f "$S/.polish/public-body"; rmdir "$S/.polish" "$S/.operation" 2>/dev/null || true' EXIT
    public_body="$S/.polish/public-body"
    cp "$public_source" "$public_body"
  fi
  head=$(git rev-parse HEAD)
  title=$(git log -1 --format=%s)
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
cmd_pr_wait() {
  [ "$#" -ge 1 ] || fail 'usage: dv pr-wait ISSUE [--foreground [--review-handled]]'
  load_issue "$1"; shift; require_worktree; cd "$WT" || exit
  local foreground=false handled=false arg
  for arg in "$@"; do
    case "$arg" in --foreground) foreground=true ;; --review-handled) handled=true ;; *) fail "unknown option: $arg" ;; esac
  done
  [ "$handled:$foreground" != true:false ] || fail '--review-handled requires --foreground'
  local pr head rc=0 deadline='' reviewed=false snapshot tmp current green comments endpoint loop review_head=''
  pr=$(jq -er .url "$S/pr.json")
  # A foreground caller must receive a result even when dv pr's safety net owns
  # the lock. Never terminate a live waiter or return an empty success.
  until pr_wait_lock; do
    [ "$foreground" = true ] || return 0
    sleep "$DV_POLL_INTERVAL"
  done
  trap pr_wait_unlock EXIT
  trap 'exit 0' INT TERM
  head=$(jq -r '.head // empty' "$S/meta")
  [ -n "$head" ] || head=$(git rev-parse HEAD)
  loop='{"failed_heads":[],"review_handled":false}'
  [ ! -f "$S/pr-loop.json" ] || loop=$(cat "$S/pr-loop.json")
  if [ "$handled" = true ]; then
    review_head=$(jq -er '.head' "$S/pr-ready.json") || fail 'wait for a review snapshot before acknowledging it'
    git merge-base --is-ancestor "$review_head" "$head" || fail 'review snapshot is not an ancestor of the PR head'
    loop=$(printf '%s\n' "$loop" | jq --arg head "$review_head" '.review_handled=true | .review_head=$head')
    tmp=$(mktemp "$S/.pr-loop.XXXXXX"); printf '%s\n' "$loop" > "$tmp"; mv "$tmp" "$S/pr-loop.json"
  fi
  if printf '%s\n' "$loop" | jq -e '.review_handled' >/dev/null; then
    review_head=$(printf '%s\n' "$loop" | jq -er .review_head)
    git merge-base --is-ancestor "$review_head" "$head" || fail 'handled review is not an ancestor of the PR head'
  fi
  while :; do
    rc=0
    gh pr checks "$pr" --watch > "$S/checks.log" 2>&1 || rc=$?
    snapshot=$(gh pr view "$pr" --json headRefOid,baseRefName,statusCheckRollup,reviews,state)
    tmp=$(mktemp "$S/.pr-snapshot.XXXXXX"); printf '%s\n' "$snapshot" > "$tmp"; mv "$tmp" "$S/pr-snapshot.json"
    if [ "$(jq -r .state "$S/pr-snapshot.json")" != OPEN ]; then
      [ "$foreground" != true ] || fail 'PR is no longer open'
      return 0
    fi
    # A correction can push while the first wait is active. Follow the new head.
    current=$(jq -r '.head // empty' "$S/meta")
    if [ -n "$current" ] && [ "$current" != "$head" ]; then
      head=$current; deadline=''; reviewed=false
      if [ -n "$review_head" ]; then
        git merge-base --is-ancestor "$review_head" "$head" || fail 'handled review is not an ancestor of the PR head'
      fi
    fi
    if [ "$(jq -r .headRefOid "$S/pr-snapshot.json")" = "$head" ] && checks_finished "$S/pr-snapshot.json"; then
      [ -n "$deadline" ] || deadline=$(( $(now) + DV_REVIEW_WAIT ))
      reviewed=false
      if printf '%s\n' "$snapshot" | jq -e --arg bots "$DV_REVIEW_BOTS" --arg head "$head" \
        '.reviews as $reviews | ($bots|split(",")) | all(.[]; . as $pattern | any($reviews[]?; (.author.login|test($pattern;"i")) and .commit.oid==$head))' >/dev/null; then reviewed=true; fi
      if [ -n "$review_head" ] || [ "$reviewed" = true ] || [ "$(now)" -ge "$deadline" ]; then break; fi
    else
      # gh checks --watch returns immediately before CI is registered. Empty
      # or pending rollups must be polled again, even after the review timeout.
      deadline=''; reviewed=false
    fi
    sleep "$DV_POLL_INTERVAL"
  done
  green=false
  checks_green "$S/pr-snapshot.json" && green=true
  # Inline findings are not part of gh pr view's reviews field. Fetch all pages
  # before publishing a result; an API error must not look like a clean review.
  if [[ "$pr" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)$ ]]; then
    endpoint="repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/pulls/${BASH_REMATCH[3]}/comments"
  else fail 'invalid PR URL'; fi
  comments=$(mktemp "$S/.pr-comments.XXXXXX")
  if ! gh api --paginate "$endpoint" | jq -s 'add // []' > "$comments"; then
    rm -f "$comments"
    return 1
  fi
  tmp=$(mktemp "$S/.pr-snapshot.XXXXXX")
  # Inline comments include diff hunks; a normal review can exceed the OS
  # per-argument limit. Pass the data as a file, never as one argv entry.
  jq --slurpfile comments "$comments" '. + {inline_comments:$comments[0]}' "$S/pr-snapshot.json" > "$tmp"
  rm "$comments"
  mv "$tmp" "$S/pr-snapshot.json"
  if [ "$green" = false ]; then
    loop=$(printf '%s\n' "$loop" | jq --arg head "$head" '.failed_heads |= (. + [$head] | unique)')
  fi
  tmp=$(mktemp "$S/.pr-loop.XXXXXX"); printf '%s\n' "$loop" > "$tmp"; mv "$tmp" "$S/pr-loop.json"
  tmp=$(mktemp "$S/.pr-ready.XXXXXX")
  jq -n --arg head "$head" --argjson checks_exit "$rc" --argjson green "$green" --argjson reviewed "$reviewed" \
    --argjson loop "$loop" --slurpfile snapshot "$S/pr-snapshot.json" \
    '{head:$head,checks_exit:$checks_exit,green:$green,bot_review:$reviewed,
      review_handled:$loop.review_handled,review_timed_out:(($reviewed|not) and ($loop.review_handled|not)),
      ci_rounds:($loop.failed_heads|length),blocked:(($loop.failed_heads|length)>=3 and ($green|not)),snapshot:$snapshot[0]}' > "$tmp"
  mv "$tmp" "$S/pr-ready.json"
  if jq -e '.blocked' "$S/pr-ready.json" >/dev/null; then
    if [ ! -f "$S/pr-ci-blocked" ]; then
      cmd_kick blocked "$ISSUE" 'CI failed in 3 rounds; worker could not make the PR green'
      touch "$S/pr-ci-blocked"
    fi
    [ "$foreground" != true ] || cat "$S/pr-ready.json"
    return 1
  fi
  if [ "$foreground" = true ]; then cat "$S/pr-ready.json"; return; fi
  # Recovery uses the existing one-shot revival, only with positive exit
  # evidence. Release ownership BEFORE observing the worker: a later exit can
  # then start a successor. If its wrapper already observed our lock, agent.exit
  # was published first; wait for that wrapper to finish its handoff instead.
  pr_wait_unlock; trap - EXIT
  # Native exec and App Server clients own their recovery. Neither backend
  # should enter the terminal revival path after a PR wait.
  case "$BACKEND" in exec|appserver) return 0 ;; esac
  # Releasing the PR lock can admit the exiting wrapper's second waiter.
  # Serialize recovery too, so it cannot report a live revival as blocked
  # before that revival has published its new agent.pid.
  owned_lock "$S/.pr-recovery" "$$" || return 0
  trap 'owned_unlock "$S/.pr-recovery" "$$"' EXIT
  [ ! -d "$S/revive" ] || return 0
  local pid
  pid=$(cat "$S/agent.pid" 2>/dev/null) || pid=''
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
    [ -f "$S/agent.exit" ] || return 0
    while kill -0 "$pid" 2>/dev/null; do sleep "$DV_POLL_INTERVAL"; done
  fi
  [ "$(jq -r '.head // empty' "$S/meta")" = "$head" ] || return 0
  if jq -e --arg head "$head" '.head==$head and .checks=="green" and .review=="handled"' "$S/done.json" >/dev/null 2>&1; then return 0; fi
  if agent_gone; then
    "$DV_ROOT/bin/dv" send "$ISSUE" "Continue owning this PR in the same worktree. Read $S/pr-ready.json and $S/pr-snapshot.json for CI, reviews and inline findings. Fix P0/P1 review findings once (preserve review-fix.sent) and fix CI within 3 rounds. After handling the findings, acknowledge with dv pr-wait $ISSUE --foreground --review-handled before the next push. Commit, dv pr $ISSUE, and dv pr-wait $ISSUE --foreground until green. Do not request another review. Only run dv done $ISSUE after green CI and review handling."
  fi
}

pr_done_check() {
  local head=$1 pr tmp
  [ -f "$S/pr.json" ] || fail 'GitHub completion requires dv pr and a green PR'
  jq -e '.review_handled==true' "$S/pr-loop.json" >/dev/null 2>&1 || fail 'handle the review and acknowledge with pr-wait --foreground --review-handled'
  jq -e --arg head "$head" '.head==$head and .green and .review_handled' "$S/pr-ready.json" >/dev/null 2>&1 || fail 'wait for the current PR head before done'
  require_clean "$WT"
  pr=$(jq -er .url "$S/pr.json")
  tmp=$(mktemp "$S/.done-checks.XXXXXX")
  (cd "$WT" && gh pr view "$pr" --json headRefOid,baseRefName,statusCheckRollup,state) > "$tmp"
  mv "$tmp" "$S/done-checks.json"
  jq -e --arg head "$head" --arg base "$BASE" '.headRefOid==$head and .baseRefName==$base and .state=="OPEN"' "$S/done-checks.json" >/dev/null || fail 'PR head/base/state mismatch'
  checks_green "$S/done-checks.json" || fail 'current PR checks must be green before done'
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
  clean_worktree merged-pr
  if ! jq -se --arg head "$head" 'any(.[]; .kind=="landed" and .head==$head)' "$S/events.log" >/dev/null 2>&1; then
    cmd_kick landed "$ISSUE" 'Landed'
  fi
}
cmd_land() {
  [ "$#" -eq 1 ] || fail 'usage: dv land ISSUE'
  load_issue "$1"; issue_lock
  local pr head='' method rc context=$WT
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
    stack_land_gate "$pr" "$head" || { rc=$?; stack_conflict_send; return "$rc"; }
    head=$(git -C "$WT" rev-parse HEAD)
    (cd "$WT" && gh pr view "$pr" --json headRefOid,baseRefName,statusCheckRollup,state) > "$S/land-checks.json"
    jq -e --arg head "$head" --arg base "$BASE" '.headRefOid==$head and .baseRefName==$base and .state=="OPEN"' "$S/land-checks.json" >/dev/null || fail 'PR head/base/state mismatch'
    checks_green "$S/land-checks.json" || fail 'all PR checks must be successful (empty, skipped, pending and failed checks refuse land)'
    method=$(github_land_method) || return 1
    (cd "$WT" && gh pr merge "$pr" "--$method" --match-head-commit "$head")
    (cd "$WT" && gh pr view "$pr" --json state,headRefOid) > "$S/land-result.json"
    jq -e --arg head "$head" '.state=="MERGED" and .headRefOid==$head' "$S/land-result.json" >/dev/null || fail 'merge not confirmed; worktree retained'
  else
    local_land
  fi
  metrics_note merged "$(git -C "$WT" rev-parse HEAD)"
  meta_set --argjson time "$(now)" '.status="landed" | .landed_at=$time'
  clean_worktree
  cmd_kick landed "$ISSUE" 'Landed'
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
