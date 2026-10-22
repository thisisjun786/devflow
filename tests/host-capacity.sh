#!/usr/bin/env bash
capacity_fixture() {
  repo capacity
  bidding_functions
  export DV_MAX_JOBS=6 DV_TARGET_LOAD=1.2 DV_MIN_MEMORY_MB=1024
  export DV_AGENT_READY_codex=true DV_AGENT_CMD_codex='' DV_CODEX_MODE=exec
  printf '{"cores":8,"load5":16,"memory_available_mb":8192,"disk_available_gb":100}\n' > "$CASE_DIR/resources"
  bid_resources() { cat "$CASE_DIR/resources"; }
  jq -cn --arg host "$DV_HOST" '{version:1,host:$host,cores:8,learned_cap:6,computed_at:0,sample_count:0,curve:[]}' > "$DV_STATE/.host-capacity/cap.json"
}
case_capacity_load() {
  capacity_fixture
  cmd_bid --json > "$CASE_DIR/bid.json"
  cat "$CASE_DIR/bid.json"
  jq -e '.status=="rejected" and .free_slots==0 and .effective_slots==0 and .max_jobs==6' "$CASE_DIR/bid.json"
  jq '.load5=0' "$CASE_DIR/resources" > "$CASE_DIR/next"; mv "$CASE_DIR/next" "$CASE_DIR/resources"
  cmd_bid --json | jq -e '.status=="submitted" and .effective_slots==6 and .free_slots==6'
}
case_capacity_memory() {
  capacity_fixture
  jq '.load5=0 | .memory_available_mb=2048' "$CASE_DIR/resources" > "$CASE_DIR/next"; mv "$CASE_DIR/next" "$CASE_DIR/resources"
  cmd_bid --json | jq -e '.effective_slots==2 and .free_slots==2'
  jq '.memory_available_mb=512' "$CASE_DIR/resources" > "$CASE_DIR/next"; mv "$CASE_DIR/next" "$CASE_DIR/resources"
  cmd_bid --json | jq -e '.effective_slots==0 and .reason=="low memory" and (.score|type)=="number"'
}
case_capacity_award() {
  capacity_fixture
  local request
  request=$(jq -cn --arg repo "$REPO" --argjson deadline "$(( $(date +%s) + 30 ))" \
    '{issue:"CAP-1",repo:$repo,slug:"capacity",agent:"codex",mode:"exec",base:"main",brief:"synthetic",token:"cap",deadline:$deadline}')
  cmd__award <<< "$request" | jq -e '.status=="rejected" and .free_slots==0'
  test ! -d "$DV_STATE/CAP-1"
}
case_capacity_start() {
  capacity_fixture
  local rc=0
  (cmd_start "$REPO" CAP-2 capacity --mode exec --brief "$CASE_DIR/brief") > "$CASE_DIR/start.log" 2>&1 || rc=$?
  cat "$CASE_DIR/start.log"
  test "$rc" != 0
  test ! -d "$DV_STATE/CAP-2"
}
case_capacity_headroom() {
  capacity_fixture
  mkdir -p "$DV_STATE/RUNNING-1" "$DV_STATE/RUNNING-2"
  printf '{"status":"running"}\n' > "$DV_STATE/RUNNING-1/meta"
  printf '{"status":"running"}\n' > "$DV_STATE/RUNNING-2/meta"
  jq '.load5=4.1' "$CASE_DIR/resources" > "$CASE_DIR/next"; mv "$CASE_DIR/next" "$CASE_DIR/resources"
  cmd_bid --json | jq -e '.active==2 and .learned_cap==6 and .effective_slots==6 and .free_slots==4'
  jq '.load5=7' "$CASE_DIR/resources" > "$CASE_DIR/next"; mv "$CASE_DIR/next" "$CASE_DIR/resources"
  cmd_bid --json | jq -e '.active==2 and .effective_slots==6 and .free_slots==4'
  jq '.load5=16' "$CASE_DIR/resources" > "$CASE_DIR/next"; mv "$CASE_DIR/next" "$CASE_DIR/resources"
  cmd_bid --json | jq -e '.active==2 and .effective_slots==2 and .free_slots==0'
  test -f "$DV_STATE/RUNNING-1/meta"
  test -f "$DV_STATE/RUNNING-2/meta"
}
case_capacity_task() {
  capacity_fixture; task_setup
  DV_AGENT_CMD_codex=''
  DV_TRUSTED_REPOS="$CASE_DIR/Desk project"
  # shellcheck source=lib/task.sh
  source "$ROOT/lib/task.sh"
  local rc=0
  (task_submit "$CASE_DIR/Desk project" CAP-3 capacity --brief "$CASE_DIR/task-brief") > "$CASE_DIR/task.log" 2>&1 || rc=$?
  cat "$CASE_DIR/task.log"
  test "$rc" != 0
  grep -F 'host has no free task slots' "$CASE_DIR/task.log"
  test ! -d "$DV_STATE/CAP-3"
}
case_capacity_launch_reservation() {
  capacity_fixture
  jq '.load5=0' "$CASE_DIR/resources" > "$CASE_DIR/next"; mv "$CASE_DIR/next" "$CASE_DIR/resources"
  DV_MAX_JOBS=1
  launch_agent() {
    # No agent PID exists yet. A competing start must still fail to acquire
    # admission until this launcher publishes its process or returns failure.
    bash -c '
      DV_ENTRY="$ROOT/bin/dv"
      source "$ROOT/lib/common.sh"
      sleep() { :; }
      if owned_lock "$DV_STATE/.admission-lock" "$$"; then
        owned_unlock "$DV_STATE/.admission-lock" "$$"
        printf "another start entered before launch completed\n" >&2
        exit 1
      fi
    '
  }
  (cmd_start "$REPO" CAP-4 reservation --mode exec --brief "$CASE_DIR/brief")
  test ! -d "$DV_STATE/.admission-lock"
}
