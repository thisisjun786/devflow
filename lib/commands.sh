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
  need git; need jq; need tmux
  mkdir -p "$DV_STATE" "$DV_WORK"
  S="$DV_STATE/$ISSUE"; SESSION="dv-$ISSUE"
  [ ! -e "$S" ] || fail 'issue state already exists'
  ! tmux_dv has-session -t "=$SESSION" 2>/dev/null || fail 'tmux session already exists'
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
    --arg host "$DV_HOST" --argjson started "$(now)" \
    '{issue:$issue,repo:$repo,worktree:$worktree,branch:$branch,base:$base,start_head:$start_head,agent:$agent,mode:$mode,slug:$slug,host:$host,started:$started,status:"running"}' > "$S/meta"
  : > "$S/log"
  # tmux server environment can predate this shell. Pass the task's exported DV_* values explicitly.
  local env_args=() key launcher
  while IFS= read -r key; do
    case "$key" in DV_*|GH_STUB_DIR|CASE_DIR|GIT_CONFIG_*|GIT_TERMINAL_PROMPT) env_args+=("$key=${!key}") ;; esac
  done < <(compgen -e)
  launcher=$(shell_join env "PATH=$PATH" "${env_args[@]}" "$DV_ROOT/bin/dv" _agent "$ISSUE")
  tmux_dv new-session -d -s "$SESSION" -c "$WT" "$launcher"
  printf '%s %s %s\n' "$ISSUE" "$BRANCH" "$WT"
}
run_agent() {
  load_issue "$1"; require_worktree; cd "$WT" || exit
  export DV_ISSUE="$ISSUE"
  local agent mode override instruction rc=0
  agent=$(jq -r .agent "$S/meta"); mode=$(jq -r .mode "$S/meta")
  override="DV_AGENT_CMD_$agent"; override=${!override}
  instruction="Read $S/brief.md and complete everything it asks. Finish with dv done $ISSUE."
  # pipe-pane preserves a real TTY for interactive agents.
  tmux_dv pipe-pane -o -t "$SESSION:0.0" "cat >> $(shell_join "$S/log")"
  if [ -n "$override" ]; then
    bash -c "$override" || rc=$?
  else
    local args=()
    case "$agent" in
      codex)
        args=("$DV_CODEX_BIN" -m "$DV_CODEX_MODEL" -c "model_reasoning_effort=\"$DV_CODEX_EFFORT\"" -s danger-full-access -a never)
        args+=(-c "projects.$(jq -Rn --arg path "$WT" '$path').trust_level=\"trusted\"")
        [ "$DV_CODEX_DISABLE_HOOKS" != 1 ] || args+=(--disable hooks)
        [ "$DV_CODEX_DISABLE_CRW" != 1 ] || args+=(-c 'plugins."crw@crw".enabled=false')
        if [ "$mode" = exec ]; then "${args[@]}" exec "$instruction" || rc=$?
        else
          inject_goal "$instruction" &
          "${args[@]}" || rc=$?
          wait || true
        fi ;;
      claude) "$DV_CLAUDE_BIN" --model "$DV_CLAUDE_MODEL" --effort "$DV_CLAUDE_EFFORT" --dangerously-skip-permissions "$instruction" || rc=$? ;;
      devin)
        accept_devin_trust &
        "$DV_DEVIN_BIN" --model "$DV_DEVIN_MODEL" --permission-mode dangerous -- "$instruction" || rc=$?
        wait || true ;;
    esac
  fi
  printf '%s\n' "$rc" > "$S/agent.exit"
  if [ "$mode" = exec ]; then
    if [ "$rc" -eq 0 ]; then "$DV_ROOT/bin/dv" 'done' "$ISSUE"
    else "$DV_ROOT/bin/dv" kick failed "$ISSUE" "agent exited $rc"; fi
  fi
  return "$rc"
}
inject_goal() {
  local instruction=$1 end=$(( $(now) + DV_START_WAIT )) pane
  while [ "$(now)" -lt "$end" ]; do
    pane=$(tmux_dv capture-pane -p -t "$SESSION:0.0" 2>/dev/null) || return 1
    if printf '%s\n' "$pane" | grep -Eq "$DV_READY_PATTERN"; then send_text "/goal $instruction"; return; fi
    sleep 0.2
  done
  printf 'Codex prompt not detected; use dv send to submit /goal.\n' >> "$S/log"
  "$DV_ROOT/bin/dv" kick failed "$ISSUE" 'Codex prompt not detected'
}
accept_devin_trust() {
  local end=$(( $(now) + DV_START_WAIT )) pane
  while [ "$(now)" -lt "$end" ]; do
    pane=$(tmux_dv capture-pane -p -t "$SESSION:0.0" 2>/dev/null) || return 0
    if printf '%s\n' "$pane" | grep -Eiq 'trust (this|the) (folder|directory)|do you trust'; then
      tmux_dv send-keys -t "$SESSION:0.0" Enter; return
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
  head=$(git -C "$WT" rev-parse HEAD)
  files=$(git -C "$WT" diff --name-only "$(jq -r .start_head "$S/meta")" "$head" | wc -l | tr -d ' ')
  tmp=$(mktemp "$S/.done.XXXXXX")
  jq -n --arg head "$head" --argjson files "$files" --arg report "$S/report.md" --arg note "$note" \
    --argjson done_at "$(now)" '{head:$head,files:$files,report:$report,note:$note,done_at:$done_at}' > "$tmp"
  mv "$tmp" "$S/done.json"
  meta_set --arg head "$head" --argjson done_at "$(now)" '.head=$head | .done_at=$done_at | if .status=="running" then .status="done" else . end'
  cmd_kick 'done' "$ISSUE" "$note"
}
cmd_kick() {
  [ "$#" -ge 2 ] || fail 'usage: dv kick kind ISSUE [message]'
  local kind=$1 issue=$2 message=${3:-} head='' host=$DV_HOST rc=0 line remote
  valid_issue "$issue"; mkdir -p "$DV_STATE/$issue"
  if [ -f "$DV_STATE/$issue/meta" ]; then
    head=$(jq -r '.head // .start_head' "$DV_STATE/$issue/meta")
    host=$(jq -r .host "$DV_STATE/$issue/meta")
  fi
  line=$(event_json "$kind" "$issue" "$message" "$host" "$head")
  if [ -n "$DV_KICK" ]; then
    bash -c "$DV_KICK \"\$@\"" dv-kick "$kind" "$issue" "$message" "$host" "$head" >> "$DV_STATE/$issue/kick.log" 2>&1 || rc=$?
  else
    # The remote shell often lacks ~/.local/bin: use the installed path explicitly.
    remote=$(shell_join bash -lc "PATH=\$HOME/.local/bin:\$PATH $(shell_join dv-kick "$kind" "$issue" "$message" "$host" "$head")")
    ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$DV_KICK_HOST" "$remote" >> "$DV_STATE/$issue/kick.log" 2>&1 || rc=$?
  fi
  printf '%s\n' "$line" | jq -c --argjson rc "$rc" '. + {delivered:($rc==0),exit:$rc}' >> "$DV_STATE/$issue/events.log"
  return 0
}
cmd_status() {
  local selected='' json=0 path row alive last elapsed
  for path in "$@"; do case "$path" in --json) json=1 ;; *) [ -z "$selected" ] || fail 'one issue only'; valid_issue "$path"; selected=$path ;; esac; done
  if [ -n "$selected" ]; then [ -f "$DV_STATE/$selected/meta" ] || fail 'unknown issue'; fi
  {
    for path in "$DV_STATE"/*/meta; do
      [ -f "$path" ] || continue
      [ -z "$selected" ] || [ "$(basename "$(dirname "$path")")" = "$selected" ] || continue
      alive=false
      if command -v tmux >/dev/null && tmux_dv has-session -t "=dv-$(jq -r .issue "$path")" 2>/dev/null; then alive=true; fi
      last=$(tail -n 1 "$(dirname "$path")/log" 2>/dev/null || true)
      elapsed=$(( $(now) - $(jq -r .started "$path") ))
      row=$(jq -c --argjson tmux "$alive" --argjson elapsed "$elapsed" --arg last "$last" '.+{tmux:$tmux,elapsed:$elapsed,last_log:$last}' "$path")
      if [ "$json" = 1 ]; then printf '%s\n' "$row"
      else printf '%s\n' "$row" | jq -r '[.issue,.status,.agent,.host,(.elapsed|tostring)+"s","tmux="+(.tmux|tostring),(.last_log|gsub("[\\r\\n\\t]";" "))]|join("\t")'; fi
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
  tmux_dv kill-session -t "=$SESSION" 2>/dev/null || true
  if [ -d "$WT" ]; then (cd "$REPO" && git worktree remove "$WT"); fi
  if git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH" && git -C "$REPO" merge-base --is-ancestor "$BRANCH" "$BASE"; then
    git -C "$REPO" branch -d "$BRANCH"
  fi
}
