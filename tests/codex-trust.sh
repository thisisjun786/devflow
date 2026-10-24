#!/usr/bin/env bash
# Sourced by run.sh; no real credentials or agents.
# shellcheck disable=SC2154,SC2016
case_codex_allowlist() {
  repo denied; herdr_setup
  local allowed
  for allowed in '' "$REPO-suffix" "$CASE_DIR"; do
    if DV_TRUSTED_REPOS="$allowed" dv start "$REPO" DENY-1 trust > "$CASE_DIR/denied.log" 2>&1; then
      cat "$CASE_DIR/denied.log"; return 1
    fi
    grep -F 'DV_TRUSTED_REPOS' "$CASE_DIR/denied.log"
    test ! -e "$DV_STATE/DENY-1"
    test ! -e "$HOME/.codex/config.toml"
  done
  DV_TRUSTED_REPOS='' dv bid --json --repo "$REPO" | jq -e '.status=="rejected" and (.reason|contains("DV_TRUSTED_REPOS"))'
}
case_bid_reject_repos() {
  needs_tmux; repo excluded remote
  local origin failed=0
  # The clone's origin and the remote URL both match the owner/name entry.
  DV_BID_REJECT_REPOS='other/app test/repo' dv bid --json --repo "$REPO" |
    jq -e '.status=="rejected" and .reason=="repository excluded by DV_BID_REJECT_REPOS"'
  # Equivalent origins identify the same repository: a trailing slash after
  # .git and an uppercase host must not bypass the exclusion.
  for origin in https://github.com/test/repo.git/ https://GITHUB.COM/test/repo.git; do
    git -C "$REPO" config remote.origin.url "$origin"
    if ! DV_BID_REJECT_REPOS='test/repo' dv bid --json --repo "$REPO" |
      jq -e '.status=="rejected" and .reason=="repository excluded by DV_BID_REJECT_REPOS"'; then
      printf 'origin not rejected: %s\n' "$origin" >&2
      failed=1
    fi
  done
  [ "$failed" = 0 ] || return 1
  DV_BID_REJECT_REPOS='test/repo.git' dv bid --json --repo https://github.com/test/repo.git |
    jq -e '.status=="rejected" and (.reason|contains("DV_BID_REJECT_REPOS"))'
  # GitHub names are case-insensitive.
  DV_BID_REJECT_REPOS='Test/Repo' dv bid --json --repo https://github.com/test/REPO.git |
    jq -e '.status=="rejected" and (.reason|contains("DV_BID_REJECT_REPOS"))'
  # Another repository, a prefix and an empty list still bid normally.
  git -C "$REPO" config remote.origin.url https://GITHUB.COM/test/other.git/
  DV_BID_REJECT_REPOS='test/repo-app test/rep test/repo' dv bid --json --repo "$REPO" | jq -e '.status=="submitted"'
  DV_BID_REJECT_REPOS='' dv bid --json --repo "$REPO" | jq -e '.status=="submitted"'
}
case_codex_persisted_trust() {
  repo 'trust "quoted"'; herdr_setup
  local root
  root=$(cd "$REPO" && pwd -P)
  mkdir -p "$HOME/.codex"
  printf '# preserve user settings\nmodel = "test"\n\n[projects."/elsewhere"]\ntrust_level = "untrusted"\n' > "$HOME/.codex/config.toml"
  cp "$HOME/.codex/config.toml" "$CASE_DIR/original"
  ln -s "$REPO" "$CASE_DIR/repo-alias"
  export DV_TRUSTED_REPOS="$CASE_DIR/repo-alias"
  dv start "$REPO" TRUST-1 trust --mode exec
  wait_native TRUST-1
  head -n 5 "$HOME/.codex/config.toml" | cmp "$CASE_DIR/original" -
  grep -Fx "[projects.$(jq -Rn --arg path "$root" '$path')]" "$HOME/.codex/config.toml"
  grep -Fx 'trust_level = "trusted"' "$HOME/.codex/config.toml"
  cp "$HOME/.codex/config.toml" "$CASE_DIR/trusted"
  dv start "$REPO" TRUST-2 trust --mode exec
  wait_native TRUST-2
  cmp "$CASE_DIR/trusted" "$HOME/.codex/config.toml"
  dv clean TRUST-1; dv clean TRUST-2
}
case_codex_trust_conflict() {
  repo conflict; herdr_setup
  local root
  root=$(cd "$REPO" && pwd -P)
  mkdir -p "$HOME/.codex"
  printf '[projects."%s"]\ntrust_level = "untrusted"\n' "$root" > "$HOME/.codex/config.toml"
  cp "$HOME/.codex/config.toml" "$CASE_DIR/original"
  if dv start "$REPO" CONFLICT-1 trust > "$CASE_DIR/denied.log" 2>&1; then return 1; fi
  grep -Fi 'untrusted' "$CASE_DIR/denied.log"
  cmp "$CASE_DIR/original" "$HOME/.codex/config.toml"
  test ! -e "$DV_STATE/CONFLICT-1"
}
case_codex_trust_duplicate() {
  repo duplicate; herdr_setup
  local root
  root=$(cd "$REPO" && pwd -P)
  mkdir -p "$HOME/.codex"
  printf '[projects."%s"]\ntrust_level = "untrusted"\ntrust_level = "trusted"\n' "$root" > "$HOME/.codex/config.toml"
  cp "$HOME/.codex/config.toml" "$CASE_DIR/original"
  if dv start "$REPO" DUP-1 trust > "$CASE_DIR/duplicate.log" 2>&1; then cat "$CASE_DIR/duplicate.log"; return 1; fi
  cmp "$CASE_DIR/original" "$HOME/.codex/config.toml"
  test ! -e "$DV_STATE/DUP-1"
}
case_codex_trust_parallel() {
  repo parallel; herdr_setup
  local first second
  dv start "$REPO" TRUST-1 trust --mode exec > "$CASE_DIR/first" 2>&1 & first=$!
  dv start "$REPO" TRUST-2 trust --mode exec > "$CASE_DIR/second" 2>&1 & second=$!
  if ! wait "$first"; then cat "$CASE_DIR/first"; return 1; fi
  if ! wait "$second"; then cat "$CASE_DIR/second"; return 1; fi
  wait_native TRUST-1; wait_native TRUST-2
  test "$(grep -c 'trust_level = "trusted"' "$HOME/.codex/config.toml")" = 1
  dv clean TRUST-1; dv clean TRUST-2
}
provider_config() {
  mkdir -p "$HOME/.codex"
  cat > "$HOME/.codex/config.toml" <<'CONFIG'
model_provider = "custom"
[model_providers.unused]
env_key = "UNUSED_TEST_TOKEN"
[model_providers.custom]
env_key = "DF43_TEST_TOKEN"
CONFIG
}
case_codex_provider_missing() {
  repo missing; herdr_setup; provider_config
  unset DF43_TEST_TOKEN
  dv bid --json --repo "$REPO" | jq -e '.status=="rejected" and (.agent_ready|not)'
  if dv start "$REPO" AUTH-1 auth > "$CASE_DIR/missing.log" 2>&1; then return 1; fi
  grep -F DF43_TEST_TOKEN "$CASE_DIR/missing.log"
  test ! -e "$DV_STATE/AUTH-1"
}
case_codex_provider_env() {
  repo env; herdr_setup; provider_config
  unset DF43_TEST_TOKEN
  mkdir -p "$(dirname "$DV_CODEX_ENV_FILE")"
  printf 'export DF43_TEST_TOKEN=fixture-secret\n' > "$DV_CODEX_ENV_FILE"
  mkdir -p "$CASE_DIR/herdr"
  touch "$CASE_DIR/herdr/drop-provider-env"
  dv bid --json --repo "$REPO" | jq -e '.status=="submitted" and .agent_ready'
  dv start "$REPO" AUTH-1 auth --mode exec
  wait_native AUTH-1
  test -f "$DV_STATE/AUTH-1/provider-ready"
  if grep -RF fixture-secret "$DV_STATE" "$CASE_DIR/herdr"; then return 1; fi
  dv clean AUTH-1
}
case_codex_trust_formats() {
  repo formats; herdr_setup
  local root
  root=$(cd "$REPO" && pwd -P)
  mkdir -p "$HOME/.codex"
  # Literal strings, quoted provider keys, comments and dotted assignments.
  cat > "$HOME/.codex/config.toml" <<CONFIG
  model_provider = 'custom' # active provider
[model_providers.'custom']
  env_key = 'DF43_TEST_TOKEN'
[projects]
'$root'.trust_level = 'trusted' # keep this spelling
CONFIG
  cp "$HOME/.codex/config.toml" "$CASE_DIR/original"
  export DF43_TEST_TOKEN=fixture-secret
  dv start "$REPO" FORMAT-1 trust --mode exec
  wait_native FORMAT-1
  cmp "$CASE_DIR/original" "$HOME/.codex/config.toml"
  dv clean FORMAT-1
}
case_codex_trust_refuse() {
  repo unsupported; herdr_setup
  mkdir -p "$HOME/.codex"
  local config root
  root=$(cd "$REPO" && pwd -P)
  for config in "[projects.\"$root\"]" 'projects = { "/somewhere" = { trust_level = "trusted" } }' 'model_provider = "unfinished'; do
    printf '%s\n' "$config" > "$HOME/.codex/config.toml"
    cp "$HOME/.codex/config.toml" "$CASE_DIR/original"
    if dv start "$REPO" REFUSE-1 trust > "$CASE_DIR/refuse.log" 2>&1; then return 1; fi
    cmp "$CASE_DIR/original" "$HOME/.codex/config.toml"
    test ! -e "$DV_STATE/REFUSE-1"
  done
  rm "$HOME/.codex/config.toml"
  printf '# original\n' > "$CASE_DIR/original"
  ln -s "$CASE_DIR/original" "$HOME/.codex/config.toml"
  if dv start "$REPO" REFUSE-1 trust > "$CASE_DIR/refuse.log" 2>&1; then return 1; fi
  grep -F 'regular file' "$CASE_DIR/refuse.log"
  test "$(cat "$CASE_DIR/original")" = '# original'
}
case_codex_trust_linked() {
  repo linked; herdr_setup
  local root
  root=$(cd "$REPO" && pwd -P)
  git -C "$REPO" worktree add -qb linked "$CASE_DIR/linked"
  dv start "$CASE_DIR/linked" LINK-1 trust --mode exec
  wait_native LINK-1
  grep -Fx "[projects.$(jq -Rn --arg path "$root" '$path')]" "$HOME/.codex/config.toml"
  test "$(grep -c '^\[projects' "$HOME/.codex/config.toml")" = 1
  dv clean LINK-1
}
case_codex_trust_clone_bid() {
  repo clone; herdr_setup
  export DV_REPO_ROOT="$CASE_DIR/new/clones" DV_TRUSTED_REPOS="$CASE_DIR/new/clones/repo"
  dv bid --json --repo https://github.com/test/repo.git | jq -e '.status=="submitted" and (.repo_cloned|not)'
  test ! -e "$DV_REPO_ROOT"
  test ! -e "$HOME/.codex/config.toml"
  DV_TRUSTED_REPOS="$CASE_DIR/new/clones" dv bid --json --repo https://github.com/test/repo.git |
    jq -e '.status=="rejected" and (.reason|contains("DV_TRUSTED_REPOS"))'
}
case_codex_folder_trust() {
  startup_case folder
  startup_failed 'codex folder trust required'
  test ! -f "$DV_STATE/HS-1/goal-input"
  startup_no_keys
  dv clean HS-1
}
case_codex_folder_after_prompt() {
  startup_case folder-late
  startup_failed 'codex folder trust required'
  test -f "$DV_STATE/HS-1/goal-input"
  startup_no_keys
  dv clean HS-1
}
