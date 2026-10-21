#!/usr/bin/env bash
# Sourced by run.sh: synthetic status, herdr/Codex fixtures, no live agents.
# shellcheck disable=SC2154,SC2016
stall_fixture() {
  repo stall; herdr_setup; watch_fixture
  export DV_HOSTS="$DV_HOST" DV_STALL_AFTER=1 DV_RECONCILE_INTERVAL=1
  mkdir "$DV_STATE/ST-1"
  jq -n --arg repo "$REPO" --arg head "$(git -C "$REPO" rev-parse HEAD)" \
    '{issue:"ST-1",repo:$repo,worktree:$repo,branch:"main",base:"main",agent:"codex",mode:"goal",
      host:"test-host",started:1,status:"running",start_head:$head,backend:"herdr",herdr_pane:"w-ST-1:p1",award_token:"round-1"}' > "$DV_STATE/ST-1/meta"
  herdr workspace create --label dv-ST-1 --cwd "$REPO" --no-focus >/dev/null
  touch "$CASE_DIR/herdr/w-ST-1/detected"
  printf 'idle\n' > "$CASE_DIR/herdr/w-ST-1/status"
  printf 'Goal stalled\n› \n' > "$CASE_DIR/herdr/w-ST-1/output"
}
case_stall_watch() {
  stall_fixture
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  if ! wait_seen 1; then
    printf 'Expected one stalled event for running+idle past DV_STALL_AFTER; queue:\n'
    cat "$DV_HOME/kick.q"; return 1
  fi
  sleep 1.2
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  jq -se 'length==1 and .[0].kind=="stalled" and .[0].issue=="ST-1" and .[0].token=="round-1"' "$DV_HOME/kick.q"
  rm "$DV_HOME/stop"
  dv-watch >> "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  sleep 1.5
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  jq -se 'length==1' "$DV_HOME/kick.q"
  grep -l 'stalled:' "$DV_HOME/workers/"*.prompt.md
}
case_stall_status() {
  stall_fixture
  printf 'working\n' > "$CASE_DIR/herdr/w-ST-1/status"
  printf '7\n' > "$CASE_DIR/herdr/w-ST-1/seq"
  dv status ST-1 --json | jq -e '.[0] | .goal_stalled and .agent_state_seq==7'
  printf 'Goal stalled\n• Pursuing goal\n› \n' > "$CASE_DIR/herdr/w-ST-1/output"
  printf 'Goal stalled\n' > "$DV_STATE/ST-1/log"
  dv status ST-1 --json | jq -e '.[0] | .goal_stalled==false and .goal_active'
  printf 'Pursuing goal\n• Goal stalled\n› \n' > "$CASE_DIR/herdr/w-ST-1/output"
  dv status ST-1 --json | jq -e '.[0] | .goal_stalled and .goal_active==false'
  jq -se 'any(.[]; .==["pane","read","w-ST-1:p1","--source","visible"])' "$CASE_DIR/herdr/calls"
}
stall_functions() {
  bidding_functions
  # shellcheck source=lib/stall.sh
  source "$ROOT/lib/stall.sh"
  DV_STALL_AFTER=600
  STALL_TIME=1000
  now() { printf '%s\n' "$STALL_TIME"; }
  STALL_ROW='{"issue":"ST-1","host":"canonical-host","status":"running","alive":true,"agent_status":"idle","started":1,"start_head":"h","award_token":"token","agent_state_seq":1}'
  touch "$DV_HOME/kick.q"
}
stall_scan() { stall_reconcile alias "[$STALL_ROW]" 60; }
stall_tick() {
  local count=0
  while [ "$count" -lt "${1:-10}" ]; do
    STALL_TIME=$((STALL_TIME + 60)); stall_scan; count=$((count + 1))
  done
}
stall_count() {
  jq -se --argjson count "$1" '[.[]|select(.kind=="stalled")]|length==$count' "$DV_HOME/kick.q"
}
case_stall_episodes() {
  stall_functions
  stall_scan; stall_count 0
  STALL_TIME=1059; stall_scan; stall_count 0
  stall_tick 9; stall_count 0 # 599 seconds is below the configured threshold.
  STALL_TIME=1600; stall_scan; stall_count 1
  stall_tick; stall_count 1
  # Activity resets both the clock and deduplication, even at the same head.
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.agent_status="working" | .goal_stalled=true')
  stall_scan; stall_tick; stall_count 1
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.agent_status="idle"')
  stall_scan; stall_count 1; stall_tick; stall_count 2
  # Work can start and finish between polls: the herdr sequence exposes it.
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.agent_state_seq=3')
  stall_scan; stall_count 2; stall_tick; stall_count 3
  jq -se '[.[].id]|length==(unique|length)' "$DV_HOME/kick.q"
  jq -se 'all(.[]; .host=="canonical-host" and .token=="token" and .head=="h")' "$DV_HOME/kick.q"
}
case_stall_inactive() {
  stall_functions
  local status
  for status in done landed ready pr start-failed; do
    STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.status="running"')
    stall_scan; stall_tick 9
    STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq --arg status "$status" '.status=$status')
    stall_scan; stall_tick
  done
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.status="running" | .done_at=1')
  stall_scan; stall_tick
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq 'del(.done_at) | .cleaned_at=1')
  stall_scan; stall_tick
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq 'del(.cleaned_at) | .alive=false')
  stall_scan; stall_tick
  stall_count 0
}
case_stall_observation() {
  stall_functions
  stall_scan
  # A missed host scan / long watcher outage does not prove continuous idle.
  STALL_TIME=3000; stall_scan; stall_count 0
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.agent_status="unknown"')
  STALL_TIME=3060; stall_scan; stall_tick; stall_count 0
  # The visible Codex banner also works without herdr agent detection.
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.goal_stalled=true')
  stall_scan; stall_tick; stall_count 1
  # agent get can fail while pane get/read still succeed. Losing optional
  # herdr telemetry must not turn the same banner into a new episode.
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.agent_state_seq=null')
  stall_scan; stall_tick; stall_count 1
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.agent_state_seq=1')
  stall_scan; stall_tick; stall_count 1
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.alive=false')
  stall_scan; stall_tick
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.alive=true')
  stall_scan; stall_tick; stall_count 1
  # Crash after queue append, before recording its acknowledgement.
  jq 'map_values(.emitted=false)' "$DV_HOME/stalls.json" > "$CASE_DIR/stalls.tmp"
  mv "$CASE_DIR/stalls.tmp" "$DV_HOME/stalls.json"
  stall_scan; stall_count 1
  # A new award of the same issue is a distinct episode.
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.award_token="round-2"')
  stall_scan; stall_tick; stall_count 2
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.goal_stalled=false | .goal_active=true')
  stall_scan
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.goal_stalled=true | .goal_active=false')
  stall_scan; stall_tick; stall_count 3
}
case_stall_remote() {
  watch_fixture
  export DV_HOSTS=ssh-alias DV_RECONCILE_INTERVAL=1 DV_STALL_AFTER=1
  printf '[{"issue":"ST-1","host":"canonical-host","status":"running","alive":true,"agent_status":"idle","head":"h","award_token":"t"}]\n' > "$CASE_DIR/remote-status"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_seen 1
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  jq -se 'length==1 and .[0].kind=="stalled" and .[0].host=="canonical-host" and .[0].token=="t"' "$DV_HOME/kick.q"
}
case_stall_tmux() {
  needs_tmux; stall_fixture
  jq '.backend="tmux" | del(.herdr_pane)' "$DV_STATE/ST-1/meta" > "$CASE_DIR/meta.tmp"
  mv "$CASE_DIR/meta.tmp" "$DV_STATE/ST-1/meta"
  tmux -L "$DV_TMUX_SOCKET" new-session -d -s dv-ST-1 "printf 'Goal stalled\\n› \\n'; sleep 30"
  local tries
  for tries in {1..50}; do
    if dv status ST-1 --json | jq -e '.[0].goal_stalled==true' >/dev/null; then break; fi
    sleep 0.1
  done
  dv status ST-1 --json | jq -e '.[0] | .goal_stalled and .alive and .agent_status=="unknown"'
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_seen 1
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  stall_count 1
  tmux -L "$DV_TMUX_SOCKET" respawn-pane -k -t dv-ST-1:0.0 "printf 'Pursuing goal\\n› \\n'; sleep 30"
  for tries in {1..50}; do
    if dv status ST-1 --json | jq -e '.[0].goal_active==true' >/dev/null; then break; fi
    sleep 0.1
  done
  dv status ST-1 --json | jq -e '.[0] | .goal_active and .goal_stalled==false'
}
