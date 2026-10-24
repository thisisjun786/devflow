#!/usr/bin/env bash
# shellcheck disable=SC2016
case_tmp_reap() {
  local child path
  export DV_TMP="$CASE_DIR/disk tmp"
  mkdir -p "$DV_TMP"
  cat > "$CASE_DIR/owner" <<'OWNER'
set -euo pipefail
DV_ENTRY="$ROOT/bin/dv"
source "$ROOT/lib/common.sh"
[ "${DV_TEST_NO_BASHPID:-0}" != 1 ] || unset BASHPID
for prefix in dv-appserver dv-qa dv-host-probe; do
  tmp_make path "$prefix"
  printf '%s\n' "$path" >> "$CASE_DIR/paths"
done
touch "$CASE_DIR/owner-ready"
exec sleep 60
OWNER
  bash "$CASE_DIR/owner" > "$CASE_DIR/owner.log" 2>&1 & child=$!
  # Always reap the fixture, including on red.
  for _ in {1..100}; do
    [ ! -f "$CASE_DIR/owner-ready" ] || break
    kill -0 "$child" 2>/dev/null || break
    sleep 0.01
  done
  if [ ! -f "$CASE_DIR/owner-ready" ]; then
    kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true
    cat "$CASE_DIR/owner.log"; return 1
  fi
  dv help
  while IFS= read -r path; do
    test -d "$path"
    test "$(cat "$path/owner.pid")" = "$child"
  done < "$CASE_DIR/paths"
  kill -KILL "$child"; wait "$child" 2>/dev/null || true
  dv help
  while IFS= read -r path; do test ! -e "$path"; done < "$CASE_DIR/paths"
}
case_tmp_guards() {
  local dir
  export DV_TMP="$CASE_DIR/disk tmp"
  mkdir -p "$DV_TMP" "$CASE_DIR/external"
  for dir in dv-appserver.unmarked dv-qa.invalid dv-host-probe.live unrelated.dead dv-qa.dirty; do
    mkdir "$DV_TMP/$dir"
    printf '2147483647\n' > "$DV_TMP/$dir/owner.pid"
  done
  rm "$DV_TMP/dv-appserver.unmarked/owner.pid"
  printf '0\n' > "$DV_TMP/dv-qa.invalid/owner.pid"
  printf '%s\n' "$$" > "$DV_TMP/dv-host-probe.live/owner.pid"
  printf '2147483647\n' > "$CASE_DIR/external/owner.pid"
  ln -s "$CASE_DIR/external" "$DV_TMP/dv-appserver.link"
  git init -q "$DV_TMP/dv-qa.dirty/source"
  touch "$DV_TMP/dv-qa.dirty/source/keep"
  dv help
  for dir in dv-appserver.unmarked dv-qa.invalid dv-host-probe.live unrelated.dead dv-qa.dirty dv-appserver.link; do
    test -d "$DV_TMP/$dir"
  done
}
case_tmp_agent() {
  needs_tmux; repo tmp
  # An already running terminal server must receive current host settings.
  tmux -L "$DV_TMUX_SOCKET" new-session -d -s preexisting 'sleep 60'
  printf 'DV_TMP="$HOME/disk temporary"\n' > "$DV_CONFIG"
  export TMPDIR="$CASE_DIR/ram" GOCACHE=/tmp/old-go-cache
  mkdir "$TMPDIR"
  export DV_AGENT_CMD_codex='printf "%s\n" "$TMPDIR" "$GOCACHE" > "$DV_STATE/$DV_ISSUE/environment"; exec "$ROOT/tests/fixtures/agent"'
  start TMP-1; wait_done TMP-1
  printf '%s\n' "$HOME/disk temporary" "$HOME/disk temporary/go-build" > "$CASE_DIR/expected"
  cmp "$CASE_DIR/expected" "$DV_STATE/TMP-1/environment"
}
case_tmp_appserver() {
  export DV_TMP="$HOME/disk temporary" GOCACHE=/tmp/old-go-cache
  appserver_setup
  jq -se --arg tmp "$DV_TMP" 'any(.[]; .method=="thread/start" and
    .params.config.shell_environment_policy.set.TMPDIR==$tmp and
    .params.config.shell_environment_policy.set.DV_TMP==$tmp and
    .params.config.shell_environment_policy.set.GOCACHE==($tmp+"/go-build"))' "$CASE_DIR/server/requests"
  local rg_config
  rg_config=$(jq -sr '[.[] | select(.method=="thread/start")][0].params.config.shell_environment_policy.set.RIPGREP_CONFIG_PATH' "$CASE_DIR/server/requests")
  test -f "$rg_config"
  grep -Fx -- '--max-filesize=20M' "$rg_config"
  local dir count=0
  for dir in "$DV_TMP"/dv-appserver.*; do
    test -s "$dir/owner.pid"
    kill -0 "$(cat "$dir/owner.pid")"
    count=$((count+1))
  done
  test "$count" -gt 0
}
case_tmp_default() {
  unset DV_TMP
  # Assigned by the shared test harness.
  # shellcheck disable=SC2153
  DV_ENTRY="$ROOT/bin/dv"
  source "$ROOT/lib/common.sh"
  test "$TMPDIR" = "$HOME/.cache/dv/tmp"
  test "$GOCACHE" = "$HOME/.cache/go-build"
}
case_tmp_quota() {
  host_setup
  # The copied host library uses deterministic quota and usage probes only.
  cat >> "$CASE_DIR/host-root/lib/host.sh" <<'PROBES'
quota() { cat "$CASE_DIR/quota"; return 1; }
tmp_usage_kb() { printf '%s\n' "$DV_TEST_TMP_USED_KB"; }
PROBES
  export DV_TMP_QUOTA_KB=100 DV_TEST_TMP_USED_KB=81
  : > "$CASE_DIR/quota"
  "$HOST_DV" host check --json > "$CASE_DIR/quota.json"
  jq -e '.tmp.usage_kb==81 and .tmp.quota_kb==100 and .tmp.warning and .tmp.source=="configured-estimate"' "$CASE_DIR/quota.json"
  "$HOST_DV" host check > "$CASE_DIR/quota.txt"
  grep 'WARNING: /tmp' "$CASE_DIR/quota.txt"
  export DV_TEST_TMP_USED_KB=80
  "$HOST_DV" host check --json > "$CASE_DIR/quota.json"
  jq -e '.tmp.percent==80 and (.tmp.warning|not)' "$CASE_DIR/quota.json"
  # A quota command may exit nonzero when the quota is exceeded. Its data
  # still takes precedence over the configured estimate.
  printf 'Disk quotas for user fixture:\nFilesystem blocks quota limit grace files quota limit grace\ntmpfs 90* 100 110 none 2 0 0\n' > "$CASE_DIR/quota"
  "$HOST_DV" host check --json > "$CASE_DIR/quota.json"
  jq -e '.tmp.usage_kb==90 and .tmp.quota_kb==100 and .tmp.warning and .tmp.source=="quota"' "$CASE_DIR/quota.json"
  : > "$CASE_DIR/quota"
  export DV_TEST_TMP_USED_KB=null DV_TMP_QUOTA_KB=0
  "$HOST_DV" host check --json > "$CASE_DIR/quota.json"
  jq -e '.tmp.percent==null and .tmp.quota_kb==null and .tmp.warning==null' "$CASE_DIR/quota.json"
}
case_tmp_reap_bash32() { export DV_TEST_NO_BASHPID=1; case_tmp_reap; }
case_tmp_appserver_killed() {
  local client dir found='' remaining
  export DV_TMP="$HOME/disk temporary"
  appserver_setup
  client=$(cat "$DV_STATE/AS-1/appserver/client.pid")
  for dir in "$DV_TMP"/dv-appserver.*; do
    if [ "$(cat "$dir/owner.pid")" = "$client" ]; then found=$dir; fi
  done
  test -n "$found"
  dv help >/dev/null
  test -d "$found"
  kill -KILL "$client"
  for _ in {1..100}; do
    remaining=$(ps -p "$client" -o stat= 2>/dev/null) || remaining=''
    { [ -n "$remaining" ] && [[ "$remaining" != Z* ]]; } || break
    sleep 0.01
  done
  # A defunct process must be reaped by its parent before kill -0 is false.
  for _ in {1..100}; do kill -0 "$client" 2>/dev/null || break; sleep 0.01; done
  dv help >/dev/null
  test ! -e "$found"
}
case_tmp_usage() {
  DV_ENTRY="$ROOT/bin/dv"
  source "$ROOT/lib/common.sh"
  mkdir "$CASE_DIR/usage"
  ln -s "$CASE_DIR/usage" "$CASE_DIR/usage-link"
  dd if=/dev/zero of="$CASE_DIR/usage/data" bs=1024 count=1024 2>/dev/null
  dd if=/dev/zero of="$CASE_DIR/external-data" bs=1024 count=2048 2>/dev/null
  ln -s "$CASE_DIR/external-data" "$CASE_DIR/usage/ignored-link"
  local expected
  expected=$(du -k "$CASE_DIR/usage/data" | awk '{print $1}')
  test "$(tmp_usage_kb "$CASE_DIR/usage-link")" = "$expected"
}
# Fixture functions are called indirectly by loaded helpers.
# shellcheck disable=SC2317,SC2329
case_tmp_cache() {
  DV_ENTRY="$ROOT/bin/dv"
  source "$ROOT/lib/common.sh"
  GOCACHE=off; tmp_agent_environment; test "$GOCACHE" = off
  # Preserve an explicitly configured cache outside the system tmp roots.
  GOCACHE=/disk/cache; tmp_agent_environment; test "$GOCACHE" = /disk/cache
  unset GOCACHE
  go() { test "$*" = 'env GOCACHE'; printf '/tmp/go-env-cache\n'; }
  tmp_agent_environment
  test "$GOCACHE" = "$DV_TMP/go-build"
  GOCACHE=/private/tmp/go-cache; tmp_agent_environment
  test "$GOCACHE" = "$DV_TMP/go-build"
}
