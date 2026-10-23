#!/usr/bin/env bash
# Host-wide advisory slots. Never unlink slot files: every caller must lock the
# same inode, including commands in separate workspace sandboxes.
heavy_slots() {
  local slots=${DV_HEAVY_SLOTS:-} cores
  if [ -z "$slots" ]; then
    cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
    [[ "$cores" =~ ^[1-9][0-9]*$ ]] || cores=1
    slots=$((cores / 8)); [ "$slots" -gt 0 ] || slots=1
  fi
  [[ "$slots" =~ ^[1-9][0-9]*$ ]] || fail 'DV_HEAVY_SLOTS must be a positive integer'
  printf '%s\n' "$slots"
}
heavy_locked() (
  # Opening read-only lets status/bid inspect without creating state. A killed
  # waiter may leave a file, but only a live kernel lock counts as waiting.
  local rc=0
  exec 9< "$1" || return 2
  flock -n 9 || rc=$?
  case "$rc" in 0) return 1 ;; 1) return 0 ;; *) return 2 ;; esac
)
heavy_snapshot() {
  local slots path rc used=0 waiting=0
  slots=$(heavy_slots) || return
  for path in "$DV_STATE/.heavy"/slot-*.lock "$DV_STATE/.heavy"/wait-*; do
    [ -f "$path" ] || continue
    rc=0; heavy_locked "$path" 2>/dev/null || rc=$?
    case "$rc" in
      0) case "${path##*/}" in slot-*) used=$((used + 1)) ;; wait-*) waiting=$((waiting + 1)) ;; esac ;;
      1) ;;
      *) used=null; waiting=null; break ;;
    esac
  done
  jq -cn --argjson slots "$slots" --argjson used "$used" --argjson waiting "$waiting" \
    '{slots:$slots,in_use:$used,waiting:$waiting}'
}
cmd_heavy() {
  if [ "${1:-}" != -- ] || [ "$#" -lt 2 ]; then
    fail 'usage: dv heavy -- command [args...]'
  fi
  shift
  need flock; need nice
  local slots dir="$DV_STATE/.heavy" slot rc waiter=''
  slots=$(heavy_slots) || return
  mkdir -p "$dir"
  # Only a waiting invocation has a marker. EXIT handles errors and TERM;
  # SIGKILL releases its fd lock, so leftover files never inflate the count.
  trap '[ -z "$waiter" ] || rm -f "$waiter"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  while :; do
    slot=1
    while [ "$slot" -le "$slots" ]; do
      exec 9>> "$dir/slot-$slot.lock"
      rc=0; flock -n 9 || rc=$?
      if [ "$rc" = 0 ]; then
        if [ -n "$waiter" ]; then rm -f "$waiter"; exec 8>&-; fi
        trap - EXIT INT TERM HUP
        # exec keeps the PID/signals/exit status and fd 9 in the actual command.
        # Descendants retaining fd 9 keep the slot until their work also ends.
        if command -v ionice >/dev/null; then
          exec nice -n 10 ionice -c 2 -n 7 -t "$@"
        else
          exec nice -n 10 "$@"
        fi
      fi
      exec 9>&-
      [ "$rc" = 1 ] || fail "cannot lock heavy slot $slot (flock exit $rc)"
      slot=$((slot + 1))
    done
    if [ -z "$waiter" ]; then
      waiter=$(mktemp "$dir/wait-XXXXXX")
      exec 8>> "$waiter"
      # A read-only status probe can briefly hold this newly created marker.
      # Wait for that probe instead of turning harmless contention into failure.
      flock 8 || fail 'cannot register heavy waiter'
      printf 'waiting for heavy slot 1/%s\n' "$slots" >&2
    fi
    sleep 0.2 8>&-
  done
}
