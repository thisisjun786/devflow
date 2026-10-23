#!/usr/bin/env bash
# Bounded, watcher-owned host jobs. No network operation runs in the queue reader.
# stall_scan_interval is computed by dv-watch from the configured scan cadence.
# shellcheck disable=SC2154
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
    if printf '%s\n' "$rows" | jq -e "any(.[]; $pr_reconcile_filter)" >/dev/null; then
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
    bid_rpc "$host" _appserver-watch < /dev/null || true
  fi
}
