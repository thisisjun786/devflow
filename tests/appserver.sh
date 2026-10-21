#!/usr/bin/env bash
# Sourced by run.sh. No real model, daemon, provider or remote repository.
# shellcheck disable=SC2154,SC2016
case_teardown_wait_client() {
  local fixture="$CASE_DIR/teardown" pid stopped=false
  mkdir -p "$fixture/state/T-1/appserver" "$fixture/home"
  cat > "$CASE_DIR/late-client" <<'CLIENT'
#!/usr/bin/env bash
trap 'sleep 0.3; touch "$CASE_DIR/client-stopped"; exit 0' TERM
touch "$CASE_DIR/client-ready"
while :; do sleep 0.1; done
CLIENT
  bash "$CASE_DIR/late-client" & pid=$!
  printf '%s\n' "$pid" > "$fixture/state/T-1/appserver/client.pid"
  wait_file "$CASE_DIR/client-ready"
  CASE_DIR="$fixture" DV_STATE="$fixture/state" DV_HOME="$fixture/home" DV_TEST_KEEP=0 teardown
  [ ! -f "$CASE_DIR/client-stopped" ] || stopped=true
  wait "$pid" || true
  test "$stopped" = true
  test ! -e "$fixture"
}
case_teardown_preserve_live_client() {
  local fixture="$CASE_DIR/teardown" pid refused=false
  mkdir -p "$fixture/state/T-1/appserver" "$fixture/home"
  cat > "$CASE_DIR/held-client" <<'CLIENT'
#!/usr/bin/env bash
trap '' TERM
touch "$CASE_DIR/client-ready"
while :; do sleep 0.1; done
CLIENT
  bash "$CASE_DIR/held-client" & pid=$!
  printf '%s\n' "$pid" > "$fixture/state/T-1/appserver/client.pid"
  wait_file "$CASE_DIR/client-ready"
  # Only the driver's bounded wait is accelerated; the fake client is a
  # separate shell and still ignores TERM until this test explicitly stops it.
  sleep() { command sleep 0.001; }
  if CASE_DIR="$fixture" DV_STATE="$fixture/state" DV_HOME="$fixture/home" DV_TEST_KEEP=0 teardown; then :
  else refused=true; fi
  kill -KILL "$pid"; wait "$pid" 2>/dev/null || true
  test "$refused" = true
  test -d "$fixture"
  rm "$fixture/state/T-1/appserver/client.pid"
}
appserver_setup() {
  repo appserver "${1:-}"
  export DV_AGENT_CMD_codex='' DV_CODEX_MODE=appserver DV_HERDR=0
  export DV_CODEX_BIN="$ROOT/tests/fixtures/appserver" DV_APPSERVER_TIMEOUT=2
  export DV_APPSERVER_POLL=1 DV_STALL_AFTER=300
  mkdir -p "$CASE_DIR/server"
  printf 'idle\n' > "$CASE_DIR/server/status"
  dv start "$REPO" AS-1 change --brief "$CASE_DIR/brief"
}
case_appserver_start() {
  appserver_setup
  jq -e '.backend=="appserver" and .thread_id=="thread-1"' "$DV_STATE/AS-1/meta"
  test -f "$DV_STATE/AS-1/agent.started"
  test ! -f "$DV_STATE/AS-1/herdr_pane"
  jq -se 'any(.[]; .method=="thread/start") and any(.[]; .method=="turn/start" and (.params.input[0].text|contains("Implement one file.")))' "$CASE_DIR/server/requests"
  jq -se --arg config "$DV_CONFIG" 'any(.[]; .method=="thread/start" and .params.config.shell_environment_policy.set.DV_CONFIG==$config)' "$CASE_DIR/server/requests"
  dv status AS-1 --json | jq -e '.[0] | .backend=="appserver" and .agent_status=="working" and .alive and (.tmux|not)'
}
appserver_send_outcome() {
  local outcome=$1
  appserver_setup
  printf '%s\n' "$outcome" > "$CASE_DIR/server/outcome"
  local rc=0
  dv send AS-1 'keep literal $(touch nope) and `commands`' > "$CASE_DIR/receipt" || rc=$?
  jq -e --arg outcome "$outcome" '.outcome==$outcome and (.id|length)>0' "$CASE_DIR/receipt"
  if [ "$outcome" = accepted ]; then test "$rc" = 0; else test "$rc" != 0; fi
  jq -se 'map(select(.method=="turn/steer")) | length==1 and .[0].params.expectedTurnId=="turn-1" and (. [0].params.input[0].text|contains("$(touch nope)"))' "$CASE_DIR/server/requests"
  test ! -e "$CASE_DIR/nope"
  if [ "$outcome" = unknown ]; then
    if dv send AS-1 'keep literal $(touch nope) and `commands`' > "$CASE_DIR/retry"; then return 1; fi
    cmp "$CASE_DIR/receipt" "$CASE_DIR/retry"
    jq -se '[.[]|select(.method=="turn/steer")]|length==1' "$CASE_DIR/server/requests"
  fi
}
case_appserver_accepted() { appserver_send_outcome accepted; }
case_appserver_refused() { appserver_send_outcome refused; }
case_appserver_unknown() { appserver_send_outcome unknown; }
case_appserver_idle_send() {
  appserver_setup
  printf 'idle\n' > "$CASE_DIR/server/status"
  dv send AS-1 'next task' | jq -e '.outcome=="accepted"'
  jq -se '[.[]|select(.method=="turn/start")]|length==2 and .[1].params.threadId=="thread-1" and .[1].params.input[0].text=="next task"' "$CASE_DIR/server/requests"
}
case_appserver_states() {
  appserver_setup
  local state expected
  for state in idle active systemError gone unknown; do
    case "$state" in idle) expected=idle-with-goal-active ;; active) expected=working ;; systemError) expected=failed ;; *) expected=$state ;; esac
    printf '%s\n' "$state" > "$CASE_DIR/server/status"
    dv status AS-1 --json | jq -e --arg expected "$expected" '.[0].agent_status==$expected'
  done
  printf 'idle\n' > "$CASE_DIR/server/status"
  printf 'complete\n' > "$CASE_DIR/server/goal"
  dv status AS-1 --json | jq -e '.[0].agent_status=="goal-complete"'
  dv 'done' AS-1
  dv clean AS-1
  test ! -d "$(jq -r .worktree "$DV_STATE/AS-1/meta")"
}
case_appserver_failed() {
  appserver_setup
  printf '%s\n' '{"thread":{"id":"thread-1","status":{"type":"idle"},"turns":[{"id":"turn-1","status":"failed","items":[],"error":{"message":"model failed","codexErrorInfo":"other"}}]}}' > "$CASE_DIR/server/thread.json"
  dv status AS-1 --json | jq -e '.[0] | .agent_status=="failed" and .appserver.error.codexErrorInfo=="other"'
  dv _appserver-watch
  jq -se 'any(.[]; .kind=="failed" and (.message|contains("model failed")))' "$DV_STATE/AS-1/events.log"
  dv _appserver-watch
  jq -se 'any(.[];.kind=="blocked")' "$DV_STATE/AS-1/events.log"
  jq -se '[.[]|select(.method=="turn/start" and .params.input[0].text=="continue")]|length==1' "$CASE_DIR/server/requests"
}
case_appserver_stall() {
  appserver_setup
  printf 'idle\n' > "$CASE_DIR/server/status"
  printf '0\n' > "$DV_STATE/AS-1/appserver/activity"
  dv _appserver-watch
  jq -se 'any(.[]; .kind=="stalled")' "$DV_STATE/AS-1/events.log"
  printf 'idle\n' > "$CASE_DIR/server/status"
  printf '0\n' > "$DV_STATE/AS-1/appserver/activity"
  dv _appserver-watch
  jq -se 'any(.[]; .kind=="blocked")' "$DV_STATE/AS-1/events.log"
  jq -se '[.[]|select(.method=="turn/start" and (.params.input[0].text|contains("You stopped without dv done")))]|length==1' "$CASE_DIR/server/requests"
}
case_appserver_question() {
  appserver_setup
  printf '%s\n' '{"id":"question-1","method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","questions":[{"id":"format","question":"Choose format","options":[]}]}}' > "$CASE_DIR/server/notify"
  for _ in {1..100}; do [ ! -f "$DV_STATE/AS-1/events.log" ] || break; sleep 0.1; done
  jq -se 'any(.[]; .kind=="question" and (.message|fromjson|.questions[0].id)=="format")' "$DV_STATE/AS-1/events.log"
  dv status AS-1 --json | jq -e '.[0].question_pending'
  dv send AS-1 'JSON' | jq -e '.outcome=="accepted"'
  jq -se 'any(.[]; .id=="question-1" and .result.answers.format.answers==["JSON"])' "$CASE_DIR/server/requests"
  dv status AS-1 --json | jq -e '.[0].question_pending|not'
}
case_appserver_auto() {
  repo automatic
  unset DV_CODEX_MODE
  export DV_AGENT_CMD_codex='' DV_CODEX_BIN="$ROOT/tests/fixtures/appserver" DV_APPSERVER_TIMEOUT=2
  mkdir -p "$CASE_DIR/server"
  printf 'idle\n' > "$CASE_DIR/server/status"
  dv start "$REPO" AS-1 automatic
  jq -e '.backend=="appserver"' "$DV_STATE/AS-1/meta"
  jq -se '[.[]|select(.method=="initialize")]|length==2' "$CASE_DIR/server/requests"
}
case_appserver_no_goal() {
  mkdir -p "$CASE_DIR/server"; touch "$CASE_DIR/server/no-goal"
  appserver_setup
  jq -e '.thread_id=="thread-1"' "$DV_STATE/AS-1/meta"
  dv send AS-1 next | jq -e '.outcome=="accepted"'
}
case_appserver_clean_guard() {
  appserver_setup
  local wt
  wt=$(jq -r .worktree "$DV_STATE/AS-1/meta")
  if dv clean AS-1; then return 1; fi
  test -d "$wt"
  printf 'idle\n' > "$CASE_DIR/server/status"
  printf 'complete\n' > "$CASE_DIR/server/goal"
  touch "$wt/dirty"
  if dv clean AS-1; then return 1; fi
  test -f "$wt/dirty"
}
case_appserver_reconnect() {
  appserver_setup
  kill "$(cat "$DV_STATE/AS-1/appserver/client.pid")"
  wait_file "$DV_STATE/AS-1/appserver/exited"
  dv status AS-1 --json | jq -e '.[0].agent_status=="working" and .[0].alive'
  dv send AS-1 'reconnect same thread' | jq -e '.outcome=="accepted"'
  jq -se '[.[]|select(.method=="thread/start")]|length==1' "$CASE_DIR/server/requests"
  jq -se 'any(.[]; .method=="thread/resume" and .params.threadId=="thread-1")' "$CASE_DIR/server/requests"
}
case_appserver_active_stall() {
  appserver_setup
  printf '0\n' > "$DV_STATE/AS-1/appserver/activity"
  dv _appserver-watch
  jq -se '[.[]|select(.method=="turn/interrupt" or (.method=="turn/start" and .params.input[0].text=="continue"))] | map(.method)==["turn/interrupt","turn/start"]' "$CASE_DIR/server/requests"
  printf '0\n' > "$DV_STATE/AS-1/appserver/activity"
  dv _appserver-watch
  jq -se '[.[]|select(.method=="turn/interrupt")]|length==1' "$CASE_DIR/server/requests"
}
case_appserver_unknown_restart() {
  appserver_setup
  printf 'unknown\n' > "$CASE_DIR/server/outcome"
  if dv send AS-1 once; then return 1; fi
  kill "$(cat "$DV_STATE/AS-1/appserver/client.pid")"
  wait_file "$DV_STATE/AS-1/appserver/exited"
  printf 'accepted\n' > "$CASE_DIR/server/outcome"
  if dv send AS-1 once; then return 1; fi
  dv send AS-1 fresh | jq -e '.outcome=="accepted"'
  jq -se '[.[]|select(.method=="turn/steer" and .params.input[0].text=="once")]|length==1' "$CASE_DIR/server/requests"
  jq -se '[.[]|select(.method=="thread/start")]|length==1' "$CASE_DIR/server/requests"
}
case_appserver_question_multiple() {
  appserver_setup
  printf '%s\n' '{"id":42,"method":"item/tool/requestUserInput","params":{"threadId":"thread-1","questions":[{"id":"format","question":"Format?"},{"id":"scope","question":"Scope?"}]}}' > "$CASE_DIR/server/notify"
  for _ in {1..100}; do [ ! -f "$DV_STATE/AS-1/events.log" ] || break; sleep 0.1; done
  if dv send AS-1 ambiguous; then return 1; fi
  dv send AS-1 '{"requestId":42,"answers":{"format":{"answers":["JSON"]},"scope":{"answers":["local"]}}}' | jq -e '.outcome=="accepted"'
  jq -se 'any(.[]; .id==42 and .result.answers.scope.answers==["local"])' "$CASE_DIR/server/requests"
}
case_appserver_question_retry() {
  export DV_KICK=false
  appserver_setup
  export DV_KICK=false
  # The job runner has inherited the setup default. Restart it with failed kicks.
  kill "$(cat "$DV_STATE/AS-1/appserver/client.pid")"
  wait_file "$DV_STATE/AS-1/appserver/exited"
  dv send AS-1 connect >/dev/null
  printf '%s\n' '{"id":"q","method":"item/tool/requestUserInput","params":{"threadId":"thread-1","questions":[{"id":"one","question":"Choose"}]}}' > "$CASE_DIR/server/notify"
  for _ in {1..100}; do
    if [ -f "$DV_STATE/AS-1/events.log" ] && [ "$(wc -l < "$DV_STATE/AS-1/events.log")" -ge 2 ]; then break; fi
    sleep 0.1
  done
  jq -se 'length>=2 and all(.[];.kind=="question" and (.delivered|not)) and (map(.id)|unique|length)==1' "$DV_STATE/AS-1/events.log"
}
case_appserver_malformed() {
  appserver_setup
  printf 'malformed\n' > "$CASE_DIR/server/outcome"
  if dv send AS-1 bad > "$CASE_DIR/result"; then return 1; fi
  jq -e '.outcome=="unknown"' "$CASE_DIR/result"
}
case_appserver_watch() {
  appserver_setup
  printf 'idle\n' > "$CASE_DIR/server/status"
  printf '0\n' > "$DV_STATE/AS-1/appserver/activity"
  export DV_HOSTS=test-host DV_WORKER_CMD="$ROOT/tests/fixtures/worker" DV_WATCH_INTERVAL=0.1
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_file "$DV_STATE/AS-1/appserver/recovery"
  touch "$DV_HOME/stop"
  wait "$watcher"
  jq -se 'any(.[];.kind=="stalled")' "$DV_HOME/kick.q"
}
case_appserver_fallback() {
  exec_setup
  export DV_CODEX_MODE=auto
  dv start "$REPO" EX-1 fallback
  exec_wait
  jq -e '.backend=="exec" and .mode=="exec" and .status=="done"' "$DV_STATE/EX-1/meta"
  test ! -e "$CASE_DIR/herdr/calls"
  dv clean EX-1
}
case_appserver_exec_override() {
  exec_setup
  export DV_CODEX_MODE=appserver
  dv start "$REPO" EX-1 override --mode exec
  exec_wait
  jq -e '.backend=="exec" and .status=="done"' "$DV_STATE/EX-1/meta"
}
case_appserver_goal_override() {
  needs_tmux; repo goal-override
  export DV_CODEX_MODE=auto DV_AGENT_CMD_codex='' DV_CODEX_BIN="$ROOT/tests/fixtures/interactive"
  dv start "$REPO" AS-1 override --mode goal
  wait_file "$DV_STATE/AS-1/done.json"
  # done.json is published before metrics and the terminal metadata update.
  # The completion event is emitted after both, so teardown cannot race them.
  wait_file "$DV_STATE/AS-1/events.log"
  jq -e '.backend=="tmux" and .mode=="goal" and .status=="done"' "$DV_STATE/AS-1/meta"
  dv clean AS-1
}
case_appserver_submit_auto() {
  repo submit-auto
  export DV_CODEX_MODE=auto DV_MANAGER_HOST="$DV_HOST"
  dv submit "$REPO" AS-1 automatic --brief "$CASE_DIR/brief"
  jq -e '.mode=="auto" and .agent=="codex" and .status=="submitted"' "$DV_HOME/submissions/AS-1/task.json"
}
case_appserver_exec() {
  needs_tmux; repo exec-fallback
  export DV_CODEX_MODE=exec
  dv start "$REPO" AS-1 fallback
  wait_done AS-1
  jq -e '.mode=="exec" and .backend=="tmux" and .status=="done"' "$DV_STATE/AS-1/meta"
}
case_appserver_pipeline() {
  export DV_APP_TEST_WORK=1
  appserver_setup remote
  wait_file "$CASE_DIR/server/work.done"
  jq -e '.files==1' "$DV_STATE/AS-1/done.json"
  dv status AS-1 --json | jq -e '.[0] | .status=="ready" and .agent_status=="goal-complete" and .backend=="appserver" and (.tmux|not)'
  printf 'Exercise synthetic App Server delivery.\n' > "$DV_STATE/AS-1/pr.md"
  dv pr AS-1
  dv pr-wait AS-1 --foreground --review-handled > "$CASE_DIR/pr-result"
  dv 'done' AS-1
  jq -e '.status=="ready"' "$DV_STATE/AS-1/meta"
  cmp "$DV_STATE/AS-1/pr.md" "$GH_STUB_DIR/live-body"
  test -f "$CASE_DIR/server/socket-used"
  test ! -f "$CASE_DIR/herdr/calls"
}
case_appserver_pr_pending() {
  appserver_setup remote
  if dv 'done' AS-1; then return 1; fi
  test ! -f "$DV_STATE/AS-1/done.json"
  test "$(cat "$CASE_DIR/server/goal")" = active
  jq -se '[.[]|select(.method=="thread/goal/set" and .params.status=="complete")]|length==0' "$CASE_DIR/server/requests"
}
case_appserver_preserve_config() {
  mkdir -p "$HOME/.codex"
  printf '# operator config\n' > "$HOME/.codex/config.toml"
  cp "$HOME/.codex/config.toml" "$CASE_DIR/config.original"
  appserver_setup
  cmp "$CASE_DIR/config.original" "$HOME/.codex/config.toml"
}
case_appserver_detached() {
  if [ "${1:-}" = fallback ]; then
    cat > "$CASE_DIR/no-setsid" <<'STUB'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = setsid ]; then return 1; fi
  builtin command "$@"
}
STUB
    export BASH_ENV="$CASE_DIR/no-setsid"
  fi
  appserver_setup
  local client
  client=$(cat "$DV_STATE/AS-1/appserver/client.pid")
  test "$(ps -o pgid= -p "$client" | tr -d ' ')" = "$client"
  test "$(ps -o pgid= -p "$$" | tr -d ' ')" != "$client"
}
case_appserver_detached_fallback() { case_appserver_detached fallback; }
case_appserver_websocket() {
  # Independent RFC 6455 examples test masking, fragmentation, control frames,
  # 16/64-bit lengths and truncation rather than only roundtripping our encoder.
  # shellcheck source=lib/appserver-transport.sh
  source "$ROOT/lib/appserver-transport.sh"
  AS_IO="$CASE_DIR/frames"; mkdir "$AS_IO"
  printf '\201\205\067\372\041\075\177\237\115\121\130\210\200\000\000\000\000' |
    appserver_ws_receive 1 > "$CASE_DIR/hello"
  test "$(cat "$CASE_DIR/hello")" = Hello
  printf '\001\003abc\211\001x\200\003def\210\000' |
    appserver_ws_receive 0 > "$CASE_DIR/fragments"
  test "$(cat "$CASE_DIR/fragments")" = abcdef
  test "$(cat "$AS_IO"/pong.*.ready)" = x
  { printf '\201\176\000\202'; head -c 130 /dev/zero | tr '\0' a; printf '\210\000'; } |
    appserver_ws_receive 0 > "$CASE_DIR/extended"
  test "$(wc -c < "$CASE_DIR/extended" | tr -d ' ')" = 131
  { printf '\201\177\000\000\000\000\000\001\021\160'; head -c 70000 /dev/zero | tr '\0' a; printf '\210\000'; } |
    appserver_ws_receive 0 > "$CASE_DIR/large"
  test "$(wc -c < "$CASE_DIR/large" | tr -d ' ')" = 70001
  if printf '\201\176\000' | appserver_ws_receive 0; then return 1; fi
  if printf '\201\177\177\377\377\377\377\377\377\377' | appserver_ws_receive 0; then return 1; fi
  test "$(appserver_ws_accept dGhlIHNhbXBsZSBub25jZQ==)" = s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
}
case_appserver_active_error_send() {
  appserver_setup
  printf '%s\n' '{"thread":{"id":"thread-1","status":{"type":"active"},"turns":[{"id":"turn-1","status":"inProgress","items":[],"error":{"message":"transient capacity error"}}]}}' > "$CASE_DIR/server/thread.json"
  dv send AS-1 'steer while server retries' | jq -e '.outcome=="accepted"'
  jq -se '[.[]|select(.method=="turn/steer")]|length==1 and .[0].params.expectedTurnId=="turn-1"' "$CASE_DIR/server/requests"
  jq -se '[.[]|select(.method=="turn/start")]|length==1' "$CASE_DIR/server/requests"
}
case_appserver_interrupt_pending() {
  appserver_setup
  printf '2\n' > "$CASE_DIR/server/interrupt-polls"
  printf '0\n' > "$DV_STATE/AS-1/appserver/activity"
  dv _appserver-watch
  jq -se '[.[]|select(.method=="turn/start" and .params.input[0].text=="continue")]|length==1' "$CASE_DIR/server/requests"
  test ! -f "$DV_STATE/AS-1/appserver/blocked"
}
case_appserver_interrupt_timeout() {
  appserver_setup
  printf '100\n' > "$CASE_DIR/server/interrupt-polls"
  printf '0\n' > "$DV_STATE/AS-1/appserver/activity"
  dv _appserver-watch
  test -f "$DV_STATE/AS-1/appserver/blocked"
  dv _appserver-watch
  jq -se '[.[]|select(.method=="turn/interrupt")]|length==1' "$CASE_DIR/server/requests"
  jq -se '[.[]|select(.method=="turn/start" and .params.input[0].text=="continue")]|length==0' "$CASE_DIR/server/requests"
}
appserver_done_failure() {
  local outcome=$1
  appserver_setup
  printf '%s\n' "$outcome" > "$CASE_DIR/server/finish-outcome"
  if dv 'done' AS-1; then return 1; fi
  test ! -f "$DV_STATE/AS-1/done.json"
  test ! -f "$DV_STATE/AS-1/events.log"
  jq -e '.status=="running"' "$DV_STATE/AS-1/meta"
  rm "$CASE_DIR/server/finish-outcome"
  dv 'done' AS-1
  test -f "$DV_STATE/AS-1/done.json"
  if [ "$outcome" = unknown ]; then
    jq -se '[.[]|select(.method=="thread/goal/set" and .params.status=="complete")]|length==1' "$CASE_DIR/server/requests"
  fi
}
case_appserver_done_refused() { appserver_done_failure refused; }
case_appserver_done_unknown() { appserver_done_failure unknown; }
case_appserver_land_active() {
  appserver_setup
  local wt before
  wt=$(jq -r .worktree "$DV_STATE/AS-1/meta")
  printf 'change\n' > "$wt/change"
  git -C "$wt" add change
  git -C "$wt" commit -qm 'AS-1: fake change'
  dv 'done' AS-1
  before=$(git -C "$REPO" rev-parse main)
  if DV_TEST_CMD=true dv land AS-1; then return 1; fi
  test "$(git -C "$REPO" rev-parse main)" = "$before"
  jq -e '.status=="done"' "$DV_STATE/AS-1/meta"
  printf 'idle\n' > "$CASE_DIR/server/status"
  DV_TEST_CMD=true dv land AS-1
  test -f "$REPO/change"
  test ! -d "$wt"
}

# Recovery tests drive time through synthetic state, never the host clock.
appserver_age() { printf '0\n' > "$DV_STATE/AS-1/appserver/activity"; }
appserver_progress() {
  local turn
  turn=$(cat "$CASE_DIR/server/turn-id")
  jq -cn --arg turn "$turn" '{method:"item/completed",params:{threadId:"thread-1",turnId:$turn,item:{id:"progress",type:"agentMessage",text:"Finished another step"}}}' > "$CASE_DIR/server/notify"
  dv status AS-1 --json >/dev/null
  for _ in {1..100}; do
    [ -f "$DV_STATE/AS-1/appserver/recovery" ] || return 0
    sleep 0.1
  done
  echo 'Recovery episode was not cleared by new items' >&2
  return 1
}
appserver_idle_done() {
  local goal=$1
  appserver_setup
  printf 'idle\n' > "$CASE_DIR/server/status"
  if [ "$goal" = absent ]; then touch "$CASE_DIR/server/no-goal"
  else printf '%s\n' "$goal" > "$CASE_DIR/server/goal"; fi
  # A fresh idle does not start a turn before the stall threshold.
  dv _appserver-watch
  jq -se '[.[]|select(.method=="turn/start")]|length==1' "$CASE_DIR/server/requests"
  touch "$CASE_DIR/server/recovery-work"
  appserver_age
  dv _appserver-watch
  jq -se 'any(.[]; .method=="turn/start" and (.params.input[0].text|contains("You stopped without dv done") and contains("dv done AS-1") and contains("dv kick blocked AS-1")))' "$CASE_DIR/server/requests"
  wait_file "$CASE_DIR/server/work.done"
  jq -e '.files==1' "$DV_STATE/AS-1/done.json"
  appserver_age
  dv _appserver-watch
  jq -se '[.[]|select(.method=="turn/start")]|length==2' "$CASE_DIR/server/requests"
  dv status AS-1 --json | jq -e '.[0] | .recoveries==1 and .last_recovery_reason=="idle-without-done"'
}
case_appserver_idle_done() { appserver_idle_done absent; }
case_appserver_goal_done() { appserver_idle_done complete; }
case_appserver_idle_blocked() {
  appserver_setup
  printf 'idle\n' > "$CASE_DIR/server/status"
  appserver_age
  dv _appserver-watch
  appserver_progress
  printf '%s\n' '{"thread":{"id":"thread-1","status":{"type":"idle"},"turns":[{"id":"turn-2","status":"completed","items":[{"id":"last","type":"agentMessage","text":"Cannot finish without a decision"}]}]}}' > "$CASE_DIR/server/thread.json"
  appserver_age
  dv _appserver-watch
  dv _appserver-watch
  jq -se '[.[]|select(.kind=="blocked")]|length==1 and (.[0].message|contains("Cannot finish without a decision"))' "$DV_STATE/AS-1/events.log"
  jq -se '[.[]|select(.method=="turn/start")]|length==2' "$CASE_DIR/server/requests"
}
case_appserver_episode() {
  appserver_setup
  appserver_age
  dv _appserver-watch
  appserver_progress
  appserver_age
  dv _appserver-watch
  jq -se '[.[]|select(.method=="turn/interrupt")]|length==2' "$CASE_DIR/server/requests"
  dv status AS-1 --json | jq -e '.[0] | .recoveries==2 and .last_recovery_reason=="stalled"'
  dv status AS-1 | grep 'recoveries=2.*last_recovery_reason=stalled'
}
case_appserver_budget() {
  appserver_setup
  local attempt
  for attempt in 1 2 3; do
    appserver_age
    dv _appserver-watch
    appserver_progress
  done
  appserver_age
  dv _appserver-watch
  dv _appserver-watch
  jq -se '[.[]|select(.method=="turn/interrupt")]|length==3' "$CASE_DIR/server/requests"
  jq -se '[.[]|select(.kind=="blocked")]|length==1 and (.[0].message|contains("budget"))' "$DV_STATE/AS-1/events.log"
  dv status AS-1 --json | jq -e '.[0].recoveries==3'
}
case_appserver_budget_restart() {
  export DV_RECOVER_MAX=1
  appserver_setup
  appserver_age
  dv _appserver-watch
  appserver_progress
  kill "$(cat "$DV_STATE/AS-1/appserver/client.pid")"
  wait_file "$DV_STATE/AS-1/appserver/exited"
  dv status AS-1 --json | jq -e '.[0].recoveries==1 and .[0].last_recovery_reason=="stalled"'
  dv send AS-1 'resume after reconnect' >/dev/null
  appserver_age
  dv _appserver-watch
  jq -se '[.[]|select(.method=="turn/interrupt")]|length==1' "$CASE_DIR/server/requests"
  jq -se 'any(.[]; .kind=="blocked" and (.message|contains("budget")))' "$DV_STATE/AS-1/events.log"
}
appserver_capacity_error() {
  local error=$1
  jq -cn --argjson error "$error" '{thread:{id:"thread-1",status:{type:"idle"},turns:[{id:"turn-1",status:"failed",items:[],error:$error}]}}' > "$CASE_DIR/server/thread.json"
}
case_appserver_capacity() {
  appserver_setup
  appserver_capacity_error '{"message":"model at capacity","codexErrorInfo":"usageLimitExceeded"}'
  dv _appserver-watch
  jq -se '[.[]|select(.method=="turn/start")]|length==1' "$CASE_DIR/server/requests"
  if [ -f "$DV_STATE/AS-1/events.log" ]; then jq -se 'all(.[]; .kind!="failed" and .kind!="blocked")' "$DV_STATE/AS-1/events.log"; fi
  dv status AS-1 --json | jq -e '.[0].recoveries==0 and .[0].appserver.capacity_retry_at!=null'
  # The client remains responsive during backoff. Expire only the fixture timer.
  printf '0\n' > "$DV_STATE/AS-1/appserver/capacity-since"
  dv _appserver-watch
  dv _appserver-watch
  jq -se '[.[]|select(.method=="turn/start" and .params.input[0].text=="continue")]|length==1' "$CASE_DIR/server/requests"
  dv status AS-1 --json | jq -e '.[0].recoveries==1 and .[0].last_recovery_reason=="capacity"'
}
case_appserver_rate_limit() {
  export DV_CAPACITY_BACKOFF=1
  appserver_setup
  appserver_capacity_error '{"message":"Too many requests","codexErrorInfo":{"httpConnectionFailed":{"httpStatusCode":429}}}'
  dv _appserver-watch
  test -f "$DV_STATE/AS-1/appserver/capacity-since"
  sleep 1
  dv _appserver-watch
  dv status AS-1 --json | jq -e '.[0].recoveries==1 and .[0].last_recovery_reason=="capacity"'
}
case_appserver_recovery_guards() {
  appserver_setup
  printf '%s\n' '{"id":"question-1","method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","questions":[{"id":"format","question":"Choose format"}]}}' > "$CASE_DIR/server/notify"
  dv status AS-1 --json >/dev/null
  wait_file "$DV_STATE/AS-1/events.log"
  appserver_age
  dv _appserver-watch
  test ! -f "$DV_STATE/AS-1/appserver/recovery"
  dv send AS-1 JSON >/dev/null
  dv 'done' AS-1
  # A queued watch must recheck done even if metadata has not caught up yet.
  jq '.status="running"' "$DV_STATE/AS-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/AS-1/meta"
  appserver_age
  dv _appserver-watch
  jq -se '[.[]|select(.method=="turn/start")]|length==1' "$CASE_DIR/server/requests"
}

case_appserver_recovery_uncertain() {
  appserver_setup
  printf 'unknown\n' > "$CASE_DIR/server/outcome"
  appserver_age
  dv _appserver-watch
  test -f "$DV_STATE/AS-1/appserver/blocked"
  printf '%s\n' '{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"id":"late","type":"agentMessage","text":"Late old progress"}}}' > "$CASE_DIR/server/notify"
  dv status AS-1 --json >/dev/null
  appserver_age
  dv _appserver-watch
  test -f "$DV_STATE/AS-1/appserver/recovery"
  jq -se '[.[]|select(.method=="turn/start")]|length==2' "$CASE_DIR/server/requests"
  dv status AS-1 --json | jq -e '.[0].recoveries==1'
}
case_appserver_recovery_events() {
  appserver_setup
  appserver_age
  dv _appserver-watch
  # Neither an old turn nor the echoed user prompt replenishes the episode.
  printf '%s\n' \
    '{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"type":"agentMessage","text":"Old progress"}}}' \
    '{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-2"}}}' \
    '{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-2","item":{"type":"userMessage"}}}' > "$CASE_DIR/server/notify"
  dv status AS-1 --json >/dev/null
  dv status AS-1 --json >/dev/null
  test -f "$DV_STATE/AS-1/appserver/recovery"
  printf '%s\n' '{"method":"item/commandExecution/outputDelta","params":{"threadId":"thread-1","turnId":"turn-2","delta":"new output"}}' > "$CASE_DIR/server/notify"
  dv status AS-1 --json >/dev/null
  dv status AS-1 --json >/dev/null
  test ! -f "$DV_STATE/AS-1/appserver/recovery"
  appserver_age
  dv _appserver-watch
  dv status AS-1 --json | jq -e '.[0].recoveries==2'
}
case_appserver_recovery_early_progress() {
  appserver_setup
  touch "$CASE_DIR/server/early-progress"
  appserver_age
  dv _appserver-watch
  test ! -f "$DV_STATE/AS-1/appserver/recovery"
  appserver_age
  dv _appserver-watch
  dv status AS-1 --json | jq -e '.[0].recoveries==2'
}
case_appserver_capacity_notification() {
  appserver_setup
  printf 'idle\n' > "$CASE_DIR/server/status"
  printf '%s\n' '{"method":"error","params":{"threadId":"thread-1","turnId":"turn-1","error":{"message":"Rate limit reached"}}}' > "$CASE_DIR/server/notify"
  dv status AS-1 --json >/dev/null
  dv _appserver-watch
  test -f "$DV_STATE/AS-1/appserver/capacity-since"
  jq -se '[.[]|select(.method=="turn/start")]|length==1' "$CASE_DIR/server/requests"
  printf '0\n' > "$DV_STATE/AS-1/appserver/capacity-since"
  dv _appserver-watch
  dv status AS-1 --json | jq -e '.[0].recoveries==1 and .[0].last_recovery_reason=="capacity"'
  appserver_progress
  appserver_age
  dv _appserver-watch
  dv status AS-1 --json | jq -e '.[0].recoveries==2 and .[0].last_recovery_reason=="stalled"'
}

case_appserver_pr_idle_recover() {
  appserver_setup remote
  local wt
  wt=$(jq -r .worktree "$DV_STATE/AS-1/meta")
  git -C "$wt" commit --allow-empty -qm 'AS-1: fake change awaiting delivery'
  dv pr AS-1
  jq -e '.status=="pr"' "$DV_STATE/AS-1/meta"
  printf 'idle\n' > "$CASE_DIR/server/status"
  printf 'complete\n' > "$CASE_DIR/server/goal"
  appserver_age
  dv _appserver-watch
  jq -se 'any(.[]; .method=="turn/start" and (.params.input[0].text|contains("You stopped without dv done")))' "$CASE_DIR/server/requests"
  dv pr-wait AS-1 --foreground --review-handled > "$CASE_DIR/pr-result"
  dv 'done' AS-1
  jq -e '.checks=="green" and .review=="handled"' "$DV_STATE/AS-1/done.json"
  appserver_age
  dv _appserver-watch
  jq -se '[.[]|select(.method=="turn/start")]|length==2' "$CASE_DIR/server/requests"
}

case_appserver_stale_done_recover() {
  appserver_setup remote
  local wt old_head
  wt=$(jq -r .worktree "$DV_STATE/AS-1/meta")
  git -C "$wt" commit --allow-empty -qm 'AS-1: completed revision'
  dv pr AS-1
  dv pr-wait AS-1 --foreground > "$CASE_DIR/pr-result"
  dv pr-wait AS-1 --foreground --review-handled > "$CASE_DIR/pr-result"
  dv 'done' AS-1
  old_head=$(jq -r .head "$DV_STATE/AS-1/done.json")
  git -C "$wt" commit --allow-empty -qm 'AS-1: correction still awaiting completion'
  dv pr AS-1
  jq -e --arg old "$old_head" '.status=="pr" and .head!=$old' "$DV_STATE/AS-1/meta"
  printf 'idle\n' > "$CASE_DIR/server/status"
  appserver_age
  dv _appserver-watch
  jq -se 'any(.[]; .method=="turn/start" and (.params.input[0].text|contains("You stopped without dv done")))' "$CASE_DIR/server/requests"
  # Keep the historical completion until the replacement head is really done.
  jq -e --arg old "$old_head" '.head==$old' "$DV_STATE/AS-1/done.json"
  dv pr-wait AS-1 --foreground --review-handled > "$CASE_DIR/pr-result"
  dv 'done' AS-1
  jq -e --arg head "$(git -C "$wt" rev-parse HEAD)" '.head==$head' "$DV_STATE/AS-1/done.json"
  appserver_age
  dv _appserver-watch
  jq -se '[.[]|select(.method=="turn/start")]|length==2' "$CASE_DIR/server/requests"
}
