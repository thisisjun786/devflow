#!/usr/bin/env bash
# jq filters intentionally use literal dollars.
# shellcheck disable=SC2016
herdr_bin() {
  if command -v herdr >/dev/null 2>&1; then command -v herdr
  elif [ -x "$HOME/.local/bin/herdr" ]; then printf '%s\n' "$HOME/.local/bin/herdr"
  else return 1; fi
}
herdr_cmd() {
  local bin
  bin=$(herdr_bin) || { printf 'dv: herdr is unavailable\n' >&2; return 1; }
  "$bin" "$@"
}
herdr_start() {
  local launcher=$1 reply workspace pane
  reply=$(herdr_cmd workspace create --label "$SESSION" --cwd "$WT" --no-focus) || return 1
  workspace=$(printf '%s\n' "$reply" | jq -er '.result.workspace.workspace_id | select(type=="string" and length>0)') || return 1
  # Record ownership before waiting, so clean can remove a partial startup.
  meta_set --arg workspace "$workspace" '.herdr_workspace=$workspace'
  pane=$(printf '%s\n' "$reply" | jq -er '.result.root_pane.pane_id | select(type=="string" and length>0)') || return 1
  meta_set --arg pane "$pane" '.herdr_pane=$pane'
  # Match a prompt marker in the fresh pane without depending on line endings
  # or right-prompt decorations. Verified against herdr 0.9.1's Rust matcher.
  herdr_cmd pane wait-output "$pane" --regex '[$#%>❯➜›]' --source recent-unwrapped --timeout "$((DV_START_WAIT * 1000))" >/dev/null || return 1
  # agent start uses canonical executables; pane run preserves configured binaries,
  # DV_* environment and the _agent exit/done wrapper in the pane's own foreground.
  # This command is silent on success; its exit status is the acknowledgement.
  herdr_cmd pane run "$pane" "$launcher"
}
herdr_send_text() {
  local text=$1 reply rc attempt
  for attempt in 1 2; do
    rc=0
    reply=$(herdr_cmd agent prompt "$HERDR_PANE" "$text" 2>&1) || rc=$?
    if printf '%s\n' "$reply" | jq -e '.error.code=="agent_blocked"' >/dev/null 2>&1 && [ "$attempt" = 1 ]; then
      # A blocked submission sends no input. Wait, then make exactly one retry.
      herdr_cmd agent wait "$HERDR_PANE" --until idle --until 'done' --until working --timeout "$((DV_START_WAIT * 1000))" >/dev/null || true
      continue
    fi
    if [ "$rc" = 0 ] && printf '%s\n' "$reply" | jq -e '.error==null and .result.type=="agent_prompted"' >/dev/null 2>&1; then return 0; fi
    printf 'dv: herdr prompt failed: %s\n' "$reply" >&2
    return 1
  done
}
herdr_read() {
  local pane=$1; shift
  herdr_cmd pane read "$pane" --source recent-unwrapped "$@"
}
herdr_snapshot() {
  [ -n "$HERDR_PANE" ] || return 0
  local tmp
  tmp=$(mktemp "$S/.log.XXXXXX") || return 1
  if herdr_read "$HERDR_PANE" > "$tmp"; then mv "$tmp" "$S/log"
  else rm -f "$tmp"; return 1; fi
}
herdr_info() {
  local reply
  if reply=$(herdr_cmd agent get "$1") && printf '%s\n' "$reply" | jq -e '.result.agent | type=="object"' >/dev/null; then
    printf '%s\n' "$reply" | jq -c '.result.agent'
  else
    herdr_cmd pane get "$1" | jq -ec '.result.pane | select(type=="object")'
  fi
}
# Run the CLI itself as the child so a signal interrupts wait immediately and
# cleanup can reap the socket subscriber (no orphaned shell/function child).
herdr_question_wait() {
  local rc=0
  "$question_bin" "$@" > "$question_tmp/reply" 2> "$question_tmp/error" & question_child=$!
  wait "$question_child" || rc=$?
  question_child=''
  return "$rc"
}
herdr_question_cleanup() {
  # TERM can reach a forked CLI child before exec resets its inherited EXIT
  # trap. Only the sentinel owns these files; that child must not remove them.
  [ "$BASH_SUBSHELL" = "$question_owner_subshell" ] || return 0
  trap '' INT TERM
  trap - EXIT
  if [ -n "$question_child" ]; then
    kill "$question_child" 2>/dev/null || true
    wait "$question_child" 2>/dev/null || true
  fi
  rm -f "$S/question.pending" "$question_tmp/reply" "$question_tmp/error" "$question_tmp/pending"
  rmdir "$question_tmp"
}
# Read only the session identified by herdr; transcript text is untrusted data.
herdr_question_record() {
  local info=$1 agent session_id root pattern file message
  agent=$(printf '%s\n' "$info" | jq -r '.result.agent.agent')
  session_id=$(printf '%s\n' "$info" | jq -er '.result.agent.agent_session.value | select(type=="string" and length>0)') || return 1
  # Keep IDs literal in find patterns and reject paths / wildcard selectors.
  [[ "$session_id" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || return 1
  case "$agent" in
    codex) root=$DV_CODEX_SESSIONS; pattern="rollout-*-$session_id.jsonl" ;;
    claude) root=$DV_CLAUDE_SESSIONS; pattern="$session_id.jsonl" ;;
    *) return 1 ;;
  esac
  [ -d "$root" ] || return 1
  while IFS= read -r file; do
    # Stream JSONL and tolerate a partially written tail. An answered or invalid
    # latest question must not revive an older question from the same session.
    if message=$(jq -ner --arg agent "$agent" --arg session "$session_id" '
      reduce (inputs?) as $row ({matches:false,question:null,id:null};
        if $agent=="codex" then
          if $row.type=="session_meta" then .matches=($row.payload.id==$session)
          elif .matches and $row.type=="response_item" and $row.payload.type=="function_call"
            and (($row.payload.name // "" | split(".") | last) | .=="request_user_input" or .=="request_user_input_async") then
            .id=$row.payload.call_id |
            .question=($row.payload.arguments | if type=="string" then try fromjson catch null else . end)
          elif .matches and $row.type=="response_item" and $row.payload.type=="function_call_output"
            and .id!=null and $row.payload.call_id==.id then .question=null
          else . end
        elif $row.sessionId==$session then
          reduce $row.message.content[]? as $item (.;
            if $item.type=="tool_use" and $item.name=="AskUserQuestion" then .question=$item.input | .id=$item.id
            elif $item.type=="tool_result" and .id!=null and $item.tool_use_id==.id then .question=null
            else . end)
        else . end)
      | select(.question|type=="object")
      | {key:($session+":"+(.id // (.question|tojson))),message:(.question|tojson|.[0:2000])} | tojson
    ' "$file" 2>/dev/null); then
      printf '%s\n' "$message"
      return 0
    fi
  done < <(find "$root" -type f -name "$pattern" -print 2>/dev/null)
  return 1
}
herdr_question_sentinel() {
  local question_bin question_tmp question_child='' question_owner_subshell=$BASH_SUBSHELL seq info message first=1
  local record key status sent_key='' sent_seq='' episode=0
  question_bin=$(herdr_bin) || return 0
  question_tmp=$(mktemp -d "$S/.question.XXXXXX") || return 0
  trap herdr_question_cleanup EXIT
  trap 'exit 0' INT TERM
  while :; do
    # Bound the subscription so a question in a still-working session is read.
    if ! herdr_question_wait agent wait "$HERDR_PANE" --until blocked --timeout 1000; then
      # agent.wait cannot subscribe before an agent is detected (herdr 0.9.1).
      # Wait once for the application's banner through herdr's output waiter;
      # do not poll agent.get while the process is starting.
      if [ "$first" = 1 ] && jq -e '.error.code=="agent_not_found"' "$question_tmp/error" >/dev/null 2>&1; then
        first=0
        herdr_question_wait pane wait-output "$HERDR_PANE" --regex '(?m)^[^[:alnum:]]*(OpenAI Codex|Claude Code|Devin)' --source visible --timeout "$((DV_START_WAIT * 1000))" || break
        continue
      fi
      jq -e '.error.code=="timeout"' "$question_tmp/error" >/dev/null 2>&1 || break
      info=$(herdr_cmd agent get "$HERDR_PANE") || break
    else
      info=$(cat "$question_tmp/reply")
    fi
    first=0
    status=$(printf '%s\n' "$info" | jq -r .result.agent.agent_status)
    seq=$(printf '%s\n' "$info" | jq -er .result.agent.state_change_seq) || break
    record=$(herdr_question_record "$info") || record=''
    key=''; message=''
    if [ -n "$record" ]; then
      key=$(printf '%s\n' "$record" | jq -r .key)
      message=$(printf '%s\n' "$record" | jq -r .message)
    elif [ "$status" = blocked ] && [ "$seq" != "$sent_seq" ]; then
      if herdr_question_wait agent wait "$HERDR_PANE" --until idle --until working --until 'done' --until unknown --timeout "$((DV_BLOCKED_GRACE * 1000))"; then continue; fi
      # Only server timeout means grace elapsed, never transport/detection errors.
      jq -e '.error.code=="timeout"' "$question_tmp/error" >/dev/null 2>&1 || break
      info=$(herdr_cmd agent get "$HERDR_PANE") || break
      printf '%s\n' "$info" | jq -e --argjson seq "$seq" '.result.agent | .agent_status=="blocked" and .state_change_seq==$seq' >/dev/null || continue
      # The writer can append the question while grace is running.
      record=$(herdr_question_record "$info") || record=''
      if [ -n "$record" ]; then
        key=$(printf '%s\n' "$record" | jq -r .key)
        message=$(printf '%s\n' "$record" | jq -r .message)
      else
        key="blocked:$seq"
        message=$(herdr_cmd pane read "$HERDR_PANE" --source visible --lines 8) || message='Blocked pane; screen unavailable'
        # Screen fallback keeps the existing cleanup; JSON question text stays exact.
        message=$(printf '%s\n' "$message" | jq -Rrs '
          gsub("\u001b\\[[0-?]*[ -/]*[@-~]"; "") |
          gsub("\u001b\\][^\u0007]*(\u0007|\u001b\\\\)"; "") |
          gsub("[\u0000-\u001f\u007f]"; " ") | gsub("\\s+"; " ") |
          sub("^ +"; "") | sub(" +$"; "") | .[-1000:]')
      fi
    fi
    if [ -n "$key" ] && [ "$key" != "$sent_key" ]; then
      sent_key=$key
      if [ "$status" = blocked ]; then sent_seq=$seq; fi
      episode=$((episode + 1))
      rm -f "$S/question.pending"
      DV_QUESTION_EPISODE="$HERDR_PANE:$$:$episode" "$DV_ROOT/bin/dv" kick question "$ISSUE" "$message"
      # kick deliberately exits successfully even on delivery failure. Only a
      # matching delivered event can publish the pending marker.
      if jq -se --arg suffix ":$HERDR_PANE:$$:$episode" 'any(.[]; .kind=="question" and .delivered and (.id|endswith($suffix)))' "$S/events.log" >/dev/null; then
        jq -cn --argjson seq "$seq" --argjson owner "$$" --arg key "${record:+$key}" '{seq:$seq,owner:$owner,key:$key}' > "$question_tmp/pending"
        mv "$question_tmp/pending" "$S/question.pending"
      fi
    elif [ -z "$record" ] && { [ "$status" != blocked ] || [[ "$sent_key" != blocked:* ]]; }; then
      rm -f "$S/question.pending"
    fi
    if [ "$status" = blocked ]; then
      if ! herdr_question_wait agent wait "$HERDR_PANE" --until idle --until working --until 'done' --until unknown --timeout 1000; then
        jq -e '.error.code=="timeout"' "$question_tmp/error" >/dev/null 2>&1 || break
      fi
    elif [ -z "$record" ]; then
      sent_key=''; sent_seq=''
    fi
  done
  printf 'dv: question sentinel stopped: %s\n' "$(cat "$question_tmp/error")"
}
herdr_clean() {
  local workspace reply rc=0
  workspace=$(jq -er '.herdr_workspace | select(type=="string" and length>0)' "$S/meta") || return 0
  reply=$(herdr_cmd workspace get "$workspace" 2>&1) || rc=$?
  if printf '%s\n' "$reply" | jq -e '.error.code=="workspace_not_found"' >/dev/null 2>&1; then
    meta_set 'del(.herdr_workspace,.herdr_pane)'
    return 0
  fi
  [ "$rc" = 0 ] || return 1
  # A saved id alone is insufficient if the server has reused it for another label.
  printf '%s\n' "$reply" | jq -e --arg workspace "$workspace" --arg label "$SESSION" \
    '.result.workspace | .workspace_id==$workspace and .label==$label' >/dev/null || return 1
  herdr_snapshot || printf 'dv: warning: could not capture herdr log for %s\n' "$ISSUE" >&2
  reply=$(herdr_cmd workspace close "$workspace") || return 1
  printf '%s\n' "$reply" | jq -e '.result!=null and .error==null' >/dev/null || return 1
  meta_set 'del(.herdr_workspace,.herdr_pane)'
}
