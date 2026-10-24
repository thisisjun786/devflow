#!/usr/bin/env bash
# Isolated fake headless workers; no provider requests or real PRs.
# shellcheck disable=SC2016
dsh_setup() {
  repo dsh "${2:-}"
  export DV_DSH_BIN="$ROOT/tests/fixtures/dsh" DV_DSH_SCENARIO=${1:-success} DV_DSH_JAIL=off
  export DV_DSH_HOME="$HOME/.dsh-dv" DV_DSH_KEY_FILE="$HOME/dsh.env" DV_DSH_KEY_VAR=INFERHUB_API_KEY
  export DV_DSH_SESSIONS="$DV_DSH_HOME/sessions"
  unset DV_DSH_TOOL_MAX
  export DV_AGENT_CMD_omp="$ROOT/tests/fixtures/dsh-omp" DV_MIN_DISK_GB=0
  mkdir -p "$DV_DSH_HOME/profiles/headless" "$CASE_DIR/dsh-bin"
  printf '# profile\n' > "$DV_DSH_HOME/profiles/headless/cordis.patch.yml"
  printf 'export INFERHUB_API_KEY="fixture-dsh-secret"\ntouch "$HOME/key-was-sourced"\n' > "$DV_DSH_KEY_FILE"
  printf '#!/usr/bin/env bash\nprintf "v24.20.0\\n"\n' > "$CASE_DIR/dsh-bin/node"
  chmod +x "$CASE_DIR/dsh-bin/node"
  export PATH="$CASE_DIR/dsh-bin:$PATH"
}
dsh_start_wait() {
  dv start "$REPO" DS-1 dsh --agent dsh
  exec_wait DS-1
}
case_dsh_success() {
  dsh_setup
  dsh_start_wait
  jq -e '.agent=="dsh" and .backend=="exec" and .exec_status=="done"' "$DV_STATE/DS-1/meta"
  jq -se 'length==1 and .[0].args==["--profile","headless","--json","-"]' "$DV_STATE/DS-1/dsh-runs.jsonl"
  test "$(cat "$DV_STATE/DS-1/agent.session")" = dsh-session-1
  dv send DS-1 'One more turn'
  exec_wait DS-1
  jq -se 'length==2 and (.[1].args|index("--session-id")!=null) and .[1].cwd==.[0].cwd' "$DV_STATE/DS-1/dsh-runs.jsonl"
  dv clean DS-1
}
case_dsh_restart() {
  dsh_setup restart
  dsh_start_wait
  jq -se 'length==2 and all(.[]; (.args|index("--session-id"))==null) and (.[1].instruction|contains("wip=committed"))' "$DV_STATE/DS-1/dsh-runs.jsonl"
  test -z "$(git -C "$(jq -r .worktree "$DV_STATE/DS-1/meta")" status --porcelain)"
}
case_dsh_fallback() {
  needs_tmux
  dsh_setup unfinished
  dsh_start_wait
  jq -e '.agent=="omp" and .fallback_from=="dsh" and .fallback_reason!=null and .fallback_at!=null and .status=="done"' "$DV_STATE/DS-1/meta"
  test "$(cat "$DV_STATE/DS-1/dsh-count")" = 2
  test ! -f "$DV_STATE/DS-1/overlap"
  test -f "$DV_STATE/DS-1/omp-instruction"
}
case_dsh_resume() {
  dsh_setup crash
  dsh_start_wait
  jq -se 'length==2 and (.[1].args|index("--session-id")!=null and index("dsh-session-1")!=null)' "$DV_STATE/DS-1/dsh-runs.jsonl"
  jq -e '(.dsh_failures // 0)==0' "$DV_STATE/DS-1/meta"
  test ! -e "$DV_STATE/DS-1/overlap"
}
case_dsh_stall() {
  dsh_setup stall
  export DV_STALL_AFTER=2
  dsh_start_wait
  jq -se 'length==2 and (.[1].args|index("--session-id")!=null)' "$DV_STATE/DS-1/dsh-runs.jsonl"
  test ! -e "$DV_STATE/DS-1/overlap"
  grep -F 'stalled:' "$DV_HOME/dsh-events.log"
}
case_dsh_silent_tool() {
  dsh_setup silent-tool
  export DV_STALL_AFTER=2
  dsh_start_wait
  test -f "$DV_STATE/DS-1/silent-finished"
  test "$(cat "$DV_STATE/DS-1/dsh-count")" = 1
  jq -e '.exec_status=="done" and .dsh_failures==0' "$DV_STATE/DS-1/meta"
}
case_dsh_session_activity() {
  dsh_setup session-log
  export DV_DSH_SESSIONS="$CASE_DIR/custom dsh sessions"
  export DV_STALL_AFTER=2
  dsh_start_wait
  test -f "$DV_STATE/DS-1/silent-finished"
  test "$(cat "$DV_STATE/DS-1/dsh-count")" = 1
}
case_dsh_session_scope() {
  dsh_setup other-session-log
  export DV_STALL_AFTER=2
  dsh_start_wait
  test ! -f "$DV_STATE/DS-1/silent-finished"
  test "$(cat "$DV_STATE/DS-1/dsh-count")" = 2
  grep -F 'stalled:' "$DV_HOME/dsh-events.log"
}
dsh_tool_cap() {
  dsh_setup "$1"
  export DV_STALL_AFTER=2 DV_DSH_TOOL_MAX=3
  dsh_start_wait
  test ! -f "$DV_STATE/DS-1/silent-finished"
  jq -se 'length==2 and (.[1].args|index("--session-id")!=null)' "$DV_STATE/DS-1/dsh-runs.jsonl"
  grep -F 'dsh tool exceeded DV_DSH_TOOL_MAX=3 seconds' "$DV_HOME/dsh-events.log"
  test ! -e "$DV_STATE/DS-1/overlap"
}
case_dsh_tool_cap() { dsh_tool_cap tool-cap; }
case_dsh_tool_cap_activity() { dsh_tool_cap tool-cap-active; }
case_dsh_tool_cap_per_call() {
  dsh_setup sequential-tools
  export DV_STALL_AFTER=2 DV_DSH_TOOL_MAX=3
  dsh_start_wait
  test -f "$DV_STATE/DS-1/silent-finished"
  test "$(cat "$DV_STATE/DS-1/dsh-count")" = 1
}
case_dsh_tool_cap_disabled() {
  dsh_setup silent-tool
  export DV_STALL_AFTER=2 DV_DSH_TOOL_MAX=0
  dsh_start_wait
  test -f "$DV_STATE/DS-1/silent-finished"
  test "$(cat "$DV_STATE/DS-1/dsh-count")" = 1
}
case_dsh_capacity() {
  dsh_setup capacity
  export DV_CAPACITY_BACKOFF=1 DV_CAPACITY_MAX_WAIT=30
  dsh_start_wait
  jq -e '.agent=="dsh" and .exec_status=="done" and (.dsh_failures // 0)==0' "$DV_STATE/DS-1/meta"
  test "$(cat "$DV_STATE/DS-1/dsh-count")" = 3
  jq -se 'map(.kind)==["waiting-capacity","done"]' "$DV_STATE/DS-1/events.log"
}
case_dsh_not_ready() {
  needs_tmux
  dsh_setup
  rm "$DV_DSH_KEY_FILE"
  dv bid --repo "$REPO" --agent dsh --json | jq -e '.status=="submitted"'
  dsh_start_wait
  jq -e '.agent=="omp" and .fallback_from=="dsh"' "$DV_STATE/DS-1/meta"
  test ! -f "$DV_STATE/DS-1/dsh-count"
}
case_dsh_key() {
  dsh_setup leak
  dsh_start_wait
  test ! -f "$HOME/key-was-sourced"
  if grep -Rq 'fixture-dsh-secret' "$DV_STATE" "$DV_HOME"; then return 1; fi
}
case_dsh_quota() {
  dsh_setup quota
  export DV_CAPACITY_BACKOFF=1 DV_CAPACITY_MAX_WAIT=30
  dsh_start_wait
  test "$(cat "$DV_STATE/DS-1/dsh-count")" = 3
  jq -e '.agent=="dsh" and .dsh_failures==0' "$DV_STATE/DS-1/meta"
}
case_dsh_crash_fallback() {
  needs_tmux
  dsh_setup crash-always
  dsh_start_wait
  test "$(cat "$DV_STATE/DS-1/dsh-count")" = 4
  jq -e '.agent=="omp" and .dsh_failures==2' "$DV_STATE/DS-1/meta"
  test ! -e "$DV_STATE/DS-1/overlap"
}
case_dsh_completion_gate() {
  needs_tmux
  dsh_setup final-only
  dsh_start_wait
  test "$(cat "$DV_STATE/DS-1/dsh-count")" = 4
  jq -e '.agent=="omp" and .dsh_failures==2' "$DV_STATE/DS-1/meta"
}
case_dsh_last_status() {
  needs_tmux
  dsh_setup last-aborted
  dsh_start_wait
  jq -e '.agent=="omp" and .dsh_failures==2' "$DV_STATE/DS-1/meta"
}
case_dsh_jail() {
  if [ "$(uname -s)" != Linux ] || ! command -v bwrap >/dev/null ||
    ! bwrap --dev-bind / / -- /bin/true >/dev/null 2>&1; then
    printf 'SKIP dsh_jail (working Linux bwrap unavailable)\n'; return 77
  fi
  dsh_setup jail
  mkdir -p "$HOME/code/other" "$DV_DSH_HOME/sessions/other"
  mv "$REPO" "$HOME/code/source"; REPO="$HOME/code/source"
  git clone -q "$REPO" "$DV_WORK/sibling"
  printf 'hidden\n' > "$DV_WORK/sibling/secret"
  printf 'hidden\n' > "$HOME/code/other/secret"
  printf 'hidden\n' > "$DV_DSH_HOME/sessions/other/secret"
  export DV_DSH_JAIL=on
  dsh_start_wait
  jq -e '.agent=="dsh" and .exec_status=="done" and .dsh_jail.status=="on"' "$DV_STATE/DS-1/meta"
  test "$(cat "$DV_STATE/DS-1/dsh-count")" = 1
  test -f "$(jq -r .worktree "$DV_STATE/DS-1/meta")/jailed.txt"
}
case_dsh_jail_unavailable() {
  dsh_setup
  if [ "$(uname -s)" != Linux ]; then
    export DV_DSH_JAIL=on
    dsh_start_wait
    jq -e '.dsh_jail.status=="off" and .dsh_jail.reason=="non-Linux host"' "$DV_STATE/DS-1/meta"
    return
  fi
  printf '#!/usr/bin/env bash\nexit 1\n' > "$CASE_DIR/dsh-bin/bwrap"
  chmod +x "$CASE_DIR/dsh-bin/bwrap"
  export DV_DSH_JAIL=on
  if dv start "$REPO" DS-1 jail --agent dsh > "$CASE_DIR/on.log" 2>&1; then return 1; fi
  grep 'dsh jail required' "$CASE_DIR/on.log"
  test ! -e "$DV_STATE/DS-1"
  export DV_DSH_JAIL=auto
  dsh_start_wait
  jq -e '.dsh_jail.status=="off" and .dsh_jail.reason=="bwrap unusable"' "$DV_STATE/DS-1/meta"
  grep 'jail=off bwrap unusable' "$DV_STATE/DS-1/log"
}
case_dsh_host_sync() {
  host_setup
  "$HOST_DV" host sync > "$CASE_DIR/sync"
  cmp "$ROOT/templates/dsh/headless.cordis.patch.yml" "$HOME/.dsh-dv/profiles/headless/cordis.patch.yml"
  grep -F 'install --prefix' "$HOME/installs" | grep -F '@deepseek-ai/dsh@0.2.1-rc.3'
  cp "$HOME/installs" "$CASE_DIR/installs.before"
  "$HOST_DV" host sync > "$CASE_DIR/sync-again"
  cmp "$HOME/installs" "$CASE_DIR/installs.before"
  "$HOST_DV" host check --json > "$CASE_DIR/check.json"
  jq -e '.dsh.version=="0.2.1-rc.3" and .dsh.profile_present and (.dsh.key_present|not)' "$CASE_DIR/check.json"
  host_fake "$HOME/node/bin/node" 24.8.0
  if PATH="$HOME/node/bin:$PATH" bash -c 'set -euo pipefail; DV_ENTRY="$1/bin/dv"; source "$1/lib/common.sh"; source "$1/lib/host.sh"; host_dsh_sync' _ "$ROOT" > "$CASE_DIR/old-node" 2>&1; then return 1; fi
  grep 'Node >= 24.9' "$CASE_DIR/old-node"
}
case_dsh_host_probe() {
  host_setup
  mkdir -p "$HOME/.dsh-dv/profiles/headless" "$HOME/.omp/agent"
  host_fake "$HOME/system/node" 24.20.0
  export DV_DSH_BIN="$ROOT/tests/fixtures/dsh" DV_DSH_SMOKE=1
  printf '# patch\n' > "$HOME/.dsh-dv/profiles/headless/cordis.patch.yml"
  printf "INFERHUB_API_KEY='fixture-dsh-secret'\n" > "$HOME/.omp/agent/.env"
  "$HOST_DV" host check --probe-dsh --json > "$CASE_DIR/check.json"
  jq -e '.dsh.probe=="ready" and .dsh.key_present' "$CASE_DIR/check.json"
  jq -se 'length==2 and .[0].cwd==.[1].cwd and (.[1].args|index("--session-id")!=null and index("smoke-session")!=null)' "$HOME/dsh-probes"
  test ! -f "$HOME/.dsh-dv/.anonymous-user-id"
  if grep -q 'fixture-dsh-secret' "$CASE_DIR/check.json"; then return 1; fi
  if DV_DSH_SMOKE_BAD=1 "$HOST_DV" host check --probe-dsh --json > "$CASE_DIR/bad.json"; then return 1; fi
  jq -e '.dsh.probe=="failed"' "$CASE_DIR/bad.json"
}
case_dsh_delivery() {
  dsh_setup delivery remote
  dsh_start_wait
  jq -e '.exec_status=="done" and .status=="ready"' "$DV_STATE/DS-1/meta"
  jq -e '.checks=="green" and .review=="handled"' "$DV_STATE/DS-1/done.json"
  dv land DS-1
  jq -e '.status=="landed"' "$DV_STATE/DS-1/meta"
}
case_dsh_herdr_fallback() {
  dsh_setup unfinished
  herdr_setup
  dv start "$REPO" DS-1 dsh --agent dsh
  wait_native DS-1
  jq -e '.agent=="omp" and .backend=="herdr" and .fallback_from=="dsh"' "$DV_STATE/DS-1/meta"
  test ! -e "$DV_STATE/DS-1/overlap"
}
