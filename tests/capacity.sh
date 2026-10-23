#!/usr/bin/env bash
# Fake provider failures only; no live agents or remote PRs.
# shellcheck disable=SC2016,SC2154
capacity_clock_setup() {
  date +%s > "$CASE_DIR/capacity-time"
  export BASH_ENV="$ROOT/tests/fixtures/capacity-clock"
  export DV_CAPACITY_BACKOFF=120 DV_CAPACITY_MAX_WAIT=21600
}
capacity_clock_advance() {
  printf '%s\n' "$(( $(cat "$CASE_DIR/capacity-time") + $1 ))" > "$CASE_DIR/capacity-time.next"
  mv "$CASE_DIR/capacity-time.next" "$CASE_DIR/capacity-time"
}
capacity_status_wait() {
  local issue=$1 i
  # Cached status no longer waits for a client RPC; allow the client's next
  # poll/recovery to publish capacity metadata before exhausting this wait.
  for i in {1..100}; do
    if dv status "$issue" --json > "$CASE_DIR/capacity-status" &&
      jq -e '.[0] | .status=="waiting-capacity" and .agent_status=="waiting-capacity" and .alive and .capacity_retry_at>0' "$CASE_DIR/capacity-status"; then return; fi
    sleep 0.05
  done
  return 1
}
case_capacity_exec_once() {
  exec_setup capacity-once
  capacity_clock_setup
  dv start "$REPO" EX-1 exec --mode exec
  capacity_status_wait EX-1
  dv status EX-1 | grep 'waiting-capacity.*next_try='
  dv bid --json --repo "$REPO" | jq -e '.active==1'
  capacity_clock_advance 120
  exec_wait
  jq -e '.status=="done" and .capacity==null' "$DV_STATE/EX-1/meta"
  test ! -f "$DV_STATE/EX-1/exec-retry.used"
  jq -se 'length==2 and (.[1].args|index("resume")!=null and index("fixture-thread")!=null) and (.[1].args[-1]|contains("Continue the interrupted request")) and .[0].cwd==.[1].cwd' "$DV_STATE/EX-1/stub-runs.jsonl"
  jq -se 'map(.kind)==["waiting-capacity","done"]' "$DV_STATE/EX-1/events.log"
}
case_capacity_exec_timeout() {
  exec_setup "${1:-capacity}"
  export DV_CAPACITY_BACKOFF=1 DV_CAPACITY_MAX_WAIT=3
  dv start "$REPO" EX-1 exec --mode exec
  exec_wait
  jq -e '.status=="blocked" and (.failure_reason|contains("provider usage limit for"))' "$DV_STATE/EX-1/meta"
  test ! -f "$DV_STATE/EX-1/exec-retry.used"
  jq -se 'map(.kind)==["waiting-capacity","blocked"]' "$DV_STATE/EX-1/events.log"
}
case_capacity_appserver_once() {
  capacity_clock_setup
  export DV_RECOVER_MAX=1
  appserver_setup
  printf '{"recoveries":1,"last_recovery_reason":"stalled"}\n' > "$DV_STATE/AS-1/appserver/recoveries.json"
  touch "$CASE_DIR/server/capacity-once" "$CASE_DIR/server/recovery-work"
  appserver_capacity_error '{"message":"You have hit your usage limit. Try again at Oct 27th, 2026 3:34 PM."}'
  dv _appserver-watch
  capacity_status_wait AS-1
  capacity_clock_advance 120
  appserver_wait_work
  jq -e '.status=="done"' "$DV_STATE/AS-1/meta"
  dv status AS-1 --json | jq -e '.[0].recoveries==1 and .[0].last_recovery_reason=="stalled"'
  test ! -f "$DV_STATE/AS-1/appserver/recovery"
  jq -se 'map(.kind)==["waiting-capacity","done"]' "$DV_STATE/AS-1/events.log"
}
case_capacity_appserver_slow_work() {
  # Local work may outlast a single RPC deadline without any RPC timing out.
  export DV_APP_WORK_DELAY=11
  case_capacity_appserver_once
}
case_capacity_qa_once() {
  qa_fixture
  capacity_clock_setup
  export DV_QA_CAPACITY=1
  qa_event capacity
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  qa_wait_runs 1
  local issue
  issue=$(jq -r .issue "$CASE_DIR/qa-runs")
  capacity_status_wait "$issue"
  capacity_clock_advance 120
  qa_wait_runs 2
  qa_finish
  jq -e '.status=="done" and .capacity==null' "$DV_STATE/$issue/meta"
  test ! -f "$DV_STATE/$issue/exec-retry.used"
  test ! -f "$DV_STATE/$issue/appserver/recoveries.json"
  jq -se 'length==2 and .[0].worktree==.[1].worktree' "$CASE_DIR/qa-runs"
  jq -se '[.[]|select(.kind=="waiting-capacity")]|length==1' "$DV_STATE/$issue/events.log"
}
capacity_terminal_case() {
  local agent=$1
  needs_tmux; repo terminal
  capacity_clock_setup
  export DV_HERDR=0
  export "DV_AGENT_CMD_$agent=$ROOT/tests/fixtures/capacity-terminal"
  dv start "$REPO" CT-1 capacity --agent "$agent" --mode goal
  capacity_status_wait CT-1
  capacity_clock_advance 120
  wait_done CT-1
  jq -e '.status=="done" and .capacity==null' "$DV_STATE/CT-1/meta"
  grep -F 'Continue the interrupted request' "$DV_STATE/CT-1/capacity-input"
  jq -se 'map(.kind)==["waiting-capacity","done"]' "$DV_STATE/CT-1/events.log"
  test ! -f "$DV_STATE/CT-1/revive/used"
  test ! -f "$DV_STATE/CT-1/stall-recovery.json"
}
case_capacity_claude() { capacity_terminal_case claude; }
case_capacity_devin() { capacity_terminal_case devin; }
case_capacity_terminal_exit() { export DV_CAPACITY_EXIT=1; capacity_terminal_case claude; }
capacity_due() {
  jq '.capacity.next_try_at=0' "$DV_STATE/$1/meta" > "$CASE_DIR/capacity-meta"
  mv "$CASE_DIR/capacity-meta" "$DV_STATE/$1/meta"
}
case_capacity_classifier() {
  bidding_functions
  local message file="$CASE_DIR/error"
  for message in 'usage limit' usageLimitExceeded rate_limit_exceeded 'HTTP 429' 'HTTP/1.1 429' 'Selected model is at capacity' overloaded '{"httpStatusCode":429}' '{"statusCode":429}'; do
    printf '%s\n' "$message" | capacity_error
    jq -cn --arg message "$message" '{type:"turn.failed",error:(try ($message|fromjson) catch {message:$message})}' > "$file"
    capacity_output_error "$file" 1
  done
  printf '{"type":"item.completed","item":{"type":"agent_message","text":"HTTP 429 is an example"}}\n' > "$file"
  if capacity_output_error "$file" 1; then return 1; fi
  printf 'normal failure\n' | capacity_error && return 1
  return 0
}
case_capacity_backoff() {
  bidding_functions
  ISSUE=CAP-1; S="$DV_STATE/$ISSUE"; mkdir "$S"
  printf '{"status":"pr"}\n' > "$S/meta"
  local fixture_time=1000 rc
  now() { printf '%s\n' "$fixture_time"; }
  cmd_kick() { printf '%s\n' "$1" >> "$S/notices"; }
  DV_CAPACITY_BACKOFF=120 DV_CAPACITY_MAX_WAIT=21600
  rc=0; capacity_poll || rc=$?; test "$rc" = 1
  jq -e '.status=="waiting-capacity" and .capacity.next_try_at==1120' "$S/meta"
  meta_set '.done_at=1'
  test "$(bid_active)" = 1
  fixture_time=1120; capacity_poll; capacity_resume
  jq -e '.status=="pr"' "$S/meta"
  rc=0; capacity_poll || rc=$?; test "$rc" = 1
  jq -e '.capacity.next_try_at==1420' "$S/meta"
  fixture_time=1420; capacity_poll; capacity_resume
  rc=0; capacity_poll || rc=$?; test "$rc" = 1
  jq -e '.capacity.next_try_at==2320' "$S/meta"
  fixture_time=2320; capacity_poll; capacity_resume
  rc=0; capacity_poll || rc=$?; test "$rc" = 1
  jq -e '.capacity.next_try_at==3220' "$S/meta"
  fixture_time=22600; rc=0; capacity_poll || rc=$?; test "$rc" = 2
  capacity_block
  jq -e '.status=="blocked" and (.failure_reason|startswith("provider usage limit for 6 h"))' "$S/meta"
  test "$(cat "$S/notices")" = "$(printf 'waiting-capacity\nblocked')"
}
case_capacity_appserver_timeout() {
  export DV_CAPACITY_BACKOFF=1 DV_CAPACITY_MAX_WAIT=3
  appserver_setup
  appserver_capacity_error '{"message":"overloaded"}'
  local i
  for i in {1..20}; do
    dv _appserver-watch
    if jq -e '.status=="blocked"' "$DV_STATE/AS-1/meta" >/dev/null; then break; fi
    sleep 0.1
  done
  jq -e '.status=="blocked" and (.failure_reason|contains("provider usage limit for"))' "$DV_STATE/AS-1/meta"
  dv status AS-1 --json | jq -e '.[0].recoveries==0'
  jq -se 'map(.kind)==["waiting-capacity","blocked"]' "$DV_STATE/AS-1/events.log"
}
case_capacity_qa_native() {
  qa_fixture
  capacity_clock_setup
  export DV_QA_CAPACITY=1
  export DV_QA_AGENT_CMD='' DV_CODEX_BIN="$ROOT/tests/fixtures/qa-agent" DV_CODEX_ENV_FILE=''
  qa_event capacity
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  qa_wait_runs 1
  local issue
  issue=$(jq -r .issue "$CASE_DIR/qa-runs")
  capacity_status_wait "$issue"
  capacity_clock_advance 120
  qa_wait_runs 2
  qa_finish
  jq -e '(.args|index("resume")!=null and index("qa-thread")!=null) and (.args[-1]|startswith("Continue the interrupted request"))' "$CASE_DIR/qa-command"
  jq -se 'length==2 and .[0].worktree==.[1].worktree' "$CASE_DIR/qa-runs"
}
case_capacity_qa_timeout() {
  qa_fixture
  export DV_CAPACITY_BACKOFF=1 DV_CAPACITY_MAX_WAIT=2 DV_QA_CAPACITY=always
  qa_event capacity
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  qa_wait_runs 1
  local issue i
  issue=$(head -n 1 "$CASE_DIR/qa-runs" | jq -r .issue)
  for i in {1..100}; do
    [ ! -f "$DV_STATE/$issue/agent.exit" ] || break
    sleep 0.1
  done
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  jq -e '.status=="blocked" and (.failure_reason|contains("provider usage limit for"))' "$DV_STATE/$issue/meta"
  jq -se 'map(.kind)==["waiting-capacity","blocked"]' "$DV_STATE/$issue/events.log"
}
case_capacity_legacy_terminal() {
  stall_fixture; stall_functions; stall_recovery_functions
  printf 'Error: usage limit\n' > "$CASE_DIR/herdr/w-ST-1/output"
  cmd__stall_recover ST-1 capacity round-1
  jq -e '.status=="waiting-capacity" and .capacity.next_try_at!=null' "$DV_STATE/ST-1/meta"
  test ! -f "$DV_STATE/ST-1/stall-recovery.json"
  capacity_due ST-1
  cmd__stall_recover ST-1 capacity round-1
  stall_resume_count 1
  jq -se 'map(.kind)==["waiting-capacity"]' "$DV_STATE/ST-1/events.log"
}
case_capacity_appserver_rpc() {
  capacity_clock_setup
  export DV_APP_CAPACITY_RPC=2
  appserver_setup
  touch "$CASE_DIR/server/recovery-work"
  capacity_status_wait AS-1
  local i
  capacity_clock_advance 120
  for i in {1..200}; do
    if jq -e '.capacity.attempt==2' "$DV_STATE/AS-1/meta" >/dev/null; then break; fi
    sleep 0.1
  done
  jq -e '.capacity.attempt==2' "$DV_STATE/AS-1/meta"
  capacity_clock_advance 300
  appserver_wait_work
  jq -e '.status=="done" and .capacity==null' "$DV_STATE/AS-1/meta"
  dv status AS-1 --json | jq -e '.[0].recoveries==0'
  jq -se 'map(.kind)==["waiting-capacity","done"]' "$DV_STATE/AS-1/events.log"
  jq -se '[.[]|select(.method=="turn/start")]|length==3' "$CASE_DIR/server/requests"
  jq -se '[.[]|select(.method=="turn/start")][-1].params.input[0].text | contains("Test brief") and contains("dv done AS-1")' "$CASE_DIR/server/requests"
}
case_capacity_appserver_unknown() {
  appserver_setup
  appserver_capacity_error '{"message":"model at capacity"}'
  dv _appserver-watch
  capacity_due AS-1
  printf 'unknown\n' > "$CASE_DIR/server/outcome"
  dv _appserver-watch
  dv _appserver-watch
  jq -e '.status=="blocked"' "$DV_STATE/AS-1/meta"
  dv status AS-1 --json | jq -e '.[0].recoveries==0'
  jq -se '[.[]|select(.method=="turn/start")]|length==2' "$CASE_DIR/server/requests"
  jq -se 'map(.kind)==["waiting-capacity","blocked"]' "$DV_STATE/AS-1/events.log"
}
case_capacity_terminal_timeout() {
  needs_tmux; repo terminal
  export DV_HERDR=0 DV_CAPACITY_BACKOFF=1 DV_CAPACITY_MAX_WAIT=3 DV_CAPACITY_TERMINAL_ALWAYS=1
  export DV_AGENT_CMD_devin="$ROOT/tests/fixtures/capacity-terminal"
  dv start "$REPO" CT-1 capacity --agent devin --mode goal
  wait_done CT-1
  jq -e '.status=="blocked" and (.failure_reason|contains("provider usage limit for"))' "$DV_STATE/CT-1/meta"
  jq -se 'map(.kind)==["waiting-capacity","blocked"]' "$DV_STATE/CT-1/events.log"
  test "$(cat "$DV_STATE/CT-1/agent.exit")" = 1
  test -d "$(jq -r .worktree "$DV_STATE/CT-1/meta")"
  if kill -0 "$(cat "$DV_STATE/CT-1/held.pid")" 2>/dev/null; then return 1; fi
}
