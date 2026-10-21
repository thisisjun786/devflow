#!/usr/bin/env bash
# All cleanup targets are synthetic and live under the driver's temporary HOME.
disk_fixture() {
  export GOCACHE="$HOME/.cache/go-build"
  mkdir -p "$GOCACHE" "$CASE_DIR/disk-bin"
  cat > "$CASE_DIR/disk-bin/go" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "$*" = 'env GOCACHE' ]; then printf '%s\n' "$CASE_DIR/go env cache"; exit; fi
test "$*" = 'clean -cache'
printf '%s\n' "$GOCACHE" > "$CASE_DIR/go.cache"
printf '%s\n' "$*" >> "$CASE_DIR/go.calls"
find "$GOCACHE" -type f -exec rm -f '{}' +
STUB
  chmod +x "$CASE_DIR/disk-bin/go"
  export PATH="$CASE_DIR/disk-bin:$PATH" DV_MIN_DISK_GB=15 DV_CACHE_TRIM_DAYS=2 DV_DISK_INTERVAL=1800
}
case_disk_bid() {
  export DV_AGENT_CMD_codex='' DV_CODEX_MODE=exec DV_AGENT_READY_codex=true DV_MIN_MEMORY_MB=0
  export DF_STUB_KB=14680064 DV_MAX_JOBS=1
  dv bid --json > "$CASE_DIR/bid.json"
  jq -e '.disk_available_gb==14 and .reason=="low disk" and .status=="rejected"' "$CASE_DIR/bid.json"
  DF_STUB_KB=15728640 dv bid --json | jq -e '.disk_available_gb==15 and .status=="submitted"'
  # The old score terms remain intact; the disk penalty is 20 at the minimum.
  jq -e '(.score-(100-20*.load5/.cores+([64,.memory_available_mb/1024]|min)-20*(30-14)/15)|fabs)<0.00001' "$CASE_DIR/bid.json"
  DF_STUB_KB=31457280 dv bid --json | jq -e '(.score-(100-20*.load5/.cores+([64,.memory_available_mb/1024]|min))|fabs)<0.00001'
  DV_MIN_DISK_GB=20 DF_STUB_KB=19922944 dv bid --json | jq -e '.reason=="low disk"'
  DV_MIN_DISK_GB=0 DF_STUB_KB=0 dv bid --json | jq -e '.status=="submitted" and (.score-(100-20*.load5/.cores+([64,.memory_available_mb/1024]|min))|fabs)<0.00001'
}
case_disk_probe() {
  export DV_AGENT_CMD_codex='' DV_CODEX_MODE=exec DV_AGENT_READY_codex=true DV_MIN_MEMORY_MB=0
  export DV_WORK="$CASE_DIR/not created/child" DF_STUB_LOG="$CASE_DIR/df.paths"
  dv bid --json | jq -e '.disk_available_gb==100'
  grep -Fx "$CASE_DIR" "$DF_STUB_LOG"
  test ! -e "$DV_WORK"
  DF_STUB_FAIL=1 dv bid --json | jq -e '.disk_available_gb==null and .reason=="disk unavailable" and .status=="rejected"'
  if DV_MIN_DISK_GB=bad dv bid --json; then return 1; fi
}
case_disk_trim() {
  disk_fixture
  printf 'stale\n' > "$HOME/.cache/go-build/old file"
  printf 'recent\n' > "$HOME/.cache/go-build/recent"
  touch -a -t 202001010000 "$HOME/.cache/go-build/old file"
  touch -m -t 202001010000 "$HOME/.cache/go-build/recent"
  printf 'outside\n' > "$CASE_DIR/outside"
  ln -s "$CASE_DIR/outside" "$HOME/.cache/go-build/link"
  dv _disk-maintain
  test ! -e "$HOME/.cache/go-build/old file"
  test -f "$HOME/.cache/go-build/recent"
  test -f "$CASE_DIR/outside"
  test -L "$HOME/.cache/go-build/link"
  test ! -e "$CASE_DIR/go.calls"
  grep 'cache_trim.*freed_kb' "$DV_STATE/.disk/cleanup.log"
  # Restarted or overlapping watcher calls do not run another pass immediately.
  printf 'stale again\n' > "$HOME/.cache/go-build/again"
  touch -a -t 202001010000 "$HOME/.cache/go-build/again"
  dv _disk-maintain
  test -f "$HOME/.cache/go-build/again"
}
case_disk_pressure() {
  disk_fixture
  printf 'recent\n' > "$HOME/.cache/go-build/recent"
  DF_STUB_KB=14680064 dv _disk-maintain
  test ! -e "$HOME/.cache/go-build/recent"
  test "$(cat "$CASE_DIR/go.calls")" = 'clean -cache'
  grep 'go_clean.*freed_kb' "$DV_STATE/.disk/cleanup.log"
}
case_disk_recovered() {
  disk_fixture
  printf 'stale\n' > "$HOME/.cache/go-build/old"
  touch -a -t 202001010000 "$HOME/.cache/go-build/old"
  cat > "$CASE_DIR/disk-bin/df" <<'STUB'
#!/usr/bin/env bash
if [ -f "$HOME/.cache/go-build/old" ]; then export DF_STUB_KB=1048576; else export DF_STUB_KB=31457280; fi
exec "$ROOT/tests/fixtures/df" "$@"
STUB
  chmod +x "$CASE_DIR/disk-bin/df"
  dv _disk-maintain
  test ! -e "$CASE_DIR/go.calls"
  test ! -e "$HOME/.cache/go-build/old"
}
case_disk_cache_guard() {
  disk_fixture
  rmdir "$HOME/.cache/go-build"
  mkdir "$CASE_DIR/elsewhere"
  printf keep > "$CASE_DIR/elsewhere/old"
  touch -a -t 202001010000 "$CASE_DIR/elsewhere/old"
  ln -s "$CASE_DIR/elsewhere" "$HOME/.cache/go-build"
  DF_STUB_KB=1048576 dv _disk-maintain
  test -f "$CASE_DIR/elsewhere/old"
  test ! -e "$CASE_DIR/go.calls"
}
case_disk_cache_alias_guard() {
  disk_fixture
  mkdir -p "$HOME/keep" "$CASE_DIR/aliases"
  ln -s "$HOME" "$CASE_DIR/aliases/home"
  local cache
  for cache in "$HOME/.cache/.." "$HOME/" "$CASE_DIR/aliases/home/." "$HOME/.."; do
    printf 'user document\n' > "$HOME/keep/document"
    touch -a -t 202001010000 "$HOME/keep/document"
    GOCACHE="$cache" DF_STUB_KB=1048576 dv _disk-maintain
    test -f "$HOME/keep/document"
    test ! -e "$CASE_DIR/go.calls"
    printf '0\n' > "$DV_STATE/.disk/last-run"
  done
  # Do not attempt to traverse a real root even in a regression. Exercise the
  # destructive-target validator directly for aliases resolving to root.
  bidding_functions
  if disk_cache_target /.; then return 1; fi
  if disk_cache_target //; then return 1; fi
}
case_disk_cache_canonical() {
  disk_fixture
  mkdir -p "$CASE_DIR/physical/cache"
  ln -s "$CASE_DIR/physical" "$CASE_DIR/cache-parent"
  printf recent > "$CASE_DIR/physical/cache/recent"
  GOCACHE="$CASE_DIR/cache-parent/cache/." DF_STUB_KB=1048576 dv _disk-maintain
  test ! -e "$CASE_DIR/physical/cache/recent"
  test "$(cat "$CASE_DIR/go.cache")" = "$(cd "$CASE_DIR/physical/cache" && pwd -P)"
}
case_disk_custom_cache() {
  host_setup; disk_fixture
  export GOCACHE="$CASE_DIR/other disk/go cache"
  mkdir -p "$GOCACHE"
  printf old > "$GOCACHE/old"
  touch -a -t 202001010000 "$GOCACHE/old"
  printf keep > "$HOME/.cache/go-build/untouched"
  touch -a -t 202001010000 "$HOME/.cache/go-build/untouched"
  "$HOST_DV" host check --json | jq -e --arg cache "$GOCACHE" '.go_cache_path==$cache and .cache_disk_available_gb==100 and .cache_sizes_kb.go_build>0'
  dv _disk-maintain
  test ! -e "$GOCACHE/old"
  test -f "$HOME/.cache/go-build/untouched"
  grep -F "$(cd "$GOCACHE" && pwd -P)" "$DV_STATE/.disk/cleanup.log"
}
case_disk_go_env_cache() {
  disk_fixture
  unset GOCACHE
  mkdir -p "$CASE_DIR/go env cache"
  printf recent > "$CASE_DIR/go env cache/recent"
  DF_STUB_KB=1048576 dv _disk-maintain
  test ! -e "$CASE_DIR/go env cache/recent"
  test "$(cat "$CASE_DIR/go.cache")" = "$(cd "$CASE_DIR/go env cache" && pwd -P)"
}
case_disk_separate_filesystems() {
  disk_fixture
  export GOCACHE="$CASE_DIR/cache disk"
  mkdir -p "$GOCACHE"
  export CACHE_DF_PATH
  CACHE_DF_PATH=$(cd "$GOCACHE" && pwd -P)
  printf recent > "$GOCACHE/recent"
  cat > "$CASE_DIR/disk-bin/df" <<'STUB'
#!/usr/bin/env bash
case "$2" in
  "$GOCACHE"|"$CACHE_DF_PATH") export DF_STUB_KB=${CACHE_FREE_KB:-104857600} ;;
  *) export DF_STUB_KB=${WORK_FREE_KB:-1048576} ;;
esac
exec "$ROOT/tests/fixtures/df" "$@"
STUB
  chmod +x "$CASE_DIR/disk-bin/df"
  export DV_AGENT_CMD_codex='' DV_CODEX_MODE=exec DV_AGENT_READY_codex=true DV_MIN_MEMORY_MB=0
  dv bid --json | jq -e '.disk_available_gb==1 and .cache_disk_available_gb==100 and .reason=="low disk"'
  CACHE_FREE_KB=1048576 WORK_FREE_KB=104857600 dv bid --json | jq -e '.disk_available_gb==100 and .cache_disk_available_gb==1 and .reason=="low disk"'
  CACHE_FREE_KB=15728640 WORK_FREE_KB=104857600 dv bid --json | jq -e '.status=="submitted" and (.score-(100-20*.load5/.cores+([64,.memory_available_mb/1024]|min)-20)|fabs)<0.00001'
  # A full work disk cannot justify emptying a different, healthy cache disk.
  dv _disk-maintain
  test -f "$GOCACHE/recent"
  test ! -e "$CASE_DIR/go.calls"
  printf '0\n' > "$DV_STATE/.disk/last-run"
  CACHE_FREE_KB=1048576 WORK_FREE_KB=104857600 dv _disk-maintain
  test ! -e "$GOCACHE/recent"
  test "$(cat "$CASE_DIR/go.cache")" = "$CACHE_DF_PATH"
  grep '"cache_disk_available_gb":' "$DV_STATE/.disk/cleanup.log"
}
case_disk_unknown() {
  disk_fixture
  printf recent > "$GOCACHE/recent"
  DF_STUB_FAIL=1 dv _disk-maintain
  test -f "$GOCACHE/recent"
  test ! -e "$CASE_DIR/go.calls"
  grep 'cache disk unavailable' "$DV_STATE/.disk/cleanup.log"
  printf '0\n' > "$DV_STATE/.disk/last-run"
  GOCACHE=off dv _disk-maintain
  test -f "$GOCACHE/recent"
  test ! -e "$CASE_DIR/go.calls"
  if DV_CACHE_TRIM_DAYS=-1 dv _disk-maintain; then return 1; fi
}
case_disk_award() {
  disk_fixture; repo award
  export DV_AGENT_CMD_codex='' DV_CODEX_MODE=exec DV_AGENT_READY_codex=true DV_MIN_MEMORY_MB=0
  dv bid --repo "$REPO" --json | jq -e '.status=="submitted"'
  jq -cn --arg repo "$REPO" --argjson deadline "$(( $(date +%s) + 30 ))" \
    '{issue:"DISK-1",repo:$repo,slug:"disk",agent:"codex",mode:"exec",base:"",brief:"fake",token:"disk",deadline:$deadline}' |
    DF_STUB_KB=1048576 dv _award | jq -e '.status=="rejected" and .reason=="low disk"'
  test ! -e "$DV_STATE/DISK-1"
  test ! -e "$DV_STATE/.awards/DISK-1"
}
case_disk_bsd_stat() (
  disk_fixture; repo legacy
  disk_job OLD landed 1
  jq 'del(.landed_at,.canceled_at)' "$DV_STATE/OLD/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/OLD/meta"
  bidding_functions
  stat() {
    case "$1 $2" in '-c %Y') return 1 ;; '-f %m') printf '1\n' ;; *) return 1 ;; esac
  }
  test "$(disk_terminal_at "$DV_STATE/OLD/meta")" = 1
)
disk_job() {
  local issue=$1 status=$2 at=$3 wt=${4:-$DV_WORK/$1}
  git -C "$REPO" worktree add -qb "job/$issue" "$wt"
  mkdir "$DV_STATE/$issue"
  jq -n --arg issue "$issue" --arg repo "$REPO" --arg wt "$wt" --arg status "$status" --argjson at "$at" \
    '{issue:$issue,repo:$repo,worktree:$wt,branch:("job/"+$issue),base:"main",backend:"exec",status:$status,landed_at:$at,canceled_at:$at,started:1}' > "$DV_STATE/$issue/meta"
}
case_disk_worktrees() {
  disk_fixture; repo disk
  local old fresh issue
  old=$(( $(date +%s) - 86401 )); fresh=$(date +%s)
  disk_job OLD landed "$old"
  disk_job CANCEL canceled "$old"
  disk_job LEGACY cancelled "$old"
  disk_job NEW landed "$fresh"
  disk_job RUN running "$old"
  disk_job DIRTY landed "$old"
  disk_job LIVE landed "$old"
  disk_job OUTSIDE landed "$old" "$CASE_DIR/outside-wt"
  disk_job LOCKED landed "$old"
  disk_job UNTSTAMP landed "$fresh"
  jq 'del(.landed_at,.canceled_at)' "$DV_STATE/UNTSTAMP/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/UNTSTAMP/meta"
  printf dirty >> "$DV_WORK/DIRTY/base"
  printf '%s\n' "$$" > "$DV_STATE/LIVE/agent.pid"
  mkdir "$DV_STATE/LOCKED/.operation"
  dv _disk-maintain
  for issue in OLD CANCEL LEGACY; do
    test ! -d "$DV_WORK/$issue"
    jq -e '.cleaned_at>0' "$DV_STATE/$issue/meta"
  done
  for issue in NEW RUN DIRTY LIVE LOCKED UNTSTAMP; do test -d "$DV_WORK/$issue"; done
  test -d "$CASE_DIR/outside-wt"
  grep 'worktree.*freed_kb' "$DV_STATE/.disk/cleanup.log"
}
case_disk_host() {
  host_setup; disk_fixture
  printf cache > "$HOME/.cache/go-build/data"
  "$HOST_DV" host check --json > "$CASE_DIR/disk.json"
  jq -e '.disk_available_gb==100 and .cache_sizes_kb.go_build>0 and .cache_sizes_kb.total>=.cache_sizes_kb.go_build' "$CASE_DIR/disk.json"
  "$HOST_DV" host check | grep -E 'Disk available: 100(\.0+)? GiB'
  "$HOST_DV" host check | grep 'Go build cache:'
  test -f "$HOME/.cache/go-build/data"
}
case_disk_watch() {
  disk_fixture; watch_fixture
  export SSH_BIDDING=1 DV_HOSTS='remote-box test-host remote-box'
  mkdir -p "$CASE_DIR/hosts/remote-box"
  printf 'DV_HOST=remote-box\nDV_STATE=%q\n' "$CASE_DIR/remote-state" > "$CASE_DIR/hosts/remote-box/config"
  dv-watch > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_file "$DV_STATE/.disk/last-run"
  wait_file "$CASE_DIR/remote-state/.disk/last-run"
  test "$(grep -c 'remote-box dv _disk-maintain' "$CASE_DIR/ssh.calls")" = 1
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
}
