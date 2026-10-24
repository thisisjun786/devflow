#!/usr/bin/env bash
# Sourced by run.sh: synthetic status and herdr fixtures, no live agents.
# ROOT and DV_HOST come from the driver.
# shellcheck disable=SC2153,SC2154,SC2016
stall_omp_fixture() {
  export DV_OMP_RESTART_GAP=0 DV_OMP_RESTART_SETTLE=0
  stall_fixture; stall_functions
  git -C "$REPO" checkout -qb fix/st-1
  jq '.agent="omp" | .branch="fix/st-1" | .head=.start_head' "$DV_STATE/ST-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/ST-1/meta"
  cp "$CASE_DIR/brief" "$DV_STATE/ST-1/brief.md"
  printf 'report to preserve\n' > "$DV_STATE/ST-1/report.md"
  printf 'π > \n' > "$CASE_DIR/herdr/w-ST-1/output"
  touch -t 202001010000 "$DV_STATE/ST-1/agent.launched"
  OMP_DIR=$(agent_transcript_dir omp "$(cd "$REPO" && pwd -P)")
  mkdir -p "$OMP_DIR"
  OMP_LOG="$OMP_DIR/session.jsonl"
  stall_omp_message turn-1
}
stall_omp_message() {
  jq -cn --arg id "$1" --argjson content "${2:-null}" \
    '{type:"message",id:$id,message:{role:"assistant",stopReason:"stop",content:($content //
      [{type:"text",text:"[tool_use id=call_1 name=_bash]\n{\"command\":\"pwd\"}"}])}}' >> "$OMP_LOG"
}
stall_omp_scan() {
  stall_reconcile "$DV_HOST" "$(dv status ST-1 --json)" 60
}
stall_omp_count() {
  jq -se --argjson n "$1" '[.[]|select(.[0:2]==["agent","prompt"])]|length==$n' "$CASE_DIR/herdr/calls"
}
stall_omp_prompts() {
  jq -Rse --arg pattern "$STALL_OMP_TEXT_TOOL" '
    . as $input | (test($pattern) | not) and
    all(["[tool_use", "tool_use", "<invoke", "<function_calls>", "<tool_call>", "antml", " _"][];
      . as $forbidden | $input | contains($forbidden) | not)' "$DV_STATE/ST-1/sent-input"
  jq -se '[.[]|select(.[0:2]==["agent","prompt"])|.[3]] |
    length>0 and length%2==0' "$CASE_DIR/herdr/calls" >/dev/null
  jq -se --arg state "$DV_STATE/ST-1" --arg wt "$REPO" '
    [.[]|select(.[0:2]==["agent","prompt"])] as $calls |
    all(range(0;$calls|length;2); . as $i |
      $calls[$i][2:]==["w-ST-1:p1","/new"] and
      ($calls[$i+1][3:] | join("\n") | contains("ST-1") and contains($state+"/brief.md") and
        contains($state+"/report.md") and contains($wt) and contains("fix/st-1") and
        contains("base main") and contains("The previous session ended without running its last step.") and
        contains("transcripts") and contains("dv done ST-1")))' "$CASE_DIR/herdr/calls"
}
stall_omp_origin() {
  git init -q --bare "$CASE_DIR/remote.git"
  git -C "$REPO" config url."$CASE_DIR/remote.git".insteadOf https://github.com/test/repo.git
  git -C "$REPO" remote add origin https://github.com/test/repo.git
  git -C "$REPO" push -qu origin main fix/st-1
}
case_stall_omp_restart() {
  stall_omp_fixture
  stall_omp_scan; stall_omp_count 2
  stall_omp_prompts
}
case_stall_omp_once() {
  stall_omp_fixture
  stall_omp_scan; stall_omp_count 2
  stall_omp_scan
  # A separate command and later PR transition cannot repeat the same turn.
  dv _stall-recover ST-1 --omp-texttool round-1
  jq '.status="pr"' "$DV_STATE/ST-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/ST-1/meta"
  stall_omp_scan; stall_omp_count 2
  stall_omp_message turn-2
  stall_omp_scan; stall_omp_count 4
  stall_omp_message turn-1
  stall_omp_scan; stall_omp_count 4
  stall_omp_prompts
  jq -e 'length==2' "$DV_STATE/ST-1/omp-restarts.json"
  jq -e '.agent=="omp" and .branch=="fix/st-1" and .escalated_from==null' "$DV_STATE/ST-1/meta"
  jq -se 'all(.[]; .[0:2]!=["pane","run"] and .[0:2]!=["pane","send-keys"] and .[0:2]!=["workspace","close"])' "$CASE_DIR/herdr/calls"
  test ! -e "$DV_STATE/ST-1/revive"
  test ! -f "$DV_STATE/ST-1/stall-recovery.json"
  test ! -s "$DV_HOME/kick.q"
  grep -F 'The previous session ended without running its last step.' "$DV_STATE/ST-1/sent-input"
}
case_stall_omp_patterns() {
  stall_omp_fixture
  local marker content n=0
  for marker in '<invoke' '<function_calls>' '<tool_call>' '[tool_use'; do
    content=$(jq -cn --arg text "$marker" '[{type:"text",text:$text}]')
    stall_omp_message "pattern-$n" "$content"
    n=$((n + 1))
    stall_omp_scan; stall_omp_count "$((n * 2))"
  done
  stall_omp_prompts
}
case_stall_omp_forms() {
  stall_omp_fixture
  local form count=0 content
  for form in '[tool_use id=x name=_bash]
{"command":"pwd"}' '<tool_use id="x" name="_read">{"path":"README.md"}</tool_use>' \
    '<function_calls><invoke name="_edit"><parameter name="path">a</parameter></invoke></function_calls>' \
    '<antml:function_calls><antml:invoke name="_bash"><antml:parameter name="command">pwd</antml:parameter></antml:invoke></antml:function_calls>' \
    '<tool_call>{"name":"_bash","arguments":{"command":"pwd"}}</tool_call>'; do
    count=$((count + 1))
    content=$(jq -cn --arg text "$form" '[{type:"text",text:$text}]')
    stall_omp_message "form-$count" "$content"
    stall_omp_scan; stall_omp_count "$((count * 2))"
  done
  stall_omp_prompts
}
case_stall_omp_wip() {
  stall_omp_fixture; stall_omp_origin
  printf 'staged\n' > "$REPO/staged"
  git -C "$REPO" add staged
  printf 'unstaged\n' >> "$REPO/staged"
  printf 'untracked\n' > "$REPO/untracked"
  stall_omp_scan; stall_omp_count 2
  test "$(git -C "$REPO" log -1 --format=%s)" = 'wip: save work before restarting the omp session'
  test -z "$(git -C "$REPO" status --porcelain)"
  test "$(git -C "$CASE_DIR/remote.git" rev-parse refs/heads/fix/st-1)" = "$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" show HEAD:staged | grep -Fx unstaged
  git -C "$REPO" show HEAD:untracked | grep -Fx untracked
  grep -F 'wip: save work before restarting the omp session' "$DV_STATE/ST-1/sent-input"
  grep -F 'dv pr ST-1' "$DV_STATE/ST-1/sent-input"
  grep -F 'dv pr-wait ST-1 --foreground' "$DV_STATE/ST-1/sent-input"
  grep -F 'wip=committed' "$DV_HOME/omp-restarts.log" | grep -F 'pushed=yes'
  stall_omp_prompts
  # A clean restart still pushes existing branch commits, without a new WIP.
  local head
  head=$(git -C "$REPO" rev-parse HEAD)
  stall_omp_message clean
  stall_omp_scan; stall_omp_count 4
  test "$(git -C "$REPO" rev-parse HEAD)" = "$head"
  test "$(git -C "$REPO" symbolic-ref --short HEAD)" = fix/st-1
}
case_stall_omp_pr() {
  stall_omp_fixture; stall_omp_origin
  local remote_head
  remote_head=$(git -C "$CASE_DIR/remote.git" rev-parse refs/heads/fix/st-1)
  jq '.status="pr"' "$DV_STATE/ST-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/ST-1/meta"
  # A waiter and an already-used revive budget do not suppress this fault.
  mkdir "$DV_STATE/ST-1/.pr-wait" "$DV_STATE/ST-1/revive"
  touch "$DV_STATE/ST-1/.pr-wait/pid-$$"
  printf 'previous-revive\n' > "$DV_STATE/ST-1/revive/id"
  printf '{"rounds":2,"requests":{"old":{"retried":true}}}\n' > "$DV_STATE/ST-1/pr-loop.json"
  cp "$DV_STATE/ST-1/pr-loop.json" "$CASE_DIR/pr-loop"
  printf 'unfinished\n' > "$REPO/wip"
  stall_omp_scan; stall_omp_count 2
  stall_omp_scan; stall_omp_count 2
  test -z "$(git -C "$REPO" status --porcelain)"
  test "$(git -C "$CASE_DIR/remote.git" rev-parse refs/heads/fix/st-1)" = "$remote_head"
  cmp "$CASE_DIR/pr-loop" "$DV_STATE/ST-1/pr-loop.json"
  grep -Fx previous-revive "$DV_STATE/ST-1/revive/id"
  grep -Fx 'report to preserve' "$DV_STATE/ST-1/report.md"
  grep -F 'job status pr' "$DV_STATE/ST-1/sent-input"
  grep -F 'pr-loop.json' "$DV_STATE/ST-1/sent-input"
  grep -F 'pushed=pr' "$DV_HOME/omp-restarts.log"
}
case_stall_omp_unmerged() {
  stall_omp_fixture
  git -C "$REPO" checkout -qb other main
  printf 'other\n' > "$REPO/base"
  git -C "$REPO" commit -qam other
  git -C "$REPO" checkout -q fix/st-1
  printf 'ours\n' > "$REPO/base"
  git -C "$REPO" commit -qam ours
  if git -C "$REPO" merge other; then return 1; fi
  local head
  head=$(git -C "$REPO" rev-parse HEAD)
  git -C "$REPO" ls-files -u > "$CASE_DIR/unmerged"
  stall_omp_scan; stall_omp_count 2
  test "$(git -C "$REPO" rev-parse HEAD)" = "$head"
  git -C "$REPO" ls-files -u > "$CASE_DIR/unmerged-after"
  cmp "$CASE_DIR/unmerged" "$CASE_DIR/unmerged-after"
  grep -F 'UU base' "$DV_STATE/ST-1/sent-input"
  grep -F 'unresolved' "$DV_STATE/ST-1/sent-input"
  grep -F 'wip=unmerged' "$DV_HOME/omp-restarts.log"
}
case_stall_omp_negative() {
  stall_omp_fixture
  local marker content
  for marker in '[tool_use id=x]' '<invoke name="bash">' '<function_calls>' '<tool_call>'; do
    content=$(jq -cn --arg text "$marker" '[{type:"text",text:$text},{type:"toolCall",id:"x",name:"bash",arguments:{}}]')
    stall_omp_message real "$content"
    stall_omp_scan; stall_omp_count 0
    content=$(jq -cn --arg text "$marker" '[{type:"thinking",thinking:$text,text:$text}]')
    stall_omp_message thinking "$content"
    stall_omp_scan; stall_omp_count 0
  done
  stall_omp_message final '[{"type":"text","text":"Finished the requested work."}]'
  stall_omp_scan; stall_omp_count 0
  local role
  for role in user tool toolResult; do
    stall_omp_message superseded
    jq -cn --arg role "$role" '{type:"message",id:"later",message:{role:$role,content:[]}}' >> "$OMP_LOG"
    stall_omp_scan; stall_omp_count 0
  done
  stall_omp_message partial
  printf '{"type":"message"' >> "$OMP_LOG"
  stall_omp_scan; stall_omp_count 0
  printf '\n' >> "$OMP_LOG"
  stall_omp_message recovered
  stall_omp_scan; stall_omp_count 2
}
case_stall_omp_guards() {
  stall_omp_fixture
  local status change
  for status in working blocked unknown 'done'; do
    printf '%s\n' "$status" > "$CASE_DIR/herdr/w-ST-1/status"
    stall_omp_scan
    dv _stall-recover ST-1 --omp-texttool round-1
  done
  printf 'idle\n' > "$CASE_DIR/herdr/w-ST-1/status"
  dv _stall-recover ST-1 --omp-texttool stale-token
  cp "$DV_STATE/ST-1/meta" "$CASE_DIR/original-meta"
  for change in '.status="done"' '.done_at=1' '.cleaned_at=1' '.agent="codex"' '.capacity={}' '.escalated_from="omp"'; do
    jq "$change" "$CASE_DIR/original-meta" > "$DV_STATE/ST-1/meta"
    stall_omp_scan
    dv _stall-recover ST-1 --omp-texttool round-1
  done
  cp "$CASE_DIR/original-meta" "$DV_STATE/ST-1/meta"
  touch "$DV_STATE/ST-1/texttool-skip"
  stall_omp_scan; stall_omp_count 0
  rm "$DV_STATE/ST-1/texttool-skip"
  cmd_status() { dv status ST-1 --json | jq 'map(.question_pending=true)'; }
  cmd__stall_recover ST-1 --omp-texttool round-1
  stall_omp_count 0
  test ! -e "$DV_STATE/ST-1/omp-restarts.json"
  stall_omp_scan; stall_omp_count 2
}
case_stall_omp_session() {
  stall_omp_fixture
  touch -t 201901010000 "$OMP_LOG"
  stall_omp_scan; stall_omp_count 0
  touch -t 202101010000 "$OMP_LOG"
  OMP_LOG="$OMP_DIR/new-session.jsonl"
  stall_omp_message final '[{"type":"text","text":"Done"}]'
  stall_omp_scan; stall_omp_count 0
  stall_omp_message turn-1
  stall_omp_scan; stall_omp_count 2
  # Identical message IDs in distinct sessions are distinct turns.
  touch -t 202201010000 "$OMP_LOG"
  OMP_LOG="$OMP_DIR/session.jsonl"
  touch "$OMP_LOG"
  stall_omp_scan; stall_omp_count 4
}
case_stall_omp_transport() {
  stall_omp_fixture
  printf 'agent prompt\n' > "$CASE_DIR/herdr/fail"
  stall_omp_scan; stall_omp_count 1
  rm "$CASE_DIR/herdr/fail"
  stall_omp_scan; stall_omp_count 1
  test ! -f "$DV_STATE/ST-1/sent-input"
  grep -F 'rc=1 today=1' "$DV_HOME/omp-restarts.log"
  stall_omp_message next
  # Fail the second prompt after delivering /new; neither may be retried.
  STALL_TIME=$(date +%s)
  send_text() {
    jq -e --arg turn "$(stall_omp_turn)" 'has($turn)' "$S/omp-restarts.json" >/dev/null || return 1
    herdr_send_text "$1" || return
    if [ "$1" = /new ]; then printf 'agent prompt\n' > "$CASE_DIR/herdr/fail"; fi
  }
  if cmd__stall_recover ST-1 --omp-texttool round-1; then return 1; fi
  stall_omp_count 3
  rm "$CASE_DIR/herdr/fail"
  dv _stall-recover ST-1 --omp-texttool round-1
  stall_omp_count 3
  test "$(wc -l < "$DV_HOME/omp-restarts.log" | tr -d ' ')" = 2
}
case_stall_omp_gap() {
  stall_omp_fixture
  DV_OMP_RESTART_GAP=180
  cmd__stall_recover ST-1 --omp-texttool round-1; stall_omp_count 2
  stall_omp_message next
  STALL_TIME=1179
  cmd__stall_recover ST-1 --omp-texttool round-1; stall_omp_count 2
  jq -e 'length==1' "$DV_STATE/ST-1/omp-restarts.json"
  STALL_TIME=1180
  cmd__stall_recover ST-1 --omp-texttool round-1; stall_omp_count 4
  # A new launch does not reset the per-job spacing.
  printf 'next-launch\n' > "$DV_STATE/ST-1/agent.launched"
  touch -t 202001010000 "$DV_STATE/ST-1/agent.launched"
  stall_omp_message next-launch
  cmd__stall_recover ST-1 --omp-texttool round-1; stall_omp_count 4
  STALL_TIME=1360
  cmd__stall_recover ST-1 --omp-texttool round-1; stall_omp_count 6
}
case_stall_omp_config() {
  stall_omp_fixture
  (
    unset DV_OMP_RESTART_GAP DV_OMP_RESTART_SETTLE
    # shellcheck source=/dev/null
    source "$ROOT/config.example.sh"
    test "$DV_OMP_RESTART_GAP" = 180
    test "$DV_OMP_RESTART_SETTLE" = 2
  )
  local setting value
  for setting in DV_OMP_RESTART_GAP DV_OMP_RESTART_SETTLE; do
    for value in -1 invalid 1.5 1000000000; do
      if env "$setting=$value" dv _stall-recover ST-1 --omp-texttool round-1; then return 1; fi
      test ! -e "$DV_STATE/ST-1/omp-restarts.json"
    done
  done
  stall_omp_count 0
}
case_stall_omp_daily() {
  stall_omp_fixture
  # The per-day count survives process restarts, and excludes earlier days.
  printf '{"old":{"at":1,"day":"2000-01-01"}}\n' > "$DV_STATE/ST-1/omp-restarts.json"
  local n
  for n in 1 2 3 4 5 6 7; do
    stall_omp_message "daily-$n"
    stall_omp_scan; stall_omp_count "$((n * 2))"
    tail -1 "$DV_HOME/omp-restarts.log" | grep -F "rc=0 today=$n"
    if [ "$n" -le 5 ]; then test ! -e "$DV_HOME/omp-restarts-over5.log"; fi
  done
  test "$(wc -l < "$DV_HOME/omp-restarts.log" | tr -d ' ')" = 7
  test "$(wc -l < "$DV_HOME/omp-restarts-over5.log" | tr -d ' ')" = 2
  grep -F ST-1 "$DV_HOME/omp-restarts-over5.log"
  test ! -s "$DV_HOME/kick.q"
  test ! -e "$DV_STATE/ST-1/events.log"
  jq -e '.agent=="omp" and .escalated_from==null' "$DV_STATE/ST-1/meta"
  test ! -e "$DV_STATE/ST-1/revive"
}
case_stall_omp_remote() {
  stall_omp_fixture
  mkdir -p "$CASE_DIR/remote-home" "$CASE_DIR/hosts/ssh-alias" "$CASE_DIR/remote-state"
  local rows
  rows=$(dv status ST-1 --json)
  mv "$DV_STATE/ST-1" "$CASE_DIR/remote-state/ST-1"
  printf 'DV_HOME=%q\nDV_STATE=%q\nDV_HOST=canonical-host\n' "$CASE_DIR/remote-home" "$CASE_DIR/remote-state" > "$CASE_DIR/hosts/ssh-alias/config"
  export SSH_BIDDING=1
  stall_reconcile ssh-alias "$rows" 60
  stall_omp_count 2
  stall_reconcile ssh-alias "$rows" 60
  stall_omp_count 2
  grep -F 'ssh-alias dv _stall-recover ST-1 --omp-texttool round-1' "$CASE_DIR/ssh.calls"
  grep -F "$CASE_DIR/remote-state/ST-1/brief.md" "$CASE_DIR/remote-state/ST-1/sent-input"
  test -f "$CASE_DIR/remote-state/ST-1/omp-restarts.json"
  test -f "$CASE_DIR/remote-home/omp-restarts.log"
  test ! -e "$DV_HOME/omp-restarts.log"
  test ! -d "$DV_STATE/ST-1"
}
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
  # Ordinary idle exercises persisted event deduplication without an automatic
  # goal resume changing the agent to working (covered by stall_watch_resume).
  printf '› \n' > "$CASE_DIR/herdr/w-ST-1/output"
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
case_stall_pr_idle() {
  stall_fixture
  printf '› \n' > "$CASE_DIR/herdr/w-ST-1/output"
  jq '.status="pr" | .head=.start_head' "$DV_STATE/ST-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/ST-1/meta"
  stall_functions
  STALL_ROW=$(dv status ST-1 --json | jq -c '.[0]')
  stall_scan() { stall_reconcile "$DV_HOST" "[$STALL_ROW]" 60; }
  stall_scan; stall_tick 9; stall_count 0
  stall_tick 1; stall_count 1
  stall_tick; stall_count 1
  # A live waiter interrupts the idle episode; its stale PID does not.
  mkdir "$DV_STATE/ST-1/.pr-wait"
  touch "$DV_STATE/ST-1/.pr-wait/pid-$$"
  stall_scan; stall_tick; stall_count 1
  rm "$DV_STATE/ST-1/.pr-wait/pid-$$"
  local dead
  true & dead=$!; wait "$dead"
  touch "$DV_STATE/ST-1/.pr-wait/pid-$dead"
  stall_scan; stall_tick; stall_count 2
  jq -n --arg head "$(printf '%s\n' "$STALL_ROW" | jq -r .head)" \
    '{head:$head,green:true,review_handled:true}' > "$DV_STATE/ST-1/pr-ready.json"
  stall_scan; stall_tick; stall_count 2
  # An old clean receipt cannot handle a new head or preserve its old timer.
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.done_head=.head | .done_at=1 | .head="next-head"')
  jq '.head="next-head" | .done_at=1' "$DV_STATE/ST-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/ST-1/meta"
  stall_scan; stall_tick 9; stall_count 2
  stall_tick 1; stall_count 3
  jq -se '[.[]|select(.kind=="stalled")][-1].head=="next-head"' "$DV_HOME/kick.q"
}
case_stall_pr_remote() {
  stall_fixture
  jq '.status="pr" | .head=.start_head | .host="remote-host"' "$DV_STATE/ST-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/ST-1/meta"
  stall_functions
  STALL_ROW=$(dv status ST-1 --json | jq -c '.[0] | .goal_stalled=false')
  mkdir -p "$CASE_DIR/remote-state" "$CASE_DIR/hosts/remote-host"
  mv "$DV_STATE/ST-1" "$CASE_DIR/remote-state/ST-1"
  printf 'DV_STATE="%s"\n' "$CASE_DIR/remote-state" > "$CASE_DIR/hosts/remote-host/config"
  export SSH_BIDDING=1
  stall_scan() { stall_reconcile remote-host "[$STALL_ROW]" 60; }
  stall_scan; stall_tick; stall_count 1
  # An unreachable observation pauses timing but keeps the emitted episode.
  touch "$CASE_DIR/hosts/remote-host/offline"
  stall_scan; stall_tick; stall_count 1
  rm "$CASE_DIR/hosts/remote-host/offline"
  stall_scan; stall_tick; stall_count 1
  mkdir "$CASE_DIR/remote-state/ST-1/.pr-wait"
  touch "$CASE_DIR/remote-state/ST-1/.pr-wait/pid-$$"
  stall_scan; stall_tick; stall_count 1
  jq -e 'length==0' "$DV_HOME/stalls.json"
  grep -F 'remote-host dv _stall-recover ST-1 --pr-pending' "$CASE_DIR/ssh.calls"
}
stall_functions() {
  bidding_functions
  # shellcheck source=lib/stall.sh
  source "$ROOT/lib/stall.sh"
  # Episode timing tests do not dispatch remote commands or launch agents.
  stall_recover() { :; }
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
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.agent_status="working" | .goal_stalled=false | .goal_active=true')
  stall_scan; stall_tick; stall_count 1
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.agent_status="idle" | .goal_active=false')
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
  for status in 'done' landed ready pr start-failed; do
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
  local _
  for _ in {1..50}; do
    if dv status ST-1 --json | jq -e '.[0].goal_stalled==true' >/dev/null; then break; fi
    sleep 0.1
  done
  dv status ST-1 --json | jq -e '.[0] | .goal_stalled and .alive and .agent_status=="unknown"'
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_seen 1
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  stall_count 1
  tmux -L "$DV_TMUX_SOCKET" respawn-pane -k -t dv-ST-1:0.0 "printf 'Pursuing goal\\n› \\n'; sleep 30"
  for _ in {1..50}; do
    if dv status ST-1 --json | jq -e '.[0].goal_active==true' >/dev/null; then break; fi
    sleep 0.1
  done
  dv status ST-1 --json | jq -e '.[0] | .goal_active and .goal_stalled==false'
}
# DF-83: legacy process loss and paused/capacity goals share the existing episodes.
case_stall_dead() {
  stall_fixture
  rm "$CASE_DIR/herdr/w-ST-1/detected"
  printf 'shell$ \n' > "$CASE_DIR/herdr/w-ST-1/output"
  # No wrapper record: a legacy job, or a start whose wrapper is not running yet.
  dv status ST-1 --json | jq -e '.[0] | .agent_status=="exited" and .agent_dead==true and .agent_launched==false'
  dv status ST-1 | awk -F '\t' '$2=="running" && $8=="agent=exited" { found=1 } END { exit !found }'
  stall_functions
  STALL_ROW=$(dv status ST-1 --json | jq -c '.[0]')
  stall_scan; stall_tick 9; stall_count 0
  stall_tick 1; stall_count 1
  jq -se '.[0].message|contains("exited without dv done")' "$DV_HOME/kick.q"
  stall_tick; stall_count 1
}
# A recorded wrapper that is gone is reported and relaunched on the first scan.
# Without that record the pane may still be starting, so the threshold applies.
case_stall_dead_launched() {
  stall_functions
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq -c '.agent_status="exited" | .agent_dead=true | .agent_launched=true')
  stall_scan; stall_count 1
  stall_tick; stall_count 1
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq -c '.award_token="round-2" | .agent_launched=false')
  stall_scan; stall_count 1
  stall_tick 9; stall_count 1
  stall_tick 1; stall_count 2
}
# DF-270: a terminal server restart kills the worker together with its wrapper
# (DF-231: herdr was OOM-killed and omp got SIGHUP). No exit record is left.
# The next status scan relaunches it once in the same worktree.
stall_dead_relaunch() {
  local status=$1 wt
  repo dead-relaunch; herdr_setup; watch_fixture
  export DV_HOSTS="$DV_HOST" DV_RECONCILE_INTERVAL=1 DV_STALL_AFTER=300
  cat > "$CASE_DIR/held-agent" <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail
state="$DV_STATE/$DV_ISSUE"
printf '%s\n' "${DV_REVIVE_ID:-first}" >> "$state/held-runs"
if [ -z "${DV_REVIVE_ID:-}" ]; then
  printf 'partial work\n' > partial.txt
  printf '%s\n' "$$" > "$state/held.pid"
  while :; do sleep 0.05; done
fi
exec "$ROOT/tests/fixtures/agent"
AGENT
  chmod +x "$CASE_DIR/held-agent"
  export DV_AGENT_CMD_codex="$CASE_DIR/held-agent"
  dv start "$REPO" DR-1 relaunch --mode goal
  wait_file "$DV_STATE/DR-1/held.pid"
  wt=$(jq -r .worktree "$DV_STATE/DR-1/meta")
  kill -KILL "$(cat "$DV_STATE/DR-1/capacity-supervisor.pid")" "$(cat "$DV_STATE/DR-1/agent.pid")" "$(cat "$DV_STATE/DR-1/held.pid")"
  wait_file "$CASE_DIR/herdr/w-DR-1/exit"
  if [ "$status" = waiting-capacity ]; then
    # Killed during a provider wait; the restarted server lost the pane.
    jq --argjson time "$(date +%s)" '.status="waiting-capacity" |
      .capacity={since:$time,attempt:1,resume_status:"running",next_try_at:($time+120)}' \
      "$DV_STATE/DR-1/meta" > "$CASE_DIR/meta.tmp"
    mv "$CASE_DIR/meta.tmp" "$DV_STATE/DR-1/meta"
    rm -rf "$CASE_DIR/herdr/w-DR-1"
  else
    # The restarted server restored the pane with a fresh shell.
    printf 'shell$ \n' > "$CASE_DIR/herdr/w-DR-1/output"
  fi
  test ! -f "$DV_STATE/DR-1/agent.exit"
  dv status DR-1 --json | jq -e '.[0] | .agent_dead and .agent_launched and .agent_status=="exited"'
  dv status DR-1 | awk -F '\t' '$8=="agent=exited" { found=1 } END { exit !found }'
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_file "$DV_STATE/DR-1/done.json"
  wait_file "$CASE_DIR/herdr/w-DR-1/exit"
  wait_file "$DV_STATE/DR-1/agent.exit"
  # Later scans see a finished job and never start a second replacement.
  sleep 1.5
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  test "$(cat "$DV_STATE/DR-1/agent.exit")" = 0
  jq -e '.status=="done" and .capacity==null' "$DV_STATE/DR-1/meta"
  test "$(wc -l < "$DV_STATE/DR-1/held-runs" | tr -d ' ')" = 2
  test "$(sed -n 2p "$DV_STATE/DR-1/held-runs")" = "$(cat "$DV_STATE/DR-1/revive/id")"
  test "$(cat "$wt/partial.txt")" = 'partial work'
  grep -F 'exited without dv done' "$DV_STATE/DR-1/revive/prompt.md"
  grep -F 'Finish with dv done DR-1' "$DV_STATE/DR-1/revive/prompt.md"
  test ! -d "$DV_STATE/DR-1/revive/blocked"
  jq -se '[.[]|select(.kind=="stalled")]|length==1' "$DV_HOME/kick.q"
  jq -se 'map(.kind)|map(select(.=="done"))|length==1' "$DV_STATE/DR-1/events.log"
}
case_stall_dead_relaunch() { stall_dead_relaunch running; }
case_stall_dead_capacity_relaunch() { stall_dead_relaunch waiting-capacity; }
# DF-231's hosts returned 0.3-0.8 MB of status rows; argv (Linux: 128 KiB
# per argument) must not carry them, or every reconcile round fails.
case_stall_large_rows() {
  stall_functions
  local rows
  rows=$(jq -cn --argjson row "$STALL_ROW" '[range(300) as $n | $row + {issue:("ST-\($n)"),last_log:("x" * 4000)}]')
  test "${#rows}" -gt 1100000
  stall_reconcile alias "$rows" 60
  jq -e 'length==300' "$DV_HOME/stalls.json"
}
case_stall_capacity() {
  stall_fixture
  printf 'Pursuing goal\nSelected model is at capacity\n› \n' > "$CASE_DIR/herdr/w-ST-1/output"
  dv status ST-1 --json | jq -e '.[0] | .goal_stalled and (.goal_active|not)'
  stall_functions
  STALL_ROW=$(dv status ST-1 --json | jq -c '.[0]')
  stall_scan; stall_tick; stall_count 0
}
case_stall_resume() {
  stall_fixture; stall_functions
  stall_recovery_functions
  stall_recover_call
  stall_resume_count 1
  STALL_TIME=1299; stall_recover_call; stall_resume_count 1
  STALL_TIME=1300; stall_recover_call; stall_resume_count 2
  STALL_TIME=1600; stall_recover_call; stall_resume_count 3
  STALL_TIME=1900; stall_recover_call; stall_resume_count 3
  # State survives loading the functions again (a watcher/CLI restart).
  stall_recovery_functions
  STALL_TIME=2200; stall_recover_call; stall_resume_count 3
  jq -se '[.[]|select(.kind=="blocked")]|length==1' "$DV_STATE/ST-1/events.log"
}
stall_recovery_functions() {
  # shellcheck source=lib/herdr.sh
  source "$ROOT/lib/herdr.sh"
  # shellcheck source=lib/commands.sh
  source "$ROOT/lib/commands.sh"
}
stall_recover_call() {
  printf 'idle\n' > "$CASE_DIR/herdr/w-ST-1/status"
  printf 'Goal stalled\n› \n' > "$CASE_DIR/herdr/w-ST-1/output"
  cmd__stall_recover ST-1 episode-1 round-1
}
stall_resume_count() {
  jq -se --argjson n "$1" '[.[]|select(.[0:2]==["agent","prompt"] and .[3]=="/goal resume")]|length==$n' "$CASE_DIR/herdr/calls"
}
case_stall_resume_reset() {
  stall_fixture; stall_functions; stall_recovery_functions
  stall_recover_call; stall_resume_count 1
  # A fresh observation of activity clears the episode; the next episode gets
  # its own budget, even if the commit and award token did not change.
  STALL_TIME=1001
  printf 'idle\n' > "$CASE_DIR/herdr/w-ST-1/status"
  cmd__stall_recover ST-1 episode-2 round-1
  stall_resume_count 2
  test "$(jq -r .episode "$DV_STATE/ST-1/stall-recovery.json")" = episode-2
}
case_stall_resume_guards() {
  stall_fixture; stall_functions; stall_recovery_functions
  cmd__stall_recover ST-1 episode-1 stale-token
  printf 'working\n' > "$CASE_DIR/herdr/w-ST-1/status"
  printf '› \n' > "$CASE_DIR/herdr/w-ST-1/output"
  cmd__stall_recover ST-1 episode-1 round-1
  printf 'blocked\n' > "$CASE_DIR/herdr/w-ST-1/status"
  printf 'Goal stalled\n› \n' > "$CASE_DIR/herdr/w-ST-1/output"
  cmd__stall_recover ST-1 episode-1 round-1
  printf 'idle\n' > "$CASE_DIR/herdr/w-ST-1/status"
  printf 'Goal stalled\nPursuing goal\n' > "$CASE_DIR/herdr/w-ST-1/output"
  cmd__stall_recover ST-1 episode-1 round-1
  local status
  for status in 'done' landed pr cancelled; do
    jq --arg status "$status" '.status=$status' "$DV_STATE/ST-1/meta" > "$CASE_DIR/meta.tmp"
    mv "$CASE_DIR/meta.tmp" "$DV_STATE/ST-1/meta"
    cmd__stall_recover ST-1 episode-1 round-1
  done
  stall_resume_count 0
  test ! -f "$DV_STATE/ST-1/stall-recovery.json"
}
case_stall_resume_transport() {
  stall_fixture; stall_functions; stall_recovery_functions
  printf 'agent prompt\n' > "$CASE_DIR/herdr/fail"
  if stall_recover_call; then return 1; fi
  stall_resume_count 1
  STALL_TIME=1299; stall_recover_call; stall_resume_count 1
  rm "$CASE_DIR/herdr/fail"
  STALL_TIME=1300; stall_recover_call; stall_resume_count 2
}
case_stall_banner_sequence() {
  stall_functions
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.goal_stalled=true')
  stall_scan; stall_tick; stall_count 1
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.agent_state_seq=3')
  stall_scan; stall_tick; stall_count 1
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.goal_active=true')
  stall_scan
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.goal_active=false')
  stall_scan; stall_tick; stall_count 2
}
case_stall_watch_resume() {
  stall_fixture
  export DV_CAPACITY_BACKOFF=1 DV_CAPACITY_MAX_WAIT=30
  printf 'Selected model is at capacity\n› \n' > "$CASE_DIR/herdr/w-ST-1/output"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_file "$DV_STATE/ST-1/goal-input"
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  stall_count 0; stall_resume_count 1
  jq -se '[.[]|select(.kind=="waiting-capacity")]|length==1' "$DV_STATE/ST-1/events.log"
  grep -Fx '/goal resume' "$DV_STATE/ST-1/goal-input"
  test ! -d "$DV_STATE/ST-1/revive"
}
case_stall_watch_revive() {
  revive_setup; revive_dead; watch_fixture
  rm "$RV_STATE/agent.pid" "$RV_STATE/agent.exit"
  jq '.status="running" | del(.done_at)' "$RV_STATE/meta" > "$CASE_DIR/meta.tmp"
  mv "$CASE_DIR/meta.tmp" "$RV_STATE/meta"
  export DV_HOSTS="$DV_HOST" DV_STALL_AFTER=1 DV_RECONCILE_INTERVAL=1
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  revive_wait
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  stall_count 1
  revive_preserved
}
case_stall_remote_resume() {
  stall_fixture
  mkdir "$CASE_DIR/remote-home"
  printf 'DV_HOME=%q\nDV_HOST=canonical-host\n' "$CASE_DIR/remote-home" > "$CASE_DIR/remote-home/config.sh"
  export SSH_FIXTURE_EXEC=1 DV_HOSTS=ssh-alias
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_file "$DV_STATE/ST-1/goal-input"
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  stall_resume_count 1
}
case_stall_dead_old_banner() {
  stall_fixture
  rm "$CASE_DIR/herdr/w-ST-1/detected"
  printf 'Pursuing goal\nshell$ \n' > "$CASE_DIR/herdr/w-ST-1/output"
  dv status ST-1 --json | jq -e '.[0] | .agent_dead and (.goal_active|not)'
}
case_stall_recovery_host() {
  stall_functions
  stall_recover() { printf '%s\n' "$1" >> "$CASE_DIR/recovery-hosts"; }
  DV_STALL_AFTER=1
  STALL_ROW=$(printf '%s\n' "$STALL_ROW" | jq '.goal_stalled=true')
  stall_reconcile alias-a "[$STALL_ROW]" 60
  STALL_TIME=1001
  stall_reconcile alias-a "[$STALL_ROW]" 60
  # A second host can be scanned in the same second. Never dispatch host A's
  # pending episode to host B just because their observation times match.
  stall_reconcile alias-b '[]' 60
  test "$(cat "$CASE_DIR/recovery-hosts")" = alias-a
}
case_stall_working_banner_detection() {
  stall_fixture; stall_functions
  printf 'working\n' > "$CASE_DIR/herdr/w-ST-1/status"
  local banner count=0
  for banner in 'Selected model is at capacity' 'Goal stalled'; do
    printf '• Working\n%s\n› \n' "$banner" > "$CASE_DIR/herdr/w-ST-1/output"
    STALL_ROW=$(dv status ST-1 --json | jq -c '.[0]')
    stall_scan; stall_tick 9; stall_count "$count"
    stall_tick 1
    if [ "$banner" = 'Goal stalled' ]; then count=$((count + 1)); fi
    stall_count "$count"
    stall_tick; stall_count "$count"
    # A newer activity banner ends this episode despite old stalled text.
    printf '%s\n• Pursuing goal\n› \n' "$banner" > "$CASE_DIR/herdr/w-ST-1/output"
    STALL_ROW=$(dv status ST-1 --json | jq -c '.[0]')
    stall_scan; stall_tick; stall_count "$count"
  done
}
case_stall_working_banner_resume() {
  stall_fixture; stall_functions; stall_recovery_functions
  local banner count=0
  for banner in 'Selected model is at capacity' 'Goal stalled'; do
    printf 'working\n' > "$CASE_DIR/herdr/w-ST-1/status"
    printf '• Pursuing goal\n%s\n› \n' "$banner" > "$CASE_DIR/herdr/w-ST-1/output"
    count=$((count + 1))
    cmd__stall_recover ST-1 "working-banner-$count" round-1
    if [ "$banner" = 'Selected model is at capacity' ]; then
      stall_resume_count 0
      capacity_due ST-1
      cmd__stall_recover ST-1 "working-banner-$count" round-1
      test ! -f "$DV_STATE/ST-1/stall-recovery.json"
    fi
    stall_resume_count "$count"
    cmd__stall_recover ST-1 "working-banner-$count" round-1
    stall_resume_count "$count"
  done
}
case_stall_latest_activity() {
  stall_fixture; stall_functions; stall_recovery_functions
  local activity status
  for status in working idle; do
    printf '%s\n' "$status" > "$CASE_DIR/herdr/w-ST-1/status"
    for activity in 'Pursuing goal' 'Working' 'Working (2s • esc to interrupt)' 'Working...'; do
      printf 'Goal stalled\nSelected model is at capacity\n• %s\n› \n' "$activity" > "$CASE_DIR/herdr/w-ST-1/output"
      STALL_ROW=$(dv status ST-1 --json | jq -c '.[0]')
      printf '%s\n' "$STALL_ROW" | jq -e '.goal_active and (.goal_stalled|not)'
      stall_scan; stall_tick; stall_count 0
      cmd__stall_recover ST-1 working-banner round-1
      stall_resume_count 0
    done
  done
  test ! -f "$DV_STATE/ST-1/stall-recovery.json"
}
stall_recovery_teardown() {
  rm -f "$CASE_DIR/herdr/recovery-hold"
  touch "$CASE_DIR/recovery-release"
  local pid tries
  for pid in ${recovery_workers:-}; do wait "$pid" 2>/dev/null || true; done
  if [ -f "$DV_STATE/SR-1/recovery-runs" ]; then
    while IFS= read -r pid; do
      for tries in {1..100}; do
        [ ! -f "$DV_STATE/SR-1/recovery-exit-$pid" ] || break
        sleep 0.05
      done
    done < "$DV_STATE/SR-1/recovery-runs"
  fi
  # Agent exit bookkeeping follows the fake agent's EXIT trap.
  for tries in {1..100}; do
    if [ -f "$DV_STATE/SR-1/agent.pid" ] && ! kill -0 "$(cat "$DV_STATE/SR-1/agent.pid")" 2>/dev/null; then break; fi
    sleep 0.05
  done
  teardown
}
stall_recover_as_documented() {
  # Execute the two documented worker routes without an LLM. The old stalled
  # rule used a raw launcher, bypassing dv send's lock and permanent revive claim.
  local rule
  rule=$(sed -n '/^- stalled:/p' "$ROOT/templates/worker-prompt.md")
  if printf '%s\n' "$rule" | grep -Fq 'dv send <ISSUE>'; then
    dv send SR-1 resume
  else
    printf '%s\n' "$rule" | grep -Fq 'devflow launcher'
    load_issue SR-1
    herdr_cmd pane run "$HERDR_PANE" "$(shell_join "$ROOT/bin/dv" _agent SR-1)"
  fi
}
stall_recovery_worker() (
  local kind=$1 rc=0
  if [ "$kind" = stalled ]; then stall_recover_as_documented || rc=$?
  else dv send SR-1 'resume after failed event' || rc=$?; fi
  printf '%s\n' "$rc" > "$CASE_DIR/$kind.exit"
)
# Shared fixture state and intentionally unused polling counters/results.
# shellcheck disable=SC2034
stall_recovery_race() {
  local first=$1 second=$2 tries calls count pid
  repo stalled-recovery; herdr_setup; bidding_functions
  trap stall_recovery_teardown EXIT
  export DV_AGENT_CMD_codex="$ROOT/tests/fixtures/stalled-goal"
  dv start "$REPO" SR-1 recovery
  wait_file "$DV_STATE/SR-1/held.pid"
  dv status SR-1 --json | jq -e '.[0] | .status=="running" and .goal_stalled'
  local wt
  wt=$(jq -r .worktree "$DV_STATE/SR-1/meta")
  printf 'saved work\n' > "$wt/wip"
  git -C "$wt" add wip
  git -C "$wt" commit -qm 'SR-1: WIP before stalled recovery'
  # Stopping the real fake goal makes the production wrapper emit failed.
  kill -TERM "$(cat "$DV_STATE/SR-1/held.pid")"
  wait_file "$CASE_DIR/herdr/w-SR-1/exit"
  wait_file "$DV_STATE/SR-1/events.log"
  jq -se 'length==1 and .[0].kind=="failed"' "$DV_STATE/SR-1/events.log"
  test ! -e "$DV_STATE/SR-1/done.json"
  touch "$CASE_DIR/stall-recover" "$CASE_DIR/herdr/recovery-hold"
  stall_recovery_worker "$first" > "$CASE_DIR/$first.log" 2>&1 & recovery_workers=$!
  wait_file "$CASE_DIR/herdr/recovery-entered"
  stall_recovery_worker "$second" > "$CASE_DIR/$second.log" 2>&1 & recovery_workers="$recovery_workers $!"
  # Wait for the second path either to contend on the lock or request its own
  # launcher. Both processes are live during the initial restart's window.
  for tries in {1..100}; do
    calls=$(jq -s '[.[]|select(.[0:2]==["pane","run"])]|length' "$CASE_DIR/herdr/calls")
    if [ -f "$CASE_DIR/$second.exit" ] || [ "$calls" -eq 3 ]; then break; fi
    sleep 0.05
  done
  rm "$CASE_DIR/herdr/recovery-hold"
  for pid in $recovery_workers; do wait "$pid"; done
  recovery_workers=''
  calls=$(jq -s '[.[]|select(.[0:2]==["pane","run"])]|length-1' "$CASE_DIR/herdr/calls")
  count=0
  for tries in {1..100}; do
    if [ -f "$DV_STATE/SR-1/recovery-runs" ]; then count=$(wc -l < "$DV_STATE/SR-1/recovery-runs" | tr -d ' '); fi
    [ "$count" -lt "$calls" ] || break
    sleep 0.05
  done
  cat "$CASE_DIR/$first.log" "$CASE_DIR/$second.log"
  printf '%s then %s: new_agents=%s expected=1\n' "$first" "$second" "$count"
  test "$count" = 1
  test "$calls" = 1
  test -d "$DV_STATE/SR-1/revive"
  # Delayed duplicate events cannot bypass the claim, even while detection is
  # missing. The replacement remains alive and the saved work stays intact.
  dv send SR-1 'late failed event' > "$CASE_DIR/late.log" 2>&1 || true
  stall_recover_as_documented >> "$CASE_DIR/late.log" 2>&1 || true
  jq -se '[.[]|select(.[0:2]==["pane","run"])]|length==2' "$CASE_DIR/herdr/calls"
  test "$(cat "$wt/wip")" = 'saved work'
  pid=$(cat "$DV_STATE/SR-1/recovery-runs")
  kill -0 "$pid"
  grep '^resume' "$DV_STATE/SR-1/recovery-input-$pid"
  touch "$CASE_DIR/recovery-release"
  wait_file "$DV_STATE/SR-1/recovery-exit-$pid"
  for tries in {1..100}; do
    if ! kill -0 "$(cat "$DV_STATE/SR-1/agent.pid")" 2>/dev/null; then break; fi
    sleep 0.05
  done
  # The permanent claim also prevents a new launch after the replacement exits.
  if dv send SR-1 'replayed failed after replacement exit' >> "$CASE_DIR/late.log" 2>&1; then return 1; fi
  jq -se '[.[]|select(.[0:2]==["pane","run"])]|length==2' "$CASE_DIR/herdr/calls"
  test "$(wc -l < "$DV_STATE/SR-1/recovery-runs" | tr -d ' ')" = 1
}
case_stall_failed_race() { stall_recovery_race stalled failed; }
case_failed_stall_race() { stall_recovery_race failed stalled; }
