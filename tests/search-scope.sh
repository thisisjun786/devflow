#!/usr/bin/env bash
# The runner supplies ROOT/RV_STATE; stubs are called through sourced functions.
# shellcheck disable=SC2016,SC2153,SC2329
search_load() {
  unset RIPGREP_CONFIG_PATH DV_RG_MAX_FILESIZE DV_RG_MAX_COLUMNS DV_RG_EXCLUDE_GLOBS
  DV_ROOT=$ROOT
  # Keep this focused fixture out of the full common.sh source graph (#305).
  # shellcheck source=config.example.sh
  source "$ROOT/config.example.sh"
  # shellcheck source=lib/search.sh
  source "$ROOT/lib/search.sh"
  # shellcheck source=lib/job-limits.sh
  source "$ROOT/lib/job-limits.sh"
  S="$CASE_DIR/search-state"
  mkdir -p "$S"
}
search_commands_load() {
  # shellcheck source=lib/commands.sh
  source "$ROOT/lib/commands.sh"
}
case_search_defaults() {
  search_load
  search_environment
  test -f "$RIPGREP_CONFIG_PATH"
  grep -Fx -- '--max-filesize=20M' "$RIPGREP_CONFIG_PATH"
  grep -Fx -- '--max-columns=4000' "$RIPGREP_CONFIG_PATH"
  local path
  for path in .codex .hermes .claude .grok .local/state .cache node_modules .git/objects; do
    grep -Fx -- "--glob=!**/$path/**" "$RIPGREP_CONFIG_PATH"
  done
  bash -c 'test -f "$RIPGREP_CONFIG_PATH"'
}
case_search_override() {
  search_load
  RIPGREP_CONFIG_PATH="$CASE_DIR/user rg"
  printf '%s\n' '--max-filesize=1M' > "$RIPGREP_CONFIG_PATH"
  search_environment
  test "$RIPGREP_CONFIG_PATH" = "$CASE_DIR/user rg"
  test "$(cat "$RIPGREP_CONFIG_PATH")" = '--max-filesize=1M'
  bash -c 'test "$RIPGREP_CONFIG_PATH" = "$CASE_DIR/user rg"'
  RIPGREP_CONFIG_PATH=''
  search_environment
  test -z "$RIPGREP_CONFIG_PATH"
  unset RIPGREP_CONFIG_PATH
  DV_RG_MAX_FILESIZE=3M; DV_RG_MAX_COLUMNS=200; DV_RG_EXCLUDE_GLOBS='!**/vendor/**'
  search_environment
  grep -Fx -- '--max-filesize=3M' "$RIPGREP_CONFIG_PATH"
  grep -Fx -- '--max-columns=200' "$RIPGREP_CONFIG_PATH"
  grep -Fx -- '--glob=!**/vendor/**' "$RIPGREP_CONFIG_PATH"
}
case_search_large() (
  search_load
  search_environment
  # Large test data stays inside this checkout, even when CASE_DIR is elsewhere.
  local data
  data=$(mktemp -d "$ROOT/.search-test.XXXXXX")
  trap 'rm -rf "$data"' EXIT
  printf 'search-needle\n' > "$data/small.txt"
  dd if=/dev/zero of="$data/large.txt" bs=1048576 count=21 2>/dev/null
  printf '\nsearch-needle\n' >> "$data/large.txt"
  mkdir -p "$data/node_modules" "$data/.codex"
  printf 'search-needle\n' > "$data/node_modules/hidden.txt"
  printf 'search-needle\n' > "$data/.codex/hidden.txt"
  rg --text --hidden -l search-needle "$data" > "$CASE_DIR/matches"
  test "$(cat "$CASE_DIR/matches")" = "$data/small.txt"
  # Establish that the fixture would otherwise match, including the big file.
  rg --no-config --text --hidden -l search-needle "$data" > "$CASE_DIR/unrestricted"
  test "$(wc -l < "$CASE_DIR/unrestricted" | tr -d ' ')" = 4
)
case_search_tmux() {
  needs_tmux; repo search
  unset RIPGREP_CONFIG_PATH
  tmux -L "$DV_TMUX_SOCKET" new-session -d -s preexisting 'sleep 60'
  export RIPGREP_CONFIG_PATH="$CASE_DIR/custom rg"
  printf '%s\n' '--max-filesize=2M' > "$RIPGREP_CONFIG_PATH"
  export DV_AGENT_CMD_codex='printf "%s\n" "$RIPGREP_CONFIG_PATH" > "$DV_STATE/$DV_ISSUE/search-env"; exec "$ROOT/tests/fixtures/agent"'
  start SEARCH-1; wait_done SEARCH-1
  test "$(cat "$DV_STATE/SEARCH-1/search-env")" = "$RIPGREP_CONFIG_PATH"
}
case_search_agents() {
  search_load
  # Exercise the shared launcher with each agent's command override, no live CLI.
  search_commands_load
  local agent output
  load_issue() { :; }; require_worktree() { :; }; stop_question_sentinel() { :; }
  herdr_question_sentinel() { :; }; capacity_terminal_stop() { :; }
  capacity_terminal_run() { shift; "$@"; }
  WT="$CASE_DIR"; ISSUE=SEARCH-1; KIND=code; BACKEND=herdr
  for agent in grok codex claude omp cursor agy; do
    unset RIPGREP_CONFIG_PATH
    printf -v "DV_AGENT_CMD_$agent" '%s' 'test -f "$RIPGREP_CONFIG_PATH"; grep -Fx -- --max-filesize=20M "$RIPGREP_CONFIG_PATH"'
    jq -n --arg agent "$agent" '{agent:$agent,mode:"goal",status:"parked"}' > "$S/meta"
    output=$(run_agent SEARCH-1)
    test "$output" = '--max-filesize=20M'
  done
}
case_job_oom_evidence() {
  job_test_load
  job_attempt
  JOB_UNIT=dv-job-LIMIT-1-target.scope
  cat > "$S/kernel" <<'KERNEL'
oom-kill:constraint=CONSTRAINT_MEMCG,oom_memcg=/user.slice/dv-job-LIMIT-1-other.scope,task_memcg=/user.slice/dv-job-LIMIT-1-other.scope,task=other,pid=200,uid=1000
Memory cgroup out of memory: Killed process 200 (other) total-vm:99999999kB, anon-rss:9999999kB, file-rss:0kB
oom-kill:constraint=CONSTRAINT_MEMCG,oom_memcg=/user.slice/dv-job-LIMIT-1-target.scope,task_memcg=/user.slice/dv-job-LIMIT-1-target.scope,task=node,pid=201,uid=1000
Memory cgroup out of memory: Killed process 201 (node) total-vm:9000000kB, anon-rss:102400kB, file-rss:0kB
oom-kill:constraint=CONSTRAINT_MEMCG,oom_memcg=/user.slice/dv-job-LIMIT-1-target.scope,task_memcg=/user.slice/dv-job-LIMIT-1-target.scope/subgroup,task=rg,pid=202,uid=1000
Memory cgroup out of memory: Killed process 202 (rg) total-vm:9000000kB, anon-rss:5980160kB, file-rss:0kB
KERNEL
  journalctl() { printf '%s\n' "$*" > "$S/journal-args"; cat "$S/kernel"; }
  job_collect_oom
  job_record_failure "$(basename "$JOB_ATTEMPT")" MemoryMax-OOM
  jq -se 'length==1 and .[0].reason=="MemoryMax-OOM" and .[0].top=="rg" and .[0].rss_mb==5840' "$S/resource-events.jsonl"
  grep -F -- '--since @' "$S/journal-args"
  job_attempt
  journalctl() { return 1; }
  job_collect_oom
  job_record_failure "$(basename "$JOB_ATTEMPT")" MemoryMax-OOM
  jq -e '.top==null and .rss_mb==null and .blocked' "$S/resource-failure.json"
}
case_search_oom_retry() {
  search_load
  search_commands_load
  load_issue() { :; }; require_worktree() { :; }; codex_exec_run() { printf '%s\n' "$1"; }
  WT="$CASE_DIR"; ISSUE=SEARCH-1; KIND=code; BACKEND='exec'
  printf '{"agent":"codex","mode":"exec"}\n' > "$S/meta"
  printf '{"reason":"MemoryMax-OOM","top":"rg","rss_mb":5840}\n' > "$S/resource-failure.json"
  run_agent SEARCH-1 > "$CASE_DIR/prompt"
  grep -F '직전 OOM: rg' "$CASE_DIR/prompt"
  grep -F '같은 범위 검색 금지' "$CASE_DIR/prompt"
}
case_search_oom_revive() {
  revive_setup; revive_dead
  printf '{"reason":"MemoryMax-OOM","top":"rg","rss_mb":5840,"blocked":false}\n' > "$RV_STATE/resource-failure.json"
  dv send RV-1 'continue after memory limit'
  revive_wait
  grep -F '직전 OOM: rg' "$RV_STATE/revive/prompt.md"
  grep -F '같은 범위 검색 금지' "$RV_STATE/revive/prompt.md"
}
