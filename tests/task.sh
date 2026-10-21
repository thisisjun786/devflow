#!/usr/bin/env bash
# Non-code jobs use disposable directories and agents; no Git or provider calls.
# shellcheck disable=SC2153
task_setup() {
  mkdir -p "$CASE_DIR/Desk project" "$CASE_DIR/destination"
  printf 'original input\n' > "$CASE_DIR/Desk project/input.txt"
  printf 'Destination: %s/destination\n\nProduce a summary in out/. Done condition: summary cites input.txt.\n' "$CASE_DIR" > "$CASE_DIR/task-brief"
  export DV_AGENT_CMD_codex="$ROOT/tests/fixtures/task-agent"
  export DV_AGENT_CMD_claude="$ROOT/tests/fixtures/task-agent"
}
task_start() {
  dv submit --kind task "$CASE_DIR/Desk project" TK-1 summary --brief "$CASE_DIR/task-brief" "$@"
}
case_task_start_done() {
  needs_tmux; task_setup; task_start; wait_done TK-1
  local wt
  wt=$(jq -r .worktree "$DV_STATE/TK-1/meta")
  test -f "$wt/out/summary.txt"
  test ! -e "$wt/.git"
  test ! -e "$CASE_DIR/Desk project/out"
  test "$(cat "$CASE_DIR/Desk project/input.txt")" = 'original input'
  jq -e '.kind=="task" and .mode=="exec" and .status=="done" and .branch==""' "$DV_STATE/TK-1/meta"
  jq -e '.files==2 and (.head|startswith("task-"))' "$DV_STATE/TK-1/done.json"
  dv status TK-1 --json | jq -e '.[0] | .kind=="task" and .done_head==.head and .elapsed>=0'
  jq -e '.kind=="done" and .issue=="TK-1"' "$DV_HOME/kick.q"
  if task_start; then return 1; fi
  for command in pr pr-wait review polish; do
    if dv "$command" TK-1; then return 1; fi
  done
  test ! -f "$GH_STUB_DIR/calls"
}
case_task_land() {
  needs_tmux; task_setup; task_start; wait_done TK-1
  local head landed wt
  head=$(jq -r .head "$DV_STATE/TK-1/done.json")
  wt=$(jq -r .worktree "$DV_STATE/TK-1/meta")
  mkdir "$CASE_DIR/destination/TK-1"
  printf 'keep\n' > "$CASE_DIR/destination/TK-1/summary.txt"
  ln -s "$CASE_DIR/Desk project" "$CASE_DIR/destination/TK-1-v2"
  if dv land TK-1; then return 1; fi
  if dv land TK-1 --checked stale; then return 1; fi
  dv land TK-1 --checked "$head"
  landed=$(jq -r .landed_path "$DV_STATE/TK-1/meta")
  test "$landed" = "$CASE_DIR/destination/TK-1-v3"
  cmp "$wt/out/summary.txt" "$landed/summary.txt"
  cmp "$wt/out/nested/source.txt" "$landed/nested/source.txt"
  test "$(cat "$CASE_DIR/destination/TK-1/summary.txt")" = keep
  test ! -e "$CASE_DIR/Desk project/summary.txt"
  jq -e '.status=="landed" and .landed_at>0' "$DV_STATE/TK-1/meta"
  dv land TK-1 --checked "$head"
  test ! -e "$CASE_DIR/destination/TK-1-v4"
  dv clean TK-1
  test -f "$wt/out/summary.txt"
  test -s "$DV_STATE/TK-1/report.md"
  test ! -f "$GH_STUB_DIR/calls"
}
case_task_guards() {
  needs_tmux; task_setup; task_start; wait_done TK-1
  local wt head
  wt=$(jq -r .worktree "$DV_STATE/TK-1/meta")
  head=$(jq -r .head "$DV_STATE/TK-1/done.json")
  printf 'unreviewed\n' >> "$wt/out/summary.txt"
  if dv land TK-1 --checked "$head"; then return 1; fi
  dv 'done' TK-1
  head=$(jq -r .head "$DV_STATE/TK-1/done.json")
  printf 'changed sources\n' >> "$DV_STATE/TK-1/report.md"
  if dv land TK-1 --checked "$head"; then return 1; fi
  ln -s "$CASE_DIR/Desk project/input.txt" "$wt/out/link"
  if dv 'done' TK-1; then return 1; fi
  test ! -e "$CASE_DIR/destination/TK-1"
  rm "$wt/out/link" "$wt/out/summary.txt" "$wt/out/nested/source.txt"
  if dv 'done' TK-1; then return 1; fi
  printf 'result\n' > "$wt/out/result"
  rm "$DV_STATE/TK-1/report.md"
  if dv 'done' TK-1; then return 1; fi
}
case_task_revive() {
  needs_tmux; task_setup
  export DV_TASK_TEST_HOLD=1
  task_start
  wait_file "$DV_STATE/TK-1/held.pid"
  local wt
  wt=$(jq -r .worktree "$DV_STATE/TK-1/meta")
  dv status TK-1 --json | jq -e '.[0] | .alive and .status=="running"'
  printf 'partial\n' > "$wt/partial"
  tmux -L "$DV_TMUX_SOCKET" kill-session -t '=dv-TK-1'
  dv status TK-1 --json | jq -e '.[0] | .alive==false and .status=="running"'
  export DV_TASK_TEST_HOLD=0
  dv send TK-1 'Continue the summary with sources'
  wait_done TK-1
  test "$(cat "$wt/partial")" = partial
  test -s "$DV_STATE/TK-1/revive/done"
  jq -e --arg wt "$wt" '.worktree==$wt and .kind=="task" and .status=="done"' "$DV_STATE/TK-1/meta"
  if dv send TK-1 'Revive again'; then return 1; fi
}
case_task_claude() {
  needs_tmux; task_setup; task_start --agent claude; wait_done TK-1
  jq -e '.agent=="claude" and .mode=="goal" and .status=="done"' "$DV_STATE/TK-1/meta"
}
case_task_invalid() {
  task_setup
  printf 'No destination\n' > "$CASE_DIR/task-brief"
  if task_start; then return 1; fi
  test ! -e "$DV_STATE/TK-1"
  printf 'Destination: relative/path\n' > "$CASE_DIR/task-brief"
  if task_start; then return 1; fi
  test ! -e "$DV_STATE/TK-1"
}
case_task_native() {
  task_setup; herdr_setup
  export DV_CODEX_BIN="$ROOT/tests/fixtures/task-agent" DV_CLAUDE_BIN="$ROOT/tests/fixtures/task-agent"
  export DV_AGENT_CMD_claude='' DV_TRUSTED_REPOS="$CASE_DIR/Desk project"
  task_start; task_exec_wait TK-1
  jq -e '.args | index("exec")!=null and index("--skip-git-repo-check")!=null' "$DV_STATE/TK-1/task-agent.json"
  jq -e '.backend=="exec" and .exec_status=="done"' "$DV_STATE/TK-1/meta"
  test ! -e "$CASE_DIR/herdr/calls"
  dv send TK-1 'Verify the sources once more'
  task_exec_wait TK-1
  jq -e '.args | index("resume")!=null and index("--skip-git-repo-check")!=null' "$DV_STATE/TK-1/task-agent.json"
  dv land TK-1 --checked "$(jq -r .head "$DV_STATE/TK-1/done.json")"
  dv clean TK-1
  dv submit --kind task "$CASE_DIR/Desk project" TK-2 summary --brief "$CASE_DIR/task-brief" --agent claude
  wait_native TK-2
  jq -e '.args | index("--dangerously-skip-permissions")!=null' "$DV_STATE/TK-2/task-agent.json"
  test ! -f "$GH_STUB_DIR/calls"
}
task_exec_wait() {
  wait_file "$DV_STATE/$1/agent.exit"
  local i
  for i in {1..100}; do
    if dv status "$1" --json | jq -e '.[0].alive==false' >/dev/null; then return; fi
    sleep 0.1
  done
  return 1
}
case_task_exec_stall() {
  task_setup
  export DV_AGENT_CMD_codex='' DV_CODEX_BIN="$ROOT/tests/fixtures/task-agent"
  export DV_TRUSTED_REPOS="$CASE_DIR/Desk project" DV_STALL_AFTER=2 DV_TASK_TEST_HOLD=1
  task_start; task_exec_wait TK-1
  jq -e '.status=="blocked" and .exec_status=="blocked"' "$DV_STATE/TK-1/meta"
  test -f "$DV_STATE/TK-1/exec-retry.used"
  test "$(find "$DV_STATE/TK-1/exec" -name exit | wc -l | tr -d ' ')" = 2
  jq -se 'map(.kind)==["failed","blocked"]' "$DV_STATE/TK-1/events.log"
  test ! -f "$GH_STUB_DIR/calls"
}
case_task_capacity() {
  needs_tmux; task_setup
  export DV_MAX_JOBS=1 DV_TASK_TEST_HOLD=1
  task_start; wait_file "$DV_STATE/TK-1/held.pid"
  if dv submit --kind task "$CASE_DIR/Desk project" TK-2 summary --brief "$CASE_DIR/task-brief"; then return 1; fi
  test ! -e "$DV_STATE/TK-2"
  test ! -d "$DV_STATE/.admission-lock"
}
case_task_missing_output() {
  needs_tmux; task_setup
  export DV_AGENT_CMD_codex=true
  task_start; wait_done TK-1
  test ! -f "$DV_STATE/TK-1/done.json"
  test "$(cat "$DV_STATE/TK-1/agent.exit")" = 1
  jq -se 'any(.[]; .kind=="failed")' "$DV_STATE/TK-1/events.log"
  dv send TK-1 'Produce the missing deliverable'
  wait_done TK-1
  test -d "$DV_STATE/TK-1/revive/blocked"
  jq -se 'any(.[]; .kind=="blocked")' "$DV_STATE/TK-1/events.log"
}
case_task_watcher() {
  needs_tmux; task_setup; task_start; wait_done TK-1
  watch_fixture
  # A non-Git task uses the ordinary worker even with repo managers enabled.
  mkdir -p "$DV_HOME/managers"
  dv-watch & watcher=$!
  wait_seen 1
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  test "$(find "$DV_HOME/workers" -name '*.finished' | wc -l | tr -d ' ')" = 1
  grep -l '"issue":"TK-1"' "$DV_HOME"/workers/*.prompt.md
  grep -l 'meta.kind가 task' "$DV_HOME"/workers/*.prompt.md
  test ! -e "$DV_STATE/TK-1/pr.json"
  test ! -f "$GH_STUB_DIR/calls"
}
case_task_land_workspace() {
  needs_tmux; task_setup
  # The brief may intentionally deliver new results into its input workspace.
  # A destination alias must still preserve every existing input and bundle.
  ln -s "$CASE_DIR/Desk project" "$CASE_DIR/destination-alias"
  printf 'Destination: %s/destination-alias\n\nProduce a summary.\n' "$CASE_DIR" > "$CASE_DIR/task-brief"
  mkdir "$CASE_DIR/Desk project/TK-1"
  printf 'older result\n' > "$CASE_DIR/Desk project/TK-1/summary.txt"
  task_start; wait_done TK-1
  dv land TK-1 --checked "$(jq -r .head "$DV_STATE/TK-1/done.json")"
  test "$(cat "$CASE_DIR/Desk project/input.txt")" = 'original input'
  test "$(cat "$CASE_DIR/Desk project/TK-1/summary.txt")" = 'older result'
  test "$(cat "$CASE_DIR/Desk project/TK-1-v2/summary.txt")" = 'Summary citing input.txt'
}
