#!/usr/bin/env bash
metrics_fixture() {
  pr_fixture
  # The shared GitHub fixture must satisfy DF-100's completion gate.
  jq '{head,green:true,review_handled:true}' "$DV_STATE/P-1/meta" > "$DV_STATE/P-1/pr-ready.json"
  printf '{"review_handled":true}\n' > "$DV_STATE/P-1/pr-loop.json"
  jq '.status="running" | .started=100' "$DV_STATE/P-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/P-1/meta"
  DV_ENTRY="$ROOT/bin/dv"
  # shellcheck source=lib/common.sh
  source "$ROOT/lib/common.sh"
  # shellcheck source=lib/commands.sh
  source "$ROOT/lib/commands.sh"
  # shellcheck source=lib/delivery.sh
  source "$ROOT/lib/delivery.sh"
  METRICS_NOW=100
  now() { printf '%s\n' "$METRICS_NOW"; }
}
case_metrics_cli() {
  dv metrics --since 6h > "$CASE_DIR/metrics"
  grep 'IDLE_MIN' "$CASE_DIR/metrics"
  dv metrics --json | jq -e 'length==0'
  if dv metrics --since nonsense; then return 1; fi
  if dv metrics --since; then return 1; fi
}
case_metrics_activity() {
  metrics_fixture
  cmd__metrics_sample > "$CASE_DIR/first"
  METRICS_NOW=220; cmd__metrics_sample > "$CASE_DIR/second"
  jq -e '.[0].idle_seconds==120' "$CASE_DIR/second"
  # A content edit at the same path and size must reset the episode.
  printf 'edit\n' > "$REPO/base"
  METRICS_NOW=280; cmd__metrics_sample > "$CASE_DIR/edit"
  jq -e '.[0].idle_seconds==0' "$CASE_DIR/edit"
  METRICS_NOW=340; cmd__metrics_sample >/dev/null
  printf 'new\n' > "$REPO/untracked file"
  METRICS_NOW=400; cmd__metrics_sample > "$CASE_DIR/new"
  jq -e '.[0].idle_seconds==0' "$CASE_DIR/new"
  METRICS_NOW=460; cmd__metrics_sample >/dev/null
  cmd_kick question P-1 'needs an answer'
  METRICS_NOW=520; cmd__metrics_sample > "$CASE_DIR/event"
  jq -e '.[0].idle_seconds==0' "$CASE_DIR/event"
  cmd_metrics --json | jq -e '.[0] | .idle_minutes==4 and .observed_at==520'
  cmd_metrics --since 3m --json | jq -e '.[0].idle_minutes==1'
  # Restarting the CLI preserves samples; collecting never edits operational meta.
  jq -e '.started==100 and .status=="running" and .done_at==null' "$DV_STATE/P-1/meta"
}
case_metrics_lifecycle() {
  metrics_fixture
  METRICS_NOW=200; cmd_done P-1
  METRICS_NOW=260; cmd_done P-1
  load_issue P-1
  METRICS_NOW=300; metrics_note revive
  METRICS_NOW=320; metrics_note resume
  METRICS_NOW=400; metrics_note merged "$(git -C "$REPO" rev-parse HEAD)"
  cmd_metrics --json | jq -e '.[0] | .done_to_merged_seconds==140 and .revive_count==1 and .resume_count==1'
  cmd_metrics --since 90s --json | jq -e '.[0] | .done_to_merged_seconds==140 and .revive_count==0 and .resume_count==1'
  # A different completion head cannot be paired with the merged revision.
  METRICS_NOW=450; metrics_note merged other-head
  cmd_metrics --json | jq -e '.[0].done_to_merged_seconds==null'
}
case_metrics_handled() {
  watch_fixture
  export DV_WORKER_FAIL_ONCE=1 DV_WORKER_GATE=1
  dv-kick question LAT-1 test worker head same-event
  dv-kick question LAT-1 test worker head same-event
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  for _ in {1..100}; do [ ! -d "$DV_HOME/failed-once" ] || break; sleep 0.1; done
  dv metrics --json | jq -e 'all(.[]; .handled_count==0)'
  touch "$DV_HOME/release"
  wait_seen 1
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  dv metrics --json | jq -e '.[0] | .issue=="LAT-1" and .handled_count==1 and .event_to_handled_seconds>=1'
}
case_metrics_manager() {
  manager_setup
  dv manager start "$REPO"
  manager_event M-1 "$REPO"
  export HERMES_HOLD=2
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_seen 1
  dv metrics --json | jq -e 'all(.[]; .handled_count==0)'
  for _ in {1..100}; do
    if dv metrics --json | jq -e 'any(.[]; .handled_count==1)' >/dev/null; then break; fi
    sleep 0.1
  done
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  dv metrics --json | jq -e '.[0] | .issue=="M-1" and .handled_count==1 and .manager_resume_count==1 and .event_to_handled_seconds>=2'
}
case_metrics_idle() {
  metrics_fixture; watch_fixture
  export DV_HOSTS="$DV_HOST" DV_METRICS_INTERVAL=1 DV_STALL_AFTER=1
  # The agent remains alive and working; metrics must not consult its state.
  jq '.backend="herdr" | .herdr_pane="working-pane"' "$DV_STATE/P-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/P-1/meta"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  for _ in {1..150}; do
    if jq -se 'any(.[]; .kind=="idle")' "$DV_HOME/kick.q" >/dev/null 2>&1; then break; fi
    sleep 0.1
  done
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  jq -se '[.[]|select(.kind=="idle")]|length==1' "$DV_HOME/kick.q"
  rm "$DV_HOME/stop"
  dv-watch >> "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  sleep 2
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  jq -se '[.[]|select(.kind=="idle")]|length==1' "$DV_HOME/kick.q"
  printf 'progress\n' >> "$REPO/base"
  rm "$DV_HOME/stop"
  dv-watch >> "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  for _ in {1..150}; do
    if jq -se '[.[]|select(.kind=="idle")]|length==2' "$DV_HOME/kick.q" >/dev/null 2>&1; then break; fi
    sleep 0.1
  done
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  jq -se '[.[]|select(.kind=="idle")]|length==2 and (.[0].id!=.[1].id)' "$DV_HOME/kick.q"
}
case_metrics_external_merge() {
  metrics_fixture
  cmd__metrics_sample >/dev/null
  METRICS_NOW=200; cmd_done P-1
  printf '{"url":"https://github.com/test/repo/pull/1"}\n' > "$DV_STATE/P-1/pr.json"
  METRICS_NOW=220; cmd__metrics_sample >/dev/null
  touch "$GH_STUB_DIR/merged"
  printf '1970-01-01T00:05:00Z\n' > "$GH_STUB_DIR/merged-at"
  METRICS_NOW=400; cmd__metrics_sample > "$CASE_DIR/merged"
  jq -e '.[0] | .status=="landed" and .idle_seconds==0 and .observed_at==300' "$CASE_DIR/merged"
  cmd_metrics --json | jq -e '.[0].done_to_merged_seconds==100'
  METRICS_NOW=500; cmd__metrics_sample >/dev/null
  cmd_metrics --json | jq -e '.[0].idle_minutes==(80/60)'
}
case_metrics_agent_counts() {
  revive_setup
  dv send RV-1 'continue existing agent'
  dv metrics --json | jq -e '.[0] | .revive_count==0 and .agent_resume_count==1'
  revive_dead
  dv send RV-1 'recover existing work'
  revive_wait
  dv metrics --json | jq -e '.[0] | .revive_count==1 and .agent_resume_count==1'
}
case_metrics_remote() {
  metrics_fixture; watch_fixture
  export DV_HOSTS=remote-alias SSH_FIXTURE_EXEC=1 DV_METRICS_INTERVAL=1 DV_STALL_AFTER=1
  mkdir "$CASE_DIR/remote-home"
  printf 'DV_STATE=%q\nDV_HOME=%q\n' "$DV_STATE" "$CASE_DIR/remote-home" > "$CASE_DIR/remote-home/config.sh"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  for _ in {1..150}; do
    if jq -se 'any(.[]; .kind=="idle")' "$DV_HOME/kick.q" >/dev/null 2>&1; then break; fi
    sleep 0.1
  done
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  jq -se '[.[]|select(.kind=="idle")]|length==1 and .[0].host=="test-host"' "$DV_HOME/kick.q"
  # The watcher retains remote metrics even without local issue state.
  DV_STATE="$CASE_DIR/no-local-state" dv metrics --json | jq -e '.[0] | .issue=="P-1" and .host=="test-host" and .idle_minutes>0'
}
case_metrics_timestamp() {
  metrics_fixture; watch_fixture
  METRICS_NOW=123; cmd_kick question P-1 'original event time'
  jq -e '.time==123' "$DV_HOME/kick.q"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_seen 1
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  dv metrics --json | jq -e '.[0].event_to_handled_seconds>1000'
}
case_metrics_missing_worktree() {
  metrics_fixture
  jq --arg missing "$CASE_DIR/missing" '.worktree=$missing' "$DV_STATE/P-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/P-1/meta"
  cmd__metrics_sample >/dev/null
  METRICS_NOW=220; cmd__metrics_sample | jq -e '.[0].idle_seconds==120'
}
case_metrics_queue_activity() {
  metrics_fixture
  cmd__metrics_sample >/dev/null
  METRICS_NOW=220; cmd__metrics_sample >/dev/null
  # Queue-only events on the watcher also reset remote activity observations.
  METRICS_NOW=280
  cmd__metrics_sample --events '[{"host":"test-host","issue":"P-1","id":"remote-progress","time":270}]' | jq -e '.[0].idle_seconds==0'
  METRICS_NOW=340
  cmd__metrics_sample --events '[{"host":"test-host","issue":"P-1","id":"remote-progress","time":270}]' | jq -e '.[0].idle_seconds==60'
  dv-kick idle P-1 'an alert is not progress' test-host h ignored-alert '' 350
  METRICS_NOW=400; cmd__metrics_sample | jq -e '.[0].idle_seconds==120'
}
case_metrics_terminal() {
  metrics_fixture
  local phase
  for phase in running done pr ready start-failed; do
    jq --arg phase "$phase" '.status=$phase' "$DV_STATE/P-1/meta" > "$CASE_DIR/meta"
    mv "$CASE_DIR/meta" "$DV_STATE/P-1/meta"
    cmd__metrics_sample >/dev/null
    METRICS_NOW=$((METRICS_NOW+120))
    cmd__metrics_sample | jq -e '.[0].idle_seconds>=120'
  done
  jq '.cleaned_at=800' "$DV_STATE/P-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/P-1/meta"
  METRICS_NOW=900; cmd__metrics_sample | jq -e '.[0] | .idle_seconds==0 and .status=="cleaned"'
  local before
  before=$(cmd_metrics --json | jq '.[0].idle_minutes')
  METRICS_NOW=1100; cmd__metrics_sample >/dev/null
  cmd_metrics --json | jq -e --argjson before "$before" '.[0].idle_minutes==$before'
}
case_metrics_pull_time() {
  export SSH_FIXTURE_EXEC=1
  mkdir "$CASE_DIR/remote-home"
  printf 'DV_HOME=%q\n' "$CASE_DIR/remote-home" > "$CASE_DIR/remote-home/config.sh"
  DV_HOME="$CASE_DIR/remote-home" dv-kick question PULL-TIME 'original' source head timed-event '' 123
  dv-kick-pull source > "$CASE_DIR/pull.log" 2>&1 & local puller=$!
  for _ in {1..100}; do [ ! -s "$DV_HOME/kick.q" ] || break; sleep 0.1; done
  kill "$puller"; wait "$puller" || true
  jq -e '.time==123 and .id=="timed-event"' "$DV_HOME/kick.q"
}
case_metrics_queue_corruption() {
  metrics_fixture
  printf 'not-json\n{"incomplete":\n' > "$DV_HOME/kick.q"
  dv-kick question P-1 valid test-host h preserved '' 100
  cmd__metrics_sample | jq -e '.[0].queue_event.id=="preserved"'
}
case_metrics_concurrent() {
  metrics_fixture
  local n pid jobs='' event
  for n in 1 2 3 4 5 6 7 8; do
    event=$(event_json question P-1 '' test-host h "event-$n")
    (metrics_handled "$event"; metrics_handled "$event") & jobs="$jobs $!"
  done
  for pid in $jobs; do wait "$pid"; done
  cmd_metrics --json | jq -e '.[0].handled_count==8'
}
metrics_slow_fixture() {
  watch_fixture
  export DV_HOSTS='slow-one slow-two' DV_BID_TIMEOUT=${1:-20} DV_METRICS_INTERVAL=1
  mkdir "$CASE_DIR/metrics-bin"
  ln -s "$ROOT/tests/fixtures/metrics-ssh" "$CASE_DIR/metrics-bin/ssh"
  export PATH="$CASE_DIR/metrics-bin:$PATH"
  printf '[]\n' > "$CASE_DIR/remote-status"
  trap 'touch "$CASE_DIR/metrics-release"; watcher_teardown' EXIT
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_file "$CASE_DIR/metrics-ssh.started"
}
metrics_fast_event() {
  local id=$1
  dv-kick question FAST-1 progress test-host h "$id"
  for _ in {1..20}; do
    if grep -Fxq "$id" "$DV_HOME/seen" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  printf 'Queue blocked behind metrics collector\n' >&2
  return 1
}
metrics_stop_watch() {
  touch "$DV_HOME/stop"
  for _ in {1..30}; do
    if ! kill -0 "$watcher" 2>/dev/null; then wait "$watcher"; watcher=''; return 0; fi
    sleep 0.1
  done
  printf 'Watcher shutdown blocked behind metrics collector\n' >&2
  return 1
}
case_metrics_nonblocking() {
  metrics_slow_fixture
  metrics_fast_event fast-first
  local collector
  collector=$(cat "$DV_HOME/metrics.pid")
  sleep 1.1
  metrics_fast_event fast-second
  test "$(cat "$DV_HOME/metrics.pid")" = "$collector"
  test "$(wc -l < "$CASE_DIR/metrics-ssh.started" | tr -d ' ')" = 1
  metrics_stop_watch
  test ! -f "$DV_HOME/metrics.pid"
  if ps -o args= -p "$collector" 2>/dev/null | grep -q _metrics-collect; then return 1; fi
}
case_metrics_collector_restart() {
  metrics_slow_fixture
  local collector
  collector=$(cat "$DV_HOME/metrics.pid")
  kill -KILL "$watcher"; wait "$watcher" 2>/dev/null || true; watcher=''
  dv-watch >> "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  metrics_fast_event after-restart
  test "$(cat "$DV_HOME/metrics.pid")" = "$collector"
  test "$(wc -l < "$CASE_DIR/metrics-ssh.started" | tr -d ' ')" = 1
  metrics_stop_watch
}
case_metrics_exec() {
  case_exec_retry
  dv metrics --json | jq -e '.[0] | .revive_count==1 and .agent_resume_count==1'
  dv send EX-1 'Continue after the exec retry'
  exec_wait
  dv metrics --json | jq -e '.[0] | .revive_count==1 and .agent_resume_count==2'
}
case_metrics_exec_events() {
  metrics_fixture
  cmd__metrics_sample >/dev/null
  METRICS_NOW=220; cmd__metrics_sample >/dev/null
  printf '{"type":"item.completed"}\n' > "$DV_STATE/P-1/agent.jsonl"
  METRICS_NOW=280; cmd__metrics_sample | jq -e '.[0].idle_seconds==0'
}
case_metrics_manager_batch() {
  case_manager_batch
  dv metrics --json | jq -e 'length==3 and all(.[]; .manager_resume_count==1) and
    (map(select(.issue=="M-1"))[0].handled_count==3) and
    all(.[]|select(.issue!="M-1"); .handled_count==1)'
}
case_metrics_manager_fallback() {
  case_manager_fallback_restart
  dv metrics --json | jq -e 'length==1 and .[0].issue=="M-2" and .[0].handled_count==1'
}
case_metrics_timeout_snapshot() {
  metrics_fixture
  cmd__metrics_sample >/dev/null
  local dir collector
  dir=$(metrics_job_dir test-host P-1)
  mkdir -p "$dir"
  cp "$DV_STATE/P-1/metrics/activity.json" "$dir/snapshot.json"
  cp "$dir/snapshot.json" "$CASE_DIR/before-snapshot"
  metrics_slow_fixture 1
  collector=$(cat "$DV_HOME/metrics.pid")
  for _ in {1..80}; do
    if ! ps -o args= -p "$collector" 2>/dev/null | grep -q _metrics-collect; then break; fi
    sleep 0.1
  done
  if ps -o args= -p "$collector" 2>/dev/null | grep -q _metrics-collect; then return 1; fi
  cmp "$CASE_DIR/before-snapshot" "$dir/snapshot.json"
  metrics_stop_watch
}
