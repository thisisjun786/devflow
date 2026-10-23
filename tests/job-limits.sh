#!/usr/bin/env bash
# Bounded agents only: live cases refuse to run without verified cgroup limits.
# shellcheck disable=SC2016
job_test_load() {
  DV_ROOT=$ROOT
  # shellcheck source=lib/job-limits.sh
  source "$ROOT/lib/job-limits.sh"
  # shellcheck source=config.example.sh
  source "$ROOT/config.example.sh"
  S="$CASE_DIR/job"; ISSUE=LIMIT-1; WT="$CASE_DIR/worktree"
  mkdir -p "$S" "$WT"
  printf '{"status":"running"}\n' > "$S/meta"
  now() { date +%s; }
  meta_set() { jq "$@" "$S/meta" > "$S/meta.tmp" && mv "$S/meta.tmp" "$S/meta"; }
  cmd_kick() { printf '%s\n' "$*" >> "$S/kicks"; }
}
case_job_nproc() {
  job_test_load
  test "$(job_nproc_limit 300 5333 1000 unlimited)" = 1300
  test "$(job_nproc_limit 3300 5333 1000 unlimited)" = 3733
  test "$(job_nproc_limit 300 5333 1000 900)" = 900
  if job_nproc_limit 3800 5333 1000 unlimited; then return 1; fi
  if job_nproc_limit 300 unknown 1000 unlimited; then return 1; fi
}
case_job_failure() {
  job_test_load
  job_record_failure first TasksMax
  jq -e '.reason=="TasksMax" and .consecutive==1 and .blocked==false' "$S/resource-failure.json"
  job_record_failure first TasksMax
  jq -e '.consecutive==1' "$S/resource-failure.json"
  job_record_failure second TasksMax
  jq -e '.consecutive==2 and .blocked==true' "$S/resource-failure.json"
  grep 'blocked LIMIT-1.*TasksMax' "$S/kicks"
  if job_can_launch; then return 1; fi
}
case_job_failure_reset() {
  job_test_load
  job_record_failure first TasksMax
  job_record_failure second MemoryMax-OOM
  jq -e '.consecutive==1 and .reason=="MemoryMax-OOM"' "$S/resource-failure.json"
  job_clear_streak
  job_record_failure third MemoryMax-OOM
  jq -e '.consecutive==1' "$S/resource-failure.json"
}
case_job_supervisor_retry() {
  job_test_load
  local BACKEND=exec attempts=0 rc=0
  load_issue() { :; }
  job_systemd_available() { return 0; }
  job_scope_run() { attempts=$((attempts + 1)); job_attempt; printf 'TasksMax\n' > "$JOB_ATTEMPT/reason"; return 137; }
  job_run_agent LIMIT-1 || rc=$?
  test "$rc" = 137
  test "$attempts" = 2
  jq -e '.reason=="TasksMax" and .consecutive==2 and .blocked' "$S/resource-failure.json"
  test "$(cat "$S/agent.exit")" = 137
  job_run_agent LIMIT-1 || rc=$?
  test "$attempts" = 2
  test "$(wc -l < "$S/kicks" | tr -d ' ')" = 1
}
case_job_generic_exit() {
  job_test_load
  local BACKEND=exec rc=0
  load_issue() { :; }
  job_systemd_available() { return 0; }
  job_scope_run() { job_attempt; return 137; }
  job_run_agent LIMIT-1 || rc=$?
  test "$rc" = 137
  test ! -f "$S/resource-failure.json"
}
case_job_auto_exec() {
  job_test_load
  # shellcheck source=lib/appserver.sh
  source "$ROOT/lib/appserver.sh"
  appserver_available() { return 0; }
  DV_AGENT_CMD_codex=''; DV_CODEX_MODE=auto
  if appserver_selected codex auto; then return 1; fi
  DV_CODEX_MODE=appserver
  if appserver_selected codex auto; then return 1; fi
}
case_job_host() {
  host_setup
  export DV_JOB_MEMORY_MAX=4G DV_JOB_TASKS_MAX=700 DV_JOB_LAUNCHD_PATTERN='org.example.*'
  "$HOST_DV" host check --json > "$CASE_DIR/limits.json"
  jq -e '.job_limits | .systemd_run_available==false and .mode=="ulimit" and .memory_max=="4G" and .tasks_max=="700" and .launchd_pattern=="org.example.*" and .launchd_max==200 and .nproc_limit>.user_processes' "$CASE_DIR/limits.json"
}
case_job_fallback() {
  job_test_load
  [ "$(uname -s)" = Linux ] || return 77
  local before after fallback_current expected JOB_CHILD='' JOB_ATTEMPT=''
  before=$(ulimit -S -u)
  fallback_current=$(job_user_count Linux)
  # Keep ample headroom despite other tests starting threads concurrently.
  fallback_current=$((fallback_current + 2000))
  job_user_count() { printf '%s\n' "$fallback_current"; }
  DV_JOB_MEMORY_MAX=64M
  expected=$(job_nproc_limit "$fallback_current" "$(ulimit -H -u)" "$DV_JOB_NPROC_MAX" "$(ulimit -H -u)")
  job_fallback_run Linux bash -c 'ulimit -S -u > "$1/nproc"; ulimit -S -v > "$1/memory"' bash "$S"
  after=$(ulimit -S -u)
  test "$before" = "$after"
  test "$(cat "$S/nproc")" = "$expected"
  test "$(cat "$S/memory")" = 65536
}
case_job_launchd() {
  job_test_load
  DV_JOB_LAUNCHD_PATTERN='org.example.*'; DV_JOB_LAUNCHD_MAX=2
  launchctl() {
    case "$*" in
      'print gui/123') printf 'services = {\n  1 0 org.example.ours1\n  2 0 org.example.ours2\n  3 0 org.example.ours3\n  4 0 org.example.other\n}\n' ;;
      'print gui/123/org.example.ours'*) printf 'working directory = %s\n' "$WT" ;;
      'print gui/123/org.example.other') printf 'working directory = /some/other/job\n' ;;
      bootout*) printf '%s\n' "$*" >> "$S/bootouts" ;;
      *) return 1 ;;
    esac
  }
  job_launchd_scan 123 > "$S/owned"
  test "$(wc -l < "$S/owned" | tr -d ' ')" = 3
  ! grep other "$S/owned"
  job_launchd_check 123 attempt
  jq -e '.reason=="launchd-jobs" and .blocked' "$S/resource-failure.json"
  test "$(wc -l < "$S/bootouts" | tr -d ' ')" = 3
  ! grep other "$S/bootouts"
}
job_live() {
  job_test_load
  [ "$(uname -s)" = Linux ] || return 77
  # Resolve outside fixtures; ordinary lifecycle tests never create real scopes.
  JOB_SYSTEMD_RUN=$(PATH=/usr/bin:/bin command -v systemd-run) || return 77
  JOB_SYSTEMCTL=$(PATH=/usr/bin:/bin command -v systemctl) || return 77
  export JOB_SYSTEMD_RUN JOB_SYSTEMCTL
  DV_JOB_MEMORY_MAX=64M; DV_JOB_TASKS_MAX=16; DV_JOB_MEMORY_SWAP_MAX=0
  job_systemd_available || return 77
  sleep 60 & local sibling=$!
  local rc=0
  job_scope_run "$ROOT/tests/fixtures/resource-agent" "$1" || rc=$?
  kill -0 "$sibling"
  kill "$sibling"; wait "$sibling" 2>/dev/null || true
  test "$rc" != 0
  grep -Fx "$2" "$JOB_ATTEMPT/reason"
  test -s "$JOB_ATTEMPT/verified"
  if [ -r "$JOB_CGROUP/cgroup.procs" ]; then test -z "$(cat "$JOB_CGROUP/cgroup.procs")"; fi
}
case_job_tasks() { job_live tasks TasksMax; }
case_job_memory() { job_live memory MemoryMax-OOM; }
case_job_agent_retry() {
  needs_tmux
  job_test_load
  [ "$(uname -s)" = Linux ] || return 77
  JOB_SYSTEMD_RUN=$(PATH=/usr/bin:/bin command -v systemd-run) || return 77
  export DV_JOB_MEMORY_MAX=64M DV_JOB_TASKS_MAX=32 DV_JOB_MEMORY_SWAP_MAX=0
  job_systemd_available || return 77
  mkdir "$CASE_DIR/resource-bin"
  ln -s "$JOB_SYSTEMD_RUN" "$CASE_DIR/resource-bin/systemd-run"
  export PATH="$CASE_DIR/resource-bin:$PATH"
  export DV_AGENT_CMD_codex="$ROOT/tests/fixtures/resource-agent tasks"
  repo resource-limit
  dv start "$REPO" LIMIT-1 limit --mode goal
  local i
  for ((i=0;i<300;i++)); do
    if [ -f "$DV_STATE/LIMIT-1/agent.exit" ] && jq -e '.blocked' "$DV_STATE/LIMIT-1/resource-failure.json" >/dev/null 2>&1; then break; fi
    sleep 0.1
  done
  jq -e '.reason=="TasksMax" and .consecutive==2 and .blocked' "$DV_STATE/LIMIT-1/resource-failure.json"
  jq -se 'length==2' "$DV_STATE/LIMIT-1/resource-events.jsonl"
  jq -se 'any(.[]; .kind=="blocked" and (.message|contains("TasksMax")))' "$DV_STATE/LIMIT-1/events.log"
  if dv send LIMIT-1 'do not restart'; then return 1; fi
  jq -se 'length==2' "$DV_STATE/LIMIT-1/resource-events.jsonl"
}
