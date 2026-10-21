#!/usr/bin/env bash
# BASE is populated by load_issue in common.sh. jq filters intentionally use literal $.
# shellcheck disable=SC2153,SC2016
start_worktree() (
  local common lock
  common=$(cd "$REPO" && cd "$(git rev-parse --git-common-dir)" && pwd)
  lock="$common/devflow-worktree.lock"
  owned_lock "$lock" "$$" || fail 'repository worktree creation busy'
  trap 'owned_unlock "$lock" "$$"' EXIT
  # A timeout must leave the issue available for retry. Claim its state only
  # after admission to Git; retain it if the Git operation itself fails.
  mkdir "$S" || fail 'issue was started concurrently'
  git -C "$REPO" worktree add -b "$BRANCH" "$WT" "$1"
)
cmd_start() {
  [ "$#" -ge 3 ] || fail 'usage: dv start <repo> <ISSUE> <slug> [options]'
  REPO=$(cd "$1" && git rev-parse --show-toplevel); ISSUE=$2; local slug=$3
  shift 3; valid_issue "$ISSUE"
  [[ "$slug" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || fail 'invalid slug'
  local agent=$DV_AGENT mode=$DV_MODE brief='' base='' ref lower start_sha
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || fail "missing value for $1"
    case "$1" in
      --agent) agent=$2 ;; --mode) mode=$2 ;; --brief) brief=$2 ;; --base) base=$2 ;;
      *) fail "unknown option: $1" ;;
    esac
    shift 2
  done
  case "$agent" in codex|claude|devin) ;; *) fail 'unknown agent' ;; esac
  [ -n "$mode" ] || mode=$(codex_default_mode "$agent")
  case "$mode" in auto|goal|exec) ;; *) fail 'mode must be auto, goal or exec' ;; esac
  [ "$agent" = codex ] || [ "$mode" = goal ] || fail 'auto/exec modes are Codex-only'
  [ -z "$brief" ] || [ -f "$brief" ] || fail 'brief file not found'
  need git; need jq
  if [ "$agent" = codex ] && [ -z "$DV_AGENT_CMD_codex" ]; then
    local trust_root
    trust_root=$(codex_repo_root "$REPO") || fail 'cannot resolve Codex repository root'
    codex_repo_allowed "$trust_root" || fail 'Codex repository trust denied'
    codex_environment || fail 'Codex provider environment is not ready'
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
  if [ "$agent" = codex ] && [ -z "$DV_AGENT_CMD_codex" ] && [ "$BACKEND" != appserver ]; then
    codex_trust_repo "$trust_root" || fail 'Codex persisted folder trust is not ready'
  fi
  mkdir -p "$DV_STATE" "$DV_WORK"
  S="$DV_STATE/$ISSUE"; SESSION="dv-$ISSUE"
  [ ! -e "$S" ] || fail 'issue state already exists'
  if [ "$BACKEND" = tmux ]; then
    ! tmux_dv has-session -t "=$SESSION" 2>/dev/null || fail 'tmux session already exists'
  fi
  if git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
    git -C "$REPO" fetch origin
    if [ -z "$base" ]; then
      base=$(git -C "$REPO" ls-remote --symref origin HEAD | sed -n 's@^ref: refs/heads/\([^[:space:]]*\).*@\1@p')
      [ -n "$base" ] || fail 'remote has no default branch; use --base'
    fi
    ref="refs/remotes/origin/$base"
  else
    if [ -z "$base" ]; then
      if git -C "$REPO" show-ref --verify --quiet refs/heads/main; then base=main
      elif git -C "$REPO" show-ref --verify --quiet refs/heads/master; then base=master
      else base=$(git -C "$REPO" symbolic-ref --short HEAD); fi
    fi
    ref="refs/heads/$base"
  fi
  git check-ref-format "refs/heads/$base" >/dev/null || fail 'invalid base'
  start_sha=$(git -C "$REPO" rev-parse --verify "$ref^{commit}")
  lower=$(printf '%s' "$ISSUE" | tr '[:upper:]' '[:lower:]')
  BRANCH="$agent/$lower-$slug"; WT="$DV_WORK/$(basename "$REPO")-$ISSUE"
  start_worktree "$start_sha"
  cat "$DV_ROOT/templates/rules.md" > "$S/brief.md"
  printf '\nIssue: %s\nWorktree: %s\nReport: %s/report.md\n\n' "$ISSUE" "$WT" "$S" >> "$S/brief.md"
  if [ -n "$brief" ]; then cat "$brief" >> "$S/brief.md"; else printf 'Complete issue %s.\n' "$ISSUE" >> "$S/brief.md"; fi
  jq -n --arg issue "$ISSUE" --arg repo "$REPO" --arg worktree "$WT" --arg branch "$BRANCH" \
    --arg base "$base" --arg start_head "$start_sha" --arg agent "$agent" --arg mode "$mode" --arg slug "$slug" \
    --arg host "$DV_HOST" --arg backend "$BACKEND" --arg token "${DV_AWARD_TOKEN:-}" --argjson started "$(now)" \
    '{issue:$issue,repo:$repo,worktree:$worktree,branch:$branch,base:$base,start_head:$start_head,agent:$agent,mode:$mode,slug:$slug,host:$host,started:$started,backend:$backend,status:"running"} +
    (if $token=="" then {} else {award_token:$token} end)' > "$S/meta"
  : > "$S/log"
  if ! launch_agent; then
    meta_set '.status="start-failed"'
    fail "$BACKEND startup failed; state retained for dv clean (no backend fallback)"
  fi
  printf '%s %s %s\n' "$ISSUE" "$BRANCH" "$WT"
}
launch_agent() {
  if [ "$BACKEND" = appserver ]; then appserver_start; return; fi
  # Terminal server environments can predate this shell. Pass exported DV_* values explicitly.
  local env_args=() key launcher
  while IFS= read -r key; do
    case "$key" in DV_*|CODEX_HOME|CLAUDE_CONFIG_DIR|GH_STUB_DIR|CASE_DIR|GIT_CONFIG_*|GIT_TERMINAL_PROMPT) env_args+=("$key=${!key}") ;; esac
  done < <(compgen -e)
  launcher=$(shell_join env "PATH=$PATH" "${env_args[@]}" "$DV_ROOT/bin/dv" _agent "$ISSUE" "$@")
  if [ "$BACKEND" = exec ]; then
    codex_exec_launch "$launcher"
  elif [ "$BACKEND" = herdr ]; then
    if [ "${1:-}" = --revived ] && [ "${REVIVE_PANE_EXISTS:-0}" = 1 ]; then
      herdr_cmd pane run "$HERDR_PANE" "$launcher"
    else
      if [ "${1:-}" = --revived ]; then herdr_clean || return 1; fi
      herdr_start "$launcher"
    fi
  else
    if [ "${1:-}" = --revived ] && tmux_dv has-session -t "=$SESSION" 2>/dev/null; then
      # A retained dead pane needs no kill/force option.
      tmux_dv respawn-pane -t "$SESSION:0.0" -c "$WT" "$launcher" || return 1
    else
      tmux_dv new-session -d -s "$SESSION" -c "$WT" "$launcher" || return 1
    fi
    # tmux can return zero even when its server could not create the socket.
    tmux_dv has-session -t "=$SESSION" 2>/dev/null || {
      # A fast wrapper may already have completed and closed its session.
      # Revivals retain old done.json, so require this revival's completion.
      if [ "$(cat "$S/agent.exit" 2>/dev/null)" = 0 ] && [ -s "$S/done.json" ]; then
        if [ "${1:-}" != --revived ] ||
          { [ -s "$S/revive/id" ] && cmp -s "$S/revive/id" "$S/revive/done"; }; then
          return 0
        fi
      fi
      printf 'dv: tmux session %s is missing after startup\n' "$SESSION" >&2
      return 1
    }
  fi
}
run_agent() {
  load_issue "$1"; require_worktree; cd "$WT" || exit
  export DV_ISSUE="$ISSUE"
  local agent mode override instruction rc=0 sentinel='' helper='' revived=0
  [ "${2:-}" != --revived ] || revived=1
  [ "$BACKEND" = exec ] || printf '%s\n' "$$" > "$S/agent.pid"
  agent=$(jq -r .agent "$S/meta"); mode=$(jq -r .mode "$S/meta")
  override="DV_AGENT_CMD_$agent"; override=${!override}
  instruction="Read $S/brief.md and complete everything it asks. Finish with dv done $ISSUE."
  unset DV_REVIVE_ID
  if [ "$revived" = 1 ]; then
    instruction=$(cat "$S/revive/prompt.md")
    DV_REVIVE_ID=$(cat "$S/revive/id"); export DV_REVIVE_ID
  fi
  export DV_AGENT_INSTRUCTION="$instruction"
  if [ "$BACKEND" = exec ]; then
    if [ "${2:-}" = --exec-prompt ]; then instruction=$(cat "$3"); fi
    codex_exec_run "$instruction"
    return
  fi
  # Native herdr snapshots are collected at done/clean; tmux keeps its TTY log.
  if [ "$BACKEND" = tmux ]; then
    tmux_dv pipe-pane -o -t "$SESSION:0.0" "cat >> $(shell_join "$S/log")"
    # This backend has no question watcher to deliver answers to the operator.
    DV_AGENT_QUESTIONS=off
  else
    [[ "$DV_BLOCKED_GRACE" =~ ^[1-9][0-9]*$ ]] || fail 'DV_BLOCKED_GRACE must be a positive integer'
    herdr_question_sentinel >> "$S/question.log" 2>&1 & sentinel=$!
    trap 'stop_question_sentinel' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
  fi
  if [ -n "$override" ]; then
    [ -z "${DV_AWARD_TOKEN:-}" ] || touch "$S/agent.started"
    bash -c "$override" || rc=$?
  else
    local args=()
    case "$agent" in
      codex)
        local trust_root trust_ready=0
        if [ "$KIND" = task ]; then
          trust_root=$WT
          if task_codex_trust; then trust_ready=1; fi
        else
          trust_root=$(codex_repo_root "$REPO")
          if codex_environment && codex_trust_repo "$trust_root"; then trust_ready=1; fi
        fi
        if [ "$trust_ready" = 0 ]; then
          printf '1\n' > "$S/agent.exit"
          agent_start_failed 'codex provider environment or persisted folder trust is not ready' ''
          return 1
        fi
        args=("$DV_CODEX_BIN" -m "$DV_CODEX_MODEL" -c "model_reasoning_effort=\"$DV_CODEX_EFFORT\"" -s danger-full-access -a never)
        [ "$DV_AGENT_QUESTIONS" != off ] || args+=(-c tools.experimental_request_user_input.enabled=false)
        args+=(-c "projects.$(jq -Rn --arg path "$(pwd -P)" '$path').trust_level=\"trusted\"")
        # Codex resolves a linked worktree's trust against the original repo.
        args+=(-c "projects.$(jq -Rn --arg path "$trust_root" '$path').trust_level=\"trusted\"")
        if [ "$BACKEND" = tmux ] && [ "$DV_CODEX_DISABLE_HOOKS" = 1 ]; then args+=(--disable hooks); fi
        [ "$DV_CODEX_DISABLE_CRW" != 1 ] || args+=(-c 'plugins."crw@crw".enabled=false')
        if [ "$mode" = exec ]; then
          [ -z "${DV_AWARD_TOKEN:-}" ] || touch "$S/agent.started"
          args+=(exec)
          [ "$KIND" != task ] || args+=(--skip-git-repo-check)
          "${args[@]}" "$instruction" || rc=$?
        else
          inject_goal "$instruction" & helper=$!
          "${args[@]}" || rc=$?
          stop_question_sentinel
          wait "$helper" || true
        fi ;;
      claude)
        if ! claude_trust_worktree "$(pwd -P)"; then
          agent_start_failed "Claude folder trust could not be recorded in $HOME/.claude.json" ''; rc=1
        elif ! claude_onboarding | jq -e '.hasCompletedOnboarding and .skipDangerousModePermissionPrompt' >/dev/null; then
          agent_start_failed 'Claude onboarding incomplete: 기기에서 claude를 한 번 대화형으로 실행해 온보딩을 끝내라 (--dangerously-skip-permissions 경고 포함)' ''; rc=1
        else
          [ -z "${DV_AWARD_TOKEN:-}" ] || touch "$S/agent.started"
          args=("$DV_CLAUDE_BIN" --model "$DV_CLAUDE_MODEL" --effort "$DV_CLAUDE_EFFORT" --dangerously-skip-permissions)
          [ "$DV_AGENT_QUESTIONS" != off ] || args+=(--disallowedTools AskUserQuestion)
          "${args[@]}" -- "$instruction" || rc=$?
        fi ;;
      devin)
        [ -z "${DV_AWARD_TOKEN:-}" ] || touch "$S/agent.started"
        accept_devin_trust & helper=$!
        "$DV_DEVIN_BIN" --model "$DV_DEVIN_MODEL" --permission-mode dangerous -- "$instruction" || rc=$?
        stop_question_sentinel
        wait "$helper" || true ;;
    esac
  fi
  stop_question_sentinel
  trap - EXIT INT TERM
  printf '%s\n' "$rc" > "$S/agent.exit"
  if [ "$KIND" = task ] && [ "$mode" = exec ] && [ "$rc" = 0 ]; then
    task_exec_done "$revived"; return
  fi
  if [ "$revived" = 1 ]; then
    if [ "$rc" -ne 0 ]; then revive_blocked "revived agent exited $rc"
    elif [ "$mode" = exec ]; then agent_exec_done 1 || rc=1
    elif [ "$(cat "$S/revive/done" 2>/dev/null)" != "$DV_REVIVE_ID" ]; then revive_blocked 'revived goal agent exited without dv done'; fi
  elif jq -e '.status=="pr"' "$S/meta" >/dev/null; then
    # The PR remains the worker's responsibility, including an early nonzero
    # exit. Let the existing safety net revive it with CI/review context.
    "$DV_ROOT/bin/dv" _pr-wait-start "$ISSUE"
  elif [ "$mode" = exec ]; then
    if [ "$rc" -eq 0 ]; then agent_exec_done 0 || rc=1
    else "$DV_ROOT/bin/dv" kick failed "$ISSUE" "agent exited $rc"; fi
  # Startup failures already emitted failed through agent_start_failed.
  elif [ ! -f "$S/done.json" ] && ! jq -e '.status=="start-failed"' "$S/meta" >/dev/null; then
    "$DV_ROOT/bin/dv" kick failed "$ISSUE" "goal agent exited $rc without dv done"
  fi
  return "$rc"
}
agent_exec_done() {
  if "$DV_ROOT/bin/dv" 'done' "$ISSUE"; then return 0; fi
  # A rejected completion is an execution failure, not an abandoned running
  # issue. Keep the scheduler's exit evidence and the manager event consistent.
  printf '1\n' > "$S/agent.exit"
  meta_set '.status="failed" | .failure_reason="exec completion rejected; see log"'
  if [ "$1" = 1 ]; then revive_blocked 'revived exec completion rejected'
  else cmd_kick failed "$ISSUE" 'exec completion rejected; see log'; fi
  return 1
}
stop_question_sentinel() {
  if [ -n "$sentinel" ]; then
    kill "$sentinel" 2>/dev/null || true
    wait "$sentinel" 2>/dev/null || true
    sentinel=''
  fi
}
agent_start_failed() {
  local reason=$1 screen=$2
  printf '%s\n%s\n' "$screen" "$reason" >> "$S/log"
  meta_set --arg reason "$reason" 'if .status=="running" then .status="start-failed" | .failure_reason=$reason else . end'
  if [ "${revived:-0}" = 1 ]; then revive_blocked "$reason"
  else "$DV_ROOT/bin/dv" kick failed "$ISSUE" "$reason"; fi
}
codex_start_failed() { agent_start_failed "$@"; }
codex_screen() {
  # Use the current viewport: history can contain dismissed trust prompts or
  # an earlier /goal. Logs still use recent-unwrapped through herdr_snapshot.
  if [ "$BACKEND" = herdr ]; then herdr_cmd pane read "$HERDR_PANE" --source visible
  else read_session; fi
}
codex_hook_trust_required() {
  printf '%s\n' "$1" | grep -Eiq 'hooks? needs? review|t[[:space:]]+trust all.*enter[[:space:]]+review'
}
codex_folder_trust_required() {
  printf '%s\n' "$1" | grep -Eiq 'trust (this|the) (folder|directory)|trusting will apply to the repository root|folder access'
}
codex_goal_pending() {
  # Match the last composer, including wrapped lines, never a transcript echo.
  # Strip whitespace on both sides because terminal wrapping can split words.
  printf '%s\n' "$1" | awk -v goal="/goal $2" '
    /^[[:space:]]*(›|❯|dv-ready>)[[:space:]]*/ {
      input=$0; sub(/^[[:space:]]*(›|❯|dv-ready>)[[:space:]]*/, "", input)
      capture=1; next
    }
    /^[[:space:]]*$/ { capture=0 }
    capture { input=input $0 }
    END { gsub(/[[:space:]]/, "", input); gsub(/[[:space:]]/, "", goal); exit(input!=goal) }
  '
}
wait_codex_goal() {
  local instruction=$1 end=$(( $(now) + DV_START_WAIT )) screen='' agent retried=0 retry_at=$(( $(now) + 1 ))
  while [ "$(now)" -lt "$end" ]; do
    if screen=$(codex_screen 2>/dev/null); then
      if codex_folder_trust_required "$screen"; then
        codex_start_failed 'codex folder trust required' "$screen"; return 1
      fi
      if codex_hook_trust_required "$screen"; then
        codex_start_failed 'codex hook trust required' "$screen"; return 1
      fi
      if codex_goal_pending "$screen" "$instruction"; then
        # Let the original submit settle; only the same pending input permits
        # one extra Enter. Never re-paste the instruction or accept a dialog.
        if [ "$retried" = 0 ] && [ "$(now)" -ge "$retry_at" ]; then
          retried=1
          session_enter || true
        fi
      elif printf '%s\n' "$screen" | grep -Eq '(^|(•|[*])[[:space:]]+)Pursuing goal([[:space:]]|$)'; then
        [ -z "${DV_AWARD_TOKEN:-}" ] || touch "$S/agent.started"
        return 0
      elif [ "$BACKEND" = herdr ] && agent=$(herdr_cmd agent get "$HERDR_PANE" 2>/dev/null) &&
        printf '%s\n' "$agent" | jq -e '.result.agent | .agent=="codex" and .agent_status=="working"' >/dev/null 2>&1; then
        [ -z "${DV_AWARD_TOKEN:-}" ] || touch "$S/agent.started"
        return 0
      fi
    fi
    sleep 0.2
  done
  codex_start_failed 'codex goal did not start' "$screen"
  return 1
}
inject_goal() {
  local instruction=$1 end=$(( $(now) + DV_START_WAIT )) pane screen=''
  while [ "$(now)" -lt "$end" ]; do
    # A prompt marker and even an agent can be present behind the hook modal.
    # If the screen cannot be read, do not send uninspected input.
    if ! screen=$(codex_screen 2>/dev/null); then sleep 0.2; continue; fi
    if codex_folder_trust_required "$screen"; then
      codex_start_failed 'codex folder trust required' "$screen"; return 1
    fi
    if codex_hook_trust_required "$screen"; then
      codex_start_failed 'codex hook trust required' "$screen"; return 1
    fi
    if [ "$BACKEND" = herdr ]; then
      # Pane history can contain an old shell prompt. Require detected Codex,
      # then let agent prompt validate foreground/readiness (0.9.1 does not
      # expose interactive_ready). A rejected submission sends no input.
      # Use one attempt per poll so blocked/unready replies share this deadline
      # instead of starting send_text's separate wait/retry budget.
      if pane=$(herdr_cmd agent get "$HERDR_PANE" 2>/dev/null) &&
        printf '%s\n' "$pane" | jq -e '.result.agent.agent=="codex"' >/dev/null 2>&1 &&
        [ "$(now)" -lt "$end" ] &&
        pane=$(herdr_cmd agent prompt "$HERDR_PANE" "/goal $instruction" 2>/dev/null) &&
        printf '%s\n' "$pane" | jq -e '.error==null and .result.type=="agent_prompted"' >/dev/null 2>&1; then
        wait_codex_goal "$instruction"; return $?
      fi
    else
      if printf '%s\n' "$screen" | grep -Eq "$DV_READY_PATTERN" && send_text "/goal $instruction"; then
        wait_codex_goal "$instruction"; return $?
      fi
    fi
    sleep 0.2
  done
  printf 'Codex prompt not detected; use dv send to submit /goal.\n' >> "$S/log"
  codex_start_failed 'Codex prompt not detected' "$screen"
  return 1
}
accept_devin_trust() {
  local end=$(( $(now) + DV_START_WAIT )) pane
  while [ "$(now)" -lt "$end" ]; do
    pane=$(read_session 2>/dev/null) || return 0
    if printf '%s\n' "$pane" | grep -Eiq 'trust (this|the) (folder|directory)|do you trust'; then
      session_enter; return
    fi
    sleep 0.2
  done
}
cmd_done() {
  [ "$#" -ge 1 ] || fail 'usage: dv done ISSUE [--note TEXT]'
  load_issue "$1"; shift; local note='' head files tmp episode own_revive=0 pr_complete=false
  if [ "$(jq -r '.kind // empty' "$S/meta")" = qa ]; then qa_done "$ISSUE"; return; fi
  if [ "$#" -gt 0 ]; then
    if [ "$#" -ne 2 ] || [ "$1" != --note ]; then fail 'expected --note TEXT'; fi
    note=$2
  fi
  require_worktree
  episode=$(jq -r '.done_episode // ""' "$S/meta")
  # Only the replacement's inherited run identity can satisfy its goal wrapper.
  if [ -n "${DV_REVIVE_ID:-}" ] && [ "$DV_REVIVE_ID" = "$(cat "$S/revive/id" 2>/dev/null)" ]; then
    episode=$DV_REVIVE_ID
    own_revive=1
  fi
  if [ "$BACKEND" = herdr ]; then
    herdr_snapshot || printf 'dv: warning: could not capture herdr log for %s\n' "$ISSUE" >&2
  fi
  if [ "$KIND" = task ]; then
    issue_lock
    task_completion
  else
    head=$(git -C "$WT" rev-parse HEAD)
    if is_github; then
      pr_done_check "$head"
      pr_complete=true
      note="checks=green review=handled${note:+; $note}"
    fi
    files=$(git -C "$WT" diff --name-only "$(jq -r .start_head "$S/meta")" "$head" | wc -l | tr -d ' ')
  fi
  if [ "$BACKEND" = appserver ]; then
    appserver_request finish >/dev/null || fail 'App Server goal completion is unconfirmed; completion was not recorded (inspect receipts before retrying)'
  fi
  tmp=$(mktemp "$S/.done.XXXXXX")
  jq -n --arg head "$head" --argjson files "$files" --arg report "$S/report.md" --arg note "$note" \
    --arg episode "$episode" --argjson done_at "$(now)" --argjson pr_complete "$pr_complete" \
    '{head:$head,files:$files,report:$report,note:$note,done_at:$done_at} +
    (if $pr_complete then {checks:"green",review:"handled"} else {} end) +
    (if $episode=="" then {} else {episode:$episode} end)' > "$tmp"
  mv "$tmp" "$S/done.json"
  metrics_note 'done' "$head"
  if [ "$BACKEND" = exec ]; then
    local run
    run=$(jq -r '.exec_run // empty' "$S/meta")
    [ -z "$run" ] || touch "$S/exec/$run/done"
  fi
  meta_set --arg head "$head" --arg episode "$episode" --argjson done_at "$(now)" --argjson pr_complete "$pr_complete" '.head=$head | .done_at=$done_at |
    (if $episode!="" then .done_episode=$episode else . end) |
    if $pr_complete then .status="ready"
    elif .status=="running" or .status=="start-failed" then .status="done" | del(.failure_reason) else . end'
  cmd_kick 'done' "$ISSUE" "$note"
  if [ "$own_revive" = 1 ]; then
    printf '%s\n' "$episode" > "$S/revive/done"
  fi
}
cmd_kick() {
  [ "$#" -ge 2 ] || fail 'usage: dv kick kind ISSUE [message]'
  local kind=$1 issue=$2 message=${3:-} head='' host=$DV_HOST rc=0 line remote event_id event_time token=${DV_AWARD_TOKEN:-} episode=''
  valid_issue "$issue"; mkdir -p "$DV_STATE/$issue"
  if [ -f "$DV_STATE/$issue/meta" ]; then
    head=$(jq -r '.head // .start_head' "$DV_STATE/$issue/meta")
    host=$(jq -r .host "$DV_STATE/$issue/meta")
    [ -n "$token" ] || token=$(jq -r '.award_token // ""' "$DV_STATE/$issue/meta")
    if [ "$kind" = 'done' ]; then episode=$(jq -r '.done_episode // ""' "$DV_STATE/$issue/meta"); fi
  fi
  case "$kind" in
    failed|blocked) episode=$(cat "$DV_STATE/$issue/revive/id" 2>/dev/null) || episode='' ;;
  esac
  line=$(event_json "$kind" "$issue" "$message" "$host" "$head" '' "$token" "$episode")
  event_id=$(printf '%s\n' "$line" | jq -r .id)
  event_time=$(printf '%s\n' "$line" | jq -r .time)
  if [ -z "$DV_KICK" ] && [ "$DV_KICK_HOST" = "$DV_HOST" ]; then
    # The watcher lives on this host: write to the local queue, no ssh to ourselves.
    dv-kick "$kind" "$issue" "$message" "$host" "$head" "$event_id" "$token" "$event_time" >> "$DV_STATE/$issue/kick.log" 2>&1 || rc=$?
  elif [ -n "$DV_KICK" ]; then
    bash -c "$DV_KICK \"\$@\"" dv-kick "$kind" "$issue" "$message" "$host" "$head" "$event_id" "$token" "$event_time" >> "$DV_STATE/$issue/kick.log" 2>&1 || rc=$?
  else
    # The remote shell often lacks ~/.local/bin: use the installed path explicitly.
    remote=$(shell_join bash -lc "PATH=\$HOME/.local/bin:\$PATH $(shell_join dv-kick "$kind" "$issue" "$message" "$host" "$head" "$event_id" "$token" "$event_time")")
    ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$DV_KICK_HOST" "$remote" >> "$DV_STATE/$issue/kick.log" 2>&1 || rc=$?
  fi
  printf '%s\n' "$line" | jq -c --argjson rc "$rc" '. + {delivered:($rc==0),exit:$rc}' >> "$DV_STATE/$issue/events.log"
  return 0
}
cmd_status() {
  local selected='' json=0 path row alive last live_last elapsed backend pane info agent_status tmux_alive question_pending pending record done_head
  local goal_stalled goal_active goal_state screen agent_state_seq agent_session agent_dead
  for path in "$@"; do case "$path" in --json) json=1 ;; *) [ -z "$selected" ] || fail 'one issue only'; valid_issue "$path"; selected=$path ;; esac; done
  if [ -n "$selected" ]; then [ -f "$DV_STATE/$selected/meta" ] || fail 'unknown issue'; fi
  {
    for path in "$DV_STATE"/*/meta; do
      [ -f "$path" ] || continue
      [ -z "$selected" ] || [ "$(basename "$(dirname "$path")")" = "$selected" ] || continue
      alive=false; tmux_alive=false; agent_status=unknown; question_pending=false
      agent_dead=false
      goal_stalled=false; goal_active=false; agent_state_seq=null; agent_session=null
      backend=$(jq -r '.backend // "tmux"' "$path")
      # tmux captures share one line and can be tens of KB: keep status cheap and argv-safe.
      last=$(tail -n 1 "$(dirname "$path")/log" 2>/dev/null | sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b\][^\x07]*\x07//g' | tail -c 200 | tr -d '\000-\010\013\014\016-\037\r' || true)
      if [ "$backend" = appserver ]; then
        info=$(appserver_status "$(jq -r .issue "$path")")
        agent_status=$(printf '%s\n' "$info" | jq -r .agent_status)
        alive=$(printf '%s\n' "$info" | jq -r .alive)
        question_pending=$(printf '%s\n' "$info" | jq -r .question_pending)
      elif [ "$backend" = exec ]; then
        if codex_exec_alive "$(dirname "$path")"; then alive=true; fi
        agent_status=$(codex_exec_status "$(dirname "$path")")
        last=$(tail -n 1 "$(dirname "$path")/agent.jsonl" 2>/dev/null | tail -c 200 || true)
      elif [ "$backend" = qa ]; then
        if codex_exec_alive "$(dirname "$path")"; then alive=true; fi
        agent_status=$(jq -r .status "$path")
      elif [ "$backend" = herdr ]; then
        pane=$(jq -r '.herdr_pane // empty' "$path")
        if [ -n "$pane" ]; then
          info=$(herdr_info "$pane" 2>/dev/null) || info='{}'
          agent_status=$(printf '%s\n' "$info" | jq -r '.agent_status // "unknown"')
          agent_state_seq=$(printf '%s\n' "$info" | jq -c '.state_change_seq // null')
          agent_session=$(printf '%s\n' "$info" | jq -c '.agent_session // null')
          # A live pane may be running a custom command with no detected agent.
          alive=$(printf '%s\n' "$info" | jq -r '.pane_id!=null')
          pending="$(dirname "$path")/question.pending"
          if [ -f "$pending" ] && kill -0 "$(jq -r .owner "$pending")" 2>/dev/null; then
            if jq -e '((.keys // [])|length)>0 or (.key // "")!=""' "$pending" >/dev/null; then
              record=$(herdr_question_record "$(printf '%s\n' "$info" | jq '{result:{agent:.}}')") || record='[]'
              if printf '%s\n' "$record" | jq -e --slurpfile pending "$pending" 'any(.[]; .key as $key | ($pending[0].keys // [$pending[0].key]) | index($key)!=null)' >/dev/null 2>&1; then question_pending=true; fi
            elif [ "$agent_status" = blocked ] &&
              printf '%s\n' "$info" | jq -e --slurpfile pending "$pending" '.state_change_seq==$pending[0].seq' >/dev/null 2>&1; then question_pending=true; fi
          fi
          if live_last=$(herdr_read "$pane" --lines 1 2>/dev/null); then
            last=$(printf '%s\n' "$live_last" | tail -n 1 | tail -c 200 | tr -d '\000-\010\013\014\016-\037\r')
          fi
        fi
      elif command -v tmux >/dev/null && tmux_dv has-session -t "=dv-$(jq -r .issue "$path")" 2>/dev/null; then
        alive=true; tmux_alive=true
      fi
      if { [ "$backend" = tmux ] || [ "$backend" = herdr ]; } && [ "$agent_status" = unknown ] && jq -e '.status=="running"' "$path" >/dev/null &&
        (load_issue "$(jq -r .issue "$path")"; agent_gone); then
        agent_dead=true
      fi
      if { [ "$backend" = tmux ] || [ "$backend" = herdr ]; } && [ "$alive" = true ] && [ "$agent_dead" = false ] && jq -e '.status=="running" and .agent=="codex"' "$path" >/dev/null; then
        screen=''
        if [ "$backend" = herdr ]; then
          screen=$(herdr_cmd pane read "$pane" --source visible 2>/dev/null) || screen=''
        else
          screen=$(tmux_dv capture-pane -p -t "dv-$(jq -r .issue "$path"):0.0" 2>/dev/null) || screen=''
        fi
        # The most recent visible goal banner wins if the old one is still on
        # screen. Explicit activity also resets a tmux stall (no herdr hooks).
        # Keep multibyte markers outside bracket expressions for LC_ALL=C.
        goal_state=$(printf '%s\n' "$screen" | awk '
          /[Mm]odel is at capacity/ { state="stalled" }
          /^([[:space:]]|│|┃)*((•|[*])[[:space:]]+)?Goal stalled([[:space:]:]|$)/ { state="stalled" }
          /^([[:space:]]|│|┃)*((•|[*])[[:space:]]+)?(Pursuing goal|Working)([[:space:]:.]|$)/ { state="active" }
          END { print state }')
        case "$goal_state" in stalled) goal_stalled=true ;; active) goal_active=true ;; esac
      fi
      elapsed=$(( $(now) - $(jq -r .started "$path") ))
      # done_at can describe an earlier PR revision. Read the completion head
      # without changing metadata or the bidding code's historical done_at.
      done_head=$(jq -r '.head | select(type=="string")' "$(dirname "$path")/done.json" 2>/dev/null) || done_head=''
      row=$(jq -c --arg done_head "$done_head" --arg backend "$backend" --arg agent_status "$agent_status" --argjson alive "$alive" --argjson tmux "$tmux_alive" --argjson elapsed "$elapsed" --argjson question_pending "$question_pending" --arg last "$last" \
        --argjson goal_stalled "$goal_stalled" --argjson goal_active "$goal_active" --argjson agent_state_seq "$agent_state_seq" --argjson agent_session "$agent_session" --argjson agent_dead "$agent_dead" \
        '.+{done_head:(if $done_head=="" then null else $done_head end),backend:$backend,alive:$alive,agent_status:$agent_status,agent_dead:$agent_dead,tmux:$tmux,elapsed:$elapsed,last_log:$last,question_pending:$question_pending,goal_stalled:$goal_stalled,goal_active:$goal_active,agent_state_seq:$agent_state_seq,agent_session:$agent_session}' "$path")
      if [ "$backend" = appserver ]; then row=$(printf '%s\n%s\n' "$row" "$info" | jq -sc '.[0] + {appserver:.[1],recoveries:.[1].recoveries,last_recovery_reason:.[1].last_recovery_reason}'); fi
      if [ "$backend" = exec ] && [ "$alive" = false ] && [ "$agent_status" = failed ]; then
        row=$(printf '%s\n' "$row" | jq -c 'if .status=="running" then .status="failed" else . end')
      fi
      if [ "$json" = 1 ]; then printf '%s\n' "$row"
      else printf '%s\n' "$row" | jq -r '[.issue,.status,.agent,.host,(.elapsed|tostring)+"s",("backend="+.backend),"alive="+(.alive|tostring),"agent="+.agent_status,"tmux="+(.tmux|tostring),(if .backend=="appserver" then "recoveries="+(.recoveries|tostring),"last_recovery_reason="+(.last_recovery_reason // "none") else empty end),(.last_log|gsub("[\\r\\n\\t]";" "))]|join("\t")'; fi
    done
  } | if [ "$json" = 1 ]; then jq -s .; else cat; fi
}
agent_gone() {
  local reply pane pid unknown=0
  REVIVE_PANE_EXISTS=0
  if [ "$BACKEND" = tmux ]; then
    if pane=$(tmux_dv list-panes -t "$SESSION:0" -F '#{pane_index} #{pane_dead}' 2>/dev/null); then
      printf '%s\n' "$pane" | grep -qx '0 1'
    else
      # A session lookup also guards against a missing window in a live session.
      ! tmux_dv has-session -t "=$SESSION" 2>/dev/null
    fi
    return
  fi
  # Absence must be confirmed by a structured server reply, not a timeout or
  # transport error. An undetected custom command can still be running.
  if reply=$(herdr_cmd agent get "$HERDR_PANE" 2>&1); then
    # A cached identity in unknown state is not evidence of a live process.
    printf '%s\n' "$reply" | jq -e '.result.agent.agent_status=="unknown"' >/dev/null 2>&1 || return 1
    unknown=1
  else
    printf '%s\n' "$reply" | jq -e '.error.code=="agent_not_found"' >/dev/null 2>&1 || return 1
  fi
  if pane=$(herdr_cmd pane get "$HERDR_PANE" 2>&1); then
    printf '%s\n' "$pane" | jq -e '.result.pane.pane_id!=null' >/dev/null 2>&1 || return 1
    REVIVE_PANE_EXISTS=1
  else
    printf '%s\n' "$pane" | jq -e '.error.code=="pane_not_found"' >/dev/null 2>&1 || return 1
  fi
  if [ "$unknown" = 1 ]; then
    [ "$REVIVE_PANE_EXISTS" = 1 ] && herdr_shell_only "$HERDR_PANE" || return 1
  fi
  # A removed pane can leave its wrapper alive. Require process evidence for
  # both pane paths; terminal disappearance alone cannot authorize a duplicate.
  if [ -f "$S/agent.pid" ]; then
    pid=$(cat "$S/agent.pid")
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    ! kill -0 "$pid" 2>/dev/null
  elif [ -f "$S/agent.exit" ]; then return 0
  elif [ "$REVIVE_PANE_EXISTS" = 1 ]; then
    # Legacy jobs have no wrapper records. Detection alone is insufficient:
    # require an authoritative shell-only foreground process snapshot.
    herdr_shell_only "$HERDR_PANE"
  else return 1; fi
}
revive_blocked() {
  # Both the startup helper and the wrapper can observe the same failure.
  if mkdir "$S/revive/blocked" 2>/dev/null; then
    cmd_kick blocked "$ISSUE" "$1; automatic revival already attempted"
  fi
  # Startup helpers can report before the wrapper exits. Notify the scheduler
  # only after agent.exit makes the slot available, once for this revival.
  if [ -f "$S/agent.exit" ] && mkdir "$S/revive/failed" 2>/dev/null; then
    cmd_kick failed "$ISSUE" "$1; automatic revival already attempted"
  fi
  printf 'dv: %s; automatic revival already attempted\n' "$1" >&2
}
revive_agent() {
  require_worktree
  case "$(jq -r .status "$S/meta")" in landed|cancelled) fail 'cannot revive a finished issue' ;; esac
  if [ -d "$S/revive" ]; then
    revive_blocked 'agent unavailable after revival'
    return 1
  fi
  mkdir "$S/revive" || return 1
  printf '%s\n' "$(now):$$:$RANDOM" > "$S/revive/id"
  # Keep the previous completion and review-fix.sent intact. The new wrapper
  # checks its own completion marker, including report-only fixes at the same SHA.
  local file
  for file in agent.exit agent.pid done.json; do
    [ ! -f "$S/$file" ] || cp "$S/$file" "$S/revive/previous-$file"
  done
  {
    printf '%s\n\n' "$1"
    if [ "$KIND" = task ]; then
      printf 'Continue the task in %s; preserve partial work and write deliverables to out/. No Git or PR.\n' "$WT"
    else
      printf 'Continue in the existing worktree %s on branch %s.\n' "$WT" "$BRANCH"
    fi
    printf 'Read %s/brief.md and, if present, %s/report.md for context.\n' "$S" "$S"
    printf 'This continues the same request; preserve %s/review-fix.sent and the one-fix-per-PR limit.\n' "$S"
    printf 'Do not create a new branch or force push. Finish with dv done %s.\n' "$ISSUE"
  } > "$S/revive/prompt.md"
  # Cleanup belongs to the previous run. Publish this before launching so all
  # capacity, metrics and disk readers observe the revived lifecycle.
  meta_set 'del(.cleaned_at)'
  rm -f "$S/agent.exit" "$S/agent.pid"
  metrics_note revive
  if ! launch_agent --revived; then
    printf '1\n' > "$S/agent.exit"
    revive_blocked 'could not start revived agent'
    return 1
  fi
  printf 'dv: revived %s in %s\n' "$ISSUE" "$WT"
}
cmd_send() {
  [ "$#" -eq 2 ] || fail 'usage: dv send ISSUE text'
  load_issue "$1"; issue_lock; require_worktree
  if [ "$BACKEND" = appserver ]; then appserver_request send "$2"; return; fi
  if [ "$BACKEND" = exec ]; then codex_exec_send "$2"; return; fi
  # tmux can accept paste/Enter even when remain-on-exit retained a dead pane.
  if [ "$BACKEND" = tmux ] && agent_gone; then revive_agent "$2"; return; fi
  if send_text "$2"; then metrics_note resume; return 0; fi
  if agent_gone; then revive_agent "$2"; else return 1; fi
}
cmd_clean() {
  [ "$#" -eq 1 ] || fail 'usage: dv clean ISSUE'; load_issue "$1"; issue_lock
  clean_worktree
  meta_set --argjson time "$(now)" '.cleaned_at=$time'
}
clean_worktree() {
  if [ -d "$WT" ]; then require_worktree; require_clean "$WT"; fi
  if [ "$BACKEND" = appserver ]; then
    [ "${1:-}" = merged-pr ] || appserver_require_idle
    if appserver_alive; then kill "$(cat "$S/appserver/client.pid")"; fi
    if [ "${1:-}" = merged-pr ]; then
      local deadline
      deadline=$(( $(now) + DV_APPSERVER_TIMEOUT ))
      while appserver_alive; do
        [ "$(now)" -lt "$deadline" ] || fail 'App Server client did not stop; worktree retained'
        sleep 0.1
      done
      # The client may have written files after the initial clean check.
      if [ -d "$WT" ]; then require_clean "$WT"; fi
    fi
  elif [ "$BACKEND" = exec ]; then
    ! codex_exec_alive "$S" || fail 'exec is still running; worktree retained'
  elif [ "$BACKEND" = herdr ]; then
    herdr_clean || fail 'herdr workspace not closed; worktree and saved id retained'
  else tmux_dv kill-session -t "=$SESSION" 2>/dev/null || true; fi
  if [ -d "$WT" ]; then (cd "$REPO" && git worktree remove "$WT"); fi
  if git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH" && git -C "$REPO" merge-base --is-ancestor "$BRANCH" "$BASE"; then
    git -C "$REPO" branch -d "$BRANCH"
  fi
}
