#!/usr/bin/env bash
# All repositories are local fixtures; URL comparisons never fetch or clone.
repo_identity_urls() {
  printf '%s\n' \
    git@github.com:example/widget.git \
    https://github.com/example/widget.git \
    ssh://git@github.com/example/widget.git \
    ssh://git@github.com:22/example/widget.git \
    ssh://github.com:22/example/widget.git \
    http://GitHub.Com/Example/Widget.git/ \
    https://GITHUB.COM:443/EXAMPLE/WIDGET.GIT/// \
    http://github.com:80/example/widget \
    git@GITHUB.COM:Example/Widget.git/ \
    ssh://git@GITHUB.COM:22/Example/Widget.git/
}
repo_identity_distinct_urls() {
  printf '%s\n' \
    https://github.com/another/widget.git \
    https://github.com/example/another.git \
    https://github.com/example/widget-extra.git \
    https://github.com/example/widget.git.git \
    ssh://git@github.com:2222/example/widget.git \
    https://github.com:8443/example/widget.git \
    http://github.com:443/example/widget.git \
    https://github.com:22/example/widget.git \
    ssh://git@github.com:443/example/widget.git \
    ssh://git@gitlab.com:22/example/widget.git \
    git@gitlab.com:example/widget.git \
    https://github.com.evil.invalid/example/widget.git \
    https://github.com@evil.invalid/example/widget.git
}
repo_identity_libraries() {
  # ROOT is assigned by the shared test runner.
  # shellcheck disable=SC2153
  DV_ENTRY="$ROOT/bin/dv"
  # shellcheck source=lib/common.sh
  source "$ROOT/lib/common.sh"
  # shellcheck source=lib/bidding.sh
  source "$ROOT/lib/bidding.sh"
  # shellcheck source=lib/manager.sh
  source "$ROOT/lib/manager.sh"
}
case_bid_clone_equivalent_urls() {
  needs_tmux; repo identity
  export DV_REPO_ROOT="$CASE_DIR/clones" DV_MAX_JOBS=1 DV_MIN_DISK_GB=0 DV_BID_REJECT_REPOS=''
  mkdir -p "$DV_REPO_ROOT"
  mv "$REPO" "$DV_REPO_ROOT/widget"
  REPO="$DV_REPO_ROOT/widget"
  git -C "$REPO" remote add origin git@github.com:example/widget.git
  cp "$REPO/.git/config" "$CASE_DIR/config.before"
  local url failed=0
  while IFS= read -r url; do
    dv bid --json --repo "$url" --agent codex > "$CASE_DIR/bid.json"
    if ! jq -e --arg repo "$REPO" '.status=="submitted" and .repo_cloned and .repo==$repo and .free_slots==1 and .agent_ready' "$CASE_DIR/bid.json"; then
      printf 'clone not reused: %s\n' "$url" >&2
      cat "$CASE_DIR/bid.json" >&2
      failed=1
    fi
    cmp "$CASE_DIR/config.before" "$REPO/.git/config"
  done < <(repo_identity_urls)
  # A different owner must not replace the existing clone.
  dv bid --json --repo https://github.com/another/widget.git --agent codex |
    jq -e '.status=="rejected" and .reason=="repository unavailable" and (.repo_cloned|not)'
  cmp "$CASE_DIR/config.before" "$REPO/.git/config"
  test "$failed" = 0
}
case_bid_clone_distinct_urls() {
  repo identity
  export DV_REPO_ROOT="$CASE_DIR/clones"
  mkdir -p "$DV_REPO_ROOT"
  mv "$REPO" "$DV_REPO_ROOT/widget"
  REPO="$DV_REPO_ROOT/widget"
  git -C "$REPO" remote add origin git@github.com:example/widget.git
  repo_identity_libraries
  local url
  while IFS= read -r url; do
    bid_repo "$url"
    test "$BID_CLONED" = false
    if [ "$BID_REPO" = "$REPO" ]; then test "$BID_REPO_OK" = false; fi
  done < <(repo_identity_distinct_urls)
  # Non-GitHub origins retain exact matching and case-sensitive paths.
  git -C "$REPO" config remote.origin.url https://gitlab.com/Example/widget.git
  bid_repo https://gitlab.com/Example/widget
  test "$BID_CLONED:$BID_REPO_OK" = true:true
  bid_repo https://gitlab.com/example/widget.git
  test "$BID_CLONED:$BID_REPO_OK" = false:false
}
case_bid_reject_default_port() {
  needs_tmux; repo identity
  export DV_REPO_ROOT="$CASE_DIR/clones" DV_MAX_JOBS=1 DV_MIN_DISK_GB=0 DV_BID_REJECT_REPOS=example/widget
  local url target failed=0
  for url in ssh://git@github.com/example/widget.git ssh://git@github.com:22/example/widget.git; do
    git -C "$REPO" config remote.origin.url "$url"
    for target in "$REPO" "$url"; do
      dv bid --json --repo "$target" --agent codex > "$CASE_DIR/bid.json"
      if ! jq -e '.status=="rejected" and .reason=="repository excluded by DV_BID_REJECT_REPOS"' "$CASE_DIR/bid.json"; then
        printf 'repository not excluded: %s (origin %s)\n' "$target" "$url" >&2
        cat "$CASE_DIR/bid.json" >&2
        failed=1
      fi
    done
  done
  while IFS= read -r url; do
    dv bid --json --repo "$url" --agent codex | jq -e '.status=="submitted" and (.repo_cloned|not)'
  done < <(repo_identity_distinct_urls)
  test ! -e "$DV_REPO_ROOT"
  test "$(git -C "$REPO" config remote.origin.url)" = ssh://git@github.com:22/example/widget.git
  test "$failed" = 0
}
case_bid_repo_slug_identity() {
  repo_identity_libraries
  local url slug failed=0
  while IFS= read -r url; do
    slug=$(bid_repo_slug "$url")
    if [ "$slug" != example/widget ]; then
      printf 'unexpected slug: %s -> %s\n' "$url" "$slug" >&2
      failed=1
    fi
  done < <(repo_identity_urls)
  test "$(bid_repo_slug Example/Widget.git/)" = example/widget
  test "$(bid_repo_slug github.com/Example/Widget.git)" = example/widget
  while IFS= read -r url; do
    test "$(bid_repo_slug "$url")" != example/widget
  done < <(repo_identity_distinct_urls)
  test "$failed" = 0
}
case_manager_identity_urls() {
  manager_setup
  git -C "$REPO" remote add origin ssh://git@GITHUB.COM:22/Example/Widget.git/
  dv manager start "$REPO"
  local url failed=0
  while IFS= read -r url; do
    if ! dv manager status "$url" --json | jq -e 'length==1 and .[0].enabled and .[0].identity=="github.com/example/widget"'; then
      printf 'manager not matched: %s\n' "$url" >&2
      failed=1
    fi
  done < <(repo_identity_urls)
  while IFS= read -r url; do
    dv manager status "$url" --json | jq -e 'length==0'
  done < <(repo_identity_distinct_urls)
  repo_identity_libraries
  test "$(manager_identity github.com/Example/Widget.git/)" = github.com/example/widget
  # Local repositories and unrelated remote hosts keep their own identities.
  git -C "$REPO" remote remove origin
  test "$(manager_identity "$REPO")" = "$REPO"
  test "$(manager_identity https://gitlab.com/Example/Widget.git)" = https://gitlab.com/Example/Widget
  test "$failed" = 0
}
