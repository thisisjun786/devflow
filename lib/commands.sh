#!/usr/bin/env bash
# BASE is populated by load_issue in common.sh. jq filters intentionally use literal $.
# shellcheck disable=SC2153,SC2016
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
  case "$mode" in goal|exec) ;; *) fail 'mode must be goal or exec' ;; esac
  [ "$agent" = codex ] || [ "$mode" = goal ] || fail 'exec mode is Codex-only'
  [ -z "$brief" ] || [ -f "$brief" ] || fail 'brief file not found'
  need git; need jq
  BACKEND=tmux
  if [ "$DV_HERDR" != 0 ] && herdr_bin >/dev/null; then BACKEND=herdr; else need tmux; fi
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
  mkdir "$S" || fail 'issue was started concurrently'
  git -C "$REPO" worktree add -b "$BRANCH" "$WT" "$start_sha"
  cat "$DV_ROOT/templates/rules.md" > "$S/brief.md"
  printf '\nIssue: %s\nWorktree: %s\nReport: %s/report.md\n\n' "$ISSUE" "$WT" "$S" >> "$S/brief.md"
  if [ -n "$brief" ]; then cat "$brief" >> "$S/brief.md"; else printf 'Complete issue %s.\n' "$ISSUE" >> "$S/brief.md"; fi
  jq -n --arg issue "$ISSUE" --arg repo "$REPO" --arg worktree "$WT" --arg branch "$BRANCH" \
    --arg base "$base" --arg start_head "$start_sha" --arg agent "$agent" --arg mode "$mode" --arg slug "$slug" \
    --arg host "$DV_HOST" --arg backend "$BACKEND" --argjson started "$(now)" \
    '{issue:$issue,repo:$repo,worktree:$worktree,branch:$branch,base:$base,start_head:$start_head,agent:$agent,mode:$mode,slug:$slug,host:$host,started:$started,backend:$backend,status:"running"}' > "$S/meta"
  : > "$S/log"
  # Terminal server environments can predate this shell. Pass exported DV_* values explicitly.
  local env_args=() key launcher
  while IFS= read -r key; do
    case "$key" in DV_*|GH_STUB_DIR|CASE_DIR|GIT_CONFIG_*|GIT_TERMINAL_PROMPT) env_args+=("$key=${!key}") ;; esac
  done < <(compgen -e)
  launcher=$(shell_join env "PATH=$PATH" "${env_args[@]}" "$DV_ROOT/bin/dv" _agent "$ISSUE")
  if [ "$BACKEND" = herdr ]; then
    if ! herdr_start "$launcher"; then
      meta_set '.status="start-failed"'
      fail 'herdr startup failed; state retained for dv clean (no tmux fallback)'
    fi
  else tmux_dv new-session -d -s "$SESSION" -c "$WT" "$launcher"; fi
  printf '%s %s %s\n' "$ISSUE" "$BRANCH" "$WT"
}
run_agent() {
  load_issue "$1"; require_worktree; cd "$WT" || exit
  export DV_ISSUE="$ISSUE"
  local agent mode override instruction rc=0 sentinel='' helper=''
  agent=$(jq -r .agent "$S/meta"); mode=$(jq -r .mode "$S/meta")
  override="DV_AGENT_CMD_$agent"; override=${!override}
  instruction="Read $S/brief.md and complete everything it asks. Finish with dv done $ISSUE."
  # Native herdr snapshots are collected at done/clean; tmux keeps its TTY log.
  if [ "$BACKEND" = tmux ]; then
    tmux_dv pipe-pane -o -t "$SESSION:0.0" "cat >> $(shell_join "$S/log")"
  else
    [[ "$DV_BLOCKED_GRACE" =~ ^[1-9][0-9]*$ ]] || fail 'DV_BLOCKED_GRACE must be a positive integer'
    herdr_question_sentinel & sentinel=$!
    trap 'stop_question_sentinel' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
  fi
  if [ -n "$override" ]; then
    bash -c "$override" || rc=$?
  else
    local args=()
    case "$agent" in
      codex)
        args=("$DV_CODEX_BIN" -m "$DV_CODEX_MODEL" -c "model_reasoning_effort=\"$DV_CODEX_EFFORT\"" -s danger-full-access -a never)
        args+=(-c tools.experimental_request_user_input.enabled=false)
        args+=(-c "projects.$(jq -Rn --arg path "$WT" '$path').trust_level=\"trusted\"")
        # Codex resolves a linked worktree's trust against the original repo.
        args+=(-c "projects.$(jq -Rn --arg path "$REPO" '$path').trust_level=\"trusted\"")
        if [ "$BACKEND" = tmux ] && [ "$DV_CODEX_DISABLE_HOOKS" = 1 ]; then args+=(--disable hooks); fi
        [ "$DV_CODEX_DISABLE_CRW" != 1 ] || args+=(-c 'plugins."crw@crw".enabled=false')
        if [ "$mode" = exec ]; then "${args[@]}" exec "$instruction" || rc=$?
        else
          inject_goal "$instruction" & helper=$!
          "${args[@]}" || rc=$?
          stop_question_sentinel
          wait "$helper" || true
        fi ;;
      claude) "$DV_CLAUDE_BIN" --model "$DV_CLAUDE_MODEL" --effort "$DV_CLAUDE_EFFORT" --dangerously-skip-permissions --disallowedTools AskUserQuestion -- "$instruction" || rc=$? ;;
      devin)
        accept_devin_trust & helper=$!
        "$DV_DEVIN_BIN" --model "$DV_DEVIN_MODEL" --permission-mode dangerous -- "$instruction" || rc=$?
        stop_question_sentinel
        wait "$helper" || true ;;
    esac
  fi
  stop_question_sentinel
  trap - EXIT INT TERM
  printf '%s\n' "$rc" > "$S/agent.exit"
  if [ "$mode" = exec ]; then
    if [ "$rc" -eq 0 ]; then "$DV_ROOT/bin/dv" 'done' "$ISSUE"
    else "$DV_ROOT/bin/dv" kick failed "$ISSUE" "agent exited $rc"; fi
  fi
  return "$rc"
}
stop_question_sentinel() {
  if [ -n "$sentinel" ]; then
    kill "$sentinel" 2>/dev/null || true
    wait "$sentinel" 2>/dev/null || true
    sentinel=''
  fi
}
codex_start_failed() {
  local reason=$1 screen=$2
  printf '%s\n%s\n' "$screen" "$reason" >> "$S/log"
  meta_set --arg reason "$reason" 'if .status=="running" then .status="start-failed" | .failure_reason=$reason else . end'
  "$DV_ROOT/bin/dv" kick failed "$ISSUE" "$reason"
}
codex_screen() {
  # Use the current viewport: history can contain dismissed trust prompts or
  # an earlier /goal. Logs still use recent-unwrapped through herdr_snapshot.
  if [ "$BACKEND" = herdr ]; then herdr_cmd pane read "$HERDR_PANE" --source visible
  else read_session; fi
}
codex_hook_trust_required() {
  printf '%s\n' "$1" | grep -Eiq 'hooks? needs? review|t[[:space:]]+trust all.*enter[[:space:]]+review'
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
      elif printf '%s\n' "$screen" | grep -Eq '(^|[•*][[:space:]]+)Pursuing goal([[:space:]]|$)'; then return 0
      elif [ "$BACKEND" = herdr ] && agent=$(herdr_cmd agent get "$HERDR_PANE" 2>/dev/null) &&
        printf '%s\n' "$agent" | jq -e '.result.agent | .agent=="codex" and .agent_status=="working"' >/dev/null 2>&1; then return 0; fi
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
  load_issue "$1"; shift; local note='' head files tmp
  if [ "$#" -gt 0 ]; then
    if [ "$#" -ne 2 ] || [ "$1" != --note ]; then fail 'expected --note TEXT'; fi
    note=$2
  fi
  require_worktree
  if [ "$BACKEND" = herdr ]; then
    herdr_snapshot || printf 'dv: warning: could not capture herdr log for %s\n' "$ISSUE" >&2
  fi
  head=$(git -C "$WT" rev-parse HEAD)
  files=$(git -C "$WT" diff --name-only "$(jq -r .start_head "$S/meta")" "$head" | wc -l | tr -d ' ')
  tmp=$(mktemp "$S/.done.XXXXXX")
  jq -n --arg head "$head" --argjson files "$files" --arg report "$S/report.md" --arg note "$note" \
    --argjson done_at "$(now)" '{head:$head,files:$files,report:$report,note:$note,done_at:$done_at}' > "$tmp"
  mv "$tmp" "$S/done.json"
  meta_set --arg head "$head" --argjson done_at "$(now)" '.head=$head | .done_at=$done_at | if .status=="running" or .status=="start-failed" then .status="done" | del(.failure_reason) else . end'
  cmd_kick 'done' "$ISSUE" "$note"
}
cmd_kick() {
  [ "$#" -ge 2 ] || fail 'usage: dv kick kind ISSUE [message]'
  local kind=$1 issue=$2 message=${3:-} head='' host=$DV_HOST rc=0 line remote episode=''
  valid_issue "$issue"; mkdir -p "$DV_STATE/$issue"
  if [ -f "$DV_STATE/$issue/meta" ]; then
    head=$(jq -r '.head // .start_head' "$DV_STATE/$issue/meta")
    host=$(jq -r .host "$DV_STATE/$issue/meta")
  fi
  if [ "$kind" = question ]; then episode=${DV_QUESTION_EPISODE:-$(now):$$:$RANDOM}; fi
  line=$(event_json "$kind" "$issue" "$message" "$host" "$head" "$episode")
  if [ -z "$DV_KICK" ] && [ "$DV_KICK_HOST" = "$DV_HOST" ]; then
    # The watcher lives on this host: write to the local queue, no ssh to ourselves.
    dv-kick "$kind" "$issue" "$message" "$host" "$head" "$episode" >> "$DV_STATE/$issue/kick.log" 2>&1 || rc=$?
  elif [ -n "$DV_KICK" ]; then
    bash -c "$DV_KICK \"\$@\"" dv-kick "$kind" "$issue" "$message" "$host" "$head" "$episode" >> "$DV_STATE/$issue/kick.log" 2>&1 || rc=$?
  else
    # The remote shell often lacks ~/.local/bin: use the installed path explicitly.
    remote=$(shell_join bash -lc "PATH=\$HOME/.local/bin:\$PATH $(shell_join dv-kick "$kind" "$issue" "$message" "$host" "$head" "$episode")")
    ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$DV_KICK_HOST" "$remote" >> "$DV_STATE/$issue/kick.log" 2>&1 || rc=$?
  fi
  printf '%s\n' "$line" | jq -c --argjson rc "$rc" '. + {delivered:($rc==0),exit:$rc}' >> "$DV_STATE/$issue/events.log"
  return 0
}
cmd_status() {
  local selected='' json=0 path row alive last live_last elapsed backend pane info agent_status tmux_alive question_pending pending
  for path in "$@"; do case "$path" in --json) json=1 ;; *) [ -z "$selected" ] || fail 'one issue only'; valid_issue "$path"; selected=$path ;; esac; done
  if [ -n "$selected" ]; then [ -f "$DV_STATE/$selected/meta" ] || fail 'unknown issue'; fi
  {
    for path in "$DV_STATE"/*/meta; do
      [ -f "$path" ] || continue
      [ -z "$selected" ] || [ "$(basename "$(dirname "$path")")" = "$selected" ] || continue
      alive=false; tmux_alive=false; agent_status=unknown; question_pending=false
      backend=$(jq -r '.backend // "tmux"' "$path")
      # tmux captures share one line and can be tens of KB: keep status cheap and argv-safe.
      last=$(tail -n 1 "$(dirname "$path")/log" 2>/dev/null | sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\x1b\][^\x07]*\x07//g' | tail -c 200 | tr -d '\000-\010\013\014\016-\037\r' || true)
      if [ "$backend" = herdr ]; then
        pane=$(jq -r '.herdr_pane // empty' "$path")
        if [ -n "$pane" ]; then
          info=$(herdr_info "$pane" 2>/dev/null) || info='{}'
          agent_status=$(printf '%s\n' "$info" | jq -r '.agent_status // "unknown"')
          # A live pane may be running a custom command with no detected agent.
          alive=$(printf '%s\n' "$info" | jq -r '.pane_id!=null')
          pending="$(dirname "$path")/question.pending"
          if [ "$agent_status" = blocked ] && [ -f "$pending" ] &&
            printf '%s\n' "$info" | jq -e --slurpfile pending "$pending" '.state_change_seq==$pending[0].seq' >/dev/null 2>&1 &&
            kill -0 "$(jq -r .owner "$pending")" 2>/dev/null; then question_pending=true; fi
          if live_last=$(herdr_read "$pane" --lines 1 2>/dev/null); then
            last=$(printf '%s\n' "$live_last" | tail -n 1 | tail -c 200 | tr -d '\000-\010\013\014\016-\037\r')
          fi
        fi
      elif command -v tmux >/dev/null && tmux_dv has-session -t "=dv-$(jq -r .issue "$path")" 2>/dev/null; then
        alive=true; tmux_alive=true
      fi
      elapsed=$(( $(now) - $(jq -r .started "$path") ))
      row=$(jq -c --arg backend "$backend" --arg agent_status "$agent_status" --argjson alive "$alive" --argjson tmux "$tmux_alive" --argjson elapsed "$elapsed" --argjson question_pending "$question_pending" --arg last "$last" '.+{backend:$backend,alive:$alive,agent_status:$agent_status,tmux:$tmux,elapsed:$elapsed,last_log:$last,question_pending:$question_pending}' "$path")
      if [ "$json" = 1 ]; then printf '%s\n' "$row"
      else printf '%s\n' "$row" | jq -r '[.issue,.status,.agent,.host,(.elapsed|tostring)+"s",("backend="+.backend),"alive="+(.alive|tostring),"agent="+.agent_status,"tmux="+(.tmux|tostring),(.last_log|gsub("[\\r\\n\\t]";" "))]|join("\t")'; fi
    done
  } | if [ "$json" = 1 ]; then jq -s .; else cat; fi
}
cmd_send() { [ "$#" -eq 2 ] || fail 'usage: dv send ISSUE text'; load_issue "$1"; send_text "$2"; }
cmd_clean() {
  [ "$#" -eq 1 ] || fail 'usage: dv clean ISSUE'; load_issue "$1"; issue_lock
  clean_worktree
}
clean_worktree() {
  if [ -d "$WT" ]; then require_worktree; require_clean "$WT"; fi
  if [ "$BACKEND" = herdr ]; then
    herdr_clean || fail 'herdr workspace not closed; worktree and saved id retained'
  else tmux_dv kill-session -t "=$SESSION" 2>/dev/null || true; fi
  if [ -d "$WT" ]; then (cd "$REPO" && git worktree remove "$WT"); fi
  if git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH" && git -C "$REPO" merge-base --is-ancestor "$BRANCH" "$BASE"; then
    git -C "$REPO" branch -d "$BRANCH"
  fi
}
