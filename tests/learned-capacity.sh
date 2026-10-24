#!/usr/bin/env bash
learned_fixture() {
  capacity_fixture
  DV_MAX_JOBS=''
  # Shared fixture state and intentionally unused polling counters/results.
  # shellcheck disable=SC2034
  DV_HOST_CAPACITY_WINDOW=86400
  mkdir -p "$DV_STATE/.host-capacity"
  jq -cn --arg host "$DV_HOST" '{version:1,host:$host,cores:8,learned_cap:4,computed_at:0,sample_count:0,curve:[]}' > "$DV_STATE/.host-capacity/cap.json"
  printf '{"cores":8,"load5":1,"memory_available_mb":8192,"disk_available_gb":100}\n' > "$CASE_DIR/resources"
  learn_time=4000
  # Fixture functions are called indirectly by loaded helpers.
  # shellcheck disable=SC2317,SC2329
  now() { printf '%s\n' "$learn_time"; }
}
learned_sample() {
  jq -cn --arg host "$DV_HOST" --argjson active "$1" --argjson load "$2" --argjson time "${3:-3000}" \
    '{host:$host,cores:8,time:$time,active:$active,load5:$load,memory_available_mb:8192}' >> "$DV_STATE/.host-capacity/samples.jsonl"
}
case_learned_percentile() {
  learned_fixture
  local load
  for load in 3 4 6 90; do learned_sample 5 "$load"; done
  for load in 5 8 9 100; do learned_sample 7 "$load"; done
  for load in 7 9 10 100; do learned_sample 8 "$load"; done
  host_capacity_record "$(cat "$CASE_DIR/resources")" 0 > "$CASE_DIR/learned"
  jq -e '.observed_cap==7 and .learned_cap==6 and .computed_at==4000 and
    any(.curve[]; .jobs==7 and .p75_load==9 and .samples==4) and
    any(.curve[]; .jobs==8 and .p75_load==10)' "$DV_STATE/.host-capacity/cap.json"
  # Restart/another tick cannot grant another +2 in the same hour.
  learn_time=7599
  host_capacity_record "$(cat "$CASE_DIR/resources")" 0 > "$CASE_DIR/learned"
  jq -e '.learned_cap==6 and .computed_at==4000' "$DV_STATE/.host-capacity/cap.json"
  learn_time=7600
  host_capacity_record "$(cat "$CASE_DIR/resources")" 0 > "$CASE_DIR/learned"
  jq -e '.learned_cap==7 and .computed_at==7600' "$DV_STATE/.host-capacity/cap.json"
  cmd_bid --json | jq -e '.learned_cap==7 and .effective_slots==7 and .max_jobs==null'
}
# Shared fixture state and intentionally unused polling counters/results.
# shellcheck disable=SC2034
case_learned_active_floor() {
  learned_fixture
  learned_sample 2 3
  jq '.load5=16' "$CASE_DIR/resources" > "$CASE_DIR/next"; mv "$CASE_DIR/next" "$CASE_DIR/resources"
  host_capacity_record "$(cat "$CASE_DIR/resources")" 9 > "$CASE_DIR/learned"
  jq -e '.observed_cap==2 and .learned_cap==9' "$DV_STATE/.host-capacity/cap.json"
  # A manual cap remains an upper bound on NEW starts, not a kill command.
  DV_MAX_JOBS=3
  bid_capacity "$(cat "$CASE_DIR/resources")" 9 | jq -e '.effective_slots==9 and .free_slots==0 and .max_jobs==3'
  DV_MAX_JOBS=''
  jq '.load5=1' "$CASE_DIR/resources" > "$CASE_DIR/next"; mv "$CASE_DIR/next" "$CASE_DIR/resources"
  # The floor retains existing work; it must not refill a cap being reduced.
  bid_capacity "$(cat "$CASE_DIR/resources")" 5 | jq -e '.learned_cap==5 and .effective_slots==5 and .free_slots==0'
  bid_capacity "$(cat "$CASE_DIR/resources")" 1 | jq -e '.learned_cap==2 and .free_slots==1'
}
case_learned_idle() {
  learned_fixture
  host_capacity_record "$(cat "$CASE_DIR/resources")" 0 > "$CASE_DIR/learned"
  # Idle samples are not evidence that the host has lost all job capacity.
  jq -e '.learned_cap==4 and .observed_cap==null' "$DV_STATE/.host-capacity/cap.json"
}
case_learned_window() {
  learned_fixture
  learn_time=100000
  learned_sample 30 1 1
  learned_sample 6 7 99990
  host_capacity_record "$(cat "$CASE_DIR/resources")" 0 > "$CASE_DIR/learned"
  jq -e '.observed_cap==6 and .learned_cap==6 and all(.curve[]; .jobs!=30)' "$DV_STATE/.host-capacity/cap.json"
  jq -se 'all(.time>=13600)' "$DV_STATE/.host-capacity/samples.jsonl"
}
case_learned_readonly() {
  learned_fixture
  cp "$DV_STATE/.host-capacity/cap.json" "$CASE_DIR/before"
  cmd_bid --json | jq -e '.learned_cap==4 and .effective_slots==4'
  cmp "$CASE_DIR/before" "$DV_STATE/.host-capacity/cap.json"
  test ! -e "$DV_STATE/.host-capacity/samples.jsonl"
  printf 'corrupt history\n' > "$DV_STATE/.host-capacity/samples.jsonl"
  if host_capacity_record "$(cat "$CASE_DIR/resources")" 0; then return 1; fi
  cmp "$CASE_DIR/before" "$DV_STATE/.host-capacity/cap.json"
  grep -Fx 'corrupt history' "$DV_STATE/.host-capacity/samples.jsonl"
}
case_learned_seeds() {
  learned_fixture
  DV_STATE="$CASE_DIR/fresh-state"
  local host cores expected resource
  for host in hx-linux amd-linux go2-linux gos-linux lina-os other; do
    case "$host" in
      hx-linux) cores=24; expected=14 ;;
      amd-linux|go2-linux) cores=16; expected=12 ;;
      gos-linux) cores=8; expected=6 ;;
      lina-os) cores=20; expected=10 ;;
      *) cores=32; expected=1 ;;
    esac
    DV_HOST=$host
    resource=$(jq --argjson cores "$cores" '.cores=$cores | .memory_available_mb=65536' "$CASE_DIR/resources")
    bid_capacity "$resource" 0 | jq -e --argjson cap "$expected" '.learned_cap==$cap and .effective_slots==$cap and .max_jobs==null'
    DV_MAX_JOBS=1 bid_capacity "$resource" 0 | jq -e '.effective_slots==1'
  done
  test ! -d "$DV_STATE"
}
case_learned_unknown_resources() {
  learned_fixture
  local resources
  resources=$(jq '.load5=null' "$CASE_DIR/resources")
  if (bid_capacity "$resources" 0) > "$CASE_DIR/unknown" 2>&1; then
    cat "$CASE_DIR/unknown"; return 1
  fi
}
