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
  needs_tmux; repo retry
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
  export DV_MANAGER_HOST="$DV_HOST"
  git init -q --bare "$CASE_DIR/local.git"
  git -C "$REPO" remote add origin "$CASE_DIR/local.git"
  dv submit "$REPO" LOCAL-1 edge --brief "$CASE_DIR/brief"
  jq -e --arg repo "$REPO" '.repo==$repo' "$DV_HOME/submissions/LOCAL-1/task.json"
  git -C "$REPO" remote set-url origin file://"$CASE_DIR/local.git"
  dv submit "$REPO" LOCAL-2 edge --brief "$CASE_DIR/brief"
  jq -e --arg repo "$REPO" '.repo==$repo' "$DV_HOME/submissions/LOCAL-2/task.json"
  git -C "$REPO" remote set-url origin https://github.com/test/repo.git
  dv submit "$REPO" URL-1 edge --brief "$CASE_DIR/brief"
  jq -e '.repo=="https://github.com/test/repo.git"' "$DV_HOME/submissions/URL-1/task.json"
}
