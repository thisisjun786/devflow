#!/usr/bin/env bash
# Native exec tests use only temporary repositories, fake agents and local kicks.
# shellcheck disable=SC2154,SC2016
exec_setup() {
  repo exec "${2:-}"
  unset DV_MODE DV_CODEX_MODE
  export DV_HERDR=1 DV_AGENT_CMD_codex='' DV_CODEX_BIN="$ROOT/tests/fixtures/codex-exec" DV_STALL_AFTER=2
  export DV_EXEC_SCENARIO=${1:-success}
}
exec_wait() {
  local i
  for i in {1..200}; do
    if [ -f "$DV_STATE/EX-1/agent.exit" ] && ! dv status EX-1 --json | jq -e '.[0].alive' >/dev/null; then return 0; fi
    sleep 0.05
  done
  cat "$DV_STATE/EX-1/log" >&2
  return 1
}
case_exec_success() {
  exec_setup
  dv start "$REPO" EX-1 exec
  jq -e '.mode=="exec" and .backend=="exec"' "$DV_STATE/EX-1/meta"
  exec_wait
  jq -e '.mode=="exec" and .backend=="exec" and .status=="done"' "$DV_STATE/EX-1/meta"
  jq -se 'length==1 and (.[0].args|index("--json")!=null and index("--dangerously-bypass-approvals-and-sandbox")!=null and index("exec")!=null)' "$DV_STATE/EX-1/stub-runs.jsonl"
  jq -se 'any(.[]; .type=="turn.completed")' "$DV_STATE/EX-1/agent.jsonl"
  test "$(cat "$DV_STATE/EX-1/agent.exit")" = 0
  test ! -e "$CASE_DIR/herdr/calls"
  dv clean EX-1
}
case_exec_config_flags() {
  exec_setup config-flags
  dv start "$REPO" EX-1 exec
  exec_wait
  jq -e '.status=="done"' "$DV_STATE/EX-1/meta"
  dv send EX-1 'Continue with supported exec resume flags'
  exec_wait
  jq -e '.status=="done"' "$DV_STATE/EX-1/meta"
  test "$(cat "$DV_STATE/EX-1/stub-count")" = 2
  grep -Fx 'trust_level = "trusted"' "$HOME/.codex/config.toml"
}
exec_failure() {
  exec_setup "$1"
  dv start "$REPO" EX-1 exec --mode exec
  exec_wait
  test "$(cat "$DV_STATE/EX-1/stub-count")" = 2
  jq -se 'map(.kind)==["failed","blocked"]' "$DV_STATE/EX-1/events.log"
  jq -e '.status=="blocked"' "$DV_STATE/EX-1/meta"
  test ! -f "$DV_STATE/EX-1/done.json"
  dv status EX-1 --json | jq -e '.[0] | (.alive|not) and .agent_status=="blocked"'
}
case_exec_nonzero() { exec_failure nonzero; test "$(cat "$DV_STATE/EX-1/agent.exit")" = 7; }
case_exec_capacity() { exec_failure capacity; }
case_exec_rate() { exec_failure rate; }
case_exec_silence() { exec_failure silence; grep -F stalled "$DV_STATE/EX-1/events.log"; }
case_exec_unfinished() { exec_failure unfinished; grep -F failed-to-finish "$DV_STATE/EX-1/events.log"; }
case_exec_retry() {
  exec_setup retry
  dv start "$REPO" EX-1 exec --mode exec
  exec_wait
  jq -se 'length==2 and (.[1].args|index("resume")!=null and index("fixture-thread")!=null)' "$DV_STATE/EX-1/stub-runs.jsonl"
  jq -se 'map(.kind)==["done"]' "$DV_STATE/EX-1/events.log"
  grep -F 'retrying once' "$DV_STATE/EX-1/log"
  jq -e '.status=="done"' "$DV_STATE/EX-1/meta"
}
case_exec_send() {
  exec_setup
  dv start "$REPO" EX-1 exec --mode exec
  exec_wait
  local s="$DV_STATE/EX-1" wt message='Fix P1: literal $(touch BAD) `echo unsafe`'
  wt=$(jq -r .worktree "$s/meta")
  printf 'dirty\n' > "$wt/dirty"
  printf 'keep\n' > "$s/review-fix.sent"
  dv send EX-1 "$message"
  exec_wait
  jq -se --arg message "$message" 'length==2 and (.[1].args|index("resume")!=null and index("fixture-thread")!=null) and (.[1].args[-1]|startswith($message))' "$s/stub-runs.jsonl"
  test "$(cd "$(jq -sr '.[1].cwd' "$s/stub-runs.jsonl")" && pwd -P)" = "$(cd "$wt" && pwd -P)"
  test -f "$wt/dirty"; test ! -e "$wt/BAD"
  grep -Fx keep "$s/review-fix.sent"
  test ! -e "$CASE_DIR/herdr/calls"
}
case_exec_working() {
  exec_setup hold
  dv start "$REPO" EX-1 exec --mode exec
  wait_file "$DV_STATE/EX-1/stub-runs.jsonl"
  dv status EX-1 --json | jq -e '.[0] | .alive and .agent_status=="working" and (.question_pending|not)'
  if dv send EX-1 'duplicate worker'; then return 1; fi
  touch "$DV_STATE/EX-1/release"
  exec_wait
  test "$(cat "$DV_STATE/EX-1/stub-count")" = 1
}
case_exec_fresh() {
  exec_setup fresh
  dv start "$REPO" EX-1 exec
  exec_wait
  jq -se 'length==2 and (.[1].args|index("resume")==null) and (.[1].args[-1]|contains("original request"))' "$DV_STATE/EX-1/stub-runs.jsonl"
  jq -e '.status=="done"' "$DV_STATE/EX-1/meta"
}
case_exec_partial() {
  exec_setup partial
  dv start "$REPO" EX-1 exec
  exec_wait
  test "$(cat "$DV_STATE/EX-1/stub-count")" = 1
  jq -se 'map(.kind)==["done"]' "$DV_STATE/EX-1/events.log"
  jq -se 'length==4' "$DV_STATE/EX-1/agent.jsonl"
}
case_exec_followup_unfinished() {
  exec_setup
  dv start "$REPO" EX-1 exec
  exec_wait
  cp "$DV_STATE/EX-1/done.json" "$CASE_DIR/old-done"
  export DV_EXEC_SCENARIO=unfinished
  dv send EX-1 'A new request must call done again'
  exec_wait
  test "$(cat "$DV_STATE/EX-1/stub-count")" = 3
  jq -se 'map(.kind)==["done","failed","blocked"]' "$DV_STATE/EX-1/events.log"
  cmp "$CASE_DIR/old-done" "$DV_STATE/EX-1/done.json"
}
case_exec_no_terminal() {
  exec_setup
  cat > "$CASE_DIR/no-terminal" <<'ENV'
command() {
  case "${1:-}:${2:-}" in -v:tmux|-v:herdr) return 1 ;; esac
  builtin command "$@"
}
ENV
  export BASH_ENV="$CASE_DIR/no-terminal" DV_HERDR=0
  dv bid --json --repo "$REPO" --agent codex | jq -e '.status=="submitted"'
  dv start "$REPO" EX-1 exec
  exec_wait
  jq -e '.backend=="exec" and .status=="done"' "$DV_STATE/EX-1/meta"
}
