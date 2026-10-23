#!/usr/bin/env bash
# Sourced by run.sh; all hosts and agents are disposable fixtures.
# DV_HOST is initialized by run.sh setup.
# shellcheck disable=SC2016,SC2153
case_reconcile_alias() {
  export DV_WORKER_CMD="$ROOT/tests/fixtures/worker" DV_WATCH_INTERVAL=0.1 DV_RECONCILE_INTERVAL=1 DV_HOSTS=ssh-alias
  printf '[{"issue":"ALIAS-1","status":"done","head":"abc","host":"real-host","done_at":1}]\n' > "$CASE_DIR/remote-status"
  dv-kick 'done' ALIAS-1 original real-host abc
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_file "$DV_HOME/cursor"
  touch "$DV_HOME/stop"; wait "$watcher"
  jq -se 'length==1 and .[0].id=="real-host:ALIAS-1:done:abc"' "$DV_HOME/kick.q"
  test "$(find "$DV_HOME/workers" -name '*.finished' | wc -l | tr -d ' ')" = 1
  # Recovery must use the same identity even when no direct event arrived.
  rm "$DV_HOME/stop"
  printf '[{"issue":"ALIAS-2","status":"done","head":"def","host":"real-host","award_token":"round-2"}]\n' > "$CASE_DIR/remote-status"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  for _ in {1..100}; do
    [ "$(cat "$DV_HOME/cursor")" = 2 ] && break
    sleep 0.1
  done
  touch "$DV_HOME/stop"; wait "$watcher"
  dv-kick 'done' ALIAS-2 original real-host def '' round-2
  jq -se 'length==3 and .[1].id==.[2].id and .[1].host=="real-host" and .[1].token=="round-2"' "$DV_HOME/kick.q"
}
edge_request() {
  jq -cn --arg issue "$1" --arg token "$2" --arg repo "$REPO" --argjson deadline "$(( $(date +%s) + 10 ))" \
    '{issue:$issue,repo:$repo,slug:"edge",agent:"codex",mode:"goal",base:"",brief:"fake",token:$token,deadline:$deadline}'
}
case_award_retry_rejection() {
  needs_tmux; repo retry; failed_start_fixture
  export DV_MAX_JOBS=1
  edge_request RETRY-1 first | DV_AGENT_CMD_codex=false dv _award > "$CASE_DIR/first"
  jq -e '.status=="failed"' "$CASE_DIR/first"
  jq -se 'length>0 and all(.[]; .token=="first")' "$DV_STATE/RETRY-1/events.log"
  local awards="$DV_STATE/.awards/RETRY-1" reason
  cp "$awards/receipt.json" "$CASE_DIR/receipt.before"
  cp "$DV_STATE/RETRY-1/meta" "$CASE_DIR/meta.before"
  mkdir "$DV_STATE/OCCUPIED"
  printf '{"status":"running"}\n' > "$DV_STATE/OCCUPIED/meta"
  for reason in full unavailable; do
    if [ "$reason" = full ]; then
      edge_request RETRY-1 second | dv _award > "$CASE_DIR/rejected"
    else
      printf '0\n' > "$DV_STATE/OCCUPIED/agent.exit"
      edge_request RETRY-1 second | DV_AGENT_CMD_codex='' DV_CODEX_BIN=false dv _award > "$CASE_DIR/rejected"
    fi
    jq -e '.status=="rejected"' "$CASE_DIR/rejected"
    cmp "$CASE_DIR/receipt.before" "$awards/receipt.json"
    cmp "$CASE_DIR/meta.before" "$DV_STATE/RETRY-1/meta"
    dv _receipt RETRY-1 first | jq -e '.status=="failed" and .token=="first"'
    test "$(find "$awards" -name receipt.json | wc -l | tr -d ' ')" = 1
  done
  edge_request RETRY-1 third | DV_AGENT_CMD_codex='exec sleep 30' dv _award > "$CASE_DIR/accepted"
  jq -e '.status=="working" and .token=="third"' "$CASE_DIR/accepted"
  jq -e '.award_token=="third"' "$DV_STATE/RETRY-1/meta"
  dv kick question RETRY-1 'manual command outside agent environment'
  jq -se '.[-1].token=="third"' "$DV_STATE/RETRY-1/events.log"
  DV_AWARD_TOKEN=first dv kick failed RETRY-1 'delayed old wrapper'
  jq -se '.[-1].token=="first"' "$DV_STATE/RETRY-1/events.log"
  dv _receipt RETRY-1 first | jq -e '.status=="failed" and .token=="first"'
  test "$(find "$awards" -name receipt.json | wc -l | tr -d ' ')" = 2
}
case_award_stale_failure() {
  repo stale; bidding_functions
  export DV_MANAGER_HOST="$DV_HOST" DV_HOSTS=''
  dv submit "$REPO" STALE-1 edge --brief "$CASE_DIR/brief"
  local dir="$DV_HOME/submissions/STALE-1" old current
  bid_task_set "$dir" '.status="working"|.host="ssh-alias"|.token="new"'
  mkdir -p "$DV_STATE/.awards/STALE-1" "$DV_STATE/STALE-1"
  printf '{"token":"new","status":"working"}\n' > "$DV_STATE/.awards/STALE-1/receipt.json"
  printf '0\n' > "$DV_STATE/STALE-1/agent.exit"
  # shellcheck disable=SC2329
  bid_rpc() { shift; "cmd_$1" "${@:2}"; }
  old=$(event_json failed STALE-1 'old failure' ssh-alias h '' old)
  current=$(event_json failed STALE-1 'new failure' ssh-alias h '' new)
  bid_event "$old"
  jq -e '.status=="working" and .token=="new"' "$dir/task.json"
  test "$(printf '%s\n' "$old" | jq -r .id)" != "$(printf '%s\n' "$current" | jq -r .id)"
  # Unscoped legacy failures cannot prove that this attempt failed either.
  bid_event "$(event_json failed STALE-1 legacy ssh-alias h)"
  jq -e '.status=="working"' "$dir/task.json"
  bid_event "$(event_json failed STALE-1 'new failure' real-host h '' new)"
  jq -e '.status=="failed"' "$dir/task.json"
}
case_award_early_absent() {
  repo absent; bidding_functions
  export DV_MANAGER_HOST="$DV_HOST" DV_HOSTS=missing-host
  dv submit "$REPO" ABSENT-1 edge --brief "$CASE_DIR/brief"
  local dir="$DV_HOME/submissions/ABSENT-1"
  # First RPC loses the request entirely; the receipt reports absent before expiry.
  # shellcheck disable=SC2329
  bid_rpc() {
    case "$2" in
      bid) printf '{"status":"submitted","score":100}\n' ;;
      _award) printf '%s\n' "$1" >> "$CASE_DIR/awards"; return 255 ;;
      _receipt) cat "$CASE_DIR/receipt" ;;
    esac
  }
  printf '{"status":"absent"}\n' > "$CASE_DIR/receipt"
  DV_AWARD_TIMEOUT=60 bid_event "$(event_json submitted ABSENT-1 '' "$DV_HOST" '')"
  jq -e '.status=="submitted" and .host=="missing-host"' "$dir/task.json"
  bid_event "$(event_json 'done' OTHER-1 '' elsewhere h)"
  test "$(wc -l < "$CASE_DIR/awards" | tr -d ' ')" = 1
  # A later delivery that did start must be recovered before another award.
  jq '{token,status:"working"}' "$dir/task.json" > "$CASE_DIR/receipt"
  bid_event "$(event_json 'done' OTHER-2 '' elsewhere h)"
  jq -e '.status=="working" and .host=="missing-host"' "$dir/task.json"
  test "$(wc -l < "$CASE_DIR/awards" | tr -d ' ')" = 1
  # If it stayed absent past the deadline, a new event can safely rebid.
  bid_task_set "$dir" '.status="submitted"|.deadline=1'
  printf '{"status":"absent"}\n' > "$CASE_DIR/receipt"
  bid_event "$(event_json 'done' OTHER-3 '' elsewhere h)"
  test "$(wc -l < "$CASE_DIR/awards" | tr -d ' ')" = 2
  jq -e '.status=="submitted" and .host=="missing-host" and .deadline>1' "$dir/task.json"
}
case_bid_clean_capacity() {
  needs_tmux; repo clean-slot
  export DV_MAX_JOBS=1 DV_AGENT_CMD_codex='exec sleep 30'
  start CLEAN-1
  dv bid --json --repo "$REPO" | jq -e '.active==1 and .free_slots==0'
  local worktree
  worktree=$(jq -r .worktree "$DV_STATE/CLEAN-1/meta")
  printf 'keep\n' > "$worktree/dirty"
  if dv clean CLEAN-1; then return 1; fi
  dv bid --json --repo "$REPO" | jq -e '.active==1 and .free_slots==0'
  rm "$worktree/dirty"
  dv clean CLEAN-1
  test ! -e "$worktree"
  test ! -f "$DV_STATE/CLEAN-1/agent.exit"
  test ! -f "$DV_STATE/CLEAN-1/done.json"
  dv bid --json --repo "$REPO" | jq -e '.active==0 and .free_slots==1'
}
case_submit_local_origin() {
  repo local-origin
  local root
  root=$(cd "$REPO" && pwd -P)
  export DV_MANAGER_HOST="$DV_HOST"
  git init -q --bare "$CASE_DIR/local.git"
  git -C "$REPO" remote add origin "$CASE_DIR/local.git"
  dv submit "$REPO" LOCAL-1 edge --brief "$CASE_DIR/brief"
  jq -e --arg repo "$root" '.repo==$repo' "$DV_HOME/submissions/LOCAL-1/task.json"
  git -C "$REPO" remote set-url origin file://"$CASE_DIR/local.git"
  dv submit "$REPO" LOCAL-2 edge --brief "$CASE_DIR/brief"
  jq -e --arg repo "$root" '.repo==$repo' "$DV_HOME/submissions/LOCAL-2/task.json"
  git -C "$REPO" remote set-url origin https://github.com/test/repo.git
  dv submit "$REPO" URL-1 edge --brief "$CASE_DIR/brief"
  jq -e '.repo=="https://github.com/test/repo.git"' "$DV_HOME/submissions/URL-1/task.json"
}

# Map only the example's fixed /scratch path into this case's disposable tree.
config_work_value() (
  sed "s@/scratch@$CASE_DIR/scratch@g" "$ROOT/config.example.sh" > "$CASE_DIR/example.sh"
  unset DV_WORK
  # shellcheck source=/dev/null
  source "$CASE_DIR/example.sh"
  printf '%s\n' "$DV_WORK"
)
case_config_work_fallback() {
  mkdir "$CASE_DIR/scratch"
  chmod 555 "$CASE_DIR/scratch"
  local actual
  actual=$(config_work_value)
  chmod 755 "$CASE_DIR/scratch"
  printf 'selected=%s\n' "$actual"
  test "$actual" = "$HOME/dv/wt"
}
case_config_work_existing() {
  test "$(config_work_value)" = "$HOME/dv/wt"
  mkdir "$CASE_DIR/scratch"
  test "$(config_work_value)" = "$CASE_DIR/scratch/dv-wt"
  mkdir "$CASE_DIR/scratch/dv-wt"
  chmod 555 "$CASE_DIR/scratch"
  local actual
  actual=$(config_work_value)
  chmod 755 "$CASE_DIR/scratch"
  test "$actual" = "$CASE_DIR/scratch/dv-wt"
  # Explicit configuration must survive the default selection.
  ( source "$CASE_DIR/example.sh"; test "$DV_WORK" = "$CASE_DIR/work" )
}
work_bid_setup() {
  repo writable; bidding_functions
  # shellcheck source=lib/disk.sh
  source "$ROOT/lib/disk.sh"
  export DV_MAX_JOBS=8 DV_CODEX_MODE=exec DV_AGENT_CMD_codex=''
  work_bid_probes
}
work_bid_probes() {
  # No auth, resource probes or terminal required for these synthetic bids.
  WORK_BID_CORES=16
  seed_host_capacity "$WORK_BID_CORES"
  bid_agent() { return 0; }
  bid_resources() {
    printf '{"cores":%s,"load5":%s,"memory_available_mb":65536,"disk_available_gb":100,"go_cache_path":null,"cache_disk_available_gb":null}\n' "$WORK_BID_CORES" "${WORK_BID_LOAD:-0}"
  }
}
case_bid_work_unwritable() {
  work_bid_setup
  chmod 555 "$DV_WORK"
  cmd_bid --json --repo "$REPO" > "$CASE_DIR/bid.json"
  chmod 755 "$DV_WORK"
  cat "$CASE_DIR/bid.json"
  jq -e '.status=="rejected" and .reason=="worktree dir not writable"' "$CASE_DIR/bid.json"
}
case_bid_work_paths() {
  work_bid_setup
  local path
  mkdir "$CASE_DIR/locked"
  chmod 555 "$CASE_DIR/locked"
  touch "$CASE_DIR/file"
  ln -s "$CASE_DIR/missing" "$CASE_DIR/dangling"
  for path in "$CASE_DIR/locked/new/deep" "$CASE_DIR/file" "$CASE_DIR/file/child" "$CASE_DIR/dangling" "$CASE_DIR/dangling/child"; do
    DV_WORK="$path" cmd_bid --json --repo "$REPO" > "$CASE_DIR/bid.json"
    cat "$CASE_DIR/bid.json"
    jq -e '.status=="rejected" and .reason=="worktree dir not writable"' "$CASE_DIR/bid.json"
  done
  chmod 755 "$CASE_DIR/locked"
  # Existing directories need search permission as well as write permission.
  chmod 666 "$DV_WORK"
  cmd_bid --json --repo "$REPO" > "$CASE_DIR/bid.json"
  chmod 755 "$DV_WORK"
  jq -e '.status=="rejected" and .reason=="worktree dir not writable"' "$CASE_DIR/bid.json"
  ln -s "$DV_WORK" "$CASE_DIR/link"
  for path in "$DV_WORK" "$CASE_DIR/new parent/nested" "$CASE_DIR/link/nested"; do
    DV_WORK="$path" cmd_bid --json --repo "$REPO" | jq -e '.status=="submitted"'
  done
  test ! -e "$CASE_DIR/new parent"
  test ! -e "$DV_WORK/nested"
}
case_bid_overload() {
  work_bid_setup
  export DV_HOSTS='hx-linux amd-linux'
  bidding_order_setup
  work_bid_probes
  WORK_BID_LOAD=38 DV_MAX_JOBS=8 cmd_bid --json --repo "$REPO" > "$CASE_DIR/hosts/amd-linux/bid.json"
  mkdir "$DV_STATE/BUSY"
  printf '{"status":"running"}\n' > "$DV_STATE/BUSY/meta"
  WORK_BID_LOAD=0 DV_MAX_JOBS=2 cmd_bid --json --repo "$REPO" > "$CASE_DIR/hosts/hx-linux/bid.json"
  jq -s '.' "$CASE_DIR/hosts/amd-linux/bid.json" "$CASE_DIR/hosts/hx-linux/bid.json"
  bidding_order_run LOAD
  jq -e '.host=="hx-linux" and .status=="working"' "$DV_HOME/submissions/LOAD/task.json"
}
case_award_error_detail() {
  work_bid_setup
  mkdir -p "$CASE_DIR/launcher/bin"
  cat > "$CASE_DIR/launcher/bin/dv" <<'LAUNCHER'
#!/usr/bin/env bash
case "$1" in
  start)
    printf 'startup progress on stdout\n'
    printf '\nPreparing worktree (new branch)\nmkdir: synthetic "Permission denied"\nsecond error\n' >&2
    exit 1 ;;
  *) exec "$ROOT/bin/dv" "$@" ;;
esac
LAUNCHER
  chmod +x "$CASE_DIR/launcher/bin/dv"
  DV_ROOT="$CASE_DIR/launcher" cmd__award < <(edge_request DETAIL first) > "$CASE_DIR/receipt"
  jq -e '.status=="failed" and .token=="first"' "$CASE_DIR/receipt"
  cat "$DV_STATE/DETAIL/events.log"
  jq -se 'any(.[]; .kind=="failed" and .token=="first" and (.message|contains("mkdir: synthetic \"Permission denied\"")) and (.message|contains("second error")|not) and (.message|contains("startup progress")|not))' "$DV_STATE/DETAIL/events.log"
}
