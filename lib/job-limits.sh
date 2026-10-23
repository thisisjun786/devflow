#!/usr/bin/env bash
# The resource supervisor stays OUTSIDE the agent's scope/ulimit shell.
# shellcheck disable=SC2016,SC2153
job_memory_bytes() {
  local value=$1 number suffix scale=1
  [[ "$value" =~ ^([1-9][0-9]*)([KMGT]?)$ ]] || return 1
  number=${BASH_REMATCH[1]}; suffix=${BASH_REMATCH[2]}
  case "$suffix" in K) scale=1024 ;; M) scale=1048576 ;; G) scale=1073741824 ;; T) scale=1099511627776 ;; esac
  printf '%s\n' "$((number * scale))"
}
job_validate() {
  job_memory_bytes "$DV_JOB_MEMORY_MAX" >/dev/null || fail 'DV_JOB_MEMORY_MAX must be positive bytes or K/M/G/T'
  [[ "$DV_JOB_TASKS_MAX" =~ ^[1-9][0-9]*$ && "$DV_JOB_NPROC_MAX" =~ ^[1-9][0-9]*$ && "$DV_JOB_LAUNCHD_MAX" =~ ^[1-9][0-9]*$ ]] || fail 'job task/process/launchd limits must be positive integers'
  [ "$DV_JOB_MEMORY_SWAP_MAX" = 0 ] || job_memory_bytes "$DV_JOB_MEMORY_SWAP_MAX" >/dev/null || fail 'invalid DV_JOB_MEMORY_SWAP_MAX'
  [ -n "$DV_JOB_LAUNCHD_PATTERN" ] || fail 'DV_JOB_LAUNCHD_PATTERN must not be empty'
}
job_nproc_limit() {
  local current=$1 max=$2 budget=$3 hard=$4 limit cap
  [[ "$current" =~ ^[0-9]+$ && "$max" =~ ^[1-9][0-9]*$ && "$budget" =~ ^[1-9][0-9]*$ ]] || return 1
  limit=$((current + budget)); cap=$((max * 7 / 10))
  [ "$limit" -le "$cap" ] || limit=$cap
  if [[ "$hard" =~ ^[0-9]+$ ]] && [ "$limit" -gt "$hard" ]; then limit=$hard; fi
  [ "$limit" -gt "$current" ] || return 1
  printf '%s\n' "$limit"
}
job_user_count() {
  # RLIMIT_NPROC counts threads on Linux, processes on macOS.
  if [ "$1" = Linux ]; then ps -u "$(id -u)" -L -o lwp=
  else ps -u "$(id -u)" -o pid=; fi | awk 'END {print NR}'
}
job_systemd_available() {
  [ "$(uname -s)" = Linux ] || return 1
  "${JOB_SYSTEMD_RUN:-systemd-run}" --user --scope --quiet \
    -p "MemoryMax=$DV_JOB_MEMORY_MAX" -p "TasksMax=$DV_JOB_TASKS_MAX" \
    -p "MemorySwapMax=$DV_JOB_MEMORY_SWAP_MAX" -p OOMPolicy=kill /bin/true >/dev/null 2>&1
}
job_can_launch() {
  ! jq -e '.blocked==true' "$S/resource-failure.json" >/dev/null 2>&1
}
job_clear_streak() {
  [ -f "$S/resource-failure.json" ] || return 0
  jq '.consecutive=0' "$S/resource-failure.json" > "$S/resource-failure.tmp" && mv "$S/resource-failure.tmp" "$S/resource-failure.json"
}
job_record_failure() {
  local attempt=$1 reason=$2 count=1 blocked=false previous='{}' record
  [ ! -f "$S/resource-failure.json" ] || previous=$(cat "$S/resource-failure.json")
  [ "$(printf '%s' "$previous" | jq -r '.attempt // ""')" != "$attempt" ] || return 0
  if [ "$(printf '%s' "$previous" | jq -r '.reason // ""')" = "$reason" ]; then
    count=$(( $(printf '%s' "$previous" | jq -r '.consecutive // 0') + 1 ))
  fi
  if [ "$count" -ge 2 ] || [ "$reason" = launchd-jobs ]; then blocked=true; fi
  record=$(jq -cn --arg attempt "$attempt" --arg reason "$reason" --argjson count "$count" --argjson blocked "$blocked" --argjson at "$(now)" \
    '{attempt:$attempt,reason:$reason,consecutive:$count,blocked:$blocked,at:$at}')
  printf '%s\n' "$record" > "$S/resource-failure.tmp"
  mv "$S/resource-failure.tmp" "$S/resource-failure.json"
  printf '%s\n' "$record" >> "$S/resource-events.jsonl"
  meta_set --argjson resource "$record" '.resource_failure=$resource | .failure_reason=("resource limit: " + $resource.reason) | if $resource.blocked then .status="blocked" | .exec_status="blocked" else . end'
  printf 'dv: resource limit %s (consecutive=%s)\n' "$reason" "$count" >> "$S/log"
  if [ "$blocked" = true ]; then cmd_kick blocked "$ISSUE" "resource limit $reason; automatic revival stopped (consecutive=$count)"; fi
}
job_attempt() {
  JOB_ATTEMPT="$S/resources/$(now)-$$-$RANDOM"
  mkdir -p "$JOB_ATTEMPT"
  printf '%s\n' "$JOB_ATTEMPT" > "$S/resource-current"
}
job_scope_reason() {
  local key value
  if [ -r "$JOB_CGROUP/memory.events" ]; then
    while read -r key value; do
      if [ "$key" = oom_kill ] && [ "$value" -gt 0 ]; then printf 'MemoryMax-OOM\n'; return; fi
    done < "$JOB_CGROUP/memory.events"
  fi
  if [ -r "$JOB_CGROUP/pids.events" ]; then
    while read -r key value; do
      if [ "$key" = max ] && [ "$value" -gt 0 ]; then printf 'TasksMax\n'; return; fi
    done < "$JOB_CGROUP/pids.events"
  fi
}
job_scope_stop() {
  [ -n "${JOB_UNIT:-}" ] || return 0
  "${JOB_SYSTEMCTL:-systemctl}" --user kill --signal=KILL "$JOB_UNIT" >/dev/null 2>&1 || true
}
job_scope_run() {
  local child rc=0 group memory tasks ready=0 tick reason='' result
  job_attempt
  JOB_UNIT="dv-job-$ISSUE-$(basename "$JOB_ATTEMPT").scope"
  printf '%s\n' "$JOB_UNIT" > "$JOB_ATTEMPT/unit"
  "${JOB_SYSTEMD_RUN:-systemd-run}" --user --scope --quiet --unit="$JOB_UNIT" \
    -p "MemoryMax=$DV_JOB_MEMORY_MAX" -p "TasksMax=$DV_JOB_TASKS_MAX" \
    -p "MemorySwapMax=$DV_JOB_MEMORY_SWAP_MAX" -p OOMPolicy=kill \
    bash -c 'gate=$1; shift; : > "$gate/ready"; for ((n=0;n<100;n++)); do
      if [ -f "$gate/go" ]; then exec "$@"; fi; sleep 0.1
    done; exit 125' bash "$JOB_ATTEMPT" "$@" <&0 & child=$!
  JOB_CHILD=$child
  for ((tick=0;tick<100;tick++)); do
    if [ -f "$JOB_ATTEMPT/ready" ]; then ready=1; break; fi
    kill -0 "$child" 2>/dev/null || break
    sleep 0.1
  done
  if [ "$ready" = 1 ]; then
    group=$("${JOB_SYSTEMCTL:-systemctl}" --user show "$JOB_UNIT" -p ControlGroup --value) || group=''
    JOB_CGROUP="/sys/fs/cgroup$group"
    memory=''; tasks=''
    [ -n "$group" ] && read -r memory < "$JOB_CGROUP/memory.max" && read -r tasks < "$JOB_CGROUP/pids.max" || true
    if [[ "$memory" =~ ^[0-9]+$ && "$tasks" =~ ^[0-9]+$ ]] &&
      [ "$memory" -le "$(job_memory_bytes "$DV_JOB_MEMORY_MAX")" ] && [ "$tasks" -le "$DV_JOB_TASKS_MAX" ]; then
      printf 'MemoryMax=%s TasksMax=%s\n' "$memory" "$tasks" > "$JOB_ATTEMPT/verified"
      touch "$JOB_ATTEMPT/go"
    else
      printf 'dv: scope limits could not be verified; agent not started\n' >&2
      job_scope_stop; wait "$child" 2>/dev/null || true; JOB_CHILD=''; return 125
    fi
  else
    job_scope_stop; wait "$child" 2>/dev/null || true; JOB_CHILD=''; return 125
  fi
  while kill -0 "$child" 2>/dev/null; do
    reason=$(job_scope_reason)
    if [ -n "$reason" ]; then
      printf '%s\n' "$reason" > "$JOB_ATTEMPT/reason"
      job_scope_stop; break
    fi
    sleep 0.2
  done
  wait "$child" || rc=$?
  JOB_CHILD=''
  result=$("${JOB_SYSTEMCTL:-systemctl}" --user show "$JOB_UNIT" -p Result --value 2>/dev/null) || result=''
  if [ "$result" = oom-kill ]; then printf 'MemoryMax-OOM\n' > "$JOB_ATTEMPT/reason"; fi
  # Remove surviving descendants even when the agent returned normally.
  job_scope_stop
  "${JOB_SYSTEMCTL:-systemctl}" --user reset-failed "$JOB_UNIT" >/dev/null 2>&1 || true
  JOB_UNIT=''
  [ ! -f "$JOB_ATTEMPT/reason" ] || rc=137
  return "$rc"
}
job_launchd_scan() {
  local uid=$1 label detail
  # A global before/after delta cannot identify concurrent jobs. Require exact
  # worktree or explicit issue ownership in each launchd service definition.
  launchctl print "gui/$uid" | awk '$1 ~ /^[0-9-]+$/ && NF==3 {print $3}' | while IFS= read -r label; do
    # This configuration deliberately contains a shell glob.
    # shellcheck disable=SC2254
    case "$label" in $DV_JOB_LAUNCHD_PATTERN) ;; *) continue ;; esac
    [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    detail=$(launchctl print "gui/$uid/$label" 2>/dev/null) || continue
    if printf '%s\n' "$detail" | awk -v wt="$WT" -v issue="$ISSUE" '
      {sub(/^[ \t]+/, "")}
      $0=="working directory = "wt || $0=="DV_ISSUE => "issue {found=1}
      END {exit !found}'; then printf '%s\n' "$label"; fi
  done
}
job_launchd_check() {
  local uid=$1 attempt=$2 labels count label
  labels=$(job_launchd_scan "$uid") || { printf 'dv: launchd ownership scan unavailable\n' >&2; return 1; }
  count=$(printf '%s\n' "$labels" | awk 'NF {n++} END {print n+0}')
  printf '%s\n' "$count" > "$S/launchd-count"
  [ "$count" -gt "$DV_JOB_LAUNCHD_MAX" ] || return 0
  job_record_failure "$attempt" launchd-jobs
  if [ -n "${JOB_CHILD:-}" ]; then bid_stop_tree "$JOB_CHILD"; fi
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
  done <<< "$labels"
}
job_fallback_run() {
  local os=$1 uid current max hard limit memory rc=0
  shift
  uid=$(id -u); current=$(job_user_count "$os")
  hard=$(ulimit -H -u)
  if [ "$os" = Darwin ]; then
    max=$(sysctl -n kern.maxprocperuid) || return 125
  elif [[ "$hard" =~ ^[1-9][0-9]*$ ]]; then max=$hard
  else max=2147483647; fi
  limit=$(job_nproc_limit "$current" "$max" "$DV_JOB_NPROC_MAX" "$hard") || {
    printf 'dv: no safe process headroom for agent\n' >&2; return 125;
  }
  job_attempt
  printf 'ulimit -u %s\n' "$limit" > "$JOB_ATTEMPT/limits"
  if [ "$os" = Darwin ]; then job_launchd_check "$uid" "$JOB_ATTEMPT" || return 125; job_can_launch || return 137; fi
  memory=$(( $(job_memory_bytes "$DV_JOB_MEMORY_MAX") / 1024 ))
  (
    ulimit -S -u "$limit" || exit 125
    # macOS does not enforce RLIMIT_AS. Linux fallback is per process only.
    if [ "$os" = Linux ]; then ulimit -S -v "$memory" || exit 125; fi
    exec "$@"
  ) <&0 & JOB_CHILD=$!
  while kill -0 "$JOB_CHILD" 2>/dev/null; do
    if [ "$os" = Darwin ]; then job_launchd_check "$uid" "$JOB_ATTEMPT" || true; fi
    sleep 1
  done
  wait "$JOB_CHILD" || rc=$?
  JOB_CHILD=''
  return "$rc"
}
job_cleanup() {
  job_scope_stop
  if [ -n "${JOB_CHILD:-}" ]; then bid_stop_tree "$JOB_CHILD"; wait "$JOB_CHILD" 2>/dev/null || true; fi
}
job_run_agent() {
  load_issue "$1"
  job_validate
  job_can_launch || { printf 'dv: resource limit blocked; operator intervention required\n' >&2; return 1; }
  local JOB_CHILD='' JOB_UNIT='' JOB_CGROUP='' JOB_ATTEMPT='' rc=0 os reason attempt retries=0 scoped=0
  os=$(uname -s)
  [ "$BACKEND" = exec ] || printf '%s\n' "$$" > "$S/agent.pid"
  trap job_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if job_systemd_available; then scoped=1; fi
  while :; do
  rc=0
  if [ "$scoped" = 1 ]; then
    job_scope_run "$DV_ROOT/bin/dv" _agent-body "$@" || rc=$?
    # Never replay an agent after it started, even if its exit code is 125.
    if [ "$rc" = 125 ] && [ ! -f "$JOB_ATTEMPT/go" ]; then
      printf 'dv: WARNING: systemd scope unavailable; using per-process ulimit fallback\n' >&2
      rc=0
      job_fallback_run "$os" "$DV_ROOT/bin/dv" _agent-body "$@" || rc=$?
    fi
  else
    if [ "$os" = Linux ]; then printf 'dv: WARNING: systemd-run user scope unavailable; using per-process ulimit fallback (no aggregate memory isolation)\n' >&2; fi
    job_fallback_run "$os" "$DV_ROOT/bin/dv" _agent-body "$@" || rc=$?
  fi
  reason=$(cat "$JOB_ATTEMPT/reason" 2>/dev/null) || reason=''
  if [ -n "$reason" ]; then
    attempt=$(basename "$JOB_ATTEMPT")
    job_record_failure "$attempt" "$reason"
    printf '%s\n' "$rc" > "$S/agent.exit"
    if job_can_launch && [ "$retries" = 0 ]; then
      retries=1
      printf 'dv: resource limit %s; retrying once in a fresh scope\n' "$reason" >> "$S/log"
      rm -f "$S/agent.exit"
      continue
    fi
    meta_set '.status="blocked" | .exec_status="blocked"'
    if job_can_launch; then
      # Alternating causes still cannot create an unbounded automatic loop.
      jq '.blocked=true' "$S/resource-failure.json" > "$S/resource-failure.tmp"
      mv "$S/resource-failure.tmp" "$S/resource-failure.json"
      cmd_kick blocked "$ISSUE" "resource limit $reason; automatic resource retry already attempted"
    fi
  elif job_can_launch; then job_clear_streak; fi
  break
  done
  if ! job_can_launch; then rc=137; fi
  # The inner shell may have died before it could publish any exit evidence.
  if [ ! -f "$S/agent.exit" ]; then printf '%s\n' "$rc" > "$S/agent.exit"; fi
  job_cleanup
  trap - EXIT INT TERM
  return "$rc"
}
cmd__job_watch() (
  [ "$(uname -s)" = Darwin ] || return 0
  local path pid
  for path in "$DV_STATE"/*/meta; do
    [ -f "$path" ] || continue
    jq -e '.status=="running" or .status=="pr" or .resource_failure.reason=="launchd-jobs"' "$path" >/dev/null || continue
    load_issue "$(basename "$(dirname "$path")")"
    # The live outer supervisor already scans once a second. This safety pass
    # also catches registrations left behind when that supervisor disappeared.
    pid=$(cat "$S/agent.pid" 2>/dev/null) || pid=''
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then continue; fi
    job_launchd_check "$(id -u)" "watch-$(jq -r .started "$S/meta")" || true
  done
)
job_host_info() {
  local available=false mode=ulimit current max limit=null
  if job_systemd_available; then available=true; mode=systemd-scope; fi
  current=$(job_user_count "$(uname -s)")
  max=$(ulimit -H -u)
  if [ "$(uname -s)" = Darwin ]; then max=$(sysctl -n kern.maxprocperuid) || max=''; fi
  limit=$(job_nproc_limit "$current" "$max" "$DV_JOB_NPROC_MAX" "$(ulimit -H -u)") || limit=null
  jq -cn --argjson available "$available" --arg mode "$mode" --arg memory "$DV_JOB_MEMORY_MAX" --arg tasks "$DV_JOB_TASKS_MAX" \
    --arg swap "$DV_JOB_MEMORY_SWAP_MAX" --argjson current "$current" --argjson nproc "$limit" --arg pattern "$DV_JOB_LAUNCHD_PATTERN" --argjson jobs "$DV_JOB_LAUNCHD_MAX" \
    '{systemd_run_available:$available,mode:$mode,memory_max:$memory,tasks_max:$tasks,memory_swap_max:$swap,user_processes:$current,nproc_limit:$nproc,launchd_pattern:$pattern,launchd_max:$jobs}'
}
