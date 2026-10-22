#!/usr/bin/env bash
# Merge discovery is driven by GitHub data, not worker lifecycle records.
qa_merge_fixture() {
  qa_fixture
  bidding_functions
  # shellcheck source=lib/manager.sh
  source "$ROOT/lib/manager.sh"
  # shellcheck source=lib/qa.sh
  source "$ROOT/lib/qa.sh"
  local dir
  dir=$(manager_dir "$REPO")
  mkdir -p "$dir"
  jq -n --arg repo "$REPO" --arg identity "$(manager_identity "$REPO")" \
    '{repo:$repo,identity:$identity,enabled:true,base:"main"}' > "$dir/meta.json"
  export DV_QA_COALESCE=600 DV_MANAGER_HOST="$DV_HOST"
  rm -r "$DV_STATE/Q-1"
  jq --arg head "$(git -C "$REPO" rev-parse HEAD)" \
    '.merge_commit_sha=$head | .merged_at="2026-10-22T00:00:00Z"' "$GH_STUB_DIR/qa-pr" > "$GH_STUB_DIR/qa-merges"
}
case_qa_external_merge() {
  qa_merge_fixture
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  local request=''
  for _ in {1..50}; do
    for request in "$DV_HOME"/qa/*/pending.json; do [ ! -f "$request" ] || break 2; done
    sleep 0.1
  done
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  if [ ! -f "$request" ]; then
    printf 'No QA queued for an external base merge in an enabled repository\n' >&2
    return 1
  fi
  jq -e --arg head "$(git -C "$REPO" rev-parse HEAD)" '.head==$head and [.prs[].number]==[7]' "$request"
}
