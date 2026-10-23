#!/usr/bin/env bash
# The single dv-watch owner records observations, never changes job metadata.
# ISSUE is assigned by load_issue in common.sh; jq dollars are literal.
# shellcheck disable=SC2016,SC2153
stall_reconcile() {
  local host=$1 rows=$2 interval=$3 time state tmp row issue event_host head token id message
  time=$(now)
  state="$DV_HOME/stalls.json"
  tmp=$(mktemp "$DV_HOME/.stalls.XXXXXX") || return 1
  if [ -f "$state" ]; then
    cat "$state" > "$tmp" || { rm -f "$tmp"; return 1; }
  else printf '{}\n' > "$tmp"; fi
  # A host's status rows can exceed one argument's limit (128 KiB on Linux):
  # pass them as a file, or every reconcile round fails before recovery.
  if ! printf '%s\n' "$rows" > "$tmp.rows"; then rm -f "$tmp" "$tmp.rows"; return 1; fi
  # Unknown/unreachable agents interrupt timing but retain an emitted episode.
  # A sequence change catches activity between two otherwise idle samples.
  if ! jq --slurpfile rows "$tmp.rows" --arg host "$host" --arg source "$host" --argjson time "$time" \
    --arg nonce "$time:$$:$RANDOM" --argjson gap "$((interval * 2 + 5))" '
    reduce $rows[0][] as $row (.;
      ($row.host // $host) as $host |
      ([$host,$row.issue]|tojson) as $key |
      ([$row.started,$row.award_token,$row.herdr_pane]|tojson) as $generation |
      if ($row.issue|type)!="string" or ($row.issue|test("^[A-Za-z0-9][A-Za-z0-9_-]*$")|not) then .
      elif (($row.status=="running" or
             (($row.status=="failed" or $row.status=="waiting-capacity") and $row.agent_dead==true and
              ($row.backend=="tmux" or $row.backend=="herdr")))|not) or
           $row.capacity_detected==true or $row.done_at!=null or $row.cleaned_at!=null or $row.goal_active==true or
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
    rm -f "$tmp" "$tmp.next" "$tmp.rows"; return 1
  fi
  if ! mv "$tmp.next" "$state"; then rm -f "$tmp" "$tmp.next" "$tmp.rows"; return 1; fi
  rm "$tmp" "$tmp.rows"
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
  load_issue "$1"; issue_lock; require_worktree
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
