#!/usr/bin/env bash
# GitHub land integration cases use a disposable worktree and gh stub, no agent.
land_setup() {
  unset DV_LAND_METHOD
  repo land remote
  LAND_WT="$DV_WORK/land"
  git -C "$REPO" worktree add -qb codex/land "$LAND_WT"
  mkdir -p "$DV_STATE/LAND-1"
  jq -n --arg repo "$REPO" --arg wt "$LAND_WT" \
    '{repo:$repo,worktree:$wt,branch:"codex/land",base:"main",status:"ready"}' > "$DV_STATE/LAND-1/meta"
  printf '{"url":"https://github.com/test/repo/pull/1"}\n' > "$DV_STATE/LAND-1/pr.json"
  jq -n --argjson squash "$1" --argjson merge "$2" --argjson rebase "$3" \
    '{squashMergeAllowed:$squash,mergeCommitAllowed:$merge,rebaseMergeAllowed:$rebase}' > "$GH_STUB_DIR/repo-methods"
}
land_config() {
  printf 'DV_LAND_METHOD=%s\n' "$1" > "$LAND_WT/.devflow"
  git -C "$LAND_WT" add .devflow
  git -C "$LAND_WT" commit -qm 'land configuration'
}
land_success() {
  local head pr
  head=$(git -C "$LAND_WT" rev-parse HEAD)
  pr=$(jq -er .url "$DV_STATE/LAND-1/pr.json")
  dv land LAND-1
  if ! grep -Fx -- "pr merge $pr --$1 --match-head-commit $head" "$GH_STUB_DIR/calls"; then
    printf 'Expected --%s; gh calls:\n' "$1"
    cat "$GH_STUB_DIR/calls"; return 1
  fi
  test "$(grep -c '^api repos/' "$GH_STUB_DIR/calls")" = 1
  grep -Fx "pr view $pr --json state,headRefOid" "$GH_STUB_DIR/calls"
  jq -e '.status=="landed"' "$DV_STATE/LAND-1/meta"
  test ! -d "$LAND_WT"
}
land_failure() {
  if dv land LAND-1 > "$CASE_DIR/land-output" 2>&1; then
    printf 'Expected land failure; gh calls:\n'
    cat "$CASE_DIR/land-output" "$GH_STUB_DIR/calls"; return 1
  fi
  cat "$CASE_DIR/land-output"
  grep -F -- "$1" "$CASE_DIR/land-output"
  test -d "$LAND_WT"
  jq -e '.status=="ready"' "$DV_STATE/LAND-1/meta"
}
land_not_merged() {
  test ! -f "$GH_STUB_DIR/merged"
  if grep '^pr merge ' "$GH_STUB_DIR/calls"; then return 1; fi
}
case_land_squash_only() { land_setup true false false; land_success squash; }
case_land_merge_only() { land_setup false true false; land_success merge; }
case_land_rebase_only() { land_setup false false true; land_success rebase; }
case_land_prefer_squash() { land_setup true true true; land_success squash; }
case_land_prefer_merge() { land_setup false true true; land_success merge; }
case_land_override_env() {
  land_setup true true true
  export DV_LAND_METHOD=rebase
  land_success rebase
}
case_land_override_repo() {
  land_setup true true true
  land_config merge
  land_success merge
}
case_land_config_stdout() {
  land_setup true true true
  land_config merge
  printf "echo 'loading land config'\n" >> "$LAND_WT/.devflow"
  git -C "$LAND_WT" commit -qam 'configuration with stdout'
  land_success merge 2> "$CASE_DIR/land-stderr"
  grep -Fx 'loading land config' "$CASE_DIR/land-stderr"
}
case_land_policy_gh_repo() {
  land_setup true false false
  export GH_REPO=other/repo
  land_success squash
  grep -Fx 'api repos/test/repo' "$GH_STUB_DIR/calls"
}
case_land_policy_pr_url() {
  land_setup false false true
  export GH_REPO=other/repo GH_STUB_LAND_REPO=team/target
  printf '{"url":"https://github.com/team/target/pull/42"}\n' > "$DV_STATE/LAND-1/pr.json"
  land_success rebase
  grep -Fx 'api repos/team/target' "$GH_STUB_DIR/calls"
}
case_land_override_precedence() {
  land_setup true true true
  land_config merge
  export DV_LAND_METHOD=squash
  land_success squash
}
case_land_no_methods() {
  land_setup false false false
  land_failure 'repository allows no PR merge method'
  land_not_merged
}
case_land_invalid_method() {
  land_setup true true true
  export DV_LAND_METHOD=invalid
  land_failure 'DV_LAND_METHOD must be squash, merge or rebase'
  land_not_merged
}
case_land_disallowed_method() {
  land_setup false true false
  export DV_LAND_METHOD=squash
  land_failure 'repository does not allow squash'
  land_not_merged
}
case_land_repo_failure() {
  land_setup true true true
  touch "$GH_STUB_DIR/repo-fail"
  land_failure 'could not read repository merge methods'
  land_not_merged
}
case_land_config_failure() {
  land_setup true true true
  land_config merge
  printf 'false\n' >> "$LAND_WT/.devflow"
  git -C "$LAND_WT" commit -qam 'failing configuration'
  land_failure 'could not load repository land configuration'
  land_not_merged
}
case_land_head_mismatch() {
  land_setup false true false
  touch "$GH_STUB_DIR/head-mismatch"
  land_failure 'PR head/base/state mismatch'
  land_not_merged
}
case_land_unconfirmed() {
  land_setup false true false
  touch "$GH_STUB_DIR/merge-unconfirmed"
  land_failure 'merge not confirmed; worktree retained'
  test -f "$GH_STUB_DIR/merged"
}
