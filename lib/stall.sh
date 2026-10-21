#!/usr/bin/env bash
# The single dv-watch owner records observations, never changes job metadata.
# shellcheck disable=SC2016
stall_reconcile() {
  local host=$1 rows=$2 interval=$3 time state tmp row issue event_host head token id
  time=$(now)
  state="$DV_HOME/stalls.json"
  tmp=$(mktemp "$DV_HOME/.stalls.XXXXXX") || return 1
  if [ -f "$state" ]; then
    cat "$state" > "$tmp" || { rm -f "$tmp"; return 1; }
  else printf '{}\n' > "$tmp"; fi
  # Unknown/unreachable agents interrupt timing but retain an emitted episode.
  # A sequence change catches activity between two otherwise idle samples.
  if ! jq --argjson rows "$rows" --arg host "$host" --argjson time "$time" \
    --arg nonce "$time:$$:$RANDOM" --argjson gap "$((interval * 2 + 5))" '
    reduce $rows[] as $row (.;
      ($row.host // $host) as $host |
      ([$host,$row.issue]|tojson) as $key |
      ([$row.started,$row.award_token,$row.herdr_pane]|tojson) as $generation |
      if ($row.issue|type)!="string" or ($row.issue|test("^[A-Za-z0-9][A-Za-z0-9_-]*$")|not) then .
      elif $row.status!="running" or $row.done_at!=null or $row.cleaned_at!=null or $row.goal_active==true or
           ($row.agent_status=="working" or $row.agent_status=="blocked" or $row.agent_status=="done") then del(.[$key])
      elif $row.alive!=true or ($row.agent_status!="idle" and $row.goal_stalled!=true) then
        if .[$key]!=null then .[$key].since=null else . end
      else
        if .[$key]==null or .[$key].generation!=$generation or
           ($row.agent_state_seq!=null and .[$key].seq!=null and .[$key].seq!=$row.agent_state_seq) or
           ($row.agent_session!=null and .[$key].session!=null and .[$key].session!=$row.agent_session) then
          .[$key]={generation:$generation,since:$time,observed:$time,emitted:false,
            id:([$host,$row.issue,"stalled",($row.head // $row.start_head // ""),($row.award_token // ""),$nonce]|join(":"))}
        elif .[$key].since==null or $time < .[$key].observed or $time - .[$key].observed > $gap then
          .[$key].since=$time
        else . end |
        .[$key].seq=($row.agent_state_seq // .[$key].seq) |
        .[$key].session=($row.agent_session // .[$key].session) |
        .[$key].observed=$time | .[$key].row=($row|{issue,head,start_head,award_token}) | .[$key].host=$host
      end)' "$tmp" > "$tmp.next"; then
    rm -f "$tmp" "$tmp.next"; return 1
  fi
  if ! mv "$tmp.next" "$state"; then rm -f "$tmp" "$tmp.next"; return 1; fi
  rm "$tmp"
  # Persist IDs before delivery. If interrupted after append, the queue itself
  # is the acknowledgement and the next scan cannot append the event twice.
  while IFS= read -r row; do
    issue=$(printf '%s\n' "$row" | jq -r .row.issue)
    event_host=$(printf '%s\n' "$row" | jq -r .host)
    head=$(printf '%s\n' "$row" | jq -r '.row.head // .row.start_head // ""')
    token=$(printf '%s\n' "$row" | jq -r '.row.award_token // ""')
    id=$(printf '%s\n' "$row" | jq -r .id)
    if ! jq -se --arg id "$id" 'any(.[]; .id==$id)' "$DV_HOME/kick.q" >/dev/null 2>&1; then
      "$DV_ROOT/bin/dv-kick" stalled "$issue" "Agent idle or Goal stalled for at least $DV_STALL_AFTER seconds; inspect the current pane and log" \
        "$event_host" "$head" "$id" "$token" || continue
    fi
    tmp=$(mktemp "$DV_HOME/.stalls.XXXXXX") || return 1
    if ! jq --arg id "$id" 'with_entries(if .value.id==$id then .value.emitted=true else . end)' "$state" > "$tmp" ||
      ! mv "$tmp" "$state"; then rm -f "$tmp"; return 1; fi
  done < <(jq -c --argjson time "$time" --argjson after "$DV_STALL_AFTER" \
    '.[] | select(.emitted==false and .since!=null and .observed==$time and $time - .since >= $after)' "$state")
}
