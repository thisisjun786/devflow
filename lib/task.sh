#!/usr/bin/env bash
# Local non-code jobs share terminals, status, events and revival with code jobs.
# Globals also serve commands.sh and common.sh after this file is sourced.
# shellcheck disable=SC2016,SC2034
task_issue() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] &&
    [ -f "$DV_STATE/$1/meta" ] && jq -e '.kind=="task"' "$DV_STATE/$1/meta" >/dev/null
}
task_hash() {
  # Stdin keeps filenames (including newlines) out of the digest format.
  if command -v sha256sum >/dev/null; then sha256sum | awk '{print $1}'
  else shasum -a 256 | awk '{print $1}'; fi
}
task_codex_trust() {
  codex_repo_allowed "$REPO" || return 1
  # Only this job's fresh directory inherits its workspace's authorization.
  local DV_TRUSTED_REPOS="$DV_TRUSTED_REPOS"$'\n'"$WT"
  codex_environment && codex_trust_repo "$WT"
}
task_submit() {
  [ "$#" -ge 3 ] || fail 'usage: dv submit --kind task WORKSPACE ISSUE slug --brief FILE [--agent codex|claude]'
  REPO=$(cd "$1" && pwd -P) || fail 'workspace is not a directory'
  ISSUE=$2; local slug=$3 brief='' agent=$DV_AGENT destination mode capacity
  shift 3; valid_issue "$ISSUE"
  [[ "$slug" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || fail 'invalid slug'
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || fail "missing value for $1"
    case "$1" in --brief) brief=$2 ;; --agent) agent=$2 ;; *) fail "unknown task option: $1" ;; esac
    shift 2
  done
  case "$agent" in codex) mode='exec' ;; claude) mode=goal ;; *) fail 'task agent must be codex or claude' ;; esac
  if [ "$agent" = codex ] && [ -z "$DV_AGENT_CMD_codex" ]; then mode=$(codex_default_mode "$agent"); fi
  case "$mode" in auto|exec|goal) ;; *) fail 'task mode must be auto, exec or goal' ;; esac
  [ -f "$brief" ] || fail 'brief file not found'
  # A literal, single absolute destination is data, never evaluated shell text.
  destination=$(sed -n 's/^Destination: //p' "$brief")
  [[ "$destination" = /* && "$destination" != *$'\n'* && "$destination" != *$'\r'* ]] || fail 'brief needs exactly one Destination: /absolute/path line'
  need jq
  command -v sha256sum >/dev/null || need shasum
  if [ "$agent" = codex ] && [ -z "$DV_AGENT_CMD_codex" ]; then
    if ! codex_repo_allowed "$REPO" || ! codex_environment; then fail 'Codex workspace trust or provider environment is not ready'; fi
  fi
  BACKEND=tmux
  if appserver_selected "$agent" "$mode"; then
    BACKEND=appserver; mode=goal
  else
    [ "$mode" != auto ] || mode='exec'
    if [ "$agent:$mode" = codex:exec ] && [ -z "$DV_AGENT_CMD_codex" ]; then
      BACKEND='exec'
      [[ "$DV_STALL_AFTER" =~ ^[1-9][0-9]*$ ]] || fail 'DV_STALL_AFTER must be a positive integer'
    elif [ "$DV_HERDR" != 0 ] && herdr_bin >/dev/null; then BACKEND=herdr; else need tmux; fi
  fi
  mkdir -p "$DV_STATE" "$DV_WORK"
  S="$DV_STATE/$ISSUE"; SESSION="dv-$ISSUE"; BRANCH=''; BASE=''; KIND=task
  if [ -e "$S" ] || [ -L "$S" ]; then fail 'issue state already exists'; fi
  if [ "$BACKEND" = tmux ]; then
    ! tmux_dv has-session -t "=$SESSION" 2>/dev/null || fail 'tmux session already exists'
  fi
  # Share admission/capacity with code starts awarded by the scheduler.
  owned_lock "$DV_STATE/.admission-lock" "$$" || fail 'host admission busy'
  trap 'owned_unlock "$DV_STATE/.admission-lock" "$$"' EXIT
  capacity=$(bid_capacity "$(bid_resources)" "$(bid_active)") || return 1
  jq -e '.free_slots>0' <<< "$capacity" >/dev/null || fail 'host has no free task slots'
  mkdir "$S" || fail 'issue was started concurrently'
  WT=$(mktemp -d "$DV_WORK/task-$ISSUE.XXXXXX")
  WT=$(cd "$WT" && pwd -P)
  mkdir "$WT/out"
  cat "$DV_ROOT/templates/task-rules.md" > "$S/brief.md"
  printf '\nIssue: %s\nWorkspace (reference only): %s\nWork directory: %s\nReport: %s/report.md\n\n' "$ISSUE" "$REPO" "$WT" "$S" >> "$S/brief.md"
  cat "$brief" >> "$S/brief.md"
  jq -n --arg issue "$ISSUE" --arg repo "$REPO" --arg worktree "$WT" --arg agent "$agent" \
    --arg mode "$mode" --arg slug "$slug" --arg destination "$destination" --arg host "$DV_HOST" \
    --arg backend "$BACKEND" --arg start_head "task-$(now)-$$-$RANDOM" --argjson started "$(now)" \
    '{kind:"task",issue:$issue,repo:$repo,worktree:$worktree,branch:"",base:"",start_head:$start_head,
      agent:$agent,mode:$mode,slug:$slug,destination:$destination,host:$host,backend:$backend,started:$started,status:"running"}' > "$S/meta"
  : > "$S/log"
  if [ "$agent" = codex ] && [ -z "$DV_AGENT_CMD_codex" ] && [ "$BACKEND" != appserver ]; then
    if ! task_codex_trust; then
      meta_set '.status="start-failed"'
      fail 'Codex persisted task folder trust is not ready'
    fi
  fi
  if ! launch_agent; then
    meta_set '.status="start-failed"'
    fail "$BACKEND startup failed; task files retained"
  fi
  owned_unlock "$DV_STATE/.admission-lock" "$$"
  trap - EXIT
  printf '%s task %s\n' "$ISSUE" "$WT"
}
task_manifest() (
  local out=$1 report=$2 path digest tmp has_content=0
  if [ ! -d "$out" ] || [ -L "$out" ]; then fail 'task out/ is missing or is a symlink'; fi
  if [ ! -s "$report" ] || [ ! -f "$report" ] || [ -L "$report" ]; then
    fail 'task report.md is missing, empty or is a symlink'
  fi
  tmp=$(mktemp "$S/.manifest.XXXXXX")
  trap 'rm -f "$tmp" "$tmp.paths"' EXIT
  # Reject links, devices and FIFOs rather than reading outside out/.
  find "$out" ! -type d ! -type f -print0 > "$tmp.paths" || exit 1
  [ ! -s "$tmp.paths" ] || fail 'task out/ must contain only regular files and directories'
  find "$out" -type f -print0 > "$tmp.paths" || exit 1
  [ -s "$tmp.paths" ] || fail 'task out/ has no deliverables'
  while IFS= read -r -d '' path; do
    if [ -s "$path" ]; then has_content=1; fi
    digest=$(task_hash < "$path") || exit 1
    jq -cn --arg path "${path#"$out/"}" --arg digest "$digest" '{path:$path,sha256:$digest}' >> "$tmp" || exit 1
  done < "$tmp.paths"
  [ "$has_content" = 1 ] || fail 'task out/ has only empty files'
  digest=$(task_hash < "$report") || exit 1
  jq -cs --arg report "$digest" '{files:sort_by(.path),report_sha256:$report}' "$tmp"
)
task_snapshot() (
  local manifest copied current stage='' revision snapshot
  trap 'if [ -n "$stage" ]; then rm -rf "$stage"; fi' EXIT
  manifest=$(task_manifest "$WT/out" "$S/report.md") || return 1
  stage=$(mktemp -d "$S/.task-snapshot.XXXXXX") || return 1
  mkdir "$stage/out" || return 1
  cp -R "$WT/out/." "$stage/out/" || return 1
  cp "$S/report.md" "$stage/report.md" || return 1
  copied=$(task_manifest "$stage/out" "$stage/report.md") || return 1
  current=$(task_manifest "$WT/out" "$S/report.md") || return 1
  if [ "$manifest" != "$copied" ] || [ "$manifest" != "$current" ]; then
    fail 'task changed during done; finish writing before completing again'
  fi
  revision="task-$(printf '%s\n' "$manifest" | task_hash)" || return 1
  [ ! -L "$S/task-snapshots" ] || fail 'task snapshots directory is a symlink'
  mkdir -p "$S/task-snapshots" || return 1
  snapshot="$S/task-snapshots/$revision"
  if [ -e "$snapshot" ] || [ -L "$snapshot" ]; then
    # Repeated done for the same content must not replace an existing snapshot.
    if [ ! -d "$snapshot" ] || [ -L "$snapshot" ]; then fail 'task snapshot is not a directory'; fi
    copied=$(task_manifest "$snapshot/out" "$snapshot/report.md") || return 1
    [ "$copied" = "$manifest" ] || fail 'task snapshot has changed'
  else
    mv "$stage" "$snapshot" || return 1
    stage=''
  fi
  printf '%s\n' "$manifest"
)
task_completion() {
  local manifest
  case "$(jq -r .status "$S/meta")" in landed|cancelled) fail 'cannot complete a finished task' ;; esac
  manifest=$(task_snapshot) || return 1
  head="task-$(printf '%s\n' "$manifest" | task_hash)"
  files=$(printf '%s\n' "$manifest" | jq '.files|length')
}
task_exec_done() {
  local revived=$1
  # The agent may have completed and the manager landed before its CLI exited.
  [ "$(jq -r .status "$S/meta")" != landed ] || return 0
  if "$DV_ROOT/bin/dv" 'done' "$ISSUE"; then return 0; fi
  printf '1\n' > "$S/agent.exit"
  if [ "$revived" = 1 ]; then revive_blocked 'task exited without valid deliverables and report'
  else cmd_kick failed "$ISSUE" 'task exited without valid deliverables and report'; fi
  return 1
}
task_require_finished() {
  local pid server
  if [ "$BACKEND" = appserver ]; then
    # The client remains alive after a turn. Require a fresh successful idle
    # thread, not a stopped local wrapper or a disappeared/unknown thread.
    server=$(appserver_status "$ISSUE")
    printf '%s\n' "$server" | jq -e '
      (.agent_status=="goal-complete" or .agent_status=="idle") and
      .thread.status.type=="idle" and .turn_id==null and .question_pending==false and
      all(.thread.turns[]?; .status=="completed")' >/dev/null || fail 'task App Server thread has not finished successfully'
  elif [ "$BACKEND" = exec ]; then
    ! codex_exec_alive "$S" || fail 'task exec is still running'
    [ "$(jq -r .exec_status "$S/meta")" = 'done' ] || fail 'task exec did not finish successfully'
  else
    # done is written by the agent before its CLI and wrapper have exited.
    # A terminal can retain a shell/dead pane, so check the wrapper process,
    # not the pane. The shared PID check also treats reaped/zombie runs as dead.
    pid=$(cat "$S/agent.pid" 2>/dev/null) || fail 'task terminal exit is not confirmed'
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail 'task terminal process identity is invalid'
    ! codex_exec_alive "$S" || fail 'task terminal agent is still running'
    [ "$(cat "$S/agent.exit" 2>/dev/null)" = 0 ] || fail 'task terminal agent did not exit successfully'
  fi
}
task_land() {
  if [ "$#" -ne 3 ] || [ "$2" != --checked ]; then
    fail 'usage: dv land TASK --checked HEAD (after checking the brief, out/ and report.md)'
  fi
  load_issue "$1"; issue_lock; require_worktree
  local checked=$3 head destination target suffix=1 manifest copied snapshot current state
  # Old metadata and aliases can name the same directory through a symlink.
  # Compare physical paths on both sides of the recursive-copy guard.
  WT=$(cd "$WT" && pwd -P)
  state=$(cd "$S" && pwd -P)
  [ -f "$S/done.json" ] || fail 'task is not done'
  head=$(jq -r .head "$S/done.json")
  [ "$checked" = "$head" ] || fail 'checked task revision does not match done'
  if [ "$(jq -r .status "$S/meta")" = landed ]; then
    jq -r .landed_path "$S/meta"; return
  fi
  [ "$(jq -r .status "$S/meta")" = 'done' ] || fail 'task is not ready to land'
  task_require_finished
  # Re-read the artifacts only after the writer has successfully stopped.
  manifest=$(task_manifest "$WT/out" "$S/report.md") || return 1
  [ "task-$(printf '%s\n' "$manifest" | task_hash)" = "$checked" ] || fail 'task changed since done; inspect it and run dv done again'
  snapshot="$S/task-snapshots/$head"
  if [ -L "$S/task-snapshots" ] || [ -L "$snapshot" ] || [ ! -d "$snapshot" ]; then
    fail 'task snapshot is missing or is a symlink; run dv done again'
  fi
  copied=$(task_manifest "$snapshot/out" "$snapshot/report.md") || return 1
  [ "$copied" = "$manifest" ] || fail 'task snapshot has changed'
  destination=$(jq -r .destination "$S/meta")
  mkdir -p "$destination"
  destination=$(cd "$destination" && pwd -P)
  case "$destination/" in
    "$WT/"*|"$state/"*) fail 'destination must be outside the task work and state directories' ;;
  esac
  target="$destination/$ISSUE"
  # Atomic mkdir claims a fresh bundle. Never merge into existing directories
  # or follow an existing symlink; cp -n varies between platforms.
  while ! mkdir "$target" 2>/dev/null; do
    [ -e "$target" ] || [ -L "$target" ] || fail 'cannot create task destination'
    suffix=$((suffix + 1)); target="$destination/$ISSUE-v$suffix"
  done
  cp -R "$snapshot/out/." "$target/" || fail "copy failed; partial files retained at $target"
  copied=$(task_manifest "$target" "$snapshot/report.md") || return 1
  task_require_finished
  current=$(task_manifest "$WT/out" "$S/report.md") || return 1
  if [ "$copied" != "$manifest" ] || [ "$current" != "$manifest" ]; then
    fail "task changed during copy; partial files retained at $target"
  fi
  meta_set --arg path "$target" --arg head "$checked" --argjson time "$(now)" \
    '.status="landed" | .landed_path=$path | .landed_head=$head | .landed_at=$time'
  cmd_kick landed "$ISSUE" "Task deliverables copied to $target"
  printf '%s\n' "$target"
}
task_clean() {
  [ "$#" -eq 1 ] || fail 'usage: dv clean TASK'
  load_issue "$1"; issue_lock
  # Without Git there is no safe dirty check. Close the terminal, retain files.
  if [ "$BACKEND" = appserver ]; then
    appserver_require_idle
    if appserver_alive; then kill "$(cat "$S/appserver/client.pid")"; fi
  elif [ "$BACKEND" = exec ]; then
    ! codex_exec_alive "$S" || fail 'task exec is still running; files retained'
  elif [ "$BACKEND" = herdr ]; then herdr_clean || fail 'task terminal was not closed'
  else tmux_dv kill-session -t "=$SESSION" 2>/dev/null || true; fi
  meta_set --argjson time "$(now)" '.cleaned_at=$time'
  printf 'Task files retained: %s\n' "$WT"
}
