#!/usr/bin/env bash
# Shared provider classification and a persisted wait episode, separate from
# crash/stall recovery. Callers supply errors, never arbitrary agent messages.
# shellcheck disable=SC2016
capacity_error() {
  LC_ALL=C grep -Ei 'usage[ _-]*limit|usageLimitExceeded|rate[ _-]*limit|resource[ _-]*exhausted|too many requests|at capacity|overloaded|HTTP(/[0-9.]+)?[^[:alnum:]]*429|"(httpStatusCode|statusCode|status|code)"[[:space:]]*:[[:space:]]*429' >/dev/null
}
capacity_validate() {
  [[ "$DV_CAPACITY_BACKOFF" =~ ^[1-9][0-9]*$ ]] || fail 'DV_CAPACITY_BACKOFF must be positive seconds'
  [[ "$DV_CAPACITY_MAX_WAIT" =~ ^[1-9][0-9]*$ ]] || fail 'DV_CAPACITY_MAX_WAIT must be positive seconds'
}
# 0: retry now, 1: still waiting, 2: deadline reached. Nonblocking for clients.
capacity_poll() {
  local time since attempt delay next deadline first=false
  capacity_validate
  time=$(now)
  if ! jq -e '.capacity!=null' "$S/meta" >/dev/null; then
    first=true
    meta_set --argjson time "$time" '.capacity={since:$time,attempt:0,resume_status:.status,next_try_at:null}'
  fi
  since=$(jq -r .capacity.since "$S/meta")
  deadline=$((since + DV_CAPACITY_MAX_WAIT))
  if [ "$time" -ge "$deadline" ]; then return 2; fi
  next=$(jq -r '.capacity.next_try_at // empty' "$S/meta")
  if [ -z "$next" ]; then
    attempt=$(jq -r .capacity.attempt "$S/meta")
    case "$attempt" in
      0) delay=$DV_CAPACITY_BACKOFF ;;
      1) delay=$((DV_CAPACITY_BACKOFF * 5 / 2)) ;;
      *) delay=$((DV_CAPACITY_BACKOFF * 15 / 2)) ;;
    esac
    next=$((time + delay))
    [ "$next" -le "$deadline" ] || next=$deadline
    meta_set --argjson next "$next" '.status="waiting-capacity" | .capacity.next_try_at=$next | .capacity.attempt+=1'
  fi
  if [ "$first" = true ]; then
    cmd_kick waiting-capacity "$ISSUE" "Provider capacity unavailable; waiting in the same worktree; next try at $next (Unix seconds)"
  fi
  [ "$time" -ge "$next" ]
}
capacity_resume() {
  meta_set 'if .capacity!=null then
    (if .status=="waiting-capacity" then .status=.capacity.resume_status else . end) |
    .capacity.next_try_at=null else . end'
  now > "$S/agent.activity"
}
capacity_clear() {
  if jq -e '.capacity!=null' "$S/meta" >/dev/null; then
    meta_set '(if .status=="waiting-capacity" then .status=.capacity.resume_status else . end) | del(.capacity)'
  fi
}
capacity_block() {
  local reason hours
  hours=$(awk -v seconds="$DV_CAPACITY_MAX_WAIT" 'BEGIN {printf "%g",seconds/3600}')
  reason="provider usage limit for $hours h ($DV_CAPACITY_MAX_WAIT seconds); capacity wait exhausted"
  meta_set --arg reason "$reason" '.status="blocked" | .failure_reason=$reason | .capacity.next_try_at=null'
  cmd_kick blocked "$ISSUE" "$reason"
}
capacity_wait() {
  local rc delay next
  while :; do
    rc=0; capacity_poll || rc=$?
    case "$rc" in
      0) capacity_resume; return 0 ;;
      2) capacity_block; return 1 ;;
    esac
    next=$(jq -r .capacity.next_try_at "$S/meta")
    delay=$((next - $(now)))
    [ "$delay" -gt 0 ] || continue
    [ "$delay" -le 60 ] || delay=60
    sleep "$delay"
  done
}
# For CLI runners, extract only structured errors when the output is JSONL.
# Plain stderr is considered only after an unsuccessful process exit.
capacity_output_error() {
  local file=$1 rc=$2 errors
  errors=$(jq -Rr 'fromjson? | select(type=="object") |
    if .type=="error" or .type=="turn.failed" then .
    elif .item.type=="error" then .item
    elif .type=="result" and .is_error==true then .
    else empty end | tojson' "$file")
  if printf '%s\n' "$errors" | capacity_error; then return 0; fi
  [ "$rc" != 0 ] || return 1
  jq -Rr 'select((try fromjson catch null | type) != "object")' "$file" | capacity_error
}
# Visible terminal state only: a later activity banner supersedes an old error.
capacity_screen_error() {
  local line limited=1
  while IFS= read -r line; do
    if printf '%s\n' "$line" | capacity_error; then limited=0
    elif printf '%s\n' "$line" | LC_ALL=C grep -Eq '(^|[[:space:]])(Pursuing goal|Working|Thinking)([[:space:].:]|$)'; then limited=1; fi
  done
  return "$limited"
}
capacity_terminal_stop() {
  if [ -n "${capacity_child:-}" ]; then
    bid_stop_tree "$capacity_child"
    wait "$capacity_child" 2>/dev/null || true
    capacity_child=''
  fi
}
capacity_terminal_screen() {
  if [ "$BACKEND" = herdr ]; then herdr_cmd pane read "$HERDR_PANE" --source visible 2>/dev/null
  else tmux_dv capture-pane -p -t "$SESSION:0.0" 2>/dev/null; fi
}
capacity_terminal_pause() {
  local ticks=5
  # Keep screen polling at one second, but publish fast process exits before
  # the startup/admission caller decides that the worker is still running.
  while [ "$ticks" -gt 0 ]; do
    kill -0 "$capacity_child" 2>/dev/null || return 0
    sleep 0.2
    ticks=$((ticks - 1))
  done
}
capacity_terminal_run() {
  local mark_started=$1 rc=0 screen='' poll_rc line output capacity_child='' provider provider_mode
  shift
  provider=$(jq -r .agent "$S/meta"); provider_mode=$(jq -r .mode "$S/meta")
  touch "$S/log"
  line=$(wc -l < "$S/log")
  # Explicit stdin keeps the existing TTY for interactive CLIs in this
  # non-job-control shell while the wrapper supervises provider waits.
  "$@" <&0 & capacity_child=$!
  if [ "$mark_started" = 1 ] && [ -n "${DV_AWARD_TOKEN:-}" ]; then
    # Reject immediate launcher failures before acknowledging admission. The
    # setup above must not publish success before the command even executes.
    sleep 0.1
    if kill -0 "$capacity_child" 2>/dev/null; then touch "$S/agent.started"; fi
  fi
  while kill -0 "$capacity_child" 2>/dev/null; do
    if jq -e '.status=="done" or .status=="ready" or .status=="landed" or .status=="cancelled"' "$S/meta" >/dev/null; then capacity_terminal_pause; continue; fi
    screen=$(capacity_terminal_screen) || screen=''
    if printf '%s\n' "$screen" | capacity_screen_error; then
      poll_rc=0; capacity_poll || poll_rc=$?
      case "$poll_rc" in
        0)
          capacity_resume
          if [ "$provider" = codex ] && [ "$provider_mode" = goal ]; then send_text '/goal resume'
          else send_text 'Continue the interrupted request in this worktree. Preserve existing changes.'; fi ;;
        2) capacity_block; capacity_terminal_stop; return 1 ;;
      esac
    elif [ -n "$screen" ] && jq -e '.capacity!=null' "$S/meta" >/dev/null; then
      capacity_clear
    fi
    capacity_terminal_pause
  done
  wait "$capacity_child" || rc=$?; capacity_child=''
  # An exited CLI may have emitted its error between two visible snapshots.
  output=$(mktemp "$S/.capacity-output.XXXXXX")
  tail -n "+$((line + 1))" "$S/log" > "$output"
  screen=$(capacity_terminal_screen) || screen=''
  if capacity_output_error "$output" "$rc" || { [ ! -f "$S/done.json" ] && printf '%s\n' "$screen" | capacity_screen_error; }; then
    rm "$output"
    [ "$mark_started" != 1 ] || [ -z "${DV_AWARD_TOKEN:-}" ] || touch "$S/agent.started"
    capacity_wait || return 1
    return 75 # caller relaunches with an explicit continuation in the same WT
  fi
  rm "$output"
  capacity_clear
  [ "$rc" != 0 ] || [ "$mark_started" != 1 ] || [ -z "${DV_AWARD_TOKEN:-}" ] || touch "$S/agent.started"
  return "$rc"
}
