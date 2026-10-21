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
  AS_IO=$(mktemp -d "${TMPDIR:-/tmp}/dv-appserver.XXXXXX")
  mkfifo "$AS_IO/in" "$AS_IO/out" "$AS_IO/raw-in" "$AS_IO/raw-out"
  AS_SEND='' AS_RECEIVE=''
  appserver_proxy < "$AS_IO/raw-in" > "$AS_IO/raw-out" & AS_PID=$!
  exec 7> "$AS_IO/raw-in" 6< "$AS_IO/raw-out"
  if ! appserver_ws_upgrade; then appserver_close; return 1; fi
  appserver_ws_send 1 < "$AS_IO/in" >&7 6>&- 7>&- & AS_SEND=$!
  exec 9> "$AS_IO/in"
  appserver_ws_receive 0 <&6 > "$AS_IO/out" 6>&- 7>&- 9>&- & AS_RECEIVE=$!
  exec 8< "$AS_IO/out" 6>&- 7>&-
}
appserver_close() {
  if [ -n "${AS_WRITER:-}" ]; then
    kill "$AS_WRITER" 2>/dev/null || true
    wait "$AS_WRITER" 2>/dev/null || true
  fi
  exec 6>&- 7>&- 8>&- 9>&-
  kill "$AS_PID" ${AS_SEND:+"$AS_SEND"} ${AS_RECEIVE:+"$AS_RECEIVE"} 2>/dev/null || true
  wait "$AS_PID" 2>/dev/null || true
  [ -z "$AS_SEND" ] || wait "$AS_SEND" 2>/dev/null || true
  [ -z "$AS_RECEIVE" ] || wait "$AS_RECEIVE" 2>/dev/null || true
  rm -rf "$AS_IO"
}
appserver_handshake() {
  appserver_rpc initialize '{"clientInfo":{"name":"devflow","version":"1"},"capabilities":{"experimentalApi":true}}'
  [ "$AS_CLASS" = accepted ] || return 1
  printf '%s\n' '{"method":"initialized"}' >&9
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
  local AS_EVENTS=0 AS_SEQ=0 AS_IO AS_PID AS_SEND AS_RECEIVE AS_REPLY AS_CLASS AS_WRITER='' rc=0
  appserver_open || return 1
  trap appserver_close EXIT
  appserver_handshake || rc=$?
  appserver_close
  trap - EXIT
  return "$rc"
}
appserver_selected() {
  [ "$1" = codex ] && [ -z "$DV_AGENT_CMD_codex" ] || return 1
  [ "$2" != exec ] || return 1
  case "$DV_CODEX_MODE" in
    appserver) return 0 ;;
    auto) appserver_available ;;
    tui|exec) return 1 ;;
    *) fail 'DV_CODEX_MODE must be auto, appserver, tui or exec' ;;
  esac
}
appserver_atomic() {
  local target=$1 tmp
  tmp=$(mktemp "$target.XXXXXX")
  cat > "$tmp" && mv "$tmp" "$target"
}
appserver_event() {
  [ "$AS_EVENTS" = 1 ] || return 0
  local line=$1 method thread request key
  method=$(printf '%s\n' "$line" | jq -r '.method // ""')
  thread=$(printf '%s\n' "$line" | jq -r '.params.threadId // .params.thread.id // ""')
  [ -n "$thread" ] && [ "$thread" = "${AS_THREAD:-}" ] || return 0
  printf '%s\n' "$line" >> "$S/appserver/events.jsonl"
  case "$method" in
    item/*|turn/started) now > "$S/appserver/activity" ;;
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
appserver_rpc() {
  local method=$1 params=$2 id=${3:-} line deadline
  AS_SEQ=$((AS_SEQ + 1))
  [ -n "$id" ] || id="rpc-$$-$AS_SEQ"
  AS_REPLY='{}'; AS_CLASS=unknown
  appserver_write "$(printf '%s\n' "$params" | jq -c --arg id "$id" --arg method "$method" '{id:$id,method:$method,params:.}')"
  deadline=$(( $(now) + DV_APPSERVER_TIMEOUT ))
  while [ "$(now)" -le "$deadline" ]; do
    if IFS= read -r -t 1 line <&8; then
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
        appserver_write_end; return 0
      fi
      appserver_event "$line"
    elif ! kill -0 "$AS_PID" 2>/dev/null; then break; fi
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
  local params thread goal='null' error='null' state
  params=$(jq -cn --arg thread "$AS_THREAD" '{threadId:$thread,includeTurns:true}')
  appserver_rpc thread/read "$params"
  if [ "$AS_CLASS" != accepted ]; then
    state=unknown
    if printf '%s\n' "$AS_REPLY" | jq -e '.error.data.codexErrorInfo=="threadNotFound" or ((.error.message // "")|test("^(thread not found|no thread found)";"i"))' >/dev/null; then state=gone; fi
    AS_SNAPSHOT=$(jq -cn --arg state "$state" '{agent_status:$state,alive:false,question_pending:false}')
    return
  fi
  thread=$(printf '%s\n' "$AS_REPLY" | jq -c '.result.thread | {id,status,cwd,updatedAt,
    turns:[.turns[-1] // empty | {id,status,error,items:[.items[]? | {id,type,status,error}]}]}')
  appserver_rpc thread/goal/get "$(jq -cn --arg thread "$AS_THREAD" '{threadId:$thread}')"
  if [ "$AS_CLASS" = accepted ]; then goal=$(printf '%s\n' "$AS_REPLY" | jq -c '.result.goal // null'); fi
  if [ -f "$S/appserver/error.json" ]; then error=$(jq -c '.params.error // .params' "$S/appserver/error.json"); fi
  AS_SNAPSHOT=$(printf '%s\n%s\n%s\n' "$thread" "$goal" "$error" | jq -sc '
    .[0] as $thread | .[1] as $goal | .[2] as $error |
    ($thread.turns[-1] // {}) as $turn |
    {thread:$thread,turn:$turn,goal:$goal,error:($turn.error // $error),
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
  printf '%s\n' "$AS_SNAPSHOT" | appserver_atomic "$S/appserver/snapshot.json"
}
appserver_deliver() {
  local id=$1 text=$2 recovery=${3:-0} state turn params method active
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
  appserver_mutate "$id" "$method" "$params"
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
    if IFS= read -r -t 1 line <&8; then
      printf '%s\n' "$line" | jq -e 'type=="object"' >/dev/null 2>&1 || continue
      appserver_event "$line"
      if printf '%s\n' "$line" | jq -e --argjson id "$request" --arg thread "$AS_THREAD" '.method=="serverRequest/resolved" and .params.requestId==$id and .params.threadId==$thread' >/dev/null; then
        AS_CLASS=accepted AS_REPLY=$line; break
      fi
    elif ! kill -0 "$AS_PID" 2>/dev/null; then break; fi
  done
  appserver_write_end
  appserver_receipt "$id"
}
appserver_alive() {
  local pid
  [ -f "$S/appserver/client.pid" ] || return 1
  pid=$(cat "$S/appserver/client.pid")
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null &&
    ps -o args= -p "$pid" 2>/dev/null | grep -Fq -- "dv _appserver-run $ISSUE"
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
appserver_start() {
  local deadline client
  [[ "$DV_APPSERVER_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || fail 'DV_APPSERVER_TIMEOUT must be positive seconds'
  [[ "$DV_APPSERVER_POLL" =~ ^[1-9][0-9]*$ ]] || fail 'DV_APPSERVER_POLL must be positive seconds'
  mkdir -p "$S/appserver/outbox" "$S/appserver/questions"
  chmod 700 "$S/appserver"
  if command -v setsid >/dev/null; then
    nohup setsid "$DV_ROOT/bin/dv" _appserver-run "$ISSUE" >> "$S/log" 2>&1 < /dev/null &
    client=$!
  else
    client=$(set -m; nohup "$DV_ROOT/bin/dv" _appserver-run "$ISSUE" >> "$S/log" 2>&1 < /dev/null & printf '%s\n' "$!")
  fi
  deadline=$(( $(now) + DV_APPSERVER_TIMEOUT * 5 + 5 ))
  while [ "$(cat "$S/appserver/ready" 2>/dev/null)" != "$client" ]; do
    kill -0 "$client" 2>/dev/null && [ "$(now)" -le "$deadline" ] || return 1
    sleep 0.1
  done
}
cmd__appserver_run() {
  load_issue "$1"; require_worktree
  umask 077
  local AS_EVENTS=1 AS_SEQ=0 AS_THREAD='' AS_REPLY='{}' AS_CLASS=unknown AS_SNAPSHOT='{}' AS_IO AS_PID AS_SEND AS_RECEIVE AS_WRITER=''
  local instruction params id file operation text line last_poll=0
  DV_APPSERVER_SOCKET=$(jq -r --arg socket "$DV_APPSERVER_SOCKET" '.appserver_socket // $socket' "$S/meta")
  AS_THREAD=$(jq -r '.thread_id // ""' "$S/meta")
  printf '%s\n' "$$" > "$S/appserver/client.pid"
  appserver_open || return 1
  trap 'appserver_close; touch "$S/appserver/exited"; rm -f "$S/appserver/client.pid"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  appserver_handshake || return 1
  instruction="Read $S/brief.md and complete everything it asks. Finish with dv done $ISSUE."
  if [ -z "$AS_THREAD" ]; then
    params=$(jq -cn --arg cwd "$WT" --arg model "$DV_CODEX_MODEL" --arg effort "$DV_CODEX_EFFORT" \
      --arg config "$DV_CONFIG" --arg state "$DV_STATE" --arg work "$DV_WORK" --arg home "$DV_HOME" --arg host "$DV_HOST" --arg path "$DV_ROOT/bin:$PATH" \
      '{cwd:$cwd,model:$model,approvalPolicy:"never",sandbox:"danger-full-access",config:{model_reasoning_effort:$effort,
        shell_environment_policy:{set:{DV_CONFIG:$config,DV_STATE:$state,DV_WORK:$work,DV_HOME:$home,DV_HOST:$host,PATH:$path}}}}')
    appserver_mutate thread-start thread/start "$params"
    [ "$AS_CLASS" = accepted ] || return 1
    AS_THREAD=$(printf '%s\n' "$AS_REPLY" | jq -er '.result.thread.id') || return 1
    meta_set --arg thread "$AS_THREAD" --arg socket "$DV_APPSERVER_SOCKET" '.thread_id=$thread | .appserver_socket=$socket'
    params=$(jq -cn --arg thread "$AS_THREAD" --arg objective "$instruction" '{threadId:$thread,objective:$objective,status:"active"}')
    appserver_mutate goal-set thread/goal/set "$params"
    if [ "$AS_CLASS" != accepted ] && ! printf '%s\n' "$AS_REPLY" | jq -e '.error.code==-32601' >/dev/null; then return 1; fi
    params=$(jq -cn --arg thread "$AS_THREAD" --arg text "$instruction" --rawfile brief "$S/brief.md" --arg effort "$DV_CODEX_EFFORT" '{threadId:$thread,input:[{type:"text",text:($text+"\n\n"+$brief),text_elements:[]}],effort:$effort}')
    appserver_mutate initial-turn turn/start "$params"
    [ "$AS_CLASS" = accepted ] || return 1
  else
    appserver_rpc thread/resume "$(jq -cn --arg thread "$AS_THREAD" '{threadId:$thread}')"
    [ "$AS_CLASS" = accepted ] || return 1
  fi
  now > "$S/appserver/activity"
  touch "$S/agent.started"
  printf '%s\n' "$$" > "$S/appserver/ready"
  while kill -0 "$AS_PID" 2>/dev/null && kill -0 "$AS_SEND" 2>/dev/null && kill -0 "$AS_RECEIVE" 2>/dev/null; do
    for file in "$S/appserver/outbox/"*.json; do
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
    if IFS= read -r -t 1 line <&8; then
      if printf '%s\n' "$line" | jq -e 'type=="object"' >/dev/null 2>&1; then appserver_event "$line"; fi
    fi
    if [ $(( $(now) - last_poll )) -ge "$DV_APPSERVER_POLL" ]; then
      appserver_snapshot; appserver_questions; last_poll=$(now)
    fi
  done
  cmd_kick blocked "$ISSUE" 'App Server connection ended; inspect unknown receipts before reconnecting'
}
appserver_status() (
  load_issue "$1"
  local receipt AS_EVENTS=0 AS_SEQ=0 AS_THREAD AS_REPLY AS_CLASS AS_SNAPSHOT AS_IO AS_PID AS_SEND AS_RECEIVE AS_WRITER=''
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
  printf '{"agent_status":"unknown","alive":false,"question_pending":false}\n'
)
appserver_recover() {
  local id=$1 state last params
  appserver_snapshot
  state=$(printf '%s\n' "$AS_SNAPSHOT" | jq -r .agent_status)
  AS_CLASS=accepted AS_REPLY='{}'
  printf '%s\n' "$AS_SNAPSHOT" | jq -e '.question_pending|not' >/dev/null || return 0
  case "$state" in
    failed) cmd_kick failed "$ISSUE" "$(printf '%s\n' "$AS_SNAPSHOT" | jq -c '.error // {message:"App Server turn failed"}')" ;;
    idle-with-goal-active|working)
      last=$(cat "$S/appserver/activity")
      [ $(( $(now) - last )) -ge "$DV_STALL_AFTER" ] || return 0
      cmd_kick stalled "$ISSUE" 'App Server goal has no new items' ;;
    *) return 0 ;;
  esac
  if [ -f "$S/appserver/recovery" ]; then
    if [ ! -f "$S/appserver/blocked" ]; then
      cmd_kick blocked "$ISSUE" 'App Server recovery needs operator input; no automatic replay'
      touch "$S/appserver/blocked"
    fi
    return 0
  fi
  # Persist the one-shot decision before attempting any new turn.
  touch "$S/appserver/recovery"
  if printf '%s\n' "$AS_SNAPSHOT" | jq -e '.thread.status.type=="active" or .turn_id!=null' >/dev/null; then
    # The job runner's AS_THREAD is independent of appserver_status's subshell.
    # shellcheck disable=SC2031
    params=$(printf '%s\n' "$AS_SNAPSHOT" | jq -ce --arg thread "$AS_THREAD" 'select(.turn_id!=null) | {threadId:$thread,turnId:.turn_id}') || return 0
    appserver_mutate "$id-interrupt" turn/interrupt "$params"
    if [ "$AS_CLASS" != accepted ]; then
      cmd_kick blocked "$ISSUE" 'App Server interrupt was not accepted; recovery will not be retried'
      touch "$S/appserver/blocked"
      return 0
    fi
    if ! appserver_wait_idle; then
      AS_CLASS=refused AS_REPLY='{"error":{"message":"interrupted turn did not become idle before the deadline"}}'
      cmd_kick blocked "$ISSUE" 'App Server interrupt completion is unconfirmed; continuation was not sent'
      touch "$S/appserver/blocked"
      return 0
    fi
  fi
  appserver_deliver "$id" continue 1
  if [ "$AS_CLASS" != accepted ]; then
    cmd_kick blocked "$ISSUE" 'App Server continuation was not accepted; recovery will not be retried'
    touch "$S/appserver/blocked"
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
cmd__appserver_watch() (
  local path
  [[ "$DV_STALL_AFTER" =~ ^[1-9][0-9]*$ ]] || fail 'DV_STALL_AFTER must be positive seconds'
  for path in "$DV_STATE"/*/meta; do
    [ -f "$path" ] || continue
    jq -e '.backend=="appserver" and .status=="running"' "$path" >/dev/null || continue
    load_issue "$(jq -r .issue "$path")"
    appserver_request recover >/dev/null || true
  done
)
