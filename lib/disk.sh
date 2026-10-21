#!/usr/bin/env bash
# df/du use KiB on both BSD and GNU; the public GB field is measured in GiB.
# shellcheck disable=SC2016
disk_settings() {
  [[ "$DV_MIN_DISK_GB" =~ ^(0|[1-9][0-9]*)$ ]] || fail 'DV_MIN_DISK_GB must be a nonnegative integer'
  [[ "$DV_CACHE_TRIM_DAYS" =~ ^(0|[1-9][0-9]*)$ ]] || fail 'DV_CACHE_TRIM_DAYS must be a nonnegative integer'
  [[ "$DV_DISK_INTERVAL" =~ ^[1-9][0-9]*$ ]] || fail 'DV_DISK_INTERVAL must be positive seconds'
}
disk_available_gb() {
  local path=${1:-$DV_WORK} value
  # Bids must not create the work root. Measure its nearest existing ancestor.
  while [ ! -d "$path" ]; do
    [ "$path" != / ] && [ "$path" != . ] || return 1
    path=$(dirname "$path")
  done
  value=$(LC_ALL=C df -Pk "$path" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "%.6f", $4/1048576}') || return 1
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}
disk_cache_path() {
  local cache=${GOCACHE:-}
  if [ -z "$cache" ]; then cache=$(GOTOOLCHAIN=local go env GOCACHE 2>/dev/null) || return 1; fi
  case "$cache" in
    /*) [ "$cache" != / ] && [ "$cache" != "$HOME" ] && [[ "$cache" != *$'\n'* ]] || return 1 ;;
    *) return 1 ;; # GOCACHE=off, absent Go, or an invalid relative path
  esac
  printf '%s\n' "$cache"
}
disk_size_kb() {
  if [ ! -e "$1" ]; then printf '0\n'; return; fi
  local size
  size=$(du -sk "$1" 2>/dev/null | awk 'NR==1 {print $1}') || return 1
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$size"
}
disk_info() {
  local cache cache_free=null cache_size=null
  cache=$(disk_cache_path) || cache=''
  if [ -n "$cache" ]; then
    cache_free=$(disk_available_gb "$cache" || echo null)
    cache_size=$(disk_size_kb "$cache" || echo null)
  fi
  jq -cn --arg root "$DV_WORK" --argjson free "$(disk_available_gb || echo null)" \
    --arg cache "$cache" --argjson cache_free "$cache_free" --argjson go "$cache_size" \
    --argjson total "$(disk_size_kb "$HOME/.cache" || echo null)" \
    '{work_root:$root,disk_available_gb:$free,go_cache_path:(if $cache=="" then null else $cache end),
      cache_disk_available_gb:$cache_free,cache_sizes_kb:{go_build:$go,total:$total}}'
}
disk_log() {
  local action=$1 before=$2 after=$3 target=$4
  jq -cn --arg host "$DV_HOST" --arg action "$action" --arg target "$target" --argjson at "$(now)" \
    --argjson before "$before" --argjson after "$after" \
    '{host:$host,at:$at,action:$action,target:$target,before_kb:$before,after_kb:$after,
      freed_kb:(if $before==null or $after==null then null else [0,$before-$after]|max end)}'
}
disk_terminal_at() {
  local meta=$1 at
  at=$(jq -er 'select(.cleaned_at==null) |
    if .status=="landed" then .landed_at // empty
    elif .status=="canceled" or .status=="cancelled" then .canceled_at // .cancelled_at // empty
    else empty end | select(type=="number" and .>0) | floor' "$meta") || at=''
  if [ -z "$at" ]; then
    jq -e '.cleaned_at==null and (.status=="landed" or .status=="canceled" or .status=="cancelled")' "$meta" >/dev/null || return 1
    # Legacy terminal metadata lacks a timestamp. Its mtime is conservative:
    # later metadata writes postpone cleanup, never use the job's start time.
    at=$(stat -c %Y "$meta" 2>/dev/null || stat -f %m "$meta") || return 1
  fi
  printf '%s\n' "$at"
}
cmd__disk_prune() {
  [ "$#" = 1 ] || fail 'usage: dv _disk-prune ISSUE'
  load_issue "$1"; issue_lock
  local at root actual repo_common wt_common before
  at=$(disk_terminal_at "$S/meta") || return 0
  [ $(( $(now) - at )) -gt 86400 ] || return 0
  [ -d "$WT" ] || return 0
  root=$(cd "$DV_WORK" && pwd -P)
  actual=$(cd "$WT" && pwd -P)
  case "$actual" in "$root"/*) ;; *) fail 'disk cleanup: worktree outside work root' ;; esac
  # Never remove the source checkout or a directory merely naming its branch.
  [ -f "$WT/.git" ] && [ ! -L "$WT/.git" ] && [ ! -L "$WT" ] || fail 'disk cleanup: not a linked worktree'
  repo_common=$(cd "$REPO" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
  wt_common=$(cd "$WT" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
  [ "$repo_common" = "$wt_common" ] || fail 'disk cleanup: repository mismatch'
  require_worktree; require_clean "$WT"
  case "$BACKEND" in
    exec) ! codex_exec_alive "$S" || fail 'disk cleanup: exec still running' ;;
    appserver) appserver_require_idle ;;
    tmux) need tmux; agent_gone || fail 'disk cleanup: terminal still running' ;;
    herdr) agent_gone || fail 'disk cleanup: agent still running or uncertain' ;;
    *) fail 'disk cleanup: unknown backend' ;;
  esac
  before=$(disk_size_kb "$WT" || echo null)
  clean_worktree
  meta_set --argjson time "$(now)" '.cleaned_at=$time'
  disk_log worktree "$before" 0 "$WT"
}
disk_maintain() {
  local cache before after free meta issue at
  cache=$(disk_cache_path) || cache=''
  if [ -n "$cache" ] && [ -d "$cache" ] && [ ! -L "$cache" ]; then
    before=$(disk_size_kb "$cache" || echo null)
    # atime, not mtime: frequently reused build outputs can have old mtimes.
    if find "$cache" -type f -amin "+$((DV_CACHE_TRIM_DAYS * 1440))" -exec rm -f '{}' +; then
      after=$(disk_size_kb "$cache" || echo null)
      disk_log cache_trim "$before" "$after" "$cache"
    else printf 'disk cleanup: cache trim failed: %s\n' "$cache" >&2; fi
    free=$(disk_available_gb "$cache" || echo null)
    if jq -en --argjson free "$free" --argjson min "$DV_MIN_DISK_GB" '$free!=null and $free<$min' >/dev/null; then
      before=$(disk_size_kb "$cache" || echo null)
      # Pin the resolved target and prevent toolchain downloads during cleanup.
      if (cd "$cache" && GOCACHE="$cache" GOTOOLCHAIN=local go clean -cache); then
        after=$(disk_size_kb "$cache" || echo null)
        disk_log go_clean "$before" "$after" "$cache"
      else printf 'disk cleanup: go clean -cache failed\n' >&2; fi
    fi
    [ "$free" != null ] || printf 'disk cleanup: cache disk unavailable: %s\n' "$cache" >&2
  else
    printf 'disk cleanup: cache absent, disabled, unresolved or symlinked: %s\n' "$cache"
  fi
  for meta in "$DV_STATE"/*/meta; do
    [ -f "$meta" ] || continue
    at=$(disk_terminal_at "$meta") || continue
    [ $(( $(now) - at )) -gt 86400 ] || continue
    issue=$(basename "$(dirname "$meta")")
    # A separate entry point keeps errexit and the per-issue operation lock
    # effective even when a dirty/busy job refuses cleanup.
    "$DV_ROOT/bin/dv" _disk-prune "$issue" || printf 'disk cleanup: retained %s\n' "$issue" >&2
  done
  free=null
  [ -z "$cache" ] || free=$(disk_available_gb "$cache" || echo null)
  jq -cn --arg host "$DV_HOST" --argjson at "$(now)" --argjson free "$(disk_available_gb || echo null)" \
    --arg cache "$cache" --argjson cache_free "$free" \
    '{host:$host,at:$at,action:"complete",disk_available_gb:$free,go_cache_path:$cache,cache_disk_available_gb:$cache_free}'
}
cmd__disk_maintain() (
  [ "$#" = 0 ] || fail 'usage: dv _disk-maintain'
  disk_settings
  local dir="$DV_STATE/.disk" last=0
  mkdir -p "$dir"
  owned_lock "$dir/lock" "$$" || return 1
  trap 'owned_unlock "$dir/lock" "$$"' EXIT
  if [ -f "$dir/last-run" ]; then last=$(cat "$dir/last-run"); fi
  [[ "$last" =~ ^[0-9]+$ ]] || fail 'invalid disk maintenance timestamp'
  [ $(( $(now) - last )) -ge "$DV_DISK_INTERVAL" ] || return 0
  disk_maintain >> "$dir/cleanup.log" 2>&1
  now > "$dir/last-run"
)
cmd__disk_collect() {
  local host seen=' '
  for host in "$DV_HOST" $DV_HOSTS; do
    case "$seen" in *" $host "*) continue ;; esac
    seen="$seen$host "
    printf 'disk safety pass: %s\n' "$host"
    if [ "$host" = "$DV_HOST" ]; then
      bid_limit 300 "$DV_ROOT/bin/dv" _disk-maintain || printf 'disk safety pass failed: %s\n' "$host" >&2
    else
      bid_limit 300 ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$host" 'dv _disk-maintain' || printf 'disk safety pass failed: %s\n' "$host" >&2
    fi
  done
}
disk_collector_alive() {
  disk_pid=$(cat "$DV_HOME/disk.pid" 2>/dev/null) || return 1
  [[ "$disk_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$disk_pid" 2>/dev/null && ps -o args= -p "$disk_pid" 2>/dev/null | grep -q '[ /]dv _disk-collect'
}
disk_start() {
  if disk_collector_alive; then return 0; fi
  [ -z "${disk_pid:-}" ] || wait "$disk_pid" 2>/dev/null || true
  "$DV_ROOT/bin/dv" _disk-collect >> "$DV_HOME/disk.log" 2>&1 &
  disk_pid=$!; printf '%s\n' "$disk_pid" > "$DV_HOME/disk.pid"
}
disk_stop() {
  if disk_collector_alive; then
    bid_stop_tree "$disk_pid"
    wait "$disk_pid" 2>/dev/null || true
  fi
  rm -f "$DV_HOME/disk.pid"
}
