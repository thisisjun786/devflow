#!/usr/bin/env bash
# Headless dsh supervision shares exec lifecycle records with Codex.
# DV_HOME comes from common.sh; it is distinct from dsh's DSH_HOME.
# shellcheck disable=SC2016,SC2153

dsh_validate() {
  [ "$DV_DSH_FALLBACK" = omp ] || fail 'DV_DSH_FALLBACK must be omp'
  case "$DV_DSH_JAIL" in auto|on|off) ;; *) fail 'DV_DSH_JAIL must be auto, on or off' ;; esac
  [[ "$DV_DSH_PROFILE" =~ ^[A-Za-z0-9_-]+$ ]] || fail 'invalid DV_DSH_PROFILE'
  [[ "$DV_DSH_KEY_VAR" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail 'invalid DV_DSH_KEY_VAR'
}
dsh_key() (
  # A dotenv file is data, not shell code. Do not expose it to tracing either.
  set +x
  local value
  [[ "$DV_DSH_KEY_VAR" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  value=$(sed -nE "s/^[[:space:]]*(export[[:space:]]+)?${DV_DSH_KEY_VAR}[[:space:]]*=[[:space:]]*(.*)$/\2/p" "$DV_DSH_KEY_FILE" 2>/dev/null | head -n 1) || return 1
  value=$(printf '%s' "$value" | sed 's/[[:space:]]*$//')
  case "$value" in
    \"*\") value=${value#\"}; value=${value%\"} ;;
    \'*\') value=${value#\'}; value=${value%\'} ;;
    \"*|\'*) return 1 ;;
    *) value=${value%%[[:space:]#]*} ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s' "$value"
)
dsh_node_ready() {
  local version major minor
  version=$(node --version 2>/dev/null) || return 1
  [[ "$version" =~ ^v?([0-9]+)\.([0-9]+)\.[0-9]+ ]] || return 1
  major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[2]}
  [ "$major" -gt 24 ] || { [ "$major" -eq 24 ] && [ "$minor" -ge 9 ]; }
}
dsh_version() {
  DSH_HOME="$DV_DSH_HOME" DSH_TELEMETRY_DISABLED=1 DSH_TELEMETRY_MODE=DISABLED "$DV_DSH_BIN" --version 2>/dev/null |
    sed -nE 's/^[^0-9]*([0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?)[[:space:]]*$/\1/p' | head -n 1
}
dsh_ready() {
  dsh_node_ready && [ "$(dsh_version)" = "$DV_DSH_VERSION" ] &&
    [ -f "$DV_DSH_HOME/profiles/$DV_DSH_PROFILE/cordis.patch.yml" ] && dsh_key >/dev/null
}
dsh_omp_ready() {
  [ "$DV_DSH_FALLBACK" = omp ] && bid_agent omp &&
    { { [ "$DV_HERDR" != 0 ] && herdr_bin >/dev/null; } || command -v tmux >/dev/null; }
}
dsh_event() {
  mkdir -p "$DV_HOME"
  printf '%s\t%s\t%s\t%s\n' "$(date +%FT%T%z)" "$ISSUE" "$1" "$2" >> "$DV_HOME/dsh-events.log"
}
dsh_fallback_record() {
  meta_set --arg reason "$1" --argjson at "$(now)" '.fallback_from="dsh" | .fallback_reason=$reason | .fallback_at=$at'
  dsh_event fallback "$1"
}
dsh_fallback_launch() {
  local reason
  reason=$(cat "$S/dsh-fallback.pending")
  rm "$S/dsh-fallback.pending"
  if ! dsh_omp_ready; then
    meta_set '.status="blocked" | .exec_status="blocked" | .failure_reason="omp fallback unavailable"'
    cmd_kick blocked "$ISSUE" 'dsh failed; omp fallback unavailable'
    return 1
  fi
  # job_run_agent has already reaped the old body/scope. Keep this outer PID
  # as the slot reservation until the terminal wrapper replaces it.
  BACKEND=tmux
  if [ "$DV_HERDR" != 0 ] && herdr_bin >/dev/null; then BACKEND=herdr; fi
  dsh_fallback_record "$reason"
  meta_set --arg backend "$BACKEND" '.agent="omp" | .mode="goal" | .backend=$backend | .status="running" |
    del(.exec_status,.exec_run,.failure_reason,.done_at,.cleaned_at)'
  rm -f "$S/agent.exit" "$S/agent.session"
  if ! launch_agent --exec-prompt "$S/dsh-restart.md"; then
    printf '1\n' > "$S/agent.exit"
    meta_set '.status="start-failed"'
    cmd_kick blocked "$ISSUE" 'omp fallback startup failed'
    return 1
  fi
}
dsh_restart_prompt() {
  local status wip=clean pushed=no-origin
  status=$(jq -r .status "$S/meta")
  BRANCH=$(git -C "$WT" symbolic-ref --short HEAD)
  if [ -n "$(git -C "$WT" diff --name-only --diff-filter=U)" ]; then wip=unmerged
  elif [ -n "$(git -C "$WT" status --porcelain)" ]; then
    if git -C "$WT" add -A && git -C "$WT" commit -q --no-verify -m 'wip: save work before restarting the omp session'; then wip=committed
    else wip=failed; fi
  fi
  if [ "$status" = pr ]; then pushed='pr'
  elif [ "$BRANCH" = "$BASE" ]; then pushed=base
  elif git -C "$WT" remote get-url origin >/dev/null 2>&1; then
    if git -C "$WT" push -q -u origin "$BRANCH:refs/heads/$BRANCH" 2>/dev/null; then pushed=yes
    else pushed=failed; fi
  fi
  stall_omp_restart_prompt "$status" "$wip" "$pushed" | sed 's/fresh omp session/fresh worker session/; s/earlier omp session/earlier worker session/'
}
dsh_redact() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "${line//"$dsh_secret"/[REDACTED]}"
  done
}
dsh_child() (
  set +x
  set +m
  local dsh_secret rc=0 filter
  dsh_secret=$(dsh_key) || exit 1
  export INFERHUB_API_KEY="$dsh_secret" DSH_HOME="$DV_DSH_HOME"
  export DSH_TELEMETRY_DISABLED=1 DSH_TELEMETRY_MODE=DISABLED DSH_PERMISSION_MODE=danger-full-access
  # Both streams are redacted before touching disk. The key exists only in
  # this child and its descendants, never in launcher arguments or metadata.
  mkfifo "$S/exec/$run/stderr.pipe"
  dsh_redact < "$S/exec/$run/stderr.pipe" >&2 & filter=$!
  if [ "$DSH_JAIL" = on ]; then
    bwrap "${DSH_JAIL_ARGS[@]}" -- "$@" 2> "$S/exec/$run/stderr.pipe" | dsh_redact || rc=$?
  else
    "$@" 2> "$S/exec/$run/stderr.pipe" | dsh_redact || rc=$?
  fi
  wait "$filter" || rc=$?
  rm -f "$S/exec/$run/stderr.pipe"
  exit "$rc"
)
dsh_exec_stop() {
  if [ -n "${exec_child:-}" ]; then
    bid_stop_tree "$exec_child"
    # Also reap detached descendants in this invocation's process group.
    kill -KILL -- "-$exec_child" 2>/dev/null || true
    exec_stopped_rc=0
    wait "$exec_child" 2>/dev/null || exec_stopped_rc=$?
    exec_child=''
  fi
}
dsh_exec_cleanup() {
  trap - EXIT
  trap '' INT TERM
  dsh_exec_stop
  owned_unlock "$S/.exec-lock" "$$"
  trap - INT TERM
}
dsh_exec_events() {
  local line event session
  while IFS= read -r line; do
    exec_line=$((exec_line + 1))
    event=$(printf '%s\n' "$line" | jq -ce 'select(type=="object" and (.type|type)=="string")' 2>/dev/null) || continue
    exec_activity=$(now); printf '%s\n' "$exec_activity" > "$S/agent.activity"
    case "$(printf '%s\n' "$event" | jq -r .type)" in
      session)
        if [ ! -s "$S/agent.session" ]; then
          session=$(printf '%s\n' "$event" | jq -er '.session.sessionId // .sessionId | select(type=="string" and test("^[A-Za-z0-9_-]+$"))') || session=''
          [ -z "$session" ] || printf '%s\n' "$session" > "$S/agent.session"
        fi ;;
      status)
        if printf '%s\n' "$event" | jq -e '.phase=="turn_end"' >/dev/null; then
          completed=$(printf '%s\n' "$event" | jq -r '.reason.kind=="completed"')
        fi ;;
      error)
        exec_reason='dsh error event'
        if printf '%s\n' "$event" | capacity_error || printf '%s\n' "$event" | grep -Eiq 'quota'; then exec_capacity=true; fi ;;
    esac
  done < <(tail -n "+$((exec_line + 1))" "$S/agent.jsonl")
}
dsh_exec_run() {
  local instruction=$1 exec_child='' exec_stopped_rc=0 exec_line exec_activity exec_reason exec_capacity
  local run rc stderr_line completed resumed=0 failures session
  local DSH_JAIL_ARGS=() args=()
  dsh_validate
  owned_lock "$S/.exec-lock" "$$" || fail 'exec wrapper already running'
  trap dsh_exec_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if ! dsh_jail_prepare; then
    meta_set '.exec_status="blocked" | .status="blocked"'
    printf '1\n' > "$S/agent.exit"
    dsh_exec_cleanup
    cmd_kick blocked "$ISSUE" 'dsh jail required but unavailable'
    return 1
  fi
  touch "$S/agent.jsonl" "$S/agent.stderr"
  exec_line=$(wc -l < "$S/agent.jsonl")
  failures=$(jq -r '.dsh_failures // 0' "$S/meta")
  dsh_event start "jail=$DSH_JAIL"
  while :; do
    run="$(now)-$$-$RANDOM"
    mkdir -p "$S/exec/$run"
    rm -f "$S/agent.exit"
    meta_set --arg run "$run" '.exec_run=$run | .exec_status="working" | (if .status=="pr" or .status=="ready" then . else .status="running" end) | del(.done_at,.failure_reason)'
    exec_activity=$(now); printf '%s\n' "$exec_activity" > "$S/agent.activity"
    exec_reason=''; exec_capacity=false; completed=false; rc=0
    stderr_line=$(wc -l < "$S/agent.stderr")
    args=("$DV_DSH_BIN" --profile "$DV_DSH_PROFILE" --json)
    if [ -s "$S/agent.session" ]; then
      session=$(cat "$S/agent.session"); args+=(--session-id "$session")
    fi
    args+=(-)
    printf '%s\n\nDo not read other checkouts, branches or directories outside this worktree for answers.\n' "$instruction" > "$S/exec/$run/prompt"
    set -m
    dsh_child "${args[@]}" < "$S/exec/$run/prompt" >> "$S/agent.jsonl" 2>> "$S/agent.stderr" & exec_child=$!
    set +m
    printf '%s\n' "$exec_child" > "$S/exec/$run/pid"
    touch "$S/agent.started"
    while kill -0 "$exec_child" 2>/dev/null; do
      dsh_exec_events
      if tail -n "+$((stderr_line + 1))" "$S/agent.stderr" | grep -Eq '^dsh: (RATE_LIMIT|QUOTA):'; then exec_capacity=true; fi
      if [ "$exec_capacity" = true ]; then exec_reason='dsh provider capacity'; break; fi
      [ -z "$exec_reason" ] || break
      if [ "$(( $(now) - exec_activity ))" -ge "$DV_STALL_AFTER" ]; then
        exec_reason="stalled: no dsh event for $DV_STALL_AFTER seconds"; break
      fi
      sleep 0.2
    done
    if [ -n "$exec_reason" ]; then dsh_exec_stop; rc=$exec_stopped_rc
    else
      wait "$exec_child" || rc=$?
      kill -KILL -- "-$exec_child" 2>/dev/null || true
      exec_child=''
    fi
    dsh_exec_events
    printf '%s\n' "$rc" > "$S/exec/$run/exit"
    if jq -e '.status=="parked"' "$S/meta" >/dev/null; then
      capacity_clear; meta_set '.exec_status="parked"'; printf '%s\n' "$rc" > "$S/agent.exit"
      dsh_exec_cleanup; return 0
    fi
    if [ "$exec_capacity" = true ] || tail -n "+$((stderr_line + 1))" "$S/agent.stderr" | grep -Eq '^dsh: (RATE_LIMIT|QUOTA):'; then
      if capacity_wait; then continue; fi
      meta_set '.exec_status="blocked"'; printf '1\n' > "$S/agent.exit"
      dsh_exec_cleanup; return 1
    fi
    capacity_clear
    if [ "$rc" = 0 ] && [ "$completed" = true ] && [ -z "$exec_reason" ] && [ -f "$S/exec/$run/done" ]; then
      meta_set '.exec_status="done" | .dsh_failures=0 | del(.failure_reason)'
      printf '0\n' > "$S/agent.exit"
      dsh_event 'done' completed
      dsh_exec_cleanup; return 0
    fi
    if [ -z "$exec_reason" ]; then
      if [ "$rc" = 0 ] && [ "$completed" = true ]; then exec_reason='completed without dv done'
      else exec_reason="dsh exited $rc without completed turn_end"; fi
    fi
    printf '%s\n' "$exec_reason" > "$S/exec/$run/failure"
    # A crash/stall gets one same-session recovery before it counts. Capacity
    # waits preserve that allowance and never increment the failure streak.
    if [ "$exec_reason" != 'completed without dv done' ] && [ "$resumed" = 0 ] && [ -s "$S/agent.session" ]; then
      resumed=1; dsh_event resume "$exec_reason"; metrics_note resume
      instruction="Continue the interrupted request in this worktree. Preserve existing work. Read $S/brief.md and $S/report.md if present. Finish with dv done $ISSUE."
      continue
    fi
    failures=$((failures + 1)); resumed=0
    meta_set --argjson failures "$failures" --arg reason "$exec_reason" '.dsh_failures=$failures | .failure_reason=$reason'
    rm -f "$S/agent.session"
    dsh_restart_prompt > "$S/dsh-restart.md"
    if [ "$failures" -ge 2 ]; then
      printf '%s\n' "$exec_reason" > "$S/dsh-fallback.pending"
      dsh_exec_cleanup; return 0
    fi
    instruction=$(cat "$S/dsh-restart.md")
    dsh_event restart "$exec_reason"
  done
}
