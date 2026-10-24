#!/usr/bin/env bash
# Sourced by run.sh; locks, panes and locale failures use disposable fixtures.
recovery_dead_claim() {
  bidding_functions
  local dead
  bash -c 'exit 0' & dead=$!; wait "$dead"
  export RECOVERY_LOCK="$CASE_DIR/claim" RECOVERY_DEAD="$dead"
  mkdir "$RECOVERY_LOCK"
  printf '%s\n' "$dead" > "$RECOVERY_LOCK/owner"
}
case_owned_lock_missing_marker() {
  recovery_dead_claim
  if ! owned_lock "$RECOVERY_LOCK" "$$"; then
    printf 'Dead claim without pid marker was not recovered\n' >&2
    return 1
  fi
  test "$(cat "$RECOVERY_LOCK/owner")" = "$$"
  owned_unlock "$RECOVERY_LOCK" "$$"
  test ! -e "$RECOVERY_LOCK"
}
case_owned_unlock_reaper_race() {
  recovery_dead_claim
  if [ "${1:-}" = marker ]; then ln "$RECOVERY_LOCK/owner" "$RECOVERY_LOCK/pid-$RECOVERY_DEAD"; fi
  local child children=''
  cat > "$CASE_DIR/reaper" <<'REAPER'
set -euo pipefail
DV_ENTRY="$ROOT/bin/dv"
source "$ROOT/lib/common.sh"
rm() {
  if [ "$1" = "$RECOVERY_LOCK/owner" ]; then
    printf '%s\n' "$$" >> "$CASE_DIR/reapers"
    sleep 0.2
  fi
  command rm "$@"
}
owned_unlock "$RECOVERY_LOCK" "$RECOVERY_DEAD"
REAPER
  for _ in {1..8}; do
    bash "$CASE_DIR/reaper" & children="$children $!"
  done
  for child in $children; do wait "$child"; done
  test -f "$CASE_DIR/reapers"
  test "$(wc -l < "$CASE_DIR/reapers" | tr -d ' ')" = 1
  owned_lock "$RECOVERY_LOCK" "$$"
  # A delayed reaper of the previous generation must preserve the successor.
  printf '%s\n' "$RECOVERY_DEAD" > "$RECOVERY_LOCK/pid-$RECOVERY_DEAD"
  owned_unlock "$RECOVERY_LOCK" "$RECOVERY_DEAD"
  test "$(cat "$RECOVERY_LOCK/owner")" = "$$"
  rm "$RECOVERY_LOCK/pid-$RECOVERY_DEAD"
  owned_unlock "$RECOVERY_LOCK" "$$"
  test ! -e "$RECOVERY_LOCK"
}
case_owned_unlock_marker_race() { case_owned_unlock_reaper_race marker; }
case_owned_lock_dead_reaper() {
  recovery_dead_claim
  local dead_reaper
  bash -c 'exit 0' & dead_reaper=$!; wait "$dead_reaper"
  # A reaper killed before removing the old claim must not strand recovery.
  mkdir "$RECOVERY_LOCK/reap-$RECOVERY_DEAD"
  printf '%s\n' "$dead_reaper" > "$RECOVERY_LOCK/reap-$RECOVERY_DEAD/owner"
  owned_lock "$RECOVERY_LOCK" "$$"
  test "$(cat "$RECOVERY_LOCK/owner")" = "$$"
  owned_unlock "$RECOVERY_LOCK" "$$"
  test ! -e "$RECOVERY_LOCK"
}
case_owned_lock_recovery_race() {
  recovery_dead_claim
  local child children=''
  cat > "$CASE_DIR/contender" <<'CONTENDER'
set -euo pipefail
DV_ENTRY="$ROOT/bin/dv"
source "$ROOT/lib/common.sh"
owned_lock "$RECOVERY_LOCK" "$$"
mkdir "$CASE_DIR/critical"
printf '%s\n' "$$" >> "$CASE_DIR/entered"
sleep 0.05
test "$(cat "$RECOVERY_LOCK/owner")" = "$$"
rmdir "$CASE_DIR/critical"
owned_unlock "$RECOVERY_LOCK" "$$"
CONTENDER
  for _ in {1..8}; do
    bash "$CASE_DIR/contender" & children="$children $!"
  done
  for child in $children; do wait "$child"; done
  test "$(wc -l < "$CASE_DIR/entered" | tr -d ' ')" = 8
  test ! -e "$RECOVERY_LOCK/owner"
}
recovery_utf8_status() {
  local backend=$1 implementation=$2 screen_locale
  stall_fixture
  for screen_locale in C.UTF-8 C.utf8 en_US.UTF-8; do
    [ "$(LC_ALL="$screen_locale" locale charmap 2>/dev/null)" != UTF-8 ] || break
  done
  test "$(LC_ALL="$screen_locale" locale charmap 2>/dev/null)" = UTF-8
  # 301 bytes including newline: tail starts inside a three-byte character.
  printf '%100s\n' '' | sed 's/ /한/g' > "$CASE_DIR/pane-line"
  tail -c 200 "$CASE_DIR/pane-line" > "$CASE_DIR/cut-line"
  if iconv -f UTF-8 -t UTF-8 "$CASE_DIR/cut-line" >/dev/null 2>&1; then return 1; fi
  cp "$CASE_DIR/pane-line" "$DV_STATE/ST-1/log"
  cp "$CASE_DIR/pane-line" "$CASE_DIR/herdr/w-ST-1/output"
  if [ "$backend" = log ]; then
    jq '.backend="qa" | .status="done"' "$DV_STATE/ST-1/meta" > "$CASE_DIR/meta"
    mv "$CASE_DIR/meta" "$DV_STATE/ST-1/meta"
  fi
  if [ "$implementation" = bsd ]; then
    # GNU tr accepts broken UTF-8. Model BSD's rejection to make the regression
    # fail on Linux too, while the native case uses the platform's real tr.
    cat > "$CASE_DIR/bsd-tr-env" <<'BSD_TR'
tr() {
  if [ "${1:-}" = -d ] && [ "${2:-}" = '\000-\010\013\014\016-\037\r' ]; then
    local input
    input=$(mktemp "$CASE_DIR/tr.XXXXXX")
    cat > "$input"
    if [ "${LC_ALL:-}" != C ] && ! iconv -f UTF-8 -t UTF-8 "$input" >/dev/null 2>&1; then
      rm "$input"
      printf 'tr: Illegal byte sequence\n' >&2
      return 1
    fi
    command tr "$@" < "$input"
    rm "$input"
  else
    command tr "$@"
  fi
}
BSD_TR
    export BASH_ENV="$CASE_DIR/bsd-tr-env"
  fi
  local rc=0
  LC_ALL="$screen_locale" dv status ST-1 --json > "$CASE_DIR/status.json" 2> "$CASE_DIR/status.err" || rc=$?
  cat "$CASE_DIR/status.err" >&2
  printf 'status backend=%s tr=%s exit=%s\n' "$backend" "$implementation" "$rc"
  test "$rc" = 0
  test ! -s "$CASE_DIR/status.err"
  jq -e 'length==1 and (.[0].last_log | length>0 and contains("한"))' "$CASE_DIR/status.json"
}
case_status_cut_utf8_log_bsd() { recovery_utf8_status log bsd; }
case_status_cut_utf8_pane_bsd() { recovery_utf8_status pane bsd; }
case_status_cut_utf8_native() {
  recovery_utf8_status log native
  # Restore the fixture's pane backend without launching another agent.
  jq '.backend="herdr" | .status="running"' "$DV_STATE/ST-1/meta" > "$CASE_DIR/meta"
  mv "$CASE_DIR/meta" "$DV_STATE/ST-1/meta"
  local screen_locale
  screen_locale=$(locale -a | awk 'tolower($0) ~ /utf-?8/ { print; exit }')
  LC_ALL="$screen_locale" dv status ST-1 --json > "$CASE_DIR/status.json" 2> "$CASE_DIR/status.err"
  test ! -s "$CASE_DIR/status.err"
  jq -e 'length==1 and (.[0].last_log | length>0 and contains("한"))' "$CASE_DIR/status.json"
}
case_reconcile_timeout_default() {
  unset DV_STATUS_TIMEOUT
  # shellcheck source=config.example.sh
  source "$ROOT/config.example.sh"
  test "$DV_STATUS_TIMEOUT" = 60
  DV_STATUS_TIMEOUT=17
  source "$ROOT/config.example.sh"
  test "$DV_STATUS_TIMEOUT" = 17
}
