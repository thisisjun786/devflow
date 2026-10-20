#!/usr/bin/env bash
# jq filters and Markdown are literal strings, not shell substitutions.
# shellcheck disable=SC2016
cmd_pr() {
  [ "$#" -eq 1 ] || fail 'usage: dv pr ISSUE'
  load_issue "$1"; issue_lock; require_worktree; require_clean "$WT"
  is_github || fail 'dv pr requires a GitHub origin'
  cd "$WT" || exit
  [ "$BRANCH" != "$BASE" ] || fail 'cannot push the base branch'
  local head pr title
  head=$(git rev-parse HEAD)
  git push -u origin "$BRANCH:refs/heads/$BRANCH"
  if [ -f "$S/pr.json" ]; then
    pr=$(jq -er .url "$S/pr.json")
  else
    title="$ISSUE: $(jq -r .slug "$S/meta")"
    if [ -s "$S/pr.md" ]; then
      # Worker-written public body: no brief, internal report or state paths.
      cp "$S/pr.md" "$S/pr-body.md"
    else {
      printf '## 브리프\n\n'
      cat "$S/brief.md"
      printf '\n## 보고서\n\n경로: `%s/report.md`\n\n' "$S"
      if [ -f "$S/report.md" ]; then cat "$S/report.md"; else printf '보고서가 아직 없습니다.\n'; fi
    } > "$S/pr-body.md"
    fi
    pr=$(gh pr create --base "$BASE" --head "$BRANCH" --title "$title" --body-file "$S/pr-body.md")
    jq -n --arg url "$pr" '{url:$url}' > "$S/pr.json"
    nohup "$DV_ROOT/bin/dv" polish "$ISSUE" >> "$S/polish.log" 2>&1 < /dev/null &
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
    nohup setsid "$DV_ROOT/bin/dv" pr-wait "$ISSUE" >> "$S/pr-wait.log" 2>&1 < /dev/null &
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
  [ "$#" -eq 1 ] || fail 'usage: dv pr-wait ISSUE'
  load_issue "$1"; require_worktree; cd "$WT" || exit
  local pr head rc=0 deadline='' reviewed=false snapshot tmp current green
  pr=$(jq -er .url "$S/pr.json"); head=$(jq -r '.head // empty' "$S/meta")
  [ -n "$head" ] || head=$(git rev-parse HEAD)
  # Only one waiter per issue; a later push starts another after this waiter exits.
  pr_wait_lock || return 0
  trap pr_wait_unlock EXIT
  trap 'exit 0' INT TERM
  while :; do
    rc=0
    gh pr checks "$pr" --watch > "$S/checks.log" 2>&1 || rc=$?
    snapshot=$(gh pr view "$pr" --json headRefOid,baseRefName,statusCheckRollup,reviews,state)
    tmp=$(mktemp "$S/.pr-snapshot.XXXXXX"); printf '%s\n' "$snapshot" > "$tmp"; mv "$tmp" "$S/pr-snapshot.json"
    [ "$(jq -r .state "$S/pr-snapshot.json")" = OPEN ] || return 0
    # A correction can push while the first wait is active. Follow the new head.
    current=$(jq -r '.head // empty' "$S/meta")
    if [ -n "$current" ] && [ "$current" != "$head" ]; then
      head=$current; deadline=''; reviewed=false
    fi
    if [ "$(jq -r .headRefOid "$S/pr-snapshot.json")" = "$head" ] && checks_finished "$S/pr-snapshot.json"; then
      [ -n "$deadline" ] || deadline=$(( $(now) + DV_REVIEW_WAIT ))
      reviewed=false
      if printf '%s\n' "$snapshot" | jq -e --arg bots "$DV_REVIEW_BOTS" --arg head "$head" \
        '.reviews as $reviews | ($bots|split(",")) | all(.[]; . as $pattern | any($reviews[]?; (.author.login|test($pattern;"i")) and .commit.oid==$head))' >/dev/null; then reviewed=true; fi
      if [ "$reviewed" = true ] || [ "$(now)" -ge "$deadline" ]; then break; fi
    else
      # gh checks --watch returns immediately before CI is registered. Empty
      # or pending rollups must be polled again, even after the review timeout.
      deadline=''; reviewed=false
    fi
    sleep "$DV_POLL_INTERVAL"
  done
  green=false
  checks_green "$S/pr-snapshot.json" && green=true
  jq -n --arg head "$head" --argjson checks_exit "$rc" --argjson green "$green" --argjson reviewed "$reviewed" \
    '{head:$head,checks_exit:$checks_exit,green:$green,bot_review:$reviewed,review_timed_out:($reviewed|not)}' > "$S/pr-ready.json"
  meta_set --arg head "$head" 'if .head==$head and .status=="pr" then .status="ready" else . end'
  cmd_kick pr-ready "$ISSUE" "checks=$green bot-review=$reviewed"
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
cmd_land() {
  [ "$#" -eq 1 ] || fail 'usage: dv land ISSUE'
  load_issue "$1"; issue_lock; require_worktree; require_clean "$WT"
  if is_github; then
    local pr head method
    pr=$(jq -er .url "$S/pr.json"); head=$(git -C "$WT" rev-parse HEAD)
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
  meta_set '.status="landed"'
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
