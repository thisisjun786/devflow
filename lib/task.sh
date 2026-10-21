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
  if [ "$agent" = codex ] && [ -z "$DV_AGENT_CMD_codex" ]; then
    BACKEND='exec'
    [[ "$DV_STALL_AFTER" =~ ^[1-9][0-9]*$ ]] || fail 'DV_STALL_AFTER must be a positive integer'
  elif [ "$DV_HERDR" != 0 ] && herdr_bin >/dev/null; then BACKEND=herdr; else need tmux; fi
  mkdir -p "$DV_STATE" "$DV_WORK"
  S="$DV_STATE/$ISSUE"; SESSION="dv-$ISSUE"; BRANCH=''; BASE=''; KIND=task
  [ ! -e "$S" ] && [ ! -L "$S" ] || fail 'issue state already exists'
  if [ "$BACKEND" = tmux ]; then
    ! tmux_dv has-session -t "=$SESSION" 2>/dev/null || fail 'tmux session already exists'
  fi
  capacity=$DV_MAX_JOBS
  if [ -z "$capacity" ]; then
    capacity=$(( $(bid_cores) / 8 ))
    [ "$capacity" != 0 ] || capacity=1
  fi
  [[ "$capacity" =~ ^[1-9][0-9]*$ ]] || fail 'DV_MAX_JOBS must be a positive integer'
  # Share admission/capacity with code starts awarded by the scheduler.
  owned_lock "$DV_STATE/.admission-lock" "$$" || fail 'host admission busy'
  trap 'owned_unlock "$DV_STATE/.admission-lock" "$$"' EXIT
  [ "$(bid_active)" -lt "$capacity" ] || fail 'host has no free task slots'
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
  if [ "$BACKEND" = exec ] && ! task_codex_trust; then
    meta_set '.status="start-failed"'
    fail 'Codex persisted task folder trust is not ready'
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
  local out=$1 report=$2 path digest tmp
  [ -d "$out" ] && [ ! -L "$out" ] || fail 'task out/ is missing or is a symlink'
  [ -s "$report" ] && [ -f "$report" ] && [ ! -L "$report" ] || fail 'task report.md is missing, empty or is a symlink'
  tmp=$(mktemp "$S/.manifest.XXXXXX")
  trap 'rm -f "$tmp" "$tmp.paths"' EXIT
  # Reject links, devices and FIFOs rather than reading outside out/.
  find "$out" ! -type d ! -type f -print0 > "$tmp.paths" || exit 1
  [ ! -s "$tmp.paths" ] || fail 'task out/ must contain only regular files and directories'
  find "$out" -type f -print0 > "$tmp.paths" || exit 1
  [ -s "$tmp.paths" ] || fail 'task out/ has no deliverables'
  while IFS= read -r -d '' path; do
    digest=$(task_hash < "$path") || exit 1
    jq -cn --arg path "${path#"$out/"}" --arg digest "$digest" '{path:$path,sha256:$digest}' >> "$tmp" || exit 1
  done < "$tmp.paths"
  digest=$(task_hash < "$report") || exit 1
  jq -cs --arg report "$digest" '{files:sort_by(.path),report_sha256:$report}' "$tmp"
)
task_completion() {
  local manifest
  case "$(jq -r .status "$S/meta")" in landed|cancelled) fail 'cannot complete a finished task' ;; esac
  manifest=$(task_manifest "$WT/out" "$S/report.md") || return 1
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
task_land() {
  [ "$#" -eq 3 ] && [ "$2" = --checked ] || fail 'usage: dv land TASK --checked HEAD (after checking the brief, out/ and report.md)'
  load_issue "$1"; issue_lock; require_worktree
  local checked=$3 head destination target suffix=1 manifest copied
  [ -f "$S/done.json" ] || fail 'task is not done'
  head=$(jq -r .head "$S/done.json")
  [ "$checked" = "$head" ] || fail 'checked task revision does not match done'
  if [ "$(jq -r .status "$S/meta")" = landed ]; then
    jq -r .landed_path "$S/meta"; return
  fi
  [ "$(jq -r .status "$S/meta")" = 'done' ] || fail 'task is not ready to land'
  if [ "$BACKEND" = exec ]; then
    ! codex_exec_alive "$S" || fail 'task exec is still running'
    [ "$(jq -r .exec_status "$S/meta")" = 'done' ] || fail 'task exec did not finish successfully'
  fi
  manifest=$(task_manifest "$WT/out" "$S/report.md") || return 1
  [ "task-$(printf '%s\n' "$manifest" | task_hash)" = "$checked" ] || fail 'task changed since done; inspect it and run dv done again'
  destination=$(jq -r .destination "$S/meta")
  mkdir -p "$destination"
  destination=$(cd "$destination" && pwd -P)
  case "$destination/" in "$WT/"*) fail 'destination must be outside the task work directory' ;; esac
  target="$destination/$ISSUE"
  # Atomic mkdir claims a fresh bundle. Never merge into existing directories
  # or follow an existing symlink; cp -n varies between platforms.
  while ! mkdir "$target" 2>/dev/null; do
    [ -e "$target" ] || [ -L "$target" ] || fail 'cannot create task destination'
    suffix=$((suffix + 1)); target="$destination/$ISSUE-v$suffix"
  done
  cp -R "$WT/out/." "$target/" || fail "copy failed; partial files retained at $target"
  copied=$(task_manifest "$target" "$S/report.md") || return 1
  [ "$copied" = "$manifest" ] || fail "task changed during copy; partial files retained at $target"
  meta_set --arg path "$target" --arg head "$checked" --argjson time "$(now)" \
    '.status="landed" | .landed_path=$path | .landed_head=$head | .landed_at=$time'
  cmd_kick landed "$ISSUE" "Task deliverables copied to $target"
  printf '%s\n' "$target"
}
task_clean() {
  [ "$#" -eq 1 ] || fail 'usage: dv clean TASK'
  load_issue "$1"; issue_lock
  # Without Git there is no safe dirty check. Close the terminal, retain files.
  if [ "$BACKEND" = exec ]; then
    ! codex_exec_alive "$S" || fail 'task exec is still running; files retained'
  elif [ "$BACKEND" = herdr ]; then herdr_clean || fail 'task terminal was not closed'
  else tmux_dv kill-session -t "=$SESSION" 2>/dev/null || true; fi
  meta_set --argjson time "$(now)" '.cleaned_at=$time'
  printf 'Task files retained: %s\n' "$WT"
}
