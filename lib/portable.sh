#!/usr/bin/env bash
# Stand-ins for Linux-only interfaces, so a macOS host runs the same code
# paths. Linux keeps reading /proc. macOS needs flock(1) from Homebrew.

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
