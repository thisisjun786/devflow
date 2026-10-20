#!/usr/bin/env bash
# jq filters and Markdown are literal strings, not shell substitutions.
# shellcheck disable=SC2016
cmd_pr() {
  [ "$#" -eq 1 ] || fail 'usage: dv pr ISSUE'
  load_issue "$1"; issue_lock; require_worktree; require_clean "$WT"
  is_github || fail 'dv pr requires a GitHub origin'
  cd "$WT" || exit
  [ "$BRANCH" != "$BASE" ] || fail 'cannot push the base branch'
  local head pr title public_body=''
  if [ -f "$S/pr.md" ]; then
    # Coordinate with an older in-flight polish before publishing exact prose.
    mkdir "$S/.polish" 2>/dev/null || fail 'PR polish is still running; retry dv pr when it finishes'
    trap 'rm -f "$S/.polish/public-body"; rmdir "$S/.polish" "$S/.operation" 2>/dev/null || true' EXIT
    public_body="$S/.polish/public-body"
    cp "$S/pr.md" "$public_body"
  fi
  head=$(git rev-parse HEAD)
  git push -u origin "$BRANCH:refs/heads/$BRANCH"
  if [ -f "$S/pr.json" ]; then
    pr=$(jq -er .url "$S/pr.json")
    if [ -n "$public_body" ] && ! cmp -s "$public_body" "$S/pr-body.md"; then
      gh pr edit "$pr" --body-file "$public_body"
      mv "$public_body" "$S/pr-body.md"
    fi
  else
    title="$ISSUE: $(jq -r .slug "$S/meta")"
    if [ -n "$public_body" ]; then
      # Worker-written public body: no brief, internal report or state paths.
      cp "$public_body" "$S/pr-body.md"
    else {
      printf '## 브리프\n\n'
      cat "$S/brief.md"
      printf '\n## 보고서\n\n경로: `%s/report.md`\n\n' "$S"
      if [ -f "$S/report.md" ]; then cat "$S/report.md"; else printf '보고서가 아직 없습니다.\n'; fi
    } > "$S/pr-body.md"
    fi
    pr=$(gh pr create --base "$BASE" --head "$BRANCH" --title "$title" --body-file "$S/pr-body.md")
    jq -n --arg url "$pr" '{url:$url}' > "$S/pr.json"
    if [ -z "$public_body" ]; then
      nohup "$DV_ROOT/bin/dv" polish "$ISSUE" >> "$S/polish.log" 2>&1 < /dev/null &
    fi
  fi
  if [ -n "$public_body" ]; then
    rm -f "$public_body"
    rmdir "$S/.polish"
    trap 'rmdir "$S/.operation" 2>/dev/null || true' EXIT
  fi
  meta_set --arg head "$head" --arg pr "$pr" '.status="pr" | .head=$head | .pr=$pr'
  nohup "$DV_ROOT/bin/dv" pr-wait "$ISSUE" > "$S/pr-wait.log" 2>&1 < /dev/null &
  printf '%s\n' "$!" > "$S/pr-wait.pid"
  printf '%s\n' "$pr"
}
checks_green() {
  jq -e '.statusCheckRollup | length>0 and all(.[ ];
    if .__typename=="CheckRun" then .status=="COMPLETED" and .conclusion=="SUCCESS"
    elif .__typename=="StatusContext" then .state=="SUCCESS" else false end)' "$1" >/dev/null
}
cmd_pr_wait() {
  [ "$#" -eq 1 ] || fail 'usage: dv pr-wait ISSUE'
  load_issue "$1"; require_worktree; cd "$WT" || exit
  local pr head rc=0 deadline reviewed=false snapshot tmp
  pr=$(jq -er .url "$S/pr.json"); head=$(git rev-parse HEAD)
  # Only one waiter per issue; a later push starts another after this waiter exits.
  mkdir "$S/.pr-wait" 2>/dev/null || return 0
  trap 'rmdir "$S/.pr-wait" 2>/dev/null || true' EXIT
  while :; do
    gh pr checks "$pr" --watch > "$S/checks.log" 2>&1 || rc=$?
    deadline=$(( $(now) + DV_REVIEW_WAIT )); reviewed=false
    while :; do
      snapshot=$(gh pr view "$pr" --json headRefOid,baseRefName,statusCheckRollup,reviews,state)
      tmp=$(mktemp "$S/.pr-snapshot.XXXXXX"); printf '%s\n' "$snapshot" > "$tmp"; mv "$tmp" "$S/pr-snapshot.json"
      if printf '%s\n' "$snapshot" | jq -e --arg bots "$DV_REVIEW_BOTS" --arg head "$head" \
        '.reviews as $reviews | ($bots|split(",")) | all(.[]; . as $pattern | any($reviews[]?; (.author.login|test($pattern;"i")) and .commit.oid==$head))' >/dev/null; then reviewed=true; break; fi
      [ "$(now)" -lt "$deadline" ] || break
      sleep "$DV_POLL_INTERVAL"
    done
    # A correction can push while the first wait is active. Follow the new head.
    if [ "$(jq -r .head "$S/meta")" != "$head" ]; then
      head=$(jq -r .head "$S/meta"); rc=0; continue
    fi
    local green=false
    checks_green "$S/pr-snapshot.json" && green=true
    jq -n --arg head "$head" --argjson checks_exit "$rc" --argjson green "$green" --argjson reviewed "$reviewed" \
      '{head:$head,checks_exit:$checks_exit,green:$green,bot_review:$reviewed,review_timed_out:($reviewed|not)}' > "$S/pr-ready.json"
    meta_set --arg head "$head" 'if .head==$head and .status=="pr" then .status="ready" else . end'
    cmd_kick pr-ready "$ISSUE" "checks=$green bot-review=$reviewed"
    break
  done
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
  local override=${DV_LAND_METHOD:-} method settings
  cd "$WT" || exit
  if [ -f .devflow ]; then
    # Repository-owned shell configuration is trusted, as with local land.
    # shellcheck source=/dev/null
    source ./.devflow || fail 'could not load repository land configuration'
  fi
  method=${override:-${DV_LAND_METHOD:-}}
  settings=$(gh repo view --json mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed) || fail 'could not read repository merge methods'
  case "$method" in
    '')
      method=$(printf '%s\n' "$settings" | jq -r '
        if .squashMergeAllowed==true then "squash"
        elif .mergeCommitAllowed==true then "merge"
        elif .rebaseMergeAllowed==true then "rebase" else empty end') || fail 'invalid repository merge methods'
      [ -n "$method" ] || fail 'repository allows no PR merge method' ;;
    squash|merge|rebase) ;;
    *) fail 'DV_LAND_METHOD must be squash, merge or rebase' ;;
  esac
  printf '%s\n' "$settings" | jq -e --arg method "$method" '
    if $method=="merge" then .mergeCommitAllowed==true
    elif $method=="squash" then .squashMergeAllowed==true
    else .rebaseMergeAllowed==true end' >/dev/null || fail "repository does not allow $method"
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
