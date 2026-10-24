#!/usr/bin/env bash
# The watcher records observations; recovery revalidates on the issue host.
# ISSUE is assigned by load_issue in common.sh; jq dollars are literal.
# shellcheck disable=SC2016,SC2153
stall_omp_candidates() {
  jq -c '.[] | select(.agent=="omp" and .backend=="herdr" and
    (.status=="running" or .status=="pr") and .alive==true and .agent_status=="idle" and
    .question_pending!=true and .goal_active!=true and .capacity_detected!=true and .capacity==null and
    .cleaned_at==null and .escalated_from==null and (.done_at==null or (.status=="pr" and .done_head!=.head)) and
    (.issue|type)=="string" and (.issue|test("^[A-Za-z0-9][A-Za-z0-9_-]*$")))'
}
# Read the newest session written by this launch. A later user/tool message or
# an incomplete final JSON line supersedes the old assistant turn. Stream the
# log so long sessions do not need to fit in memory or one shell argument.
stall_omp_turn() {
  local physical dir file newest=''
  [ -f "$S/agent.launched" ] || return 1
  physical=$(cd "$WT" && pwd -P) || return 1
  dir=$(agent_transcript_dir omp "$physical") || return 1
  [ -d "$dir" ] || return 1
  while IFS= read -r file; do
    if [ -z "$newest" ] || [ "$file" -nt "$newest" ]; then newest=$file; fi
  done < <(find "$dir" -maxdepth 1 -type f -name '*.jsonl' -newer "$S/agent.launched" 2>/dev/null)
  [ -n "$newest" ] || return 1
  jq -Rner --arg session "$newest" '
    reduce inputs as $line (null;
      (try ($line|fromjson) catch null) as $entry |
      if $entry==null or $entry.type=="message" then $entry else . end) |
    select(.type=="message" and (.id|type)=="string" and .id!="" and
      .message.role=="assistant" and .message.stopReason=="stop" and
      (.message.content|type)=="array") |
    select(any(.message.content[]; .type=="text" and (.text|type)=="string" and (.text|contains("[tool_use"))) and
      all(.message.content[]; .type!="toolCall")) |
    [$session,.id]|tojson' "$newest"
}
stall_omp_resume() {
  local token=$1 turn row tmp launch launched count=0 state="$S/omp-texttool-nudges.json"
  [ ! -e "$S/texttool-skip" ] || return 0
  jq -e '.escalated_from==null' "$S/meta" >/dev/null || return 0
  turn=$(stall_omp_turn) || return 0
  # Recheck live activity after reading the log, under the normal issue lock.
  row=$(cmd_status "$ISSUE" --json | stall_omp_candidates) || return 1
  [ -n "$row" ] && printf '%s\n' "$row" | jq -e --arg token "$token" '(.award_token // "")==$token' >/dev/null || return 0
  [[ "$DV_OMP_TEXTTOOL_ESCALATE" =~ ^[1-9][0-9]{0,8}$ ]] || fail 'DV_OMP_TEXTTOOL_ESCALATE must be a positive integer (at most 9 digits)'
  launch=$(cat "$S/agent.launched") || return 1
  launched=$(stat -c %Y "$S/agent.launched" 2>/dev/null || stat -f %m "$S/agent.launched") || return 1
  # Older launch markers were empty. Accept their existing reservations by
  # timestamp; new markers identify distinct launches even in the same second.
  [ -n "$launch" ] || launch="legacy:$launched"
  if [ -f "$state" ]; then
    jq -e 'type=="object"' "$state" >/dev/null || return 1
    if jq -e --arg turn "$turn" 'has($turn)' "$state" >/dev/null; then return 0; fi
    count=$(jq --arg launch "$launch" --argjson launched "$launched" '[.[] |
      select(.launch==$launch or (.launch==null and (.reserved_at // 0)>=$launched))] | length' "$state") || return 1
  fi
  if [ "$count" -ge "$DV_OMP_TEXTTOOL_ESCALATE" ]; then stall_omp_escalate "$count"; return; fi
  # Reserve before sending: uncertain transport delivery is never retried for
  # the same session/message, including after watcher or command restarts.
  tmp=$(mktemp "$S/.omp-texttool.XXXXXX") || return 1
  if ! { if [ -f "$state" ]; then cat "$state"; else printf '{}\n'; fi; } |
    jq --arg turn "$turn" --arg launch "$launch" --argjson time "$(now)" '.[$turn]={reserved_at:$time,launch:$launch}' > "$tmp" ||
    ! mv "$tmp" "$state"; then rm -f "$tmp"; return 1; fi
  send_text 'Your last turn ended with a tool call written as text. Continue the existing task using actual tool calls. Preserve existing changes and finish the brief.'
}
stall_omp_escalate() {
  local count=$1 dir="$S/omp-texttool-escalation" trust_root file
  job_can_launch || return 1
  trust_root=$(codex_repo_root "$REPO") || return 1
  codex_repo_allowed "$trust_root" && codex_environment && codex_trust_repo "$trust_root" || return 1
  # The issue lock and permanent reservation cover watcher restarts and
  # uncertain interrupt/launch delivery. This does not consume the revive.
  mkdir "$dir" || return 1
  {
    printf 'The previous omp worker stalled after repeated tool calls written as text. Its uncommitted changes are still in this worktree; preserve them.\n'
    printf 'Continue the original brief in %s on branch %s. Read %s/brief.md and %s/report.md if present.\n' "$WT" "$BRANCH" "$S" "$S"
    printf 'Finish the original brief, including the PR loop if status is pr. Preserve PR review rounds and receipts; fix current-head P0/P1 findings and wait for CI and Codex review.\n'
    printf 'Do not create a new branch. Finish with dv done %s.\n' "$ISSUE"
  } > "$dir/prompt.md"
  meta_set --argjson at "$(now)" --argjson count "$count" \
    '.escalated_from="omp" | .escalation_reason="texttool" | .escalated_at=$at |
      .escalation_resumes=$count | .escalation_status="interrupting"'
  if ! herdr_interrupt; then stall_omp_escalation_blocked 'omp did not stop'; return 1; fi
  for file in agent.pid agent.exit agent.launched agent.session; do
    [ ! -f "$S/$file" ] || cp "$S/$file" "$dir/previous-$file"
  done
  if ! herdr_clean; then stall_omp_escalation_blocked 'could not close stopped omp pane'; return 1; fi
  rm -f "$S/agent.pid" "$S/agent.exit" "$S/agent.session"
  # launch_agent (commands.sh) reads the selected backend.
  # shellcheck disable=SC2034
  BACKEND='exec'
  meta_set '.agent="codex" | .mode="exec" | .backend="exec" | .escalation_status="launching"'
  if ! launch_agent --exec-prompt "$dir/prompt.md"; then
    stall_omp_escalation_blocked 'could not launch Codex'; return 1
  fi
  meta_set '.escalation_status="launched"'
}
stall_omp_escalation_blocked() {
  meta_set --arg error "$1" '.escalation_status="blocked" | .escalation_error=$error'
  cmd_kick blocked "$ISSUE" "texttool escalation: $1; inspect the retained worktree and escalation record"
}
stall_reconcile() {
  local host=$1 rows=$2 interval=$3 time state tmp row issue event_host head token id message pending
  time=$(now)
  state="$DV_HOME/stalls.json"
  tmp=$(mktemp "$DV_HOME/.stalls.XXXXXX") || return 1
  if [ -f "$state" ]; then
    cat "$state" > "$tmp" || { rm -f "$tmp"; return 1; }
  else printf '{}\n' > "$tmp"; fi
  # A host's status rows can exceed one argument's limit (128 KiB on Linux):
  # pass them as a file, or every reconcile round fails before recovery.
  if ! printf '%s\n' "$rows" > "$tmp.rows"; then rm -f "$tmp" "$tmp.rows"; return 1; fi
  # This specific ended-turn fault needs no idle timeout or PR waiter check.
  # The issue host reads its own log and persists one reservation per turn.
  while IFS= read -r row; do
    issue=$(printf '%s\n' "$row" | jq -r .issue)
    token=$(printf '%s\n' "$row" | jq -r '.award_token // ""')
    bid_rpc "$host" _stall-recover "$issue" --omp-texttool "$token" < /dev/null || true
  done < <(stall_omp_candidates < "$tmp.rows")
  # Status rows do not carry waiter ownership or review receipts. Read those
  # on the issue host, never infer a remote PID's liveness on this watcher.
  : > "$tmp.pr"
  while IFS= read -r row; do
    issue=$(printf '%s\n' "$row" | jq -r .issue)
    head=$(printf '%s\n' "$row" | jq -r .head)
    pending=$(bid_rpc "$host" _stall-recover "$issue" --pr-pending "$head" < /dev/null) || pending=null
    case "$pending" in true|false) ;; *) pending=null ;; esac
    jq -cn --arg issue "$issue" --argjson pending "$pending" '{key:$issue,value:$pending}' >> "$tmp.pr"
  done < <(jq -c '.[] | select(.status=="pr" and .alive==true and .agent_status=="idle" and
    (.issue|type)=="string" and (.issue|test("^[A-Za-z0-9][A-Za-z0-9_-]*$")) and
    (.head|type)=="string" and .head!="") | {issue,head}' "$tmp.rows")
  # Unknown/unreachable agents interrupt timing but retain an emitted episode.
  # A sequence change catches activity between two otherwise idle samples.
  if ! jq --slurpfile rows "$tmp.rows" --slurpfile prs "$tmp.pr" --arg host "$host" --arg source "$host" --argjson time "$time" \
    --arg nonce "$time:$$:$RANDOM" --argjson gap "$((interval * 2 + 5))" '
    ($prs|from_entries) as $pending |
    reduce $rows[0][] as $row (.;
      ($row.host // $host) as $host |
      ([$host,$row.issue]|tojson) as $key |
      ([$row.started,$row.award_token,$row.herdr_pane] +
        (if $row.status=="pr" then [$row.head] else [] end)|tojson) as $generation |
      if ($row.issue|type)!="string" or ($row.issue|test("^[A-Za-z0-9][A-Za-z0-9_-]*$")|not) then .
      elif $row.status=="pr" and $row.agent_status=="idle" and $pending[$row.issue]==null then
        if .[$key]!=null then .[$key].since=null else . end
      elif (($row.status=="running" or
             ($row.status=="pr" and $pending[$row.issue]==true) or
             (($row.status=="failed" or $row.status=="waiting-capacity") and $row.agent_dead==true and
              ($row.backend=="tmux" or $row.backend=="herdr")))|not) or
           $row.capacity_detected==true or
           ($row.done_at!=null and ($row.status!="pr" or $row.done_head==$row.head)) or
           $row.cleaned_at!=null or $row.goal_active==true or
           ($row.agent_status=="working" and $row.goal_stalled!=true) or
           ($row.agent_status=="blocked" or $row.agent_status=="done") then del(.[$key])
      elif ($row.alive!=true and $row.agent_dead!=true) or
           ($row.agent_status!="idle" and $row.goal_stalled!=true and $row.agent_dead!=true) then
        if .[$key]!=null then .[$key].since=null else . end
      else
        if .[$key]==null or .[$key].generation!=$generation or
           ($row.goal_stalled!=true and $row.agent_state_seq!=null and .[$key].seq!=null and .[$key].seq!=$row.agent_state_seq) or
           ($row.agent_session!=null and .[$key].session!=null and .[$key].session!=$row.agent_session) then
          .[$key]={generation:$generation,since:$time,observed:$time,emitted:false,
            id:([$host,$row.issue,"stalled",($row.head // $row.start_head // ""),($row.award_token // ""),$nonce]|join(":"))}
        elif .[$key].since==null or $time < .[$key].observed or $time - .[$key].observed > $gap then
          .[$key].since=$time
        else . end |
        .[$key].seq=($row.agent_state_seq // .[$key].seq) |
        .[$key].session=($row.agent_session // .[$key].session) |
        .[$key].observed=$time | .[$key].expires=($time+$gap) |
        .[$key].row=($row|{issue,head,start_head,award_token,goal_stalled,agent_dead,agent_launched}) |
        .[$key].host=$host | .[$key].source=$source
      end)' "$tmp" > "$tmp.next"; then
    rm -f "$tmp" "$tmp.next" "$tmp.rows" "$tmp.pr"; return 1
  fi
  if ! mv "$tmp.next" "$state"; then rm -f "$tmp" "$tmp.next" "$tmp.rows" "$tmp.pr"; return 1; fi
  rm "$tmp" "$tmp.rows" "$tmp.pr"
  # Existing terminal sessions launched before capacity supervision was added
  # use the same nonblocking wait through the already-running watcher.
  while IFS= read -r row; do
    stall_recover "$host" "$row" || true
  done < <(printf '%s\n' "$rows" | jq -c '.[] | select((.backend=="tmux" or .backend=="herdr") and
    (.capacity_detected==true or .capacity!=null)) | {row:.,id:"capacity"}')
  # A recorded wrapper that is gone needs no idle threshold: report and relaunch
  # it on the first scan (revive still allows one). Without that record the
  # pane may still be starting, so the threshold applies as before.
  # Persist IDs before delivery. If interrupted after append, the queue itself
  # is the acknowledgement and the next scan cannot append the event twice.
  while IFS= read -r row; do
    issue=$(printf '%s\n' "$row" | jq -r .row.issue)
    event_host=$(printf '%s\n' "$row" | jq -r .host)
    head=$(printf '%s\n' "$row" | jq -r '.row.head // .row.start_head // ""')
    token=$(printf '%s\n' "$row" | jq -r '.row.award_token // ""')
    id=$(printf '%s\n' "$row" | jq -r .id)
    message="Agent idle, absent, Goal stalled for at least $DV_STALL_AFTER seconds; inspect the current pane and log"
    if printf '%s\n' "$row" | jq -e '.row.agent_dead==true' >/dev/null; then
      message='Agent exited without dv done; dv relaunches it once in the same worktree (see revive/)'
    fi
    metrics_stall_notify stalled "$issue" "$message" "$event_host" "$head" "$id" "$token" || continue
    tmp=$(mktemp "$DV_HOME/.stalls.XXXXXX") || return 1
    if ! jq --arg id "$id" 'with_entries(if .value.id==$id then .value.emitted=true else . end)' "$state" > "$tmp" ||
      ! mv "$tmp" "$state"; then rm -f "$tmp"; return 1; fi
  done < <(jq -c --argjson time "$time" --argjson after "$DV_STALL_AFTER" \
    '.[] | select(.emitted==false and .since!=null and .observed==$time and
      ($time - .since >= $after or (.row.agent_dead==true and .row.agent_launched==true)))' "$state")
  # Revisit the same episode on the existing scan. The issue host serializes
  # recovery and persists its five-minute retry budget across watcher restarts.
  while IFS= read -r row; do
    stall_recover "$host" "$row" || true
  done < <(jq -c --argjson time "$time" --arg source "$host" '.[] | select(.source==$source and .emitted and .since!=null and .observed==$time and
    (.row.goal_stalled==true or .row.agent_dead==true))' "$state")
}
stall_recover() {
  local host=$1 row=$2 issue id token remote
  issue=$(printf '%s\n' "$row" | jq -r .row.issue)
  id=$(printf '%s\n' "$row" | jq -r .id)
  token=$(printf '%s\n' "$row" | jq -r '.row.award_token // ""')
  if [ "$host" = "$DV_HOST" ]; then
    "$DV_ROOT/bin/dv" _stall-recover "$issue" "$id" "$token"
  else
    remote=$(shell_join dv _stall-recover "$issue" "$id" "$token")
    ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$host" "$remote"
  fi
}

cmd__stall_recover() (
  [ "$#" -eq 3 ] || fail 'usage: dv _stall-recover ISSUE EPISODE TOKEN'
  if [ "$2" = --pr-pending ]; then
    load_issue "$1"
    if jq -e --arg head "$3" '.status=="pr" and .head==$head and .cleaned_at==null' "$S/meta" >/dev/null &&
      ! pr_wait_alive &&
      ! jq -e --arg head "$3" '.head==$head and .green==true and .review_handled==true' "$S/pr-ready.json" >/dev/null 2>&1 &&
      ! jq -e --arg head "$3" '.head==$head and .checks=="green" and .review=="handled"' "$S/done.json" >/dev/null 2>&1; then
      printf 'true\n'
    else printf 'false\n'; fi
    return 0
  fi
  load_issue "$1"; issue_lock; require_worktree
  if [ "$2" = --omp-texttool ]; then stall_omp_resume "$3"; return; fi
  local episode=$2 token=$3 row attempts=0 last=0 time tmp supervisor capacity_rc next
  row=$(cmd_status "$ISSUE" --json | jq -c '.[0]') || return 1
  # A dead wrapper no longer owns its wait (capacity_detected is false): the
  # episode is cleared and the exited agent is revived below.
  if printf '%s\n' "$row" | jq -e --arg token "$token" '
    (.status=="running" or .status=="waiting-capacity") and .done_at==null and .cleaned_at==null and
    (.award_token // "")==$token and .question_pending!=true and (.alive==true or (.agent_dead==true and .agent_launched==true)) and
    (.capacity_detected==true or .capacity!=null)' >/dev/null; then
    supervisor=$(cat "$S/capacity-supervisor.pid" 2>/dev/null) || supervisor=''
    if [[ "$supervisor" =~ ^[1-9][0-9]*$ ]] && kill -0 "$supervisor" 2>/dev/null; then return 0; fi
    if ! printf '%s\n' "$row" | jq -e '.capacity_detected' >/dev/null; then
      capacity_clear
      row=$(cmd_status "$ISSUE" --json | jq -c '.[0]') || return 1
    else
    capacity_rc=0; capacity_poll || capacity_rc=$?
    case "$capacity_rc" in
      0)
        capacity_resume
        if [ "$(jq -r .agent "$S/meta")" = codex ]; then send_text '/goal resume'
        else send_text 'Continue the interrupted request in this worktree. Preserve existing changes.'; fi ;;
      2) capacity_block ;;
    esac
    return 0
    fi
  fi
  # Revalidate on the issue host, including token, completion and current
  # activity, before sending input or touching the existing revive path.
  # A current stalled banner can outlast herdr's working state; the most recent
  # activity banner still wins via goal_active, as it does in stall_reconcile.
  # Confirmed terminal failures are still eligible for the existing revival.
  printf '%s\n' "$row" | jq -e --arg token "$token" '
    (.status=="running" or (.status=="failed" and .agent_dead==true and
      (.backend=="tmux" or .backend=="herdr"))) and .done_at==null and .cleaned_at==null and
    (.award_token // "")==$token and .goal_active!=true and .question_pending!=true and
    (.agent_status!="working" or .goal_stalled==true) and
    (.agent_status!="blocked" and .agent_status!="done")' >/dev/null || return 0
  if printf '%s\n' "$row" | jq -e '.agent_dead==true' >/dev/null; then
    agent_gone || return 0
    if [ "$KIND" = task ]; then next='complete the brief'
    elif is_github; then next="complete the brief, commit, open or update the PR with dv pr $ISSUE"
    else next='complete the brief and commit'; fi
    revive_agent "The previous agent exited without dv done. Continue the existing goal and preserve unfinished work: $next, then finish with dv done $ISSUE."
    return
  fi
  printf '%s\n' "$row" | jq -e '.agent=="codex" and .mode=="goal" and .goal_stalled==true and .alive==true' >/dev/null || return 0
  if [ -f "$S/stall-recovery.json" ] && jq -e --arg episode "$episode" '.episode==$episode' "$S/stall-recovery.json" >/dev/null; then
    attempts=$(jq -r .attempts "$S/stall-recovery.json")
    last=$(jq -r .last "$S/stall-recovery.json")
  fi
  time=$(now)
  if [ "$attempts" -gt 0 ] && [ $((time - last)) -lt 300 ]; then return 0; fi
  if [ "$attempts" -ge 3 ]; then
    if jq -e '.blocked!=true' "$S/stall-recovery.json" >/dev/null; then
      tmp=$(mktemp "$S/.stall-recovery.XXXXXX")
      jq '.blocked=true' "$S/stall-recovery.json" > "$tmp"; mv "$tmp" "$S/stall-recovery.json"
      cmd_kick blocked "$ISSUE" 'Goal still stalled after three resume attempts; inspect the pane and provider capacity'
    fi
    return 0
  fi
  # Reserve before submitting: uncertain delivery must not cause duplicate
  # input or an unbounded retry loop after a process/watcher crash.
  tmp=$(mktemp "$S/.stall-recovery.XXXXXX")
  jq -n --arg episode "$episode" --argjson attempts "$((attempts + 1))" --argjson time "$time" \
    '{episode:$episode,attempts:$attempts,last:$time,blocked:false}' > "$tmp"
  mv "$tmp" "$S/stall-recovery.json"
  send_text '/goal resume'
)
