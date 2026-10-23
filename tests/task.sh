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
  test "$landed" = "$(cd "$CASE_DIR/destination/TK-1-v3" && pwd -P)"
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
  export DV_CODEX_MODE=exec
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
  exec_wait "$1"
}
case_task_exec_launch_race() {
  task_setup
  export DV_CODEX_MODE=exec DV_AGENT_CMD_codex=''
  export DV_CODEX_BIN="$ROOT/tests/fixtures/task-agent" DV_TRUSTED_REPOS="$CASE_DIR/Desk project"
  task_start; task_exec_wait TK-1
  exec_launch_race TK-1
  jq -e '.status=="done" and .exec_status=="done"' "$DV_STATE/TK-1/meta"
  jq -e '.args | index("resume")!=null' "$DV_STATE/TK-1/task-agent.json"
}
case_task_exec_stall() {
  task_setup
  export DV_CODEX_MODE=exec
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
case_task_shellcheck() {
  shellcheck -x "$ROOT/lib/task.sh"
}
case_task_snapshot() {
  task_terminal_setup herdr
  local s="$DV_STATE/TK-1" wt head snapshot next
  wt=$(jq -r .worktree "$s/meta")
  head=$(jq -r .head "$s/done.json")
  snapshot="$s/task-snapshots/$head"
  cmp "$wt/out/summary.txt" "$snapshot/out/summary.txt"
  cmp "$s/report.md" "$snapshot/report.md"
  test ! "$wt/out/summary.txt" -ef "$snapshot/out/summary.txt"
  printf 'late change\n' >> "$wt/out/summary.txt"
  test "$(cat "$snapshot/out/summary.txt")" = 'Summary citing input.txt'
  if dv land TK-1 --checked "$head"; then return 1; fi
  touch "$s/release"; task_terminal_wait herdr
  if dv land TK-1 --checked "$head"; then return 1; fi
  dv 'done' TK-1
  next=$(jq -r .head "$s/done.json")
  test "$next" != "$head"
  test "$(cat "$snapshot/out/summary.txt")" = 'Summary citing input.txt'
  snapshot="$s/task-snapshots/$next"
  mv "$snapshot" "$s/saved-snapshot"
  if dv land TK-1 --checked "$next"; then return 1; fi
  mv "$s/saved-snapshot" "$snapshot"
  cp "$snapshot/out/summary.txt" "$CASE_DIR/snapshot-original"
  printf 'corrupt snapshot\n' > "$snapshot/out/summary.txt"
  if dv land TK-1 --checked "$next"; then return 1; fi
  cp "$CASE_DIR/snapshot-original" "$snapshot/out/summary.txt"
  dv land TK-1 --checked "$next"
  cmp "$snapshot/out/summary.txt" "$CASE_DIR/destination/TK-1/summary.txt"
}
case_task_snapshot_done_race() {
  task_setup; export DV_HERDR=1
  task_start --agent claude; task_terminal_wait herdr
  local s="$DV_STATE/TK-1" head
  head=$(jq -r .head "$s/done.json")
  export DV_TASK_TEST_WT
  DV_TASK_TEST_WT=$(jq -r .worktree "$s/meta")
  cp "$s/done.json" "$CASE_DIR/previous-done"
  printf 'new revision\n' >> "$DV_TASK_TEST_WT/out/summary.txt"
  cat > "$CASE_DIR/copy-race" <<'ENV'
cp() {
  command cp "$@" || return
  if [ "${1:-}" = -R ] && [ "${2:-}" = "$DV_TASK_TEST_WT/out/." ]; then
    printf 'changed during done\n' >> "$DV_TASK_TEST_WT/out/summary.txt"
  fi
}
ENV
  if BASH_ENV="$CASE_DIR/copy-race" dv 'done' TK-1; then
    printf 'BUG: done accepted output changed during its snapshot\n'; return 1
  fi
  cmp "$s/done.json" "$CASE_DIR/previous-done"
  test "$(cat "$s/task-snapshots/$head/out/summary.txt")" = 'Summary citing input.txt'
  test "$(find "$s/task-snapshots" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = 1
  dv 'done' TK-1
  dv land TK-1 --checked "$(jq -r .head "$s/done.json")"
}
case_task_snapshot_land_race() {
  task_setup; export DV_HERDR=1
  task_start --agent claude; task_terminal_wait herdr
  local s="$DV_STATE/TK-1" head
  head=$(jq -r .head "$s/done.json")
  export DV_TASK_TEST_WT
  DV_TASK_TEST_WT=$(jq -r .worktree "$s/meta")
  cat > "$CASE_DIR/copy-race" <<'ENV'
cp() {
  printf 'changed during land\n' > "$DV_TASK_TEST_WT/out/summary.txt"
  command cp "$@"
}
ENV
  if BASH_ENV="$CASE_DIR/copy-race" dv land TK-1 --checked "$head"; then
    printf 'BUG: land accepted output changed during delivery\n'; return 1
  fi
  # Even an interrupted delivery must contain the reviewed snapshot, never
  # bytes from the mutable working output. It must not be marked landed.
  test "$(cat "$CASE_DIR/destination/TK-1/summary.txt")" = 'Summary citing input.txt'
  jq -e '.status=="done" and .landed_path==null' "$s/meta"
  jq -se 'all(.[]; .kind!="landed")' "$s/events.log"
  dv 'done' TK-1
  dv land TK-1 --checked "$(jq -r .head "$s/done.json")"
  test "$(cat "$CASE_DIR/destination/TK-1-v2/summary.txt")" = 'changed during land'
}
task_terminal_setup() {
  if [ "$1" = tmux ]; then needs_tmux; else export DV_HERDR=1; fi
  task_setup
  export DV_TASK_TEST_WAIT_AFTER_DONE=1
  task_start --agent claude
  wait_file "$DV_STATE/TK-1/after-done"
}
task_terminal_wait() {
  if [ "$1" = tmux ]; then wait_done TK-1
  else wait_file "$CASE_DIR/herdr/w-TK-1/exit"; fi
}
task_terminal_live() {
  task_terminal_setup "$1"
  local s="$DV_STATE/TK-1" head
  head=$(jq -r .head "$s/done.json")
  if dv land TK-1 --checked "$head"; then
    printf 'BUG: land accepted a live terminal task after done\n'; return 1
  fi
  test ! -e "$CASE_DIR/destination/TK-1"
  # A retained/stale success marker cannot prove that this live wrapper exited.
  printf '0\n' > "$s/agent.exit"
  if dv land TK-1 --checked "$head"; then return 1; fi
  touch "$s/release"
  task_terminal_wait "$1"
  # Missing or invalid process/exit evidence must also fail closed.
  cp "$s/agent.pid" "$CASE_DIR/saved-pid"
  rm "$s/agent.pid"
  if dv land TK-1 --checked "$head"; then return 1; fi
  printf 'unknown\n' > "$s/agent.pid"
  if dv land TK-1 --checked "$head"; then return 1; fi
  cp "$CASE_DIR/saved-pid" "$s/agent.pid"
  rm "$s/agent.exit"
  if dv land TK-1 --checked "$head"; then return 1; fi
  printf '0\n' > "$s/agent.exit"
  dv land TK-1 --checked "$head"
  test -f "$CASE_DIR/destination/TK-1/summary.txt"
}
case_task_tmux_live() { task_terminal_live tmux; }
case_task_herdr_live() { task_terminal_live herdr; }
task_terminal_failed() {
  export DV_TASK_TEST_EXIT_AFTER_DONE=7
  task_terminal_setup "$1"
  touch "$DV_STATE/TK-1/release"
  task_terminal_wait "$1"
  test "$(cat "$DV_STATE/TK-1/agent.exit")" = 7
  if dv land TK-1 --checked "$(jq -r .head "$DV_STATE/TK-1/done.json")"; then
    printf 'BUG: land accepted a terminal task that exited 7\n'; return 1
  fi
  test ! -e "$CASE_DIR/destination/TK-1"
}
case_task_tmux_failed() { task_terminal_failed tmux; }
case_task_herdr_failed() { task_terminal_failed herdr; }
task_terminal_changed() {
  export DV_TASK_TEST_MUTATE_AFTER_DONE=1
  task_terminal_setup "$1"
  local head
  head=$(jq -r .head "$DV_STATE/TK-1/done.json")
  touch "$DV_STATE/TK-1/release"
  task_terminal_wait "$1"
  if dv land TK-1 --checked "$head"; then return 1; fi
  test ! -e "$CASE_DIR/destination/TK-1"
  dv 'done' TK-1
  dv land TK-1 --checked "$(jq -r .head "$DV_STATE/TK-1/done.json")"
  grep -Fx 'late change' "$CASE_DIR/destination/TK-1/summary.txt"
}
case_task_tmux_changed() { task_terminal_changed tmux; }
case_task_herdr_changed() { task_terminal_changed herdr; }
case_task_recursive_destination() {
  needs_tmux; task_setup; task_start; wait_done TK-1
  local wt alias destination path head
  wt=$(jq -r .worktree "$DV_STATE/TK-1/meta")
  head=$(jq -r .head "$DV_STATE/TK-1/done.json")
  mkdir "$wt/out/subdir"
  ln -s "$wt" "$CASE_DIR/work-alias"
  ln -s "$wt/out" "$CASE_DIR/out-alias"
  ln -s "$DV_STATE/TK-1/task-snapshots/$head/out" "$CASE_DIR/snapshot-alias"
  cat > "$CASE_DIR/copy-spy" <<'ENV'
cp() { touch "$CASE_DIR/copy-called"; return 99; }
ENV
  for alias in "$wt" "$CASE_DIR/work-alias"; do
    for destination in "$wt/out" "$wt/out/subdir" "$CASE_DIR/out-alias" "$CASE_DIR/out-alias/subdir" "$DV_STATE/TK-1/task-snapshots/$head/out" "$CASE_DIR/snapshot-alias"; do
      jq --arg wt "$alias" --arg destination "$destination" '.worktree=$wt | .destination=$destination' "$DV_STATE/TK-1/meta" > "$CASE_DIR/task-meta"
      mv "$CASE_DIR/task-meta" "$DV_STATE/TK-1/meta"
      if BASH_ENV="$CASE_DIR/copy-spy" dv land TK-1 --checked "$head"; then return 1; fi
      if [ -e "$CASE_DIR/copy-called" ]; then
        printf 'BUG: recursive copy attempted: worktree=%s destination=%s\n' "$alias" "$destination"; return 1
      fi
      for path in "$wt/out/TK-1" "$wt/out/subdir/TK-1"; do test ! -e "$path"; done
    done
  done
}
task_appserver_setup() {
  task_setup
  export DV_AGENT_CMD_codex='' DV_CODEX_MODE=appserver DV_HERDR=0
  export DV_CODEX_BIN="$ROOT/tests/fixtures/appserver" DV_APPSERVER_POLL=1
  export DV_TRUSTED_REPOS="$CASE_DIR/Desk project"
  mkdir -p "$CASE_DIR/server" "$HOME/.codex"
  printf 'idle\n' > "$CASE_DIR/server/status"
  printf '# retained operator config\n' > "$HOME/.codex/config.toml"
  cp "$HOME/.codex/config.toml" "$CASE_DIR/original-config"
}
case_task_appserver() {
  task_appserver_setup
  export DV_CODEX_MODE=auto DV_TASK_APP_TEST_WORK=1
  task_start
  jq -e '.kind=="task" and .backend=="appserver" and .mode=="goal" and .thread_id=="thread-1"' "$DV_STATE/TK-1/meta"
  appserver_wait_work
  local wt head
  wt=$(jq -r .worktree "$DV_STATE/TK-1/meta")
  head=$(jq -r .head "$DV_STATE/TK-1/done.json")
  test ! -e "$wt/.git"
  test ! -e "$CASE_DIR/Desk project/.git"
  cmp "$HOME/.codex/config.toml" "$CASE_DIR/original-config"
  jq -se --arg wt "$wt" 'any(.[]; .method=="thread/start" and .params.cwd==$wt) and any(.[]; .method=="thread/goal/set" and .params.status=="complete")' "$CASE_DIR/server/requests"
  dv status TK-1 --live --json | jq -e '.[0] | .agent_status=="goal-complete" and .status=="done" and .done_head==.head'
  dv land TK-1 --checked "$head"
  cmp "$wt/out/summary.txt" "$CASE_DIR/destination/TK-1/summary.txt"
  dv clean TK-1
  test -f "$wt/out/summary.txt"
  test ! -e "$CASE_DIR/herdr/calls"
  test ! -f "$GH_STUB_DIR/calls"
}
case_task_appserver_guards() {
  task_appserver_setup; task_start
  jq -e '.backend=="appserver"' "$DV_STATE/TK-1/meta"
  local wt head state
  wt=$(jq -r .worktree "$DV_STATE/TK-1/meta")
  if dv 'done' TK-1; then return 1; fi
  test ! -f "$DV_STATE/TK-1/done.json"
  test "$(cat "$CASE_DIR/server/goal")" = active
  printf 'result\n' > "$wt/out/result"
  printf 'sources and open points\n' > "$DV_STATE/TK-1/report.md"
  printf 'refused\n' > "$CASE_DIR/server/finish-outcome"
  if dv 'done' TK-1; then return 1; fi
  test ! -f "$DV_STATE/TK-1/done.json"
  rm "$CASE_DIR/server/finish-outcome"
  dv 'done' TK-1
  head=$(jq -r .head "$DV_STATE/TK-1/done.json")
  for state in active systemError unknown gone; do
    printf '%s\n' "$state" > "$CASE_DIR/server/status"
    if dv land TK-1 --checked "$head"; then return 1; fi
    test ! -e "$CASE_DIR/destination/TK-1"
  done
  printf 'idle\n' > "$CASE_DIR/server/status"
  printf 'late mutation\n' >> "$wt/out/result"
  if dv land TK-1 --checked "$head"; then return 1; fi
  dv 'done' TK-1
  dv land TK-1 --checked "$(jq -r .head "$DV_STATE/TK-1/done.json")"
}
case_task_appserver_fallback() {
  task_setup
  export DV_AGENT_CMD_codex='' DV_CODEX_MODE=auto DV_CODEX_BIN="$ROOT/tests/fixtures/task-agent"
  export DV_TRUSTED_REPOS="$CASE_DIR/Desk project"
  task_start; task_exec_wait TK-1
  jq -e '.backend=="exec" and .mode=="exec" and .status=="done"' "$DV_STATE/TK-1/meta"
  jq -e '.args | index("--skip-git-repo-check")!=null' "$DV_STATE/TK-1/task-agent.json"
}
case_task_codex_goal() {
  task_setup; herdr_setup
  export DV_CODEX_MODE=goal DV_CODEX_BIN="$ROOT/tests/fixtures/task-agent"
  export DV_TRUSTED_REPOS="$CASE_DIR/Desk project"
  task_start; wait_native TK-1
  jq -e '.backend=="herdr" and .mode=="goal" and .status=="done"' "$DV_STATE/TK-1/meta"
  test -f "$DV_STATE/TK-1/goal-input"
  local wt
  wt=$(jq -r .worktree "$DV_STATE/TK-1/meta")
  test ! -e "$wt/.git"
  grep -F "$wt" "$HOME/.codex/config.toml"
  dv land TK-1 --checked "$(jq -r .head "$DV_STATE/TK-1/done.json")"
}
