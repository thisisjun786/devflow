#!/usr/bin/env bash
# Bounded, watcher-owned host jobs. No network operation runs in the queue reader.
# stall_scan_interval is computed by dv-watch from the configured scan cadence.
# shellcheck disable=SC2154,SC2153
# shellcheck disable=SC2016
# Reuse the host's detached PR sweep for issue lookups and worker shutdown.
issue_reconcile_filter='((.kind // "code")=="code" and .cleaned_at==null and
  (.status=="running" or .status=="waiting-capacity" or .status=="input-required" or
   .status=="pr" or .status=="ready" or .status=="waiting-base"))'
issue_reconcile_stop() {
  local pid command deadline
  if [ "$BACKEND" = appserver ]; then
    appserver_require_stopped
    if appserver_alive; then kill -TERM "$(cat "$S/appserver/client.pid")" || return 1; fi
    deadline=$(( $(now) + DV_APPSERVER_TIMEOUT ))
    while appserver_alive; do
      [ "$(now)" -lt "$deadline" ] || return 1
      sleep 0.1
    done
    return 0
  fi
  pid=$(cat "$S/agent.pid" 2>/dev/null) || pid=''
  if [ -n "$pid" ]; then
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ "$pid" -gt 1 ] || return 1
    if kill -0 "$pid" 2>/dev/null && [ "$(ps -p "$pid" -o stat= 2>/dev/null | cut -c 1)" != Z ]; then
      command=$(ps -p "$pid" -o args=) || return 1
      case "$command" in
        *"/bin/dv _agent $ISSUE"|*"/bin/dv _agent $ISSUE "*) kill -TERM "$pid" || return 1 ;;
        *) return 1 ;;
      esac
      # The resource supervisor reaps its scope/tree before it exits.
      deadline=$(( $(now) + DV_START_WAIT ))
      while kill -0 "$pid" 2>/dev/null && [ "$(ps -p "$pid" -o stat= 2>/dev/null | cut -c 1)" != Z ]; do
        [ "$(now)" -lt "$deadline" ] || return 1
        sleep 0.1
      done
    fi
  fi
  case "$BACKEND" in
    tmux) tmux_dv kill-session -t "=$SESSION" 2>/dev/null || true ;;
    herdr) herdr_interrupt || return 1 ;;
  esac
}
cmd_issue_reconcile() {
  [ "$#" = 1 ] || fail 'usage: dv _issue-reconcile ISSUE'
  load_issue "$1"
  jq -e "$issue_reconcile_filter" "$S/meta" >/dev/null || return 0
  is_github || return 0
  # Serialize against pr, send and land, then re-read current metadata.
  mkdir "$S/.operation" 2>/dev/null || return 0
  trap 'rmdir "$S/.operation" 2>/dev/null || true' EXIT
  jq -e "$issue_reconcile_filter" "$S/meta" >/dev/null || return 0
  local slug number state prs linked head pr
  slug=$(manager_identity "$REPO"); slug=${slug#github.com/}
  number=$(jq -r '.source_issue // empty | tostring' "$S/meta")
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || number=${ISSUE##*-}
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || return 0
  state=$(autofill_api api "repos/$slug/issues/$number") || return 1
  jq -e '.state=="closed" and .pull_request==null' <<< "$state" >/dev/null || return 0
  # Our own merged PR belongs to the existing landing reconciliation, even
  # when its checks/cleanup need a retry or a live waiter still observes it.
  if [ -f "$S/pr.json" ]; then
    pr=$(jq -er .url "$S/pr.json") || return 1
    state=$(cd "$REPO" && autofill_api pr view "$pr" --json state) || return 1
    jq -e '.state=="OPEN" or .state=="CLOSED" or .state=="MERGED"' <<< "$state" >/dev/null || return 1
    if jq -e '.state=="MERGED"' <<< "$state" >/dev/null; then return 0; fi
  fi
  # Query the branch as well as saved PR metadata: PR creation may have
  # succeeded just before the worker could record its URL. Failures defer.
  prs=$(autofill_api api --method GET --paginate "repos/$slug/pulls" \
    -f state=open -f "head=${slug%%/*}:$BRANCH" -f per_page=100) || return 1
  jq -es 'length>0 and all(.[]; type=="array")' <<< "$prs" >/dev/null || return 1
  linked=$(jq -s --arg repo "$slug" --arg number "$number" '
    [ .[][] | .body // "" |
      scan("(?i)\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\\s+(?:https://github.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/issues/|([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#)([1-9][0-9]*)\\b") |
      select(((.[0] // .[1] // $repo)|ascii_downcase)==$repo and .[2]==$number)
    ] | length>0' <<< "$prs") || return 1
  [ "$linked" != true ] || return 0
  require_worktree
  [ "$BRANCH" != "$BASE" ] || fail 'cannot push the base branch'
  issue_reconcile_stop || fail 'issue closed but worker stop is unconfirmed; retained for retry'
  # Preserve dirty files in place; only existing commits go to the remote.
  git -C "$WT" push origin "$BRANCH:refs/heads/$BRANCH" || return 1
  head=$(git -C "$WT" rev-parse HEAD)
  meta_set --arg head "$head" --argjson time "$(now)" \
    '.status="closed" | .reason="issue closed" | .closed_at=$time | .head=$head'
  cmd_kick closed "$ISSUE" 'issue closed'
}
reconcile_submissions() (
  local host=$1 rows=$2 row issue dir
  [ "$DV_HOST" = "$DV_MANAGER_HOST" ] || return 0
  bid_lock "$DV_HOME/.schedule-lock" "${BASHPID:-$$}" || return 1
  trap 'owned_unlock "$DV_HOME/.schedule-lock" "${BASHPID:-$$}"' EXIT
  while IFS= read -r row; do
    issue=$(jq -r .issue <<< "$row")
    [[ "$issue" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || continue
    dir="$DV_HOME/submissions/$issue"
    [ -f "$dir/task.json" ] || continue
    # A status row can exceed one argument's limit (128 KiB on Linux; a landed
    # appserver job's turn dump reached 286 KB on 10-24): pass it as a file.
    printf '%s\n' "$row" > "$dir/.job-row" || return 1
    bid_task_set "$dir" --arg host "$host" --slurpfile jobs "$dir/.job-row" '
      $jobs[0] as $job |
      if (.status=="working" or .status=="input-required" or (.status=="submitted" and .host!=null)) and
        .host==$host and ($job.host // $host)==$host and
        ((.token // "")==($job.award_token // "")) then
        .status=(if $job.status=="landed" then "completed" elif $job.status=="closed" then "canceled" else "failed" end) |
        .head=($job.head // .head) |
        (if $job.reason!=null then .reason=$job.reason else del(.reason) end)
      else . end' || { rm -f "$dir/.job-row"; return 1; }
    rm -f "$dir/.job-row"
  done < <(jq -c '.[] | select(.status=="closed" or .status=="failed" or .status=="landed")' <<< "$rows")
)
reconcile_dir() { printf '%s/reconcile/%s\n' "$DV_HOME" "$(printf '%s' "$1" | cksum | awk '{print $1 "-" $2}')"; }
reconcile_alive() {
  local pid=$1 host=$2
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null &&
    ps -o args= -p "$pid" 2>/dev/null | grep -Fq -- "dv _reconcile-host $host "
}
reconcile_request() {
  local host dir
  for host in $(printf '%s\n' "$DV_HOST $DV_HOSTS" | tr ' ' '\n' | sort -u); do
    dir=$(reconcile_dir "$host"); mkdir -p "$dir"
    touch "$dir/requested"
  done
}
reconcile_start() {
  local host dir pid at status_due recovery_due last_status last_recovery
  at=$(now)
  for host in $(printf '%s\n' "$DV_HOST $DV_HOSTS" | tr ' ' '\n' | sort -u); do
    dir=$(reconcile_dir "$host"); mkdir -p "$dir"
    pid=$(cat "$dir/pid" 2>/dev/null) || pid=''
    if reconcile_alive "$pid" "$host"; then continue; fi
    [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
    last_status=$(cat "$dir/status-at" 2>/dev/null) || last_status=0
    last_recovery=$(cat "$dir/recovery-at" 2>/dev/null) || last_recovery=0
    status_due=0; recovery_due=0
    if [ $((at - last_status)) -ge "$stall_scan_interval" ]; then status_due=1; fi
    if [ -f "$dir/requested" ] && [ ! -f "$dir/timed-out" ]; then status_due=1; fi
    if [ $((at - last_recovery)) -ge "$DV_APPSERVER_POLL" ]; then recovery_due=1; fi
    case " $DV_HOSTS " in *" $host "*) ;; *) recovery_due=0 ;; esac
    [ "$status_due:$recovery_due" != 0:0 ] || continue
    if [ "$status_due" = 1 ]; then rm -f "$dir/requested" "$dir/timed-out"; fi
    [ "$status_due" = 0 ] || printf '%s\n' "$at" > "$dir/status-at"
    [ "$recovery_due" = 0 ] || printf '%s\n' "$at" > "$dir/recovery-at"
    "$DV_ROOT/bin/dv" _reconcile-host "$host" "$stall_scan_interval" "$status_due" "$recovery_due" >> "$DV_HOME/reconcile.log" 2>&1 &
    printf '%s\n' "$!" > "$dir/pid"
  done
}
reconcile_stop() {
  local host dir pid
  for host in $(printf '%s\n' "$DV_HOST $DV_HOSTS" | tr ' ' '\n' | sort -u); do
    dir=$(reconcile_dir "$host")
    pid=$(cat "$dir/pid" 2>/dev/null) || continue
    if reconcile_alive "$pid" "$host"; then bid_stop_tree "$pid"; fi
    wait "$pid" 2>/dev/null || true
    rm -f "$dir/pid"
  done
}
cmd__reconcile_host() {
  [ "$#" = 4 ] || fail 'usage: dv _reconcile-host HOST INTERVAL STATUS RECOVERY'
  local rc=0
  # The deadline covers status AND its follow-up RPCs. Descendants cannot keep
  # SSH pipes or the host slot alive after timeout. No retry within this round.
  bid_limit "$DV_STATUS_TIMEOUT" reconcile_host "$@" || rc=$?
  if [ "$rc" = 137 ]; then
    touch "$(reconcile_dir "$1")/timed-out"
    printf 'reconcile host=%s timeout after %ss; skipped this round\n' "$1" "$DV_STATUS_TIMEOUT"
  elif [ "$rc" != 0 ]; then printf 'reconcile host=%s failed (exit %s); skipped this round\n' "$1" "$rc"; fi
}
reconcile_host() {
  local host=$1 interval=$2 status_due=$3 recovery_due=$4 rows row issue head id event_host token recovered dir
  dir=$(reconcile_dir "$host")
  owned_lock "$dir/.run" "$$" || return 1
  trap 'owned_unlock "$dir/.run" "$$"' EXIT
  if [ "$status_due" = 1 ]; then
    rows=$(bid_rpc "$host" status --json < /dev/null) || return 1
    printf '%s\n' "$rows" | jq -e 'type=="array"' >/dev/null || return 1
    reconcile_submissions "$host" "$rows" || return 1
    # Keep the existing shared stall/metrics episode file serialized. Lock
    # contention and recovery RPCs wait only in this bounded background job.
    (
      owned_lock "$DV_HOME/.stall-reconcile" "$$" || exit 1
      trap 'owned_unlock "$DV_HOME/.stall-reconcile" "$$"' EXIT
      stall_reconcile "$host" "$rows" "$interval"
    ) || return 1
    stack_queue_host "$host" "$rows" || return 1
    # PRs merged or closed outside dv land: one quick RPC starts the job
    # host's detached sweep, which this pass's deadline cannot interrupt.
    if printf '%s\n' "$rows" | jq -e "any(.[]; ($pr_reconcile_filter) or ($issue_reconcile_filter))" >/dev/null; then
      bid_rpc "$host" _pr-reconcile-start < /dev/null || true
    fi
    while IFS= read -r issue; do
      [[ "$issue" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || continue
      bid_rpc "$host" _pr-wait-start "$issue" < /dev/null || true
    done < <(printf '%s\n' "$rows" | jq -r '.[] | select(.status=="pr") | .issue')
    while IFS= read -r row; do
      issue=$(printf '%s' "$row" | jq -r .issue)
      head=$(printf '%s' "$row" | jq -r '.head // .start_head // ""')
      event_host=$(printf '%s' "$row" | jq -r --arg host "$host" '.host // $host')
      token=$(printf '%s' "$row" | jq -r '.award_token // ""')
      recovered=$(event_json 'done' "$issue" 'Recovered by status safety net' "$event_host" "$head" '' "$token")
      id=$(printf '%s' "$recovered" | jq -r .id)
      if ! jq -se --arg id "$id" 'any(.[]; .id==$id)' "$DV_HOME/kick.q" >/dev/null 2>&1; then
        "$DV_ROOT/bin/dv-kick" 'done' "$issue" 'Recovered by status safety net' "$event_host" "$head" "$id" "$token"
      fi
    done < <(printf '%s\n' "$rows" | jq -c '.[] | select(.status=="done" or
      ((.status=="pr" or .status=="ready") and .done_at!=null and
       .head!=null and .head!="" and .done_head==.head))')
  fi
  if [ "$recovery_due" = 1 ]; then
    bid_rpc "$host" _job-watch < /dev/null || true
    bid_rpc "$host" _appserver-watch < /dev/null || true
  fi
}
