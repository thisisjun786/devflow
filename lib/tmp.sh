#!/usr/bin/env bash
# Owner markers are written by the process using the directory, not mktemp's
# command-substitution shell. BASHPID is absent in macOS's Bash 3.2.
tmp_make() {
  local tmp_created
  case "$2" in dv-appserver|dv-qa|dv-host-probe) ;; *) return 1 ;; esac
  tmp_created=$(mktemp -d "$TMPDIR/$2.XXXXXX") || return 1
  if ! {
    if [ -n "${BASHPID:-}" ]; then printf '%s\n' "$BASHPID"
    else bash -c 'printf "%s\n" "$PPID"'; fi
  } > "$tmp_created/owner.pid"; then
    rmdir "$tmp_created" 2>/dev/null || true
    return 1
  fi
  printf -v "$1" '%s' "$tmp_created"
}
tmp_collect() {
  local root dir owner dirty
  for root in "$@"; do
    [ -d "$root" ] || continue
    for dir in "$root"/dv-appserver.* "$root"/dv-qa.* "$root"/dv-host-probe.*; do
      [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || continue
      [ -f "$dir/owner.pid" ] && [ ! -L "$dir/owner.pid" ] && [ -O "$dir/owner.pid" ] || continue
      owner=$(cat "$dir/owner.pid" 2>/dev/null) || continue
      [[ "$owner" =~ ^[1-9][0-9]{0,9}$ ]] && [ "$owner" -gt 1 ] || continue
      kill -0 "$owner" 2>/dev/null && continue
      # EPERM is not evidence of death (e.g. a PID reused by another user).
      [ -z "$(ps -p "$owner" -o pid= 2>/dev/null)" ] || continue
      case "${dir##*/}" in
        dv-qa.*)
          if [ -e "$dir/source" ]; then
            dirty=$(git -C "$dir/source" status --porcelain --untracked-files=all 2>/dev/null) || continue
            [ -z "$dirty" ] || continue
          fi ;;
      esac
      rm -rf -- "$dir"
    done
  done
}
tmp_environment() {
  case "$DV_TMP" in /*) ;; *) fail 'DV_TMP must be an absolute disk path' ;; esac
  mkdir -p "$DV_TMP" || fail 'cannot create DV_TMP'
  export DV_TMP TMPDIR="$DV_TMP"
}
tmp_agent_environment() {
  local cache
  tmp_environment
  cache=$(disk_cache_path) || cache=''
  case "$cache" in
    /tmp|/tmp/*|/private/tmp|/private/tmp/*) export GOCACHE="$DV_TMP/go-build" ;;
    /*) export GOCACHE="$cache" ;; # also override a stale terminal/App Server environment
  esac
}
# Quota tools on older Linux distributions cannot query tmpfs usrquota. The
# fallback counts only this user's allocated regular-file blocks, without
# traversing other mounts or following symlinks. Deleted-open files are absent.
tmp_usage_kb() {
  local usage root
  # /tmp is a symlink on macOS; find's default -P would only see the link.
  root=$(cd "${1:-/tmp}" && pwd -P) || return 1
  usage=$(find "$root" -xdev \( -type d ! -user "$(id -un)" ! -path "$root" -prune \) -o \
    \( -user "$(id -un)" -type f -exec du -k {} + \) 2>/dev/null |
    awk '{sum+=$1} END {printf "%.0f\n", sum}') || return 1
  printf '%s\n' "$usage"
}
tmp_quota_info() {
  local measured usage quota
  measured=$(LC_ALL=C quota -w -u -f /tmp 2>/dev/null || true)
  measured=$(printf '%s\n' "$measured" | awk '
    $2 ~ /^[0-9]+\*?$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ {
      used=$2; sub(/\*$/, "", used); limit=$4+0
      if ($3>0 && (limit==0 || $3<limit)) limit=$3+0
      if (limit>0) {printf "{\"usage_kb\":%s,\"quota_kb\":%.0f,\"source\":\"quota\"}\n", used, limit; exit}
    }')
  if [ -z "$measured" ]; then
    quota=${DV_TMP_QUOTA_KB:-0}
    [[ "$quota" =~ ^[0-9]+$ ]] || fail 'DV_TMP_QUOTA_KB must be nonnegative KiB'
    usage=$(tmp_usage_kb) || usage=null
    measured=$(jq -cn --argjson usage "$usage" --argjson quota "$quota" \
      '{usage_kb:$usage,quota_kb:(if $quota>0 then $quota else null end),source:"configured-estimate"}')
  fi
  printf '%s\n' "$measured" | jq -c '. + {path:"/tmp",percent:(if .quota_kb==null or .usage_kb==null then null else .usage_kb*100/.quota_kb end)} |
    . + {warning:(if .percent==null then null else .percent>80 end)}'
}
