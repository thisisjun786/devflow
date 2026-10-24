#!/usr/bin/env bash
# Sourced by run.sh; exercise the same synthetic screens in byte/UTF-8 locales.
# shellcheck disable=SC2154
screen_locale_cases() {
  local screen_locale=$1 screen_case rc failed=0
  for screen_case in stall_status stall_working_banner_detection stall_latest_activity screen_markers screen_goal_markers screen_prompt_markers codex_goal_screen_working herdr_start_clean; do
    rc=0
    LC_ALL="$screen_locale" bash "$ROOT/tests/run.sh" --case "$screen_case" || rc=$?
    printf 'LC_ALL=%s %s exit=%s\n' "$screen_locale" "$screen_case" "$rc"
    [ "$rc" = 0 ] || failed=1
  done
  return "$failed"
}
case_screen_locale_c() { screen_locale_cases C; }
case_screen_locale_utf8() {
  local screen_locale
  for screen_locale in C.UTF-8 C.utf8 en_US.UTF-8; do
    if [ "$(LC_ALL="$screen_locale" locale charmap 2>/dev/null)" = UTF-8 ]; then
      screen_locale_cases "$screen_locale"
      return
    fi
  done
  printf 'No UTF-8 locale available for screen parsing tests\n' >&2
  return 1
}
case_screen_markers() {
  stall_fixture
  local prefix banner
  for prefix in '' '  ' '│ ' '┃ │ ' '* ' '│ • ' '┃ * '; do
    for banner in 'Pursuing goal' Working 'Working...'; do
      printf 'Goal stalled\n%s%s\n' "$prefix" "$banner" > "$CASE_DIR/herdr/w-ST-1/output"
      dv status ST-1 --json | jq -e '.[0] | .goal_active and (.goal_stalled|not)'
    done
    printf 'Pursuing goal\n%sGoal stalled: paused\n' "$prefix" > "$CASE_DIR/herdr/w-ST-1/output"
    dv status ST-1 --json | jq -e '.[0] | .goal_stalled and (.goal_active|not)'
  done
  # These characters share UTF-8 bytes with bullets/borders, but are not UI markers.
  for prefix in '─ ' '¢ ' '€ '; do
    printf 'Goal stalled\n%sPursuing goal\n' "$prefix" > "$CASE_DIR/herdr/w-ST-1/output"
    dv status ST-1 --json | jq -e '.[0] | .goal_stalled and (.goal_active|not)'
    printf 'Pursuing goal\n%sGoal stalled\n' "$prefix" > "$CASE_DIR/herdr/w-ST-1/output"
    dv status ST-1 --json | jq -e '.[0] | .goal_active and (.goal_stalled|not)'
  done
}
# Fixture functions are called indirectly by loaded helpers.
# Shared fixture state and intentionally unused polling counters/results.
# shellcheck disable=SC2034,SC2317,SC2329
case_screen_goal_markers() {
  bidding_functions
  local marker
  BACKEND=tmux
  DV_START_WAIT=1
  # Marker recognition should not depend on crossing a wall-clock second.
  # A nonmatch advances to the deadline after exactly one polling interval.
  now() { cat "$CASE_DIR/goal-clock"; }
  sleep() { printf '2\n' > "$CASE_DIR/goal-clock"; }
  codex_screen() { printf '%s\n' "$marker Pursuing goal"; }
  codex_start_failed() { :; }
  for marker in '•' '*'; do
    printf '0\n' > "$CASE_DIR/goal-clock"
    wait_codex_goal test
  done
  marker='¢'
  printf '0\n' > "$CASE_DIR/goal-clock"
  if wait_codex_goal test; then
    printf 'A non-bullet character acknowledged goal startup\n' >&2
    return 1
  fi
}
# Fixture functions are called indirectly by loaded helpers.
# Shared fixture state and intentionally unused polling counters/results.
# shellcheck disable=SC2034,SC2317,SC2329
case_screen_prompt_markers() {
  repo prompt; herdr_setup; bidding_functions
  local marker pattern
  # Capture the actual startup prompt regex via the existing synthetic provider.
  SESSION=dv-SP-1 WT=$REPO
  meta_set() { :; }
  herdr_start true
  pattern=$(jq -sr '[.[] | select(.[0:2]==["pane","wait-output"])] | last | .[index("--regex")+1]' "$CASE_DIR/herdr/calls")
  for marker in '$' '#' '%' '>' '❯' '➜' '›'; do
    printf '%s\n' "$marker" | grep -Eq "$pattern"
  done
  for marker in '•' '─' '¢' 'ordinary text'; do
    if printf '%s\n' "$marker" | grep -Eq "$pattern"; then
      printf 'Non-prompt matched startup regex: %s\n' "$marker" >&2
      return 1
    fi
  done
}
