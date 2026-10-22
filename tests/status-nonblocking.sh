#!/usr/bin/env bash
# Synthetic clients/hosts only; no real App Server or SSH endpoint.
case_status_cached_many() {
  bidding_functions
  local n start elapsed rc=0
  # A fake client is alive but never services its outbox.
  bash -c 'while :; do sleep 1; done' 'dv _appserver-run CACHE-1' &
  local client=$!
  mkdir -p "$DV_STATE/CACHE-1/appserver"
  printf '%s\n' "$client" > "$DV_STATE/CACHE-1/appserver/client.pid"
  for n in {1..30}; do
    mkdir -p "$DV_STATE/CACHE-$n/appserver/outbox"
    printf '%s\n' "$client" > "$DV_STATE/CACHE-$n/appserver/client.pid"
    jq -cn --arg issue "CACHE-$n" '{issue:$issue,backend:"appserver",status:"running",started:1,
      agent:"codex",host:"test-host",thread_id:"cached-thread"}' > "$DV_STATE/CACHE-$n/meta"
    jq -cn --argjson at "$(( $(date +%s) - 60 ))" '{agent_status:"working",alive:true,
      question_pending:false,observed_at:$at,thread:{id:"cached-thread"},recoveries:0}' > "$DV_STATE/CACHE-$n/appserver/status.json"
  done
  start=$SECONDS
  bid_limit 2 dv status --json > "$CASE_DIR/status.json" || rc=$?
  elapsed=$((SECONDS - start))
  printf '30 cached jobs: %ss, exit=%s\n' "$elapsed" "$rc"
  test "$rc" = 0
  test "$elapsed" -lt 2
  jq -e 'length==30 and all(.[]; .agent_status=="working" and .alive and .status_age_seconds>=60)' "$CASE_DIR/status.json"
  test "$(find "$DV_STATE" -name 'request.*.json' | wc -l | tr -d ' ')" = 0
}

case_watch_status_slow() {
  watch_fixture
  bidding_functions
  trap 'if [ -n "${watcher:-}" ]; then bid_stop_tree "$watcher"; wait "$watcher" 2>/dev/null || true; fi; teardown' EXIT
  export DV_HOSTS='slow-host fast-host' DV_STATUS_TIMEOUT=2 DV_RECONCILE_INTERVAL=60 DV_APPSERVER_POLL=60
  export DV_WATCH_INTERVAL=5 SSH_STATUS_SLOW=1
  local n
  for n in {1..20}; do
    jq -cn --arg id "event-$n" --arg issue "EVENT-$n" \
      '{id:$id,issue:$issue,kind:"done",host:"test-host",head:"abc",time:1}' >> "$DV_HOME/kick.q"
  done
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  for _ in {1..40}; do
    [ "$(cat "$DV_HOME/cursor" 2>/dev/null)" != 20 ] || break
    sleep 0.1
  done
  printf 'cursor=%s (20 events must dispatch before first 5s tick)\n' "$(cat "$DV_HOME/cursor" 2>/dev/null || echo 0)"
  test "$(cat "$DV_HOME/cursor")" = 20
  wait_file "$CASE_DIR/status-fast-host"
  for _ in {1..40}; do
    if grep -q 'slow-host.*timeout' "$DV_HOME/reconcile.log"; then break; fi
    sleep 0.1
  done
  grep 'slow-host.*timeout' "$DV_HOME/reconcile.log"
  test "$(wc -l < "$CASE_DIR/status-slow-host" | tr -d ' ')" = 1
  ! kill -0 "$(cat "$CASE_DIR/status-slow-host.pid")" 2>/dev/null
}

case_watch_status_single() {
  watch_fixture
  export DV_HOSTS=slow-host SSH_STATUS_SLOW=1 DV_STATUS_TIMEOUT=10 DV_RECONCILE_INTERVAL=1 DV_APPSERVER_POLL=1
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_file "$CASE_DIR/status-slow-host"
  local worker
  worker=$(cat "$CASE_DIR/status-slow-host.pid")
  # A watcher crash must reuse the still-running per-host handle.
  kill -KILL "$watcher"; wait "$watcher" 2>/dev/null || true
  dv-watch >> "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  sleep 2
  test "$(wc -l < "$CASE_DIR/status-slow-host" | tr -d ' ')" = 1
  kill -0 "$worker"
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  ! kill -0 "$worker" 2>/dev/null
}

case_status_cache_notifications() {
  bidding_functions
  ISSUE=NOTIFY-1; S="$DV_STATE/$ISSUE"; AS_EVENTS=1; AS_THREAD=thread-1; AS_CACHED='{}'
  mkdir -p "$S/appserver/questions"; printf '{}\n' > "$S/meta"
  # Updating the cache must never ask the server for another snapshot.
  appserver_rpc() { echo 'unexpected RPC' >&2; return 1; }
  appserver_event '{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"inProgress"}}}'
  jq -e '.agent_status=="working" and .turn_id=="turn-1" and (.observed_at|type)=="number"' "$S/appserver/status.json"
  appserver_event '{"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","delta":"synthetic"}}'
  jq -e '.agent_status=="working"' "$S/appserver/status.json"
  appserver_event '{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed"}}}'
  jq -e '.agent_status=="idle" and .turn_id==null' "$S/appserver/status.json"
  appserver_event '{"method":"thread/goal/updated","params":{"threadId":"thread-1","goal":{"status":"complete"}}}'
  jq -e '.agent_status=="goal-complete"' "$S/appserver/status.json"
  cp "$S/appserver/status.json" "$CASE_DIR/cache-before"
  appserver_event '{"method":"turn/started","params":{"threadId":"another-thread","turn":{"id":"other","status":"inProgress"}}}'
  cmp "$CASE_DIR/cache-before" "$S/appserver/status.json"
}

case_status_cache_missing() {
  local cache
  mkdir -p "$DV_STATE/CACHE-1/appserver"
  printf '{"issue":"CACHE-1","backend":"appserver","status":"running","started":1,"thread_id":"current"}\n' > "$DV_STATE/CACHE-1/meta"
  for cache in '' 'broken json' '{"observed_at":1,"thread_id":"old","alive":true,"agent_status":"working"}'; do
    printf '%s' "$cache" > "$DV_STATE/CACHE-1/appserver/status.json"
    dv status --json | jq -e 'length==1 and (.[0] | .agent_status=="unknown" and .alive==false and .status_age_seconds==null)'
  done
  rm "$DV_STATE/CACHE-1/appserver/status.json"
  dv status --json | jq -e 'length==1 and .[0].status_age_seconds==null'
}

case_status_cache_live() {
  appserver_setup
  local client
  client=$(cat "$DV_STATE/AS-1/appserver/client.pid")
  kill -STOP "$client"
  trap 'kill -CONT "$client" 2>/dev/null || true; teardown' EXIT
  cp "$CASE_DIR/server/requests" "$CASE_DIR/before"
  dv status AS-1 --json | jq -e '.[0] | .agent_status=="working" and (.status_age_seconds|type)=="number"'
  cmp "$CASE_DIR/before" "$CASE_DIR/server/requests"
  test "$(find "$DV_STATE/AS-1/appserver/outbox" -name 'request.*.json' | wc -l | tr -d ' ')" = 0
  printf 'idle\n' > "$CASE_DIR/server/status"
  kill -CONT "$client"
  dv status AS-1 --live --json | jq -e '.[0].agent_status=="idle-with-goal-active"'
  test "$(find "$DV_STATE/AS-1/appserver/outbox" -name 'request.*.json' | wc -l | tr -d ' ')" = 1
  dv status AS-1 | grep 'status_age=[0-9].*s'
  trap teardown EXIT
}

case_recovery_sweep_progress() {
  bidding_functions
  local n rc
  # Model live clients so the watcher reaches the recovery request path.
  appserver_alive() { return 0; }
  for n in 1 2; do
    mkdir -p "$DV_STATE/SWEEP-$n/appserver"
    printf '{"issue":"SWEEP-%s","backend":"appserver","status":"running"}\n' "$n" > "$DV_STATE/SWEEP-$n/meta"
  done
  appserver_request() {
    printf '%s\n' "$ISSUE" >> "$CASE_DIR/sweep-attempts"
    sleep 60
  }
  for n in 1 2 3; do
    rc=0
    bid_limit 1 cmd__appserver_watch || rc=$?
    test "$rc" = 137
  done
  cat "$CASE_DIR/sweep-attempts"
  printf 'SWEEP-1\nSWEEP-2\nSWEEP-1\n' > "$CASE_DIR/expected-sweep"
  cmp "$CASE_DIR/expected-sweep" "$CASE_DIR/sweep-attempts"
}
