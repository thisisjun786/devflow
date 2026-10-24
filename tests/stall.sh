#!/usr/bin/env bash
# Sourced by run.sh: synthetic status, herdr/Codex fixtures, no live agents.
# ROOT and DV_HOST come from the driver.
# shellcheck disable=SC2153,SC2154,SC2016
stall_omp_fixture() {
  stall_fixture; stall_functions
  jq '.agent="omp" | .head=.start_head' "$DV_STATE/ST-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/ST-1/meta"
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
      [{type:"text",text:"[tool_use id=call_1 name=_bash] {\"command\":\"pwd\"}"}])}}' >> "$OMP_LOG"
}
stall_omp_scan() {
  stall_reconcile "$DV_HOST" "$(dv status ST-1 --json)" 60
}
stall_omp_count() {
  jq -se --argjson n "$1" '[.[]|select(.[0:2]==["agent","prompt"])]|length==$n' "$CASE_DIR/herdr/calls"
}
stall_omp_escalation_fixture() {
  stall_omp_fixture
  export DV_CODEX_BIN="$ROOT/tests/fixtures/texttool-codex"
  unset DV_OMP_TEXTTOOL_ESCALATE
  cp "$CASE_DIR/brief" "$DV_STATE/ST-1/brief.md"
  jq '.herdr_workspace="w-ST-1"' "$DV_STATE/ST-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/ST-1/meta"
  printf 'report to preserve\n' > "$DV_STATE/ST-1/report.md"
  printf '{"rounds":2,"requests":{"old":{"retried":true}}}\n' > "$DV_STATE/ST-1/pr-loop.json"
  printf 'review receipt\n' > "$DV_STATE/ST-1/review-fix.sent"
  printf 'staged\n' > "$REPO/staged"
  git -C "$REPO" add staged
  printf 'unstaged\n' >> "$REPO/staged"
  printf 'untracked\n' > "$REPO/untracked"
  git -C "$REPO" diff --binary > "$CASE_DIR/unstaged"
  git -C "$REPO" diff --cached --binary > "$CASE_DIR/staged"
  cp "$DV_STATE/ST-1/report.md" "$CASE_DIR/report"
  cp "$DV_STATE/ST-1/pr-loop.json" "$CASE_DIR/pr-loop"
}
stall_omp_escalation_check() {
  local expected_status=$1 interrupts=${2:-1}
  wait_file "$DV_STATE/ST-1/takeover.json"
  dv status ST-1 --json | jq -e --arg status "$expected_status" '.[0] |
    .agent=="codex" and .escalated_from=="omp" and .escalation_reason=="texttool" and .status==$status and
    .escalation_status=="launched" and .escalation_error==null'
  dv status ST-1 | grep -F 'escalated_from=omp reason=texttool'
  jq -e --arg wt "$REPO" '.cwd==$wt and (.args|index("exec")!=null) and
    (.args[-1]|contains("stalled") and contains("uncommitted") and contains("brief.md") and contains("PR") and contains("dv done ST-1"))' "$DV_STATE/ST-1/takeover.json"
  git -C "$REPO" diff --binary > "$CASE_DIR/unstaged-after"
  git -C "$REPO" diff --cached --binary > "$CASE_DIR/staged-after"
  cmp "$CASE_DIR/unstaged" "$CASE_DIR/unstaged-after"
  cmp "$CASE_DIR/staged" "$CASE_DIR/staged-after"
  grep -Fx untracked "$REPO/untracked"
  test "$(git -C "$REPO" symbolic-ref --short HEAD)" = main
  cmp "$CASE_DIR/report" "$DV_STATE/ST-1/report.md"
  cmp "$CASE_DIR/pr-loop" "$DV_STATE/ST-1/pr-loop.json"
  grep -Fx 'review receipt' "$DV_STATE/ST-1/review-fix.sent"
  jq -se --argjson count "$interrupts" '[.[]|select(.[0:2]==["pane","send-keys"] and .[3]=="C-c")]|length==$count' "$CASE_DIR/herdr/calls"
  stall_omp_scan
  dv _stall-recover ST-1 --omp-texttool round-1
  test "$(wc -l < "$DV_STATE/ST-1/takeover-runs" | tr -d ' ')" = 1
}
case_stall_omp_escalate() {
  stall_omp_escalation_fixture
  local n
  for n in 1 2 3 4; do
    stall_omp_message "retry-$n"
    stall_omp_scan; stall_omp_count "$n"
    jq -e '.agent=="omp" and .escalated_from==null' "$DV_STATE/ST-1/meta"
  done
  # A repeated scan of the just-resumed turn must let that attempt run.
  stall_omp_scan; stall_omp_count 4
  stall_omp_message exhausted
  stall_omp_scan; stall_omp_count 4
  stall_omp_escalation_check running
  test ! -d "$DV_STATE/ST-1/revive"
}
case_stall_omp_escalate_pr() {
  stall_omp_escalation_fixture
  export DV_OMP_TEXTTOOL_ESCALATE=1
  jq '.status="pr"' "$DV_STATE/ST-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/ST-1/meta"
  mkdir "$DV_STATE/ST-1/revive" "$DV_STATE/ST-1/.pr-wait"
  printf 'previous-revive\n' > "$DV_STATE/ST-1/revive/id"
  touch "$DV_STATE/ST-1/.pr-wait/pid-$$"
  stall_omp_scan; stall_omp_count 1
  stall_omp_message exhausted
  stall_omp_scan; stall_omp_count 1
  stall_omp_escalation_check pr
  grep -Fx previous-revive "$DV_STATE/ST-1/revive/id"
}
case_stall_omp_escalate_skip() {
  stall_omp_escalation_fixture
  export DV_OMP_TEXTTOOL_ESCALATE=1
  stall_omp_scan; stall_omp_count 1
  stall_omp_message exhausted
  touch "$DV_STATE/ST-1/texttool-skip"
  stall_omp_scan; stall_omp_count 1
  test ! -e "$DV_STATE/ST-1/takeover.json"
  jq -e '.agent=="omp" and .escalated_from==null' "$DV_STATE/ST-1/meta"
}
case_stall_omp_escalate_launch() {
  stall_omp_escalation_fixture
  export DV_OMP_TEXTTOOL_ESCALATE=1
  # Existing reservation format from a previous launch must not exhaust this one.
  printf '{"old":{"reserved_at":1}}\n' > "$DV_STATE/ST-1/omp-texttool-nudges.json"
  stall_omp_scan; stall_omp_count 1
  # A distinct launch, even within the same second, starts a fresh budget.
  printf 'next-launch\n' > "$DV_STATE/ST-1/agent.launched"
  stall_omp_message next-launch
  stall_omp_scan; stall_omp_count 2
  jq -e '.agent=="omp" and .escalated_from==null' "$DV_STATE/ST-1/meta"
  stall_omp_message exhausted
  stall_omp_scan; stall_omp_count 2
  stall_omp_escalation_check running
}
case_stall_omp_escalate_interrupt() {
  stall_omp_escalation_fixture
  export DV_OMP_TEXTTOOL_ESCALATE=1
  stall_omp_scan; stall_omp_count 1
  stall_omp_message exhausted
  printf 'pane send-keys\n' > "$CASE_DIR/herdr/fail"
  stall_omp_scan; stall_omp_count 1
  jq -e '.agent=="omp" and .escalation_status=="blocked"' "$DV_STATE/ST-1/meta"
  rm "$CASE_DIR/herdr/fail"
  stall_omp_scan
  stall_omp_count 1
  stall_omp_escalation_check running 2
  jq -se '[.[]|select(.kind=="blocked")]|length==1' "$DV_STATE/ST-1/events.log"
}
stall_omp_blocked_fixture() {
  stall_omp_escalation_fixture
  export DV_OMP_TEXTTOOL_ESCALATE=1
  stall_omp_scan; stall_omp_count 1
  stall_omp_message exhausted
  # Reproduce the record retained by older releases after invalid_key.
  mkdir "$DV_STATE/ST-1/omp-texttool-escalation"
  printf 'Retained handoff: stalled, uncommitted, brief.md, PR, dv done ST-1\n' > "$DV_STATE/ST-1/omp-texttool-escalation/prompt.md"
  cp "$DV_STATE/ST-1/omp-texttool-escalation/prompt.md" "$CASE_DIR/prompt"
  jq '.escalated_from="omp" | .escalation_reason="texttool" | .escalation_status="blocked" |
    .escalation_error="omp did not stop" | .escalation_resumes=1 | .escalated_at=1' "$DV_STATE/ST-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/ST-1/meta"
}
case_stall_omp_escalate_blocked() {
  stall_omp_blocked_fixture
  stall_omp_scan
  stall_omp_escalation_check running
  cmp "$CASE_DIR/prompt" "$DV_STATE/ST-1/omp-texttool-escalation/prompt.md"
}
case_stall_omp_escalate_blocked_guards() {
  stall_omp_blocked_fixture
  local change
  cp "$DV_STATE/ST-1/meta" "$CASE_DIR/blocked-meta"
  for change in '.escalation_status="interrupting"' '.escalation_status="launching"' '.escalation_status="launched"' \
    '.escalation_error="could not close stopped omp pane"' '.escalation_error="could not launch Codex"' \
    '.escalation_reason="other"' '.done_at=1' '.capacity={}' ; do
    jq "$change" "$CASE_DIR/blocked-meta" > "$DV_STATE/ST-1/meta"
    stall_omp_scan
    dv _stall-recover ST-1 --omp-texttool round-1
  done
  cp "$CASE_DIR/blocked-meta" "$DV_STATE/ST-1/meta"
  dv _stall-recover ST-1 --omp-texttool stale-token
  touch "$DV_STATE/ST-1/texttool-skip"
  stall_omp_scan
  rm "$DV_STATE/ST-1/texttool-skip"
  printf 'working\n' > "$CASE_DIR/herdr/w-ST-1/status"
  stall_omp_scan
  dv _stall-recover ST-1 --omp-texttool round-1
  stall_omp_count 1
  test ! -e "$DV_STATE/ST-1/takeover.json"
  jq -se 'all(.[]; .[0:2]!=["pane","send-keys"])' "$CASE_DIR/herdr/calls"
  printf 'idle\n' > "$CASE_DIR/herdr/w-ST-1/status"
  stall_omp_scan
  stall_omp_escalation_check running
}
case_stall_omp_escalate_legacy() {
  stall_omp_escalation_fixture
  export DV_OMP_TEXTTOOL_ESCALATE=1
  jq -n --argjson at "$(date +%s)" '{old:{reserved_at:$at}}' > "$DV_STATE/ST-1/omp-texttool-nudges.json"
  stall_omp_scan; stall_omp_count 0
  stall_omp_escalation_check running
}
case_stall_omp_escalate_wrapper() {
  stall_omp_escalation_fixture
  export DV_OMP_TEXTTOOL_ESCALATE=1
  export DV_AGENT_CMD_omp='printf "%s\n" "$$" > "$DV_STATE/$DV_ISSUE/omp-pid"; while :; do sleep 0.1; done'
  touch "$CASE_DIR/herdr/w-ST-1/ready"
  herdr pane run w-ST-1:p1 "$(shell_join "$ROOT/bin/dv" _agent ST-1)"
  wait_file "$DV_STATE/ST-1/omp-pid"
  local previous_pid
  previous_pid=$(cat "$DV_STATE/ST-1/agent.pid")
  stall_omp_message live-wrapper
  stall_omp_scan; stall_omp_count 1
  stall_omp_message exhausted
  stall_omp_scan; stall_omp_count 1
  stall_omp_escalation_check running
  ! kill -0 "$previous_pid" 2>/dev/null
  # The old wrapper cannot publish an exit over its Codex successor.
  test ! -f "$DV_STATE/ST-1/agent.exit"
  test ! -d "$DV_STATE/ST-1/revive"
}
case_stall_omp_once() {
  stall_omp_fixture
  stall_omp_scan; stall_omp_count 1
  # The same turn survives scans, command restarts and a later PR transition.
  stall_omp_scan
  jq '.status="pr"' "$DV_STATE/ST-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/ST-1/meta"
  stall_omp_scan; stall_omp_count 1
  stall_omp_message turn-2
  stall_omp_scan; stall_omp_count 2
  stall_omp_message turn-1
  stall_omp_scan; stall_omp_count 2
  test ! -f "$DV_STATE/ST-1/stall-recovery.json"
  grep -F 'Continue' "$DV_STATE/ST-1/sent-input"
  grep -F 'Call tools only through tool_use (actual tool calls), never as text. Do not prefix tool names with _ (for example, use bash).' "$DV_STATE/ST-1/sent-input"
}
case_stall_omp_patterns() {
  stall_omp_fixture
  local marker content n=0
  for marker in '<invoke name="_bash">' '<function_calls>' '<tool_call>' '[tool_use'; do
    content=$(jq -cn --arg text "$marker" '[{type:"text",text:$text}]')
    stall_omp_message "pattern-$n" "$content"
    n=$((n + 1))
    stall_omp_scan; stall_omp_count "$n"
  done
}
case_stall_omp_pr() {
  stall_omp_fixture
  jq '.status="pr"' "$DV_STATE/ST-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/ST-1/meta"
  # A PR waiter does not suppress this specific provider fault.
  mkdir "$DV_STATE/ST-1/.pr-wait"
  touch "$DV_STATE/ST-1/.pr-wait/pid-$$"
  stall_omp_scan; stall_omp_count 1
  stall_omp_scan; stall_omp_count 1
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
  stall_omp_message superseded
  printf '%s\n' '{"type":"message","id":"user-1","message":{"role":"user","content":[{"type":"text","text":"Continue"}]}}' >> "$OMP_LOG"
  stall_omp_scan; stall_omp_count 0
  # An incomplete or corrupt trailing message must not expose an old turn.
  stall_omp_message partial
  printf '{"type":"message"' >> "$OMP_LOG"
  stall_omp_scan; stall_omp_count 0
  printf '\n' >> "$OMP_LOG"
  stall_omp_message recovered
  stall_omp_scan; stall_omp_count 1
}
case_stall_omp_guards() {
  stall_omp_fixture
  local status change
  for status in working blocked unknown 'done'; do
    printf '%s\n' "$status" > "$CASE_DIR/herdr/w-ST-1/status"
    stall_omp_scan
    # A stale idle snapshot must also be rejected by the issue host.
    dv _stall-recover ST-1 --omp-texttool round-1
  done
  printf 'idle\n' > "$CASE_DIR/herdr/w-ST-1/status"
  dv _stall-recover ST-1 --omp-texttool stale-token
  cp "$DV_STATE/ST-1/meta" "$CASE_DIR/original-meta"
  for change in '.status="done"' '.done_at=1' '.cleaned_at=1' '.agent="codex"' '.capacity={}' ; do
    jq "$change" "$CASE_DIR/original-meta" > "$DV_STATE/ST-1/meta"
    stall_omp_scan
    dv _stall-recover ST-1 --omp-texttool round-1
  done
  cp "$CASE_DIR/original-meta" "$DV_STATE/ST-1/meta"
  touch "$DV_STATE/ST-1/texttool-skip"
  stall_omp_scan; stall_omp_count 0
  rm "$DV_STATE/ST-1/texttool-skip"
  # A pending question is protected even if herdr's pane is idle.
  cmd_status() { dv status ST-1 --json | jq 'map(.question_pending=true)'; }
  cmd__stall_recover ST-1 --omp-texttool round-1
  stall_omp_count 0
  stall_omp_scan; stall_omp_count 1
}
case_stall_omp_session() {
  stall_omp_fixture
  touch -t 201901010000 "$OMP_LOG"
  stall_omp_scan; stall_omp_count 0
  # A newer session supersedes an older session's bad final message.
  touch -t 202101010000 "$OMP_LOG"
  OMP_LOG="$OMP_DIR/new-session.jsonl"
  stall_omp_message final '[{"type":"text","text":"Done"}]'
  stall_omp_scan; stall_omp_count 0
  stall_omp_message turn-1
  stall_omp_scan; stall_omp_count 1
  # Identical message IDs in distinct sessions are distinct turns.
  touch -t 202201010000 "$OMP_LOG"
  OMP_LOG="$OMP_DIR/session.jsonl"
  touch "$OMP_LOG"
  stall_omp_scan; stall_omp_count 2
}
case_stall_omp_transport() {
  stall_omp_fixture
  printf 'agent prompt\n' > "$CASE_DIR/herdr/fail"
  stall_omp_scan; stall_omp_count 1
  rm "$CASE_DIR/herdr/fail"
  stall_omp_scan; stall_omp_count 1
  test ! -f "$DV_STATE/ST-1/sent-input"
  stall_omp_message next
  stall_omp_scan; stall_omp_count 2
}
case_stall_omp_remote() {
  stall_omp_fixture
  mkdir -p "$CASE_DIR/remote-home" "$CASE_DIR/hosts/ssh-alias"
  printf 'DV_HOME=%q\nDV_HOST=canonical-host\n' "$CASE_DIR/remote-home" > "$CASE_DIR/hosts/ssh-alias/config"
  export SSH_BIDDING=1
  stall_reconcile ssh-alias "$(dv status ST-1 --json)" 60
  stall_omp_count 1
  stall_reconcile ssh-alias "$(dv status ST-1 --json)" 60
  stall_omp_count 1
  grep -F 'ssh-alias dv _stall-recover ST-1 --omp-texttool round-1' "$CASE_DIR/ssh.calls"
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
