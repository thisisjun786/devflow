#!/usr/bin/env bash
# Stand-ins for Linux-only tools, so a macOS host runs the same code paths.
# Each helper keeps the Linux tool or file whenever it is available.

# flock on an inherited descriptor: portable_flock [-n] FD. macOS ships no
# flock(1); perl's flock(2) then locks the same open file description, so the
# lock outlives perl exactly as it outlives flock(1) and both tools exclude
# each other. Status: 0 locked, 1 busy with -n, anything else an error.
portable_flock() {
  if command -v flock >/dev/null; then flock "$@"; return; fi
  local wait=1
  if [ "${1:-}" = -n ]; then wait=0; shift; fi
  if [ "$#" != 1 ] || ! [[ "$1" =~ ^[0-9]+$ ]]; then return 64; fi
  perl -MFcntl=:flock -e '
    my ($wait, $fd) = @ARGV;
    open(my $fh, "<&=", $fd) || open($fh, ">>&=", $fd) || exit 66;
    exit 0 if flock($fh, $wait ? LOCK_EX : LOCK_EX | LOCK_NB);
    exit($!{EWOULDBLOCK} ? 1 : 71);' "$wait" "$1"
}
portable_flock_ready() { command -v flock >/dev/null || command -v perl >/dev/null; }
# Five-minute load average and available memory (MiB) for bids.
portable_load5() {
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then sysctl -n vm.loadavg | awk '{print $3}'
  else awk '{print $2}' /proc/loadavg; fi
}
portable_memory_mb() {
  local page
  if [ "$(uname -s 2>/dev/null)" != Darwin ]; then
    awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo; return
  fi
  # Reclaimable pages approximate Linux MemAvailable.
  page=$(sysctl -n hw.pagesize) || return
  vm_stat | awk -v page="$page" '/^Pages (free|inactive|speculative):/ {gsub("\\.", "", $NF); pages+=$NF} END {printf "%d", pages*page/1048576}'
}
