#!/usr/bin/env bash
# PR title, body and branch formats: disposable repositories, gh stub, fake agent.
# shellcheck disable=SC2016
pr_format_libraries() {
  # Assigned by the shared test harness.
  # shellcheck disable=SC2153
  DV_ENTRY="$ROOT/bin/dv"
  # shellcheck source=lib/common.sh
  source "$ROOT/lib/common.sh"
  # shellcheck source=lib/commands.sh
  source "$ROOT/lib/commands.sh"
  # shellcheck source=lib/delivery.sh
  source "$ROOT/lib/delivery.sh"
}
case_pr_title_format() {
  pr_format_libraries
  local title
  for title in 'fix(tui): keep the progress card after restart' 'feat(delivery): check PR titles' \
    'docs: describe the PR format' 'test(pr): cover title checks' 'refactor(lib/common.sh): share type names' \
    'perf(review): read one page' 'chore(deps): update jq' 'ci(linux): run ShellCheck' 'feat(api)!: drop the legacy field'; do
    ( pr_title_check "$title" ) || { printf 'rejected valid title: %s\n' "$title"; return 1; }
  done
  for title in 'LN-512: keep the progress card' 'DF-245 feat(pr): format titles' 'ln-512 fix(tui): keep it' \
    'fix the progress card' 'Fix(tui): keep it' 'feature(tui): keep it' 'fix(tui):keep it' 'fix(): keep it' \
    'fix(tui): ' 'fix(tui) keep it' 'fix(t ui): keep it' 'WIP' ''; do
    if ( pr_title_check "$title" ) 2> "$CASE_DIR/title.err"; then printf 'accepted invalid title: %s\n' "$title"; return 1; fi
    # The worker fixes its own commit; dv never rewrites the subject.
    grep -F 'commit subject' "$CASE_DIR/title.err"
  done
  if ( pr_title_check 'LN-512: keep the progress card' ) 2> "$CASE_DIR/title.err"; then return 1; fi
  grep -F 'starts with an issue key' "$CASE_DIR/title.err"
  if ( pr_title_check 'keep the progress card' ) 2> "$CASE_DIR/title.err"; then return 1; fi
  grep -F 'feat fix docs test refactor perf chore ci' "$CASE_DIR/title.err"
}
pr_branch_expect() {
  local actual
  actual=$(issue_branch "$1" "$2" "$3")
  [ "$actual" = "$4" ] || { printf 'issue_branch %s %s %s: expected %s, got %s\n' "$1" "$2" "${3:-''}" "$4" "$actual"; return 1; }
  git check-ref-format --branch "$actual" >/dev/null
}
case_pr_branch_names() {
  pr_format_libraries
  pr_branch_expect LN-512 fix-progress-card '' fix/512-progress-card
  pr_branch_expect DF-245 pr-format '' feat/245-pr-format
  pr_branch_expect APP-42 fix-save '' fix/42-save
  pr_branch_expect APP-42 docs-readme '' docs/42-readme
  pr_branch_expect APP-42 ci-linux-only '' ci/42-linux-only
  pr_branch_expect APP-42 fixture-cleanup '' feat/42-fixture-cleanup
  pr_branch_expect APP-42 refactor '' refactor/42
  # Never repeat the key: the old codex/ln-512-ln-512 shape.
  pr_branch_expect LN-512 ln-512 '' feat/512
  pr_branch_expect LN-512 LN-512 '' feat/512
  pr_branch_expect LN-512 fix-ln-512 '' fix/512
  pr_branch_expect LN-512 ln-512-progress-card '' feat/512-progress-card
  pr_branch_expect LN-512 512-progress-card '' feat/512-progress-card
  pr_branch_expect DF-232 df-232-retry-aB3dEf '' feat/232-retry-aB3dEf
  # An explicit GitHub issue header wins; keys without a number keep the key.
  pr_branch_expect LN-214M source 214 feat/214-source
  pr_branch_expect fix-login source '' feat/fix-login-source
}
case_pr_body_template() {
  pr_format_libraries
  pr-template-body 'Checks PR titles.' 245 > "$CASE_DIR/body"
  ( pr_body_check "$CASE_DIR/body" )
  # The repository's own template passes once the issue number is filled in.
  sed 's/^Closes #$/Closes #245/' "$ROOT/.github/PULL_REQUEST_TEMPLATE.md" > "$CASE_DIR/template"
  ( pr_body_check "$CASE_DIR/template" )
  local heading
  for heading in Summary Verification Checklist; do
    grep -v "^## $heading\$" "$CASE_DIR/body" > "$CASE_DIR/missing"
    if ( pr_body_check "$CASE_DIR/missing" ) 2> "$CASE_DIR/body.err"; then printf 'accepted body without %s\n' "$heading"; return 1; fi
    grep -F "## $heading" "$CASE_DIR/body.err"
  done
  grep -v '^Closes #' "$CASE_DIR/body" > "$CASE_DIR/missing"
  if ( pr_body_check "$CASE_DIR/missing" ) 2> "$CASE_DIR/body.err"; then return 1; fi
  grep -F 'Closes #<n>' "$CASE_DIR/body.err"
  printf 'Adds the thing.\n\nCloses #41\n' > "$CASE_DIR/missing"
  if ( pr_body_check "$CASE_DIR/missing" ) 2> "$CASE_DIR/body.err"; then return 1; fi
  grep -F 'PULL_REQUEST_TEMPLATE.md' "$CASE_DIR/body.err"
}
pr_format_setup() {
  repo pr-format remote
  PR_WT="$DV_WORK/pr-format"
  PR_STATE="$DV_STATE/LN-512"
  git -C "$REPO" worktree add -qb fix/512-progress-card "$PR_WT"
  git -C "$PR_WT" commit --allow-empty -qm 'LN-512: keep the progress card'
  mkdir "$PR_STATE"
  jq -n --arg repo "$REPO" --arg wt "$PR_WT" \
    '{issue:"LN-512",repo:$repo,worktree:$wt,branch:"fix/512-progress-card",base:"main",slug:"fix-progress-card",status:"running"}' > "$PR_STATE/meta"
  printf 'Keeps the progress card.\n' > "$PR_STATE/report.md"
  : > "$GH_STUB_DIR/calls"
}
pr_format_refused() {
  local remote
  remote=$(git -C "$CASE_DIR/remote.git" rev-parse -q --verify refs/heads/fix/512-progress-card || true)
  cp "$GH_STUB_DIR/calls" "$CASE_DIR/calls-before"
  if dv pr LN-512 > "$CASE_DIR/pr.out" 2>&1; then cat "$CASE_DIR/pr.out"; return 1; fi
  cat "$CASE_DIR/pr.out"
  grep -F -- "$1" "$CASE_DIR/pr.out"
  # Refused before push: no branch update, PR creation, edit or waiter.
  test "$(git -C "$CASE_DIR/remote.git" rev-parse -q --verify refs/heads/fix/512-progress-card || true)" = "$remote"
  cmp "$CASE_DIR/calls-before" "$GH_STUB_DIR/calls"
  test ! -d "$PR_STATE/.operation"
}
case_pr_format_delivery() {
  pr_format_setup
  pr_format_refused 'commit subject'
  test ! -f "$PR_STATE/pr.json"
  # The worker rewords its unpushed commit itself.
  git -C "$PR_WT" commit --amend --allow-empty -qm 'fix(tui): keep the progress card after restart'
  pr_format_refused 'pr.md'
  pr-template-body 'Keeps the progress card after a restart.' 512 | grep -v '^## Verification$' > "$PR_STATE/pr.md"
  pr_format_refused '## Verification'
  pr-template-body 'Keeps the progress card after a restart.' 512 | grep -v '^Closes #' > "$PR_STATE/pr.md"
  pr_format_refused 'Closes #<n>'
  test ! -f "$PR_STATE/pr.json"
  pr-template-body 'Keeps the progress card after a restart.' 512 > "$PR_STATE/pr.md"
  dv pr LN-512
  wait_pr_ready LN-512
  printf 'fix(tui): keep the progress card after restart\n' > "$CASE_DIR/expected-title"
  cmp "$CASE_DIR/expected-title" "$GH_STUB_DIR/live-title"
  cmp "$PR_STATE/pr.md" "$GH_STUB_DIR/live-body"
  grep -F -- '--head fix/512-progress-card' "$GH_STUB_DIR/calls"
  git -C "$CASE_DIR/remote.git" show-ref --verify refs/heads/fix/512-progress-card
  # Later heads keep the format; the published title stays until the worker fixes it.
  git -C "$PR_WT" commit --allow-empty -qm 'LN-512: address review'
  pr_format_refused 'issue key'
  cmp "$CASE_DIR/expected-title" "$GH_STUB_DIR/live-title"
  git -C "$PR_WT" commit --amend --allow-empty -qm 'fix(tui): keep the card when the session restarts'
  printf 'Updated without the template.\n' > "$PR_STATE/pr.md"
  pr_format_refused '## Summary'
  pr-template-body 'Keeps the card when the session restarts.' 512 > "$PR_STATE/pr.md"
  rm -f "$PR_STATE/pr-ready.json"
  dv pr LN-512
  wait_pr_ready LN-512
  grep -Fx 'fix(tui): keep the card when the session restarts' "$GH_STUB_DIR/live-title"
  cmp "$PR_STATE/pr.md" "$GH_STUB_DIR/live-body"
}
case_pr_format_legacy() {
  # Jobs started before the format keep their agent branch, title and body.
  pr_body_setup
  printf 'Previously prepared public prose.\n\nCloses #56\n' > "$PR_STATE/pr.md"
  pr_body_publish
  grep -Fx 'DF-56: publish a useful PR subject' "$GH_STUB_DIR/live-title"
  cmp "$PR_STATE/pr.md" "$GH_STUB_DIR/live-body"
  git -C "$PR_WT" commit --allow-empty -qm 'DF-56: address review'
  rm -f "$PR_STATE/pr-ready.json"
  dv pr PUB-1
  wait_pr_ready PUB-1
  grep -Fx 'DF-56: address review' "$GH_STUB_DIR/live-title"
}
case_pr_format_start() {
  needs_tmux; repo pr-format-start remote
  dv start "$REPO" LN-512 fix-progress-card --brief "$CASE_DIR/brief" --mode exec
  wait_done LN-512
  jq -e '.branch=="fix/512-progress-card" and .slug=="fix-progress-card"' "$DV_STATE/LN-512/meta"
  git -C "$CASE_DIR/remote.git" show-ref --verify refs/heads/fix/512-progress-card
  git -C "$(jq -r .worktree "$DV_STATE/LN-512/meta")" log -1 --format=%s > "$CASE_DIR/expected-title"
  cmp "$CASE_DIR/expected-title" "$GH_STUB_DIR/live-title"
  ( pr_format_libraries; pr_title_check "$(cat "$GH_STUB_DIR/live-title")" )
  grep -Fx 'Closes #512' "$GH_STUB_DIR/live-body"
  grep -Fx '## Summary' "$GH_STUB_DIR/live-body"
  grep -Fx '## Verification' "$GH_STUB_DIR/live-body"
  grep -Fx '## Checklist' "$GH_STUB_DIR/live-body"
  # A slug that only repeats the key never produces the key twice.
  dv start "$REPO" LN-513 ln-513 --brief "$CASE_DIR/brief" --mode exec
  wait_done LN-513
  jq -e '.branch=="feat/513"' "$DV_STATE/LN-513/meta"
  # Slugs that cannot form a branch are refused before any state exists.
  local slug
  for slug in bad_slug -leading 'fix/x' ''; do
    if dv start "$REPO" LN-514 "$slug" --brief "$CASE_DIR/brief" --mode exec 2> "$CASE_DIR/start.err"; then return 1; fi
    grep -F 'invalid slug' "$CASE_DIR/start.err"
    test ! -e "$DV_STATE/LN-514"
  done
  if git -C "$REPO" for-each-ref --format='%(refname:short)' refs/heads | grep -E '^(codex|claude|devin)/'; then return 1; fi
}
case_pr_format_instructions() {
  local template="$ROOT/.github/PULL_REQUEST_TEMPLATE.md"
  grep -Fx '## Summary' "$template"
  grep -Fx 'Closes #' "$template"
  grep -Fx '## Verification' "$template"
  grep -Fx '## Checklist' "$template"
  # The worker brief and the devflow skill state the format once each.
  test "$(grep -c 'type(scope): subject' "$ROOT/templates/rules.md")" = 1
  grep -F 'PULL_REQUEST_TEMPLATE.md' "$ROOT/templates/rules.md"
  grep -F '<type>/<번호>-<slug>' "$ROOT/templates/rules.md"
  test "$(grep -c 'type(scope): subject' "$ROOT/skills/devflow/SKILL.md")" = 1
  # Preserve the existing probe and final README assertion in this lint change.
  # shellcheck disable=SC2251
  ! grep -F '`<ISSUE>: ...`' "$ROOT/templates/rules.md" "$ROOT/AGENTS.md"
  grep -F '<type>/<n>-<slug>' "$ROOT/README.md"
}
