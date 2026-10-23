#!/usr/bin/env bash
# A job-scoped client of an existing Codex daemon. No daemon installation,
# terminal scraping, credentials on disk, or third-party relay implementation.
# shellcheck disable=SC2016
# shellcheck source=lib/appserver-transport.sh
source "$DV_ROOT/lib/appserver-transport.sh"
appserver_proxy() {
  local args=(app-server proxy)
  [ -z "$DV_APPSERVER_SOCKET" ] || args+=(--sock "$DV_APPSERVER_SOCKET")
  exec "$DV_CODEX_BIN" "${args[@]}"
}
appserver_open() {
  [[ "$DV_APPSERVER_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || return 1
  command -v openssl >/dev/null || return 1
  tmp_make AS_IO dv-appserver || return 1
  mkfifo "$AS_IO/in" "$AS_IO/out" "$AS_IO/receive-ack" "$AS_IO/raw-in" "$AS_IO/raw-out" || { appserver_close; return 1; }
  AS_SEND='' AS_RECEIVE=''
  appserver_proxy < "$AS_IO/raw-in" > "$AS_IO/raw-out" & AS_PID=$!
  exec 7> "$AS_IO/raw-in" 6< "$AS_IO/raw-out"
  # A proxy can die before reading the upgrade. Contain SIGPIPE in a child.
  if ! (appserver_ws_upgrade); then appserver_close; return 1; fi
  appserver_ws_send 1 < "$AS_IO/in" >&7 6>&- 7>&- & AS_SEND=$!
  exec 9> "$AS_IO/in"
  exec 5<> "$AS_IO/receive-ack"
  appserver_ws_receive 0 "$AS_IO/receive-record" <&6 > "$AS_IO/out" 5< "$AS_IO/receive-ack" 6>&- 7>&- 9>&- & AS_RECEIVE=$!
  exec 8< "$AS_IO/out" 6>&- 7>&-
}
appserver_close() {
  local pid
  exec 5>&- 6>&- 7>&- 8>&- 9>&-
  for pid in "${AS_WRITER:-}" "${AS_PID:-}" "${AS_SEND:-}" "${AS_RECEIVE:-}"; do
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  done
  for pid in "${AS_WRITER:-}" "${AS_PID:-}" "${AS_SEND:-}" "${AS_RECEIVE:-}"; do
    [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  done
  [ -z "${AS_IO:-}" ] || rm -rf "$AS_IO"
  AS_WRITER='' AS_PID='' AS_SEND='' AS_RECEIVE='' AS_IO=''
}
appserver_connected() {
  local pid
  for pid in "${AS_PID:-}" "${AS_SEND:-}" "${AS_RECEIVE:-}"; do
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  done
}
appserver_reconnect() {
  local delay=1 previous_turn=''
  if [ -f "$S/appserver/snapshot.json" ]; then
    previous_turn=$(jq -r '.turn_id // empty' "$S/appserver/snapshot.json")
  fi
  appserver_close
  while :; do
    if appserver_open && appserver_handshake; then
      appserver_rpc thread/resume "$(jq -cn --arg thread "$AS_THREAD" '{threadId:$thread}')"
      if [ "$AS_CLASS" = accepted ]; then
        appserver_resume_lost_turn "$previous_turn"
        # Time without a connection is not evidence that the turn stalled.
        now > "$S/appserver/activity"
        return 0
      fi
    fi
    appserver_close
    printf 'App Server connection unavailable; retrying thread %s in %ss\n' "$AS_THREAD" "$delay" >&2
    sleep "$delay"
    delay=$((delay * 2)); [ "$delay" -le 30 ] || delay=30
  done
}
appserver_resume_lost_turn() {
  local previous_turn=$1 id
  [ -n "$previous_turn" ] || return 0
  appserver_snapshot
  appserver_connected || return 0
  jq -e '.status=="running" or .status=="pr"' "$S/meta" >/dev/null || return 0
  if [ -f "$S/appserver/blocked" ] || appserver_done_current; then return 0; fi
  # Resume only a turn known to be active before disconnect and explicitly
  # interrupted now. Completed, failed and uncertain turns keep their policies.
  printf '%s\n' "$AS_SNAPSHOT" | jq -e --arg turn "$previous_turn" '
    .thread.status.type=="idle" and .turn.id==$turn and .turn.status=="interrupted" and
    .turn_id==null and (.question_pending|not) and .goal.status!="complete"' >/dev/null || return 0
  id="reconnect-$(printf '%s' "$previous_turn" | cksum | awk '{print $1 "-" $2}')"
  [ ! -f "$S/appserver/outbox/$id.receipt" ] || return 0
  # The normal mutation receipt prevents replay even if this reply is lost.
  appserver_deliver "$id" 'Continue the interrupted request in this worktree. Preserve existing changes.' 1
}
appserver_handshake() {
  appserver_rpc initialize '{"clientInfo":{"name":"devflow","version":"1"},"capabilities":{"experimentalApi":true}}'
  [ "$AS_CLASS" = accepted ] || return 1
  (printf '%s\n' '{"method":"initialized"}' >&9)
}
appserver_write() {
  # Never block the reader on a full pipe. The RPC deadline also bounds writes.
  printf '%s\n' "$1" >&9 & AS_WRITER=$!
}
appserver_write_end() {
  kill "$AS_WRITER" 2>/dev/null || true
  wait "$AS_WRITER" 2>/dev/null || true
  AS_WRITER=''
}
appserver_available() {
  ( appserver_probe ) 2>/dev/null
}
appserver_probe() {
  local AS_EVENTS=0 AS_SEQ=0 AS_IO AS_PID AS_SEND AS_RECEIVE AS_REPLY AS_CLASS AS_WRITER='' AS_LINE='' rc=0
  appserver_open || return 1
  trap appserver_close EXIT
  appserver_handshake || rc=$?
  appserver_close
  trap - EXIT
  return "$rc"
}
appserver_selected() {
  [ "$1" = codex ] && [ -z "$DV_AGENT_CMD_codex" ] || return 1
  [ "$2" = auto ] || return 1
  case "$DV_CODEX_MODE" in
    appserver) return 0 ;;
    auto|tui|goal|exec) appserver_available ;;
    *) fail 'DV_CODEX_MODE must be auto, appserver, exec, goal or tui' ;;
  esac
}
appserver_atomic() {
  local target=$1 tmp
  tmp=$(mktemp "$target.XXXXXX")
  cat > "$tmp" && mv "$tmp" "$target"
}
appserver_cache_write() {
  [ "${AS_EVENTS:-0}" = 1 ] || return 0
  printf '%s\n' "$AS_CACHED" | jq -c --argjson at "$(now)" \
    --arg thread "$AS_THREAD" '. + {observed_at:$at,thread_id:$thread}' |
    appserver_atomic "$S/appserver/status.json"
}
appserver_cache_event() {
  local line=$1 pending=false question
  for question in "$S/appserver/questions/"*.json; do
    [ ! -f "$question" ] || pending=true
  done
  AS_CACHED=$(printf '%s\n%s\n' "${AS_CACHED:-'{}'}" "$line" | jq -sc --argjson pending "$pending" '
    .[0] as $old | .[1] as $event | $event.params as $p | $event.method as $method |
    $old | .alive=true | .question_pending=$pending |
    if $method=="turn/started" then
      .thread.status.type="active" | .turn=$p.turn | .turn_id=$p.turn.id | .error=null
    elif $method=="turn/completed" then
      .thread.status.type="idle" | .turn=$p.turn | .turn_id=null | .error=$p.turn.error
    elif $method=="thread/status/changed" then .thread.status=$p.status
    elif $method=="thread/goal/updated" then .goal=$p.goal
    elif $method=="error" then .error=($p.error // $p)
    else . end |
    .agent_status=(if .error!=null or .turn.status=="failed" or .thread.status.type=="systemError" then "failed"
      elif .thread.status.type=="active" then "working"
      elif .goal.status=="complete" then "goal-complete"
      elif .goal.status=="active" then "idle-with-goal-active"
      elif .thread.status.type=="idle" then "idle"
      else (.agent_status // "unknown") end)')
  appserver_cache_write
}
appserver_event() {
  [ "$AS_EVENTS" = 1 ] || return 0
  local line=$1 method thread request key turn
  method=$(printf '%s\n' "$line" | jq -r '.method // ""')
  thread=$(printf '%s\n' "$line" | jq -r '.params.threadId // .params.thread.id // ""')
  [ -n "$thread" ] && [ "$thread" = "${AS_THREAD:-}" ] || return 0
  printf '%s\n' "$line" >> "$S/appserver/events.jsonl"
  case "$method" in
    item/*|turn/started) now > "$S/appserver/activity" ;;
  esac
  case "$method" in
    item/started|item/completed|item/*/delta|item/*Delta)
      if printf '%s\n' "$line" | jq -e '.params.item.type!="userMessage"' >/dev/null; then
        turn=$(printf '%s\n' "$line" | jq -r '.params.turnId // empty')
        if [ -n "$turn" ] && jq -e --arg turn "$turn" '.capacity.turn_id==$turn' "$S/meta" >/dev/null &&
          printf '%s\n' "$line" | jq -e '.params.item.type!="error"' >/dev/null; then capacity_clear; fi
        if [ -n "$turn" ] && [ -f "$S/appserver/recovery" ]; then
          printf '%s\n' "$turn" >> "$S/appserver/recovery-progress"
          appserver_recovery_progress
        fi
      fi
      if printf '%s\n' "$line" | jq -e '.params.item.type=="agentMessage" and (.params.item.text|type)=="string"' >/dev/null; then
        printf '%s\n' "$line" | jq -r '.params.item.text' | appserver_atomic "$S/appserver/last-agent-message"
      fi ;;
  esac
  case "$method" in
    item/tool/requestUserInput|tool/requestUserInput)
      request=$(printf '%s\n' "$line" | jq -c .id)
      key=$(printf '%s' "$request" | cksum | awk '{print $1 "-" $2}')
      printf '%s\n' "$line" | appserver_atomic "$S/appserver/questions/$key.json"
      appserver_questions ;;
    serverRequest/resolved)
      request=$(printf '%s\n' "$line" | jq -c .params.requestId)
      key=$(printf '%s' "$request" | cksum | awk '{print $1 "-" $2}')
      if [ -f "$S/appserver/questions/$key.json" ]; then
        mv "$S/appserver/questions/$key.json" "$S/appserver/questions/$key.resolved"
      fi ;;
    error)
      printf '%s\n' "$line" | appserver_atomic "$S/appserver/error.json" ;;
    turn/started) rm -f "$S/appserver/error.json" ;;
  esac
  appserver_cache_event "$line"
}
appserver_questions() {
  local question key
  for question in "$S/appserver/questions/"*.json; do
    [ -f "$question" ] || continue
    key=${question##*/}; key=${key%.json}
    [ ! -f "$S/appserver/questions/$key.sent" ] || continue
    DV_QUESTION_EPISODE="appserver:$AS_THREAD:$key" cmd_kick question "$ISSUE" "$(jq -c '{requestId:.id,questions:.params.questions}' "$question")"
    if tail -n 1 "$S/events.log" | jq -e '.kind=="question" and .delivered' >/dev/null; then touch "$S/appserver/questions/$key.sent"; fi
  done
}
appserver_read_line() {
  # Time only the wakeup. Even a one-byte read can consume its byte and then
  # time out before Bash 3.2 assigns it. The decoder retains the full bounded
  # record until this consumer acknowledges it; partial remote frames stay
  # in the decoder and still obey the existing RPC deadline.
  local deadline=$(( $(now) + $1 )) _wake
  AS_LINE=''
  while :; do
    IFS= read -r -n 1 -t 1 _wake <&8 || true
    if [ -f "$AS_IO/receive-record" ]; then
      AS_LINE=$(cat "$AS_IO/receive-record") || return 1
      rm "$AS_IO/receive-record"
      printf '.' >&5
      return 0
    fi
    if { [ -n "${AS_PID:-}" ] && ! appserver_connected; } || [ "$(now)" -ge "$deadline" ]; then
      return 1
    fi
  done
}
appserver_rpc() {
  local method=$1 params=$2 id=${3:-} line deadline
  AS_SEQ=$((AS_SEQ + 1))
  [ -n "$id" ] || id="rpc-$$-$AS_SEQ"
  AS_REPLY='{}'; AS_CLASS=unknown
  appserver_write "$(printf '%s\n' "$params" | jq -c --arg id "$id" --arg method "$method" '{id:$id,method:$method,params:.}')"
  deadline=$(( $(now) + DV_APPSERVER_TIMEOUT ))
  while [ "$(now)" -le "$deadline" ]; do
    if appserver_read_line $(( deadline - $(now) + 1 )); then
      line=$AS_LINE
      printf '%s\n' "$line" | jq -e 'type=="object"' >/dev/null 2>&1 || continue
      if printf '%s\n' "$line" | jq -e --arg id "$id" '.id==$id and .method==null and (has("result") or has("error"))' >/dev/null; then
        AS_REPLY=$line
        if printf '%s\n' "$line" | jq -e '(.error.code|type)=="number" and (.error.message|type)=="string"' >/dev/null; then AS_CLASS=refused
        elif printf '%s\n' "$line" | jq -e --arg method "$method" '
          (.result|type)=="object" and
          (if $method=="turn/start" then (.result.turn.id|type)=="string"
           elif $method=="turn/steer" then (.result.turnId|type)=="string"
           elif $method=="thread/start" or $method=="thread/read" or $method=="thread/resume" then (.result.thread.id|type)=="string"
           else true end)' >/dev/null; then AS_CLASS=accepted; fi
        if [ "$AS_CLASS" = accepted ] && [ "${AS_EVENTS:-0}" = 1 ] && [ -n "${AS_THREAD:-}" ]; then
          case "$method" in
            turn/start)
              appserver_cache_event "$(printf '%s\n' "$AS_REPLY" | jq -c '{method:"turn/started",params:{turn:.result.turn}}')" ;;
            thread/goal/set|thread/goal/get)
              appserver_cache_event "$(printf '%s\n' "$AS_REPLY" | jq -c '{method:"thread/goal/updated",params:{goal:.result.goal}}')" ;;
          esac
        fi
        appserver_write_end; return 0
      fi
      appserver_event "$line"
    elif ! appserver_connected; then break; fi
  done
  appserver_write_end
}
appserver_receipt() {
  printf '%s\n' "$AS_REPLY" | jq -c --arg id "$1" --arg outcome "$AS_CLASS" \
    --argjson time "$(now)" '{id:$id,outcome:$outcome,reply:.,time:$time}' |
    appserver_atomic "$S/appserver/outbox/$1.receipt"
}
appserver_mutate() {
  local id=$1 method=$2 params=$3
  printf '%s\n' "$params" | jq -c --arg id "$id" --arg method "$method" '{id:$id,method:$method,params:.}' |
    appserver_atomic "$S/appserver/outbox/$id.wire"
  # Commit uncertainty BEFORE writing to the transport. A crash never replays it.
  AS_CLASS=unknown AS_REPLY='{}'; appserver_receipt "$id"
  appserver_rpc "$method" "$params" "$id"
  appserver_receipt "$id"
}
appserver_snapshot() {
  local params thread goal='null' error='null' state last
  params=$(jq -cn --arg thread "$AS_THREAD" '{threadId:$thread,includeTurns:true}')
  appserver_rpc thread/read "$params"
  if [ "$AS_CLASS" != accepted ]; then
    state=unknown
    if printf '%s\n' "$AS_REPLY" | jq -e '.error.data.codexErrorInfo=="threadNotFound" or ((.error.message // "")|test("^(thread not found|no thread found)";"i"))' >/dev/null; then state=gone; fi
    AS_SNAPSHOT=$(jq -cn --arg state "$state" '{agent_status:$state,alive:false,question_pending:false}')
    appserver_recovery_info
    appserver_cache_snapshot
    return
  fi
  last=$(printf '%s\n' "$AS_REPLY" | jq -c '[.result.thread.turns[]?.items[]? | select(.type=="agentMessage") | .text // empty][-1] // ""')
  thread=$(printf '%s\n' "$AS_REPLY" | jq -c '.result.thread | {id,status,cwd,updatedAt,
    turns:[.turns[-1] // empty | {id,status,error,items:[.items[]? | {id,type,status,error}]}]}')
  appserver_rpc thread/goal/get "$(jq -cn --arg thread "$AS_THREAD" '{threadId:$thread}')"
  if [ "$AS_CLASS" = accepted ]; then goal=$(printf '%s\n' "$AS_REPLY" | jq -c '.result.goal // null'); fi
  if [ -f "$S/appserver/error.json" ]; then
    # A retryable error (willRetry) followed by a completed turn was recovered
    # by Codex itself; it must not keep the job "failed" and block land/clean.
    error=$(printf '%s\n' "$thread" | jq -c --slurpfile e "$S/appserver/error.json" '
      ($e[0].params // {}) as $p | (.turns[-1] // {}) as $turn |
      if $p.willRetry==true and $turn.status=="completed" and ($p.turnId==null or $p.turnId==$turn.id)
      then null else ($p.error // $p) end')
  fi
  AS_SNAPSHOT=$(printf '%s\n%s\n%s\n%s\n' "$thread" "$goal" "$error" "$last" | jq -sc '
    .[0] as $thread | .[1] as $goal | .[2] as $error | .[3] as $last |
    ($thread.turns[-1] // {}) as $turn |
    {last_agent_message:$last,thread:$thread,turn:$turn,goal:$goal,error:($turn.error // $error),
     turn_id:([$thread.turns[]? | select(.status=="inProgress") | .id][-1] // null),
     alive:true,question_pending:false,
     agent_status:(if $thread.status.type=="systemError" or $turn.status=="failed" or $turn.error!=null or $error!=null or any($turn.items[]?; .type=="error") then "failed"
       elif $thread.status.type=="active" then "working"
       elif $goal.status=="complete" then "goal-complete"
       elif $goal.status=="active" then "idle-with-goal-active"
       else "idle" end)}')
  local question
  for question in "$S/appserver/questions/"*.json; do
    [ ! -f "$question" ] || AS_SNAPSHOT=$(printf '%s\n' "$AS_SNAPSHOT" | jq -c '.question_pending=true')
  done
  appserver_recovery_info
  printf '%s\n' "$AS_SNAPSHOT" | appserver_atomic "$S/appserver/snapshot.json"
  appserver_cache_snapshot
}
appserver_cache_snapshot() {
  [ "${AS_EVENTS:-0}" = 1 ] || return 0
  AS_CACHED=$AS_SNAPSHOT
  appserver_cache_write
}
appserver_deliver() {
  local id=$1 text=$2 recovery=${3:-0} state turn params method active cleaned
  appserver_snapshot
  state=$(printf '%s\n' "$AS_SNAPSHOT" | jq -r .agent_status)
  turn=$(printf '%s\n' "$AS_SNAPSHOT" | jq -r '.turn_id // ""')
  active=$(printf '%s\n' "$AS_SNAPSHOT" | jq -r '.thread.status.type=="active" or .turn_id!=null')
  AS_CLASS=refused; AS_REPLY='{"error":{"message":"thread state does not permit delivery"}}'
  case "$state" in unknown|gone) return ;; esac
  if [ "$recovery" = 1 ] && [ "$active" = true ]; then return; fi
  method=turn/start
  params=$(jq -cn --arg thread "$AS_THREAD" --arg text "$text" --arg effort "$DV_CODEX_EFFORT" '{threadId:$thread,input:[{type:"text",text:$text,text_elements:[]}],effort:$effort}')
  if [ "$active" = true ]; then
    [ -n "$turn" ] || return 0
    method=turn/steer
    params=$(printf '%s\n' "$params" | jq -c --arg turn "$turn" 'del(.effort) | .expectedTurnId=$turn')
  fi
  # Invalidate the old cleanup before a new turn can finish. An unknown
  # delivery can be running; only an explicit refusal restores the old state.
  cleaned=$(jq -c 'select(.cleaned_at!=null) | {cleaned_at,status,done_at}' "$S/meta")
  if [ -n "$cleaned" ]; then
    meta_set '.status="running" | del(.cleaned_at,.done_at)'
  fi
  appserver_mutate "$id" "$method" "$params"
  if [ "$AS_CLASS" = refused ] && [ -n "$cleaned" ]; then
    meta_set --argjson previous "$cleaned" '. + $previous'
  fi
  if [ "$AS_CLASS" = accepted ]; then
    rm -f "$S/appserver/error.json"
    now > "$S/appserver/activity"
  fi
}
appserver_answer() {
  local id=$1 text=$2 question='' file count=0 params request deadline line selected
  selected=$(printf '%s\n' "$text" | jq -c '.requestId // null' 2>/dev/null) || selected=null
  for file in "$S/appserver/questions/"*.json; do
    [ -f "$file" ] || continue
    if [ "$selected" != null ] && ! jq -e --argjson id "$selected" '.id==$id' "$file" >/dev/null; then continue; fi
    count=$((count + 1)); question=$file
  done
  AS_CLASS=refused; AS_REPLY='{"error":{"message":"answer requires one pending request and answers for every question id"}}'
  [ "$count" = 1 ] || return 0
  if params=$(printf '%s\n' "$text" | jq -ce --slurpfile q "$question" '
    select(.answers|type=="object") | select(.answers as $a | all($q[0].params.questions[]; ($a[.id].answers|type)=="array" and all($a[.id].answers[];type=="string"))) | {answers}'); then :
  elif [ "$(jq '.params.questions|length' "$question")" = 1 ]; then
    params=$(jq -cn --arg text "$text" --slurpfile q "$question" '{answers:{($q[0].params.questions[0].id):{answers:[$text]}}}')
  else return 0; fi
  request=$(jq -c .id "$question")
  jq -cn --argjson id "$request" --argjson result "$params" '{id:$id,result:$result}' | appserver_atomic "$S/appserver/outbox/$id.wire"
  AS_CLASS=unknown AS_REPLY='{}'; appserver_receipt "$id"
  appserver_write "$(cat "$S/appserver/outbox/$id.wire")"
  deadline=$(( $(now) + DV_APPSERVER_TIMEOUT ))
  while [ "$(now)" -le "$deadline" ]; do
    if appserver_read_line $(( deadline - $(now) + 1 )); then
      line=$AS_LINE
      printf '%s\n' "$line" | jq -e 'type=="object"' >/dev/null 2>&1 || continue
      appserver_event "$line"
      if printf '%s\n' "$line" | jq -e --argjson id "$request" --arg thread "$AS_THREAD" '.method=="serverRequest/resolved" and .params.requestId==$id and .params.threadId==$thread' >/dev/null; then
        AS_CLASS=accepted AS_REPLY=$line; break
      fi
    elif ! appserver_connected; then break; fi
  done
  appserver_write_end
  appserver_receipt "$id"
}
appserver_alive() { appserver_client_alive_at "$S" "$ISSUE"; }
appserver_client_alive_at() {
  local pid
  [ -f "$1/appserver/client.pid" ] || return 1
  pid=$(cat "$1/appserver/client.pid")
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null &&
    ps -o args= -p "$pid" 2>/dev/null | grep -Fq -- "dv _appserver-run $2"
}
appserver_request() {
  local operation=$1 text=${2:-} request id deadline receipt
  for request in "$S/appserver/outbox/"*.json; do
    [ -f "$request" ] || continue
    receipt=${request%.json}.receipt
    if [ "$operation" = send ] &&
      jq -e --arg text "$text" '.operation=="send" and .text==$text' "$request" >/dev/null &&
      { [ ! -f "${request%.json}.finished" ] || jq -e '.outcome=="unknown"' "$receipt" >/dev/null; }; then
      if [ -f "$receipt" ]; then cat "$receipt"
      else jq -c '{id,outcome:"unknown",reason:"original request is still pending"}' "$request"; fi
      return 1
    fi
  done
  request=$(mktemp "$S/appserver/outbox/request.XXXXXX"); id=${request##*/}
  jq -cn --arg id "$id" --arg operation "$operation" --arg text "$text" '{id:$id,operation:$operation,text:$text}' > "$request"
  if ! appserver_alive; then
    if [ "$operation" != send ] || ! jq -e '.thread_id|type=="string"' "$S/meta" >/dev/null || ! appserver_start; then
      local AS_CLASS=refused AS_REPLY='{"error":{"message":"App Server client unavailable; no delivery attempted"}}'
      appserver_receipt "$id"
      mv "$request" "$request.json"
      touch "$request.finished"
      cat "$request.receipt"; return 1
    fi
  fi
  mv "$request" "$request.json"
  deadline=$(( $(now) + DV_APPSERVER_TIMEOUT * 5 + 5 ))
  while [ ! -f "$request.finished" ]; do
    if ! appserver_alive || [ "$(now)" -gt "$deadline" ]; then
      if [ -f "$request.receipt" ]; then cat "$request.receipt"
      else jq -cn --arg id "$id" '{id:$id,outcome:"unknown",reason:"request remains queued; inspect before sending again"}'; fi
      return 1
    fi
    sleep 0.1
  done
  cat "$request.receipt"
  jq -e '.outcome=="accepted"' "$request.receipt" >/dev/null
}
appserver_start() (
  local deadline client
  owned_lock "$S/.appserver-start" "$$" || return 1
  trap 'owned_unlock "$S/.appserver-start" "$$"' EXIT
  appserver_alive && return 0
  [[ "$DV_APPSERVER_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || fail 'DV_APPSERVER_TIMEOUT must be positive seconds'
  [[ "$DV_APPSERVER_POLL" =~ ^[1-9][0-9]*$ ]] || fail 'DV_APPSERVER_POLL must be positive seconds'
  mkdir -p "$S/appserver/outbox" "$S/appserver/questions"
  chmod 700 "$S/appserver"
  [[ "$DV_RECOVER_MAX" =~ ^[1-9][0-9]*$ ]] || fail 'DV_RECOVER_MAX must be a positive integer'
  capacity_validate
  if command -v setsid >/dev/null; then
    # Reparent before waiting for readiness: bounded watcher cleanup must not
    # include the persistent client among its descendants.
    client=$(nohup setsid "$DV_ROOT/bin/dv" _appserver-run "$ISSUE" >> "$S/log" 2>&1 < /dev/null & printf '%s\n' "$!")
  else
    client=$(set -m; nohup "$DV_ROOT/bin/dv" _appserver-run "$ISSUE" >> "$S/log" 2>&1 < /dev/null & printf '%s\n' "$!")
  fi
  deadline=$(( $(now) + DV_APPSERVER_TIMEOUT * 5 + 5 ))
  while [ "$(cat "$S/appserver/ready" 2>/dev/null)" != "$client" ]; do
    kill -0 "$client" 2>/dev/null && [ "$(now)" -le "$deadline" ] || return 1
    sleep 0.1
  done
)
cmd__appserver_run() {
  load_issue "$1"
  if jq -e '.thread_id|type=="string"' "$S/meta" >/dev/null; then
    require_worktree --allow-branch-change
  else require_worktree; fi
  umask 077
  local AS_EVENTS=1 AS_SEQ=0 AS_THREAD='' AS_REPLY='{}' AS_CLASS=unknown AS_SNAPSHOT='{}'
  # EXIT also runs after this function returns; transport handles must survive
  # the function's local scope so cleanup can still reap every child.
  AS_IO='' AS_PID='' AS_SEND='' AS_RECEIVE='' AS_WRITER=''
  local AS_LINE='' AS_CACHED='{}'
  local instruction params id file operation text line last_poll=0
  # bin/dv captures HEAD before sourcing the libraries.
  local client_commit=${entry_commit:-} current_commit
  DV_APPSERVER_SOCKET=$(jq -r --arg socket "$DV_APPSERVER_SOCKET" '.appserver_socket // $socket' "$S/meta")
  AS_THREAD=$(jq -r '.thread_id // ""' "$S/meta")
  printf '%s\n' "$$" > "$S/appserver/client.pid"
  trap 'appserver_close; touch "$S/appserver/exited"; rm -f "$S/appserver/client.pid"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  rm -f "$S/appserver/exited"
  instruction="Read $S/brief.md and complete everything it asks. Finish with dv done $ISSUE."
  if [ -z "$AS_THREAD" ]; then
    appserver_open && appserver_handshake || return 1
    params=$(jq -cn --arg cwd "$WT" --arg model "$DV_CODEX_MODEL" --arg effort "$DV_CODEX_EFFORT" \
      --arg config "$DV_CONFIG" --arg state "$DV_STATE" --arg work "$DV_WORK" --arg home "$DV_HOME" --arg host "$DV_HOST" --arg path "$DV_ROOT/bin:$PATH" \
      --arg tmp "$TMPDIR" --arg cache "${GOCACHE:-}" \
      '{cwd:$cwd,model:$model,approvalPolicy:"never",sandbox:"danger-full-access",config:{model_reasoning_effort:$effort,
        shell_environment_policy:{set:({DV_CONFIG:$config,DV_STATE:$state,DV_WORK:$work,DV_HOME:$home,DV_HOST:$host,PATH:$path,TMPDIR:$tmp,DV_TMP:$tmp} +
          (if $cache=="" then {} else {GOCACHE:$cache} end))}}}')
    appserver_mutate thread-start thread/start "$params"
    [ "$AS_CLASS" = accepted ] || return 1
    AS_THREAD=$(printf '%s\n' "$AS_REPLY" | jq -er '.result.thread.id') || return 1
    meta_set --arg thread "$AS_THREAD" --arg socket "$DV_APPSERVER_SOCKET" '.thread_id=$thread | .appserver_socket=$socket'
    params=$(jq -cn --arg thread "$AS_THREAD" --arg objective "$instruction" '{threadId:$thread,objective:$objective,status:"active"}')
    appserver_mutate goal-set thread/goal/set "$params"
    if [ "$AS_CLASS" != accepted ] && ! printf '%s\n' "$AS_REPLY" | jq -e '.error.code==-32601' >/dev/null; then return 1; fi
    params=$(jq -cn --arg thread "$AS_THREAD" --arg text "$instruction" --rawfile brief "$S/brief.md" --arg effort "$DV_CODEX_EFFORT" '{threadId:$thread,input:[{type:"text",text:($text+"\n\n"+$brief),text_elements:[]}],effort:$effort}')
    appserver_mutate initial-turn turn/start "$params"
    if [ "$AS_CLASS" != accepted ]; then
      if [ "$AS_CLASS" = refused ] && printf '%s\n' "$AS_REPLY" | jq -c .error | capacity_error; then
        printf '%s\n' "$AS_REPLY" | jq -c '{params:{error:.error}}' | appserver_atomic "$S/appserver/error.json"
        printf '%s\n' "$params" | jq -r '.input[0].text' | appserver_atomic "$S/appserver/capacity-prompt"
      else return 1; fi
    fi
  else
    appserver_reconnect
  fi
  now > "$S/appserver/activity"
  touch "$S/agent.started"
  appserver_snapshot
  printf '%s\n' "$$" > "$S/appserver/ready"
  while :; do
    if ! appserver_connected; then appserver_reconnect; last_poll=0; fi
    for file in "$S/appserver/outbox/"*.json; do
      appserver_connected || break
      [ -f "$file" ] || continue
      id=${file##*/}; id=${id%.json}
      [ ! -f "$S/appserver/outbox/$id.receipt" ] || continue
      operation=$(jq -r .operation "$file"); text=$(jq -r .text "$file")
      AS_CLASS=unknown AS_REPLY='{}'; appserver_receipt "$id"
      case "$operation" in
        send)
          if [ -n "$(ls "$S/appserver/questions/"*.json 2>/dev/null)" ]; then appserver_answer "$id" "$text"
          else appserver_deliver "$id" "$text"; fi ;;
        status) appserver_snapshot; AS_CLASS=accepted; AS_REPLY=$AS_SNAPSHOT ;;
        recover) appserver_recover "$id" ;;
        stop) appserver_stop_turn "$id" ;;
        finish)
          appserver_rpc thread/goal/get "$(jq -cn --arg thread "$AS_THREAD" '{threadId:$thread}')"
          if [ "$AS_CLASS" = accepted ] && printf '%s\n' "$AS_REPLY" | jq -e '.result.goal!=null and .result.goal.status!="complete"' >/dev/null; then
            appserver_mutate "$id" thread/goal/set "$(jq -cn --arg thread "$AS_THREAD" '{threadId:$thread,status:"complete"}')"
          fi
          if printf '%s\n' "$AS_REPLY" | jq -e '.error.code==-32601' >/dev/null; then AS_CLASS=accepted; fi ;;
        *) AS_CLASS=refused; AS_REPLY='{"error":{"message":"unknown operation"}}' ;;
      esac
      appserver_receipt "$id"
      touch "$S/appserver/outbox/$id.finished"
    done
    if appserver_read_line 1; then
      line=$AS_LINE
      if printf '%s\n' "$line" | jq -e 'type=="object"' >/dev/null 2>&1; then appserver_event "$line"; fi
    fi
    if [ $(( $(now) - last_poll )) -ge "$DV_APPSERVER_POLL" ]; then
      # Outbox RPCs and their receipts are settled before switching code. exec
      # keeps client.pid valid; the persisted thread takes the resume path.
      current_commit=$(self_update_head)
      if [ -n "$current_commit" ] && [ "$current_commit" != "$client_commit" ]; then
        appserver_close
        exec "$DV_ROOT/bin/dv" _appserver-run "$ISSUE"
      fi
      appserver_snapshot; appserver_questions; last_poll=$(now)
      if [ -f "$S/appserver/blocked" ] && [ ! -f "$S/appserver/recoveries.json" ]; then
        appserver_recover legacy-recovery
      elif jq -e '.capacity!=null' "$S/meta" >/dev/null ||
        printf '%s\n' "$AS_SNAPSHOT" | jq -c '[.error,.turn.items[]?.error]' | capacity_error; then
        appserver_recover "capacity-$(now)"
      fi
    fi
  done
}
appserver_status() (
  load_issue "$1"
  local receipt AS_EVENTS=0 AS_SEQ=0 AS_THREAD AS_REPLY AS_CLASS AS_SNAPSHOT AS_IO AS_PID AS_SEND AS_RECEIVE AS_WRITER='' AS_LINE=''
  if appserver_alive; then
    if receipt=$(appserver_request status); then printf '%s\n' "$receipt" | jq -c .reply; return; fi
  else
    # This read-only connection has its own dynamically scoped thread variable.
    # shellcheck disable=SC2030
    AS_THREAD=$(jq -r '.thread_id // ""' "$S/meta")
    DV_APPSERVER_SOCKET=$(jq -r --arg socket "$DV_APPSERVER_SOCKET" '.appserver_socket // $socket' "$S/meta")
    if [ -n "$AS_THREAD" ] && appserver_open; then
      trap appserver_close EXIT
      if appserver_handshake; then appserver_snapshot; printf '%s\n' "$AS_SNAPSHOT"; return; fi
    fi
  fi
  # The caller and job runner each own their dynamically scoped snapshot.
  # shellcheck disable=SC2030
  AS_SNAPSHOT='{"agent_status":"unknown","alive":false,"question_pending":false}'
  appserver_recovery_info
  printf '%s\n' "$AS_SNAPSHOT"
)
appserver_cached_row() {
  local path=$1 time=$2 dir=${1%/meta} client=false pid=''
  [ ! -f "$dir/appserver/client.pid" ] || read -r pid < "$dir/appserver/client.pid" || true
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then client=true; fi
  jq -c --argjson at "$time" --argjson client "$client" --arg transcript "${3:-}" \
    --rawfile cache <(cat "$dir/appserver/status.json" 2>/dev/null || true) \
    --rawfile 'done' <(cat "$dir/done.json" 2>/dev/null || true) \
    --rawfile last <(tail -c 200 "$dir/log" 2>/dev/null || true) '
    . as $meta |
    ((try ($cache|fromjson|select(type=="object" and (.observed_at|type)=="number")) catch null) // null) as $cached |
    (if $cached.thread_id!=null and $cached.thread_id!=$meta.thread_id then null else $cached end) as $valid |
    ({agent_status:"unknown",alive:false,question_pending:false,recoveries:0,last_recovery_reason:null} + $valid |
      if $client then . else .alive=false | .question_pending=false |
        .agent_status=(if $meta.status=="done" or $meta.status=="landed" or $meta.status=="cancelled" or $meta.cleaned_at!=null then "gone" else "unknown" end) end |
      .status_age_seconds=(if $valid.observed_at!=null then [0,($at-$valid.observed_at)]|max else null end)) as $info |
    . + {done_head:(try ($done|fromjson|.head) catch null),transcript:(if $transcript=="" then null else $transcript end),backend:"appserver",alive:$info.alive,
      agent_status:$info.agent_status,agent_dead:false,tmux:false,elapsed:($at-.started),
      last_log:($last|split("\n")|map(select(length>0))|last // ""),question_pending:$info.question_pending,
      goal_stalled:false,goal_active:false,agent_state_seq:null,agent_session:null,capacity_detected:false,
      appserver:$info,recoveries:$info.recoveries,last_recovery_reason:$info.last_recovery_reason,
      status_age_seconds:$info.status_age_seconds,capacity_retry_at:(.capacity.next_try_at // null)} |
    if .status=="waiting-capacity" then .agent_status="waiting-capacity" else . end' "$path"
}
appserver_recovery_info() {
  local info='{"recoveries":0,"last_recovery_reason":null}' retry=null
  if [ -f "$S/appserver/recoveries.json" ]; then info=$(cat "$S/appserver/recoveries.json")
  elif [ -f "$S/appserver/recovery" ]; then info='{"recoveries":1,"last_recovery_reason":"legacy"}'; fi
  retry=$(jq -r '.capacity.next_try_at // "null"' "$S/meta")
  # shellcheck disable=SC2031
  AS_SNAPSHOT=$(printf '%s\n%s\n' "$AS_SNAPSHOT" "$info" | jq -sc --argjson retry "$retry" '.[0] + .[1] + {capacity_retry_at:$retry}')
}
appserver_recovery_progress() {
  local turn
  [ -f "$S/appserver/recovery" ] && [ -f "$S/appserver/recovery-progress" ] || return 0
  turn=$(jq -r '.turn_id // empty' "$S/appserver/recovery")
  # An uncertain receipt, an old turn, or turn/started alone is not progress.
  if [ -n "$turn" ] && grep -Fxq -- "$turn" "$S/appserver/recovery-progress"; then
    rm -f "$S/appserver/recovery" "$S/appserver/recovery-progress"
  fi
}
appserver_blocked() {
  local message=$1 last
  [ ! -f "$S/appserver/blocked" ] || return 0
  last=$(printf '%s\n' "$AS_SNAPSHOT" | jq -r '.last_agent_message // empty')
  if [ -z "$last" ] && [ -f "$S/appserver/last-agent-message" ]; then last=$(cat "$S/appserver/last-agent-message"); fi
  cmd_kick blocked "$ISSUE" "$message${last:+; last agent message: $last}"
  if jq -e '.capacity!=null' "$S/meta" >/dev/null; then
    meta_set --arg reason "$message" '.status="blocked" | .failure_reason=$reason | .capacity.next_try_at=null'
  fi
  touch "$S/appserver/blocked"
}
appserver_done_current() {
  local head
  [ -f "$S/done.json" ] || return 1
  # Completion belongs to one revision. Keep older markers as history when a
  # PR correction resumes the same job. If HEAD is unreadable, do not replay.
  head=$(git -C "$WT" rev-parse HEAD) || return 0
  jq -e --arg head "$head" '.head==$head' "$S/done.json" >/dev/null 2>&1
}
appserver_recover() {
  local id=$1 state last params reason text=continue count turn capacity_rc
  AS_CLASS=accepted AS_REPLY='{}'
  # A queued watch may outlive dv done or a prior recovery decision.
  if [ -f "$S/appserver/blocked" ] && { [ -f "$S/appserver/recoveries.json" ] || jq -e '.capacity!=null' "$S/meta" >/dev/null; }; then return 0; fi
  if appserver_done_current; then return 0; fi
  jq -e '.status=="running" or .status=="pr" or .status=="waiting-capacity"' "$S/meta" >/dev/null || return 0
  appserver_snapshot
  state=$(printf '%s\n' "$AS_SNAPSHOT" | jq -r .agent_status)
  AS_CLASS=accepted AS_REPLY='{}'
  printf '%s\n' "$AS_SNAPSHOT" | jq -e '.question_pending|not' >/dev/null || return 0
  if appserver_done_current; then return 0; fi
  if [ -f "$S/appserver/blocked" ]; then
    [ "$state" = failed ] || return 0
    # Older clients could block before recording a recovery budget. Persist
    # the migration before unblocking so a later block is never reconsidered.
    # Keep any legacy recovery episode and its consumed count intact.
    printf '%s\n' "$AS_SNAPSHOT" | jq -c '{recoveries,last_recovery_reason}' |
      appserver_atomic "$S/appserver/recoveries.json"
    rm -f "$S/appserver/blocked"
  fi
  case "$state" in
    failed)
      reason=failed
      if printf '%s\n' "$AS_SNAPSHOT" | jq -c '[.error,.turn.items[]?.error]' | capacity_error; then
        reason=capacity
      fi ;;
    idle|goal-complete|idle-with-goal-active|working)
      # A new turn with real output or a completed request ends this episode.
      # Merely accepting turn/start must not reset a persistent provider limit.
      if printf '%s\n' "$AS_SNAPSHOT" | jq -e '.turn.status=="completed" or any(.turn.items[]?; .type!="userMessage" and .type!="error")' >/dev/null; then
        capacity_clear
      fi
      last=$(cat "$S/appserver/activity")
      [ $(( $(now) - last )) -ge "$DV_STALL_AFTER" ] || return 0
      reason=stalled
      if [ "$state" != working ]; then
        reason=idle-without-done
        text="You stopped without dv done. Read your brief, finish what is missing (push, PR, CI green, review fix), then run dv done $ISSUE. If something truly blocks you, run dv kick blocked $ISSUE with the reason."
        if [ -f "$S/appserver/idle-continuation" ]; then
          appserver_blocked 'App Server returned to idle without dv done after its continuation'
          return 0
        fi
      fi ;;
    *) return 0 ;;
  esac
  if [ "$reason" = capacity ]; then
    if [ -f "$S/appserver/recovery" ] && jq -e '.turn_id==null' "$S/appserver/recovery" >/dev/null; then
      appserver_blocked 'App Server recovery outcome is unknown; no automatic replay'
      return 0
    fi
    capacity_rc=0; capacity_poll || capacity_rc=$?
    case "$capacity_rc" in
      1) return 0 ;;
      2) capacity_block; touch "$S/appserver/blocked"; return 0 ;;
    esac
    text='Continue the interrupted request in this worktree. Preserve existing changes.'
    if [ -f "$S/appserver/capacity-prompt" ]; then
      text="$text The original request follows:
$(cat "$S/appserver/capacity-prompt")"
    fi
    capacity_resume
  else
  capacity_clear
  if [ -f "$S/appserver/recovery" ]; then
    appserver_blocked 'App Server recovery made no new progress; no automatic replay'
    return 0
  fi
  count=$(printf '%s\n' "$AS_SNAPSHOT" | jq -r .recoveries)
  if [ "$count" -ge "$DV_RECOVER_MAX" ]; then
    appserver_blocked "App Server recovery budget exhausted ($count/$DV_RECOVER_MAX)"
    return 0
  fi
  case "$reason" in
    failed) cmd_kick failed "$ISSUE" "$(printf '%s\n' "$AS_SNAPSHOT" | jq -c '.error // {message:"App Server turn failed"}')" ;;
    stalled|idle-without-done) cmd_kick stalled "$ISSUE" 'App Server job has no new items and no dv done' ;;
  esac
  # Persist the episode and budget BEFORE attempting any mutation. Unknown
  # outcomes stay consumed, including across a client restart.
  printf '{"turn_id":null}\n' | appserver_atomic "$S/appserver/recovery"
  rm -f "$S/appserver/recovery-progress"
  jq -cn --argjson count "$((count + 1))" --arg reason "$reason" \
    '{recoveries:$count,last_recovery_reason:$reason}' | appserver_atomic "$S/appserver/recoveries.json"
  if [ "$reason" = idle-without-done ]; then touch "$S/appserver/idle-continuation"; fi
  fi
  if printf '%s\n' "$AS_SNAPSHOT" | jq -e '.thread.status.type=="active" or .turn_id!=null' >/dev/null; then
    # shellcheck disable=SC2031
    if ! params=$(printf '%s\n' "$AS_SNAPSHOT" | jq -ce --arg thread "$AS_THREAD" 'select(.turn_id!=null) | {threadId:$thread,turnId:.turn_id}'); then
      appserver_blocked 'App Server active turn ID is unknown; continuation was not sent'
      return 0
    fi
    appserver_mutate "$id-interrupt" turn/interrupt "$params"
    if [ "$AS_CLASS" != accepted ]; then
      appserver_blocked 'App Server interrupt was not accepted; recovery will not be retried'
      return 0
    fi
    if ! appserver_wait_idle; then
      AS_CLASS=refused AS_REPLY='{"error":{"message":"interrupted turn did not become idle before the deadline"}}'
      appserver_blocked 'App Server interrupt completion is unconfirmed; continuation was not sent'
      return 0
    fi
  fi
  appserver_deliver "$id" "$text" 1
  if [ "$AS_CLASS" != accepted ]; then
    if [ "$reason" = capacity ] && [ "$AS_CLASS" = refused ] &&
      printf '%s\n' "$AS_REPLY" | jq -c .error | capacity_error; then
      printf '%s\n' "$AS_REPLY" | jq -c '{params:{error:.error}}' | appserver_atomic "$S/appserver/error.json"
      capacity_rc=0; capacity_poll || capacity_rc=$?
      if [ "$capacity_rc" = 2 ]; then capacity_block; touch "$S/appserver/blocked"; fi
    else appserver_blocked 'App Server continuation was not accepted; recovery will not be retried'; fi
  elif [ "$reason" = capacity ]; then
    rm -f "$S/appserver/capacity-prompt"
    turn=$(printf '%s\n' "$AS_REPLY" | jq -r '.result.turn.id')
    meta_set --arg turn "$turn" 'if .capacity!=null then .capacity.turn_id=$turn else . end'
  else
    turn=$(printf '%s\n' "$AS_REPLY" | jq -r '.result.turn.id')
    jq -cn --arg turn "$turn" '{turn_id:$turn}' | appserver_atomic "$S/appserver/recovery"
    appserver_recovery_progress
  fi
}
appserver_wait_idle() {
  local deadline params
  deadline=$(( $(now) + DV_APPSERVER_TIMEOUT ))
  # This runs in the job client's scope, not appserver_status's read-only scope.
  # shellcheck disable=SC2031
  params=$(jq -cn --arg thread "$AS_THREAD" '{threadId:$thread,includeTurns:true}')
  while :; do
    appserver_rpc thread/read "$params"
    if [ "$AS_CLASS" = accepted ] && printf '%s\n' "$AS_REPLY" | jq -e '
      .result.thread.status.type=="idle" and all(.result.thread.turns[]?; .status!="inProgress")' >/dev/null; then return 0; fi
    [ "$(now)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}
appserver_require_idle() {
  local server
  server=$(appserver_status "$ISSUE")
  printf '%s\n' "$server" | jq -e '.agent_status=="goal-complete" or .agent_status=="idle" or .agent_status=="gone"' >/dev/null ||
    fail 'App Server thread is active or uncertain; worktree retained'
}
# Runs in the job client's scope, separate from appserver_status's connection.
# shellcheck disable=SC2031
appserver_stop_turn() {
  local id=$1 params
  appserver_rpc thread/read "$(jq -cn --arg thread "$AS_THREAD" '{threadId:$thread,includeTurns:true}')"
  [ "$AS_CLASS" = accepted ] || return 0
  if printf '%s\n' "$AS_REPLY" | jq -e '
    (.result.thread.status.type=="idle" or .result.thread.status.type=="systemError") and
    all(.result.thread.turns[]?; .status!="inProgress")' >/dev/null; then return 0; fi
  if ! params=$(printf '%s\n' "$AS_REPLY" | jq -ce --arg thread "$AS_THREAD" '
    [.result.thread.turns[]? | select(.status=="inProgress") | .id][-1] |
    select(type=="string" and length>0) | {threadId:$thread,turnId:.}'); then
    AS_CLASS=refused AS_REPLY='{"error":{"message":"active turn ID is unknown"}}'
    return 0
  fi
  appserver_mutate "$id-interrupt" turn/interrupt "$params"
  [ "$AS_CLASS" = accepted ] || return 0
  if ! appserver_wait_idle; then
    AS_CLASS=refused AS_REPLY='{"error":{"message":"turn interruption is unconfirmed"}}'
  fi
}
appserver_require_stopped() {
  local server
  server=$(appserver_status "$ISSUE")
  # Failed/systemError threads may be terminal even though the ordinary idle
  # guard refuses them. An active or uncertain turn still needs confirmation.
  if printf '%s\n' "$server" | jq -e '
    .agent_status=="gone" or
    ((.thread.status.type=="idle" or .thread.status.type=="systemError") and .turn_id==null)' >/dev/null; then return 0; fi
  appserver_request stop >/dev/null || fail 'App Server turn stop is unconfirmed; worktree retained'
}
cmd__appserver_watch() (
  local path after='' pass candidate
  [[ "$DV_STALL_AFTER" =~ ^[1-9][0-9]*$ ]] || fail 'DV_STALL_AFTER must be positive seconds'
  [ ! -f "$DV_STATE/.appserver-watch-after" ] || read -r after < "$DV_STATE/.appserver-watch-after" || true
  for pass in after wrap; do
    for path in "$DV_STATE"/*/meta; do
      [ -f "$path" ] || continue
      candidate=${path%/meta}; candidate=${candidate##*/}
      if [ "$pass" = after ]; then [[ "$candidate" > "$after" ]] || continue
      else [[ "$candidate" > "$after" ]] && continue; fi
      jq -e '.backend=="appserver" and (.status=="running" or .status=="pr" or .status=="waiting-capacity")' "$path" >/dev/null || continue
      load_issue "$candidate"
      # Advance BEFORE waiting: a host deadline may kill this sweep while an
      # early client is unresponsive. The next round starts with its successor.
      printf '%s\n' "$candidate" | appserver_atomic "$DV_STATE/.appserver-watch-after"
      if ! appserver_alive; then
        jq -e '.status=="running" and (.thread_id|type)=="string"' "$S/meta" >/dev/null || continue
        if [ -f "$S/appserver/blocked" ] || appserver_done_current; then continue; fi
        # Claim before launch: repeated/concurrent scans get one attempt per job.
        (set -C; printf '%s\n' "$(now)" > "$S/appserver/watch-restart.sent") 2>/dev/null || continue
        appserver_start || true
        continue
      fi
      appserver_request recover >/dev/null || true
    done
  done
)
