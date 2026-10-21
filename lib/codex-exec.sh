#!/usr/bin/env bash
# Non-interactive Codex supervision. No terminal or screen parser is involved.
# shellcheck disable=SC2016
codex_default_mode() {
  if [ -n "$DV_MODE" ]; then printf '%s\n' "$DV_MODE"
  elif [ "$1" = codex ]; then
    case "$DV_CODEX_MODE" in
      auto|appserver) printf 'auto\n' ;;
      goal|tui) printf 'goal\n' ;;
      exec) printf 'exec\n' ;;
      *) fail 'DV_CODEX_MODE must be auto, appserver, exec, goal or tui' ;;
    esac
  else printf 'goal\n'; fi
}
codex_exec_alive() {
  local pid
  [ -f "$1/agent.pid" ] || return 1
  pid=$(cat "$1/agent.pid")
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null &&
    [ "$(ps -p "$pid" -o stat= 2>/dev/null | cut -c 1)" != Z ]
}
codex_exec_status() {
  local dir=$1 last current
  if codex_exec_alive "$dir"; then
    last=$(cat "$dir/agent.activity" 2>/dev/null) || last=$(jq -r .started "$dir/meta")
    current=$(date +%s)
    if [ "$((current - last))" -ge "$DV_STALL_AFTER" ]; then printf 'stalled\n'
    else printf 'working\n'; fi
  elif [ -f "$dir/agent.exit" ]; then
    jq -r '.exec_status // "failed"' "$dir/meta"
  else printf 'failed\n'; fi
}
codex_exec_stop() {
  if [ -n "${exec_child:-}" ]; then
    bid_stop_tree "$exec_child"
    exec_stopped_rc=0
    wait "$exec_child" 2>/dev/null || exec_stopped_rc=$?
    exec_child=''
  fi
}
codex_exec_cleanup() {
  # Normal returns must clean up before the function's locals leave scope.
  # EXIT still covers errors and signals while the function is executing.
  trap - EXIT
  trap '' INT TERM
  codex_exec_stop
  owned_unlock "$S/.exec-lock" "$$"
  trap - INT TERM
}
codex_exec_events() {
  local line event kind session
  # Read complete lines only. An unfinished final JSON record is retried on
  # the next pass, and old attempts are never interpreted as new activity.
  while IFS= read -r line; do
    exec_line=$((exec_line + 1))
    event=$(printf '%s\n' "$line" | jq -ce 'select(type=="object" and (.type|type)=="string")' 2>/dev/null) || continue
    exec_activity=$(now)
    printf '%s\n' "$exec_activity" > "$S/agent.activity"
    kind=$(printf '%s\n' "$event" | jq -r .type)
    if [ "$kind" = thread.started ]; then
      session=$(printf '%s\n' "$event" | jq -er '.thread_id | select(type=="string" and test("^[A-Za-z0-9_-]+$"))') || session=''
      [ -z "$session" ] || printf '%s\n' "$session" > "$S/agent.session"
    fi
    case "$kind" in
      error|turn.failed)
        exec_reason=$(printf '%s\n' "$event" | jq -r '.message // .error.message // "codex error event"') ;;
      item.*)
        if printf '%s\n' "$event" | jq -e '.item.type=="error"' >/dev/null; then
          exec_reason=$(printf '%s\n' "$event" | jq -r '.item.message // "codex error item"')
        fi ;;
    esac
  done < <(tail -n "+$((exec_line + 1))" "$S/agent.jsonl")
}
codex_exec_run() {
  local instruction=$1 original_instruction=$1 exec_child='' exec_stopped_rc=0 exec_line exec_activity exec_reason rc session run
  local args=()
  owned_lock "$S/.exec-lock" "$$" || fail 'exec wrapper already running'
  trap codex_exec_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  touch "$S/agent.jsonl"
  exec_line=$(wc -l < "$S/agent.jsonl")
  while :; do
    run="$(now)-$$-$RANDOM"
    mkdir -p "$S/exec/$run"
    rm -f "$S/agent.exit"
    meta_set --arg run "$run" '.exec_run=$run | .exec_status="working" | (if .status=="pr" or .status=="ready" then . else .status="running" end) | del(.done_at,.failure_reason)'
    exec_activity=$(now); printf '%s\n' "$exec_activity" > "$S/agent.activity"
    exec_reason=''; rc=0
    if ! codex_environment; then
      exec_reason='codex provider environment is not ready'; rc=1
    else
      args=("$DV_CODEX_BIN" -m "$DV_CODEX_MODEL" -c "model_reasoning_effort=\"$DV_CODEX_EFFORT\"" -C "$WT")
      args+=(-c tools.experimental_request_user_input.enabled=false)
      # Project trust is persisted by cmd_start. Current exec rejects projects
      # session overrides and emits error items even though the turn starts.
      [ "$DV_CODEX_DISABLE_HOOKS" != 1 ] || args+=(--disable hooks)
      [ "$DV_CODEX_DISABLE_CRW" != 1 ] || args+=(-c 'plugins."crw@crw".enabled=false')
      args+=(exec)
      if [ -s "$S/agent.session" ]; then
        session=$(cat "$S/agent.session")
        args+=(resume --json --dangerously-bypass-approvals-and-sandbox "$session")
        metrics_note resume
      else args+=(--json --dangerously-bypass-approvals-and-sandbox); fi
      export DV_AGENT_INSTRUCTION="$instruction"
      "${args[@]}" "$instruction" >> "$S/agent.jsonl" 2>> "$S/agent.stderr" < /dev/null & exec_child=$!
      printf '%s\n' "$exec_child" > "$S/exec/$run/pid"
      touch "$S/agent.started"
      while kill -0 "$exec_child" 2>/dev/null; do
        codex_exec_events
        if [ -n "$exec_reason" ]; then break; fi
        if [ "$(( $(now) - exec_activity ))" -ge "$DV_STALL_AFTER" ]; then
          exec_reason="stalled: no Codex event for $DV_STALL_AFTER seconds"; break
        fi
        sleep 0.2
      done
      if [ -n "$exec_reason" ]; then codex_exec_stop; rc=$exec_stopped_rc
      else wait "$exec_child" || rc=$?; exec_child=''; fi
      codex_exec_events
    fi
    printf '%s\n' "$rc" > "$S/exec/$run/exit"
    if [ -z "$exec_reason" ]; then
      if [ "$rc" -ne 0 ]; then exec_reason="codex exec exited $rc"
      elif [ ! -f "$S/exec/$run/done" ]; then exec_reason='failed-to-finish: codex exec exited 0 without dv done'; fi
    fi
    if [ -z "$exec_reason" ]; then
      meta_set '.exec_status="done" | del(.failure_reason)'
      printf '%s\n' "$rc" > "$S/agent.exit"
      codex_exec_cleanup
      return 0
    fi
    printf '%s\n' "$exec_reason" > "$S/exec/$run/failure"
    meta_set --arg reason "$exec_reason" '.exec_status=(if $reason|startswith("stalled:") then "stalled" elif $reason|startswith("failed-to-finish:") then "failed-to-finish" else "failed" end) | .failure_reason=$reason'
    if [ ! -f "$S/exec-retry.used" ]; then
      printf '%s\n' "$run" > "$S/exec-retry.used"
      metrics_note revive
      # A failed event is terminal for the scheduler. Keep the retry local so
      # it cannot consume/deduplicate the eventual terminal failure event.
      printf '%s; retrying once in the same worktree\n' "$exec_reason" >> "$S/log"
      instruction="Continue the interrupted request in this worktree. Preserve existing changes. The original request follows:
$original_instruction"
    else
      meta_set '.status="blocked" | .exec_status="blocked"'
      printf '%s\n' "$rc" > "$S/agent.exit"
      codex_exec_cleanup
      cmd_kick failed "$ISSUE" "$exec_reason; automatic exec retry already attempted"
      cmd_kick blocked "$ISSUE" "$exec_reason; automatic exec retry already attempted"
      return 1
    fi
  done
}
codex_exec_send() {
  case "$(jq -r .status "$S/meta")" in landed|cancelled) fail 'cannot resume a finished issue' ;; esac
  if codex_exec_alive "$S"; then fail 'Codex exec is still running; send the follow-up after it exits'; fi
  local prompt
  prompt=$(mktemp "$S/exec-prompt.XXXXXX")
  {
    printf '%s\n\n' "$1"
    printf 'Continue in the same worktree and branch. Read %s/brief.md and %s/report.md if present.\n' "$S" "$S"
    printf 'Preserve existing changes and review-fix.sent. Finish with dv done %s.\n' "$ISSUE"
  } > "$prompt"
  launch_agent --exec-prompt "$prompt"
}
