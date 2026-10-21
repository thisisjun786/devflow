#!/usr/bin/env bash
# Public delivery regressions: disposable repositories, fake gh/SSH, no agents.
# shellcheck disable=SC2016
pr_body_setup() {
  repo public-body remote
  PR_WT="$DV_WORK/public-body"
  PR_STATE="$DV_STATE/PUB-1"
  git -C "$REPO" worktree add -qb codex/public-body "$PR_WT"
  git -C "$PR_WT" commit --allow-empty -qm 'DF-56: publish a useful PR subject'
  mkdir "$PR_STATE"
  jq -n --arg repo "$REPO" --arg wt "$PR_WT" \
    '{repo:$repo,worktree:$wt,branch:"codex/public-body",base:"main",slug:"uninformative",status:"running"}' > "$PR_STATE/meta"
  printf 'Private instructions: hx-linux; read %s/brief.md.\n' "$PR_STATE" > "$PR_STATE/brief.md"
  printf '# Changes\n\nPublishes a safe report summary.\n\n## Details\n\nInternal report tail.\n' > "$PR_STATE/report.md"
}
pr_body_publish() { dv pr PUB-1; wait_pr_ready PUB-1; }
case_pr_fallback_body() {
  pr_body_setup
  pr_body_publish
  if grep -E 'hx-linux|Private instructions|brief\.md' "$GH_STUB_DIR/live-body"; then return 1; fi
  grep -Fx 'Publishes a safe report summary.' "$GH_STUB_DIR/live-body"
}
case_pr_fallback_summary() {
  pr_body_setup
  {
    printf '# Changes\n\nPublishes a safe report summary.\n'
    printf 'State: `%s/report.md`\n' "$PR_STATE"
    printf 'Other issue: %s/OTHER/meta\n' "$DV_STATE"
    printf 'Saved in $DV_STATE/PUB-1/report.md and $S/report.md\n'
    printf 'Archive: ~/.local/state/devflow/PUB-1/report.md\n'
    printf '\n## Details\n\nInternal report tail.\n'
  } > "$PR_STATE/report.md"
  pr_body_publish
  grep -Fx 'Publishes a safe report summary.' "$GH_STUB_DIR/live-body"
  if grep -F -e "$DV_STATE" -e '$DV_STATE' -e '$S/' -e '.local/state/devflow' -e 'Internal report tail.' "$GH_STUB_DIR/live-body"; then return 1; fi
  test "$(wc -c < "$GH_STUB_DIR/live-body")" -lt 1200
}
case_pr_fallback_private_paths() {
  pr_body_setup
  {
    printf '# Changes\n\nPublishes a safe report summary.\n'
    printf 'Worktree: `%s`\nHome: "%s"\nRepository: %s\n' "$PR_WT" "$HOME" "$REPO"
    printf 'Saved in %s/PUB-1/report.md\n' "$DV_STATE"
    cat <<'PATHS'
Private absolute: /home/reporter/project/report.md
Private home: ~/project/report.md
Private named home: ~reporter/project/report.md
Private link: [report](/opt/project/report.md)
Private label:path=/var/private/report.md
Private quoted:'/srv/private/report.md'
Private root: /
Private variable: $HOME
Private variable: ${HOME}/project
Private variable: $WT/report.md
Private variable: ${WT}
Private variable: $DV_STATE/report.md
Private variable: ${DV_STATE}
Private variable: $REPO/report.md
Private variable: $S/report.md
PATHS
  } > "$PR_STATE/report.md"
  pr_body_publish
  printf 'Publishes a safe report summary.\n' > "$CASE_DIR/expected-summary"
  if ! cmp "$CASE_DIR/expected-summary" "$GH_STUB_DIR/live-body"; then
    cat "$GH_STUB_DIR/live-body"; return 1
  fi
}
case_pr_fallback_private_hosts() {
  pr_body_setup
  # Configuration values need not be exported to child processes.
  cat > "$DV_CONFIG" <<'CONFIG'
DV_HOSTS='build.internal
worker-02'
DV_PULL_HOSTS='pull.internal pull-02'
DV_HOST=local.internal
export -n DV_HOSTS DV_PULL_HOSTS
CONFIG
  cat > "$PR_STATE/report.md" <<'REPORT'
# Changes

Publishes a safe report summary.
Built on build.internal.
Run on worker-02.
Pulled from pull.internal.
Fallback: pull-02.
Local runtime is local.internal.
REPORT
  pr_body_publish
  printf 'Publishes a safe report summary.\n' > "$CASE_DIR/expected-summary"
  if ! cmp "$CASE_DIR/expected-summary" "$GH_STUB_DIR/live-body"; then
    cat "$GH_STUB_DIR/live-body"; return 1
  fi
}
case_pr_fallback_public_tokens() {
  pr_body_setup
  printf "DV_HOSTS=''\nDV_PULL_HOSTS=''\nDV_HOST=''\n" > "$DV_CONFIG"
  cat > "$PR_STATE/report.md" <<'REPORT'
Updates src/lib.sh and tests/run.sh.
See [docs](https://example.test/guide) and https://example.test/a/b.
Keep `a/b`, `$HOMEWORK`, and foo~bar unchanged.
REPORT
  pr_body_publish
  cmp "$PR_STATE/report.md" "$GH_STUB_DIR/live-body"
}
case_pr_fallback_missing() {
  pr_body_setup
  rm "$PR_STATE/report.md"
  pr_body_publish
  test -s "$GH_STUB_DIR/live-body"
  if grep -F -e hx-linux -e "$DV_STATE" "$GH_STUB_DIR/live-body"; then return 1; fi
}
case_pr_fallback_bounded() {
  pr_body_setup
  awk 'BEGIN { for (i=0;i<1500;i++) printf "x"; print "\n" }' > "$PR_STATE/report.md"
  pr_body_publish
  test "$(wc -c < "$GH_STUB_DIR/live-body")" -eq 1000
  rm "$PR_STATE/pr.json" "$PR_STATE/pr-body.md"
  awk 'BEGIN { for (i=1;i<=20;i++) print "Summary line " i }' > "$PR_STATE/report.md"
  pr_body_publish
  test "$(wc -l < "$GH_STUB_DIR/live-body")" -eq 10
}
case_pr_fallback_private_only() {
  pr_body_setup
  printf '# Report\n\nSee %s/report.md\nSee ${DV_STATE}/PUB-1/report.md\nSee ${S}/report.md\n' "$PR_STATE" > "$PR_STATE/report.md"
  pr_body_publish
  grep -Fx 'Implementation report is not available.' "$GH_STUB_DIR/live-body"
}
case_pr_head_title() {
  pr_body_setup
  pr_body_publish
  git -C "$PR_WT" log -1 --format=%s > "$CASE_DIR/expected-title"
  cmp "$CASE_DIR/expected-title" "$GH_STUB_DIR/live-title"
}
case_pr_prepared_body() {
  pr_body_setup
  printf 'Public prose with `literal code`.\n\nCloses #56' > "$PR_STATE/pr.md"
  cp "$PR_STATE/pr.md" "$CASE_DIR/prepared"
  DV_POLISH=1 pr_body_publish
  cmp "$CASE_DIR/prepared" "$GH_STUB_DIR/live-body"
  cmp "$CASE_DIR/prepared" "$PR_STATE/pr.md"
  dv polish PUB-1
  test ! -e "$CASE_DIR/polish-prompt"
}
case_pr_legacy_body() {
  pr_body_setup
  printf 'Previously prepared public prose.\n\nCloses #56' > "$PR_STATE/pr-body.md"
  cp "$PR_STATE/pr-body.md" "$CASE_DIR/prepared"
  DV_POLISH=1 pr_body_publish
  cmp "$CASE_DIR/prepared" "$GH_STUB_DIR/live-body"
  cmp "$CASE_DIR/prepared" "$PR_STATE/pr-body.md"
  dv polish PUB-1
  test ! -e "$CASE_DIR/polish-prompt"
}
case_pr_patch_title() {
  pr_body_setup
  pr_body_publish
  printf 'Human body edit.\n' > "$GH_STUB_DIR/live-body"
  cp "$GH_STUB_DIR/live-body" "$CASE_DIR/human-body"
  git -C "$PR_WT" commit --allow-empty -qm 'DF-56: retain literal $(text) and `code`'
  printf '{"url":"https://github.com/another-owner/another.repo/pull/37"}\n' > "$PR_STATE/pr.json"
  export GH_STUB_PR_ENDPOINT=repos/another-owner/another.repo/pulls/37 GH_REPO=wrong/repo
  pr_body_publish
  git -C "$PR_WT" log -1 --format=%s > "$CASE_DIR/expected-title"
  cmp "$CASE_DIR/expected-title" "$GH_STUB_DIR/live-title"
  cmp "$CASE_DIR/human-body" "$GH_STUB_DIR/live-body"
  grep -F 'api -X PATCH repos/another-owner/another.repo/pulls/37' "$GH_STUB_DIR/calls"
}
case_pr_patch_body() {
  pr_body_setup
  printf 'First body.\n' > "$PR_STATE/pr.md"
  pr_body_publish
  touch "$GH_STUB_DIR/projectcards-error"
  printf 'Updated body.\n' > "$PR_STATE/pr.md"
  pr_body_publish
  cmp "$PR_STATE/pr.md" "$GH_STUB_DIR/live-body"
  grep -F 'api -X PATCH repos/test/repo/pulls/1' "$GH_STUB_DIR/calls"
  if grep '^pr edit ' "$GH_STUB_DIR/calls"; then return 1; fi
}
case_polish_unreachable() {
  polish_setup
  local client="$CASE_DIR/client" utility
  mkdir "$client"
  for utility in bash dirname readlink jq mkdir rm cat cp awk grep cmp mv date sleep env; do
    ln -s "$(command -v "$utility")" "$client/$utility"
  done
  ln -s "$ROOT/tests/fixtures/gh" "$client/gh"
  ln -s "$ROOT/tests/fixtures/ssh" "$client/ssh"
  PATH="$client" DV_POLISH_CMD='' SSH_POLISH_UNREACHABLE="${SSH_POLISH_UNREACHABLE:-1}" "$ROOT/bin/dv" polish POL-1
  cmp "$CASE_DIR/original" "$DV_STATE/POL-1/pr-body.md"
  test ! -f "$GH_STUB_DIR/edited-body"
  grep -F 'polish skipped: remote host unavailable' "$DV_STATE/POL-1/polish.log"
  if grep -E 'agy|It is worth noting' "$CASE_DIR/polish-ssh-calls"; then return 1; fi
  if grep -F 'polish failed' "$DV_STATE/POL-1/polish.log"; then return 1; fi
}
case_polish_unreachable_timeout() {
  export SSH_POLISH_UNREACHABLE=hang DV_POLISH_TIMEOUT=1
  case_polish_unreachable
}
