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
    HTTP://GITHUB.COM:80/EXAMPLE/WIDGET.git/ \
    HTTPS://GITHUB.COM:443/EXAMPLE/WIDGET.git/ \
    SSH://git@GITHUB.COM:22/EXAMPLE/WIDGET.git/ \
    HtTpS://GitHub.Com/Example/Widget.git/ \
    git@GITHUB.COM:Example/Widget.git/ \
    ssh://git@GITHUB.COM:22/Example/Widget.git/
}
repo_identity_distinct_urls() {
  printf '%s\n' \
    https://github.com/another/widget.git \
    HTTPS://github.com/another/widget.git \
    SSH://git@github.com:2222/example/widget.git \
    HTTPS://gitlab.com/example/widget.git \
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
  git -C "$REPO" remote add origin https://GitHub.Com:443/Example/Widget.git/
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
  dv bid --json --repo HTTPS://github.com/another/widget.git --agent codex |
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
  git -C "$REPO" remote add origin https://GitHub.Com:443/Example/Widget.git/
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

case_submit_equivalent_urls() {
  repo identity
  export DV_MANAGER_HOST="$DV_HOST" DV_HOSTS=''
  local url index=0
  while IFS= read -r url; do
    index=$((index + 1))
    dv submit "$url" "URL-$index" identity --brief "$CASE_DIR/brief" --agent codex
    jq -e --arg url "$url" '.repo==$url and .status=="submitted"' "$DV_HOME/submissions/URL-$index/task.json"
  done < <(repo_identity_urls)
  git -C "$REPO" remote add origin HTTPS://GitHub.Com:443/Example/Widget.git/
  dv submit "$REPO" URL-LOCAL identity --brief "$CASE_DIR/brief" --agent codex
  jq -e '.repo=="HTTPS://GitHub.Com:443/Example/Widget.git/"' "$DV_HOME/submissions/URL-LOCAL/task.json"
}

manager_identity_legacy_setup() {
  manager_setup
  git -C "$REPO" remote add origin ssh://git@github.com:22/Example/Widget.git
  local key=ssh://git@github.com:22/Example/Widget
  LEGACY_DIR="$DV_HOME/managers/$(printf '%s' "$key" | cksum | awk '{print $1 "-" $2}')"
  mkdir -p "$LEGACY_DIR/pending" "$LEGACY_DIR/failed" "$LEGACY_DIR/notices"
  jq -cn --arg repo "$REPO" --arg identity "$key" --arg host "$DV_HOST" \
    '{repo:$repo,identity:$identity,host:$host,agent:"hermes",enabled:true,session_id:"legacy-session",extra:{keep:true}}' > "$LEGACY_DIR/meta.json"
  printf 'pending event\n' > "$LEGACY_DIR/pending/event.json"
  printf 'failed event\n' > "$LEGACY_DIR/failed/event.json"
  printf 'operator note\n' > "$LEGACY_DIR/notices/note.json"
  printf 'historical log\n' > "$LEGACY_DIR/events.log"
  cp -R "$LEGACY_DIR" "$CASE_DIR/legacy.before"
}

case_manager_identity_legacy() {
  manager_identity_legacy_setup
  # Lookup uses an equivalent spelling, not the legacy origin's raw key.
  dv manager status HTTPS://GITHUB.COM:443/EXAMPLE/WIDGET.git/ --json |
    jq -e 'length==1 and .[0].identity=="github.com/example/widget" and .[0].session_id=="legacy-session"'
  jq -e '.identity=="github.com/example/widget"' "$LEGACY_DIR/meta.json"
  jq 'del(.identity)' "$CASE_DIR/legacy.before/meta.json" > "$CASE_DIR/meta.before"
  jq 'del(.identity)' "$LEGACY_DIR/meta.json" > "$CASE_DIR/meta.after"
  cmp "$CASE_DIR/meta.before" "$CASE_DIR/meta.after"
  local entry url
  for entry in pending failed notices events.log; do
    diff -r "$CASE_DIR/legacy.before/$entry" "$LEGACY_DIR/$entry"
  done
  # Repeated equivalent lookups must not rewrite metadata or duplicate state.
  ln "$LEGACY_DIR/meta.json" "$CASE_DIR/migrated.meta"
  while IFS= read -r url; do
    dv manager status "$url" --json | jq -e 'length==1 and .[0].session_id=="legacy-session"'
    test "$LEGACY_DIR/meta.json" -ef "$CASE_DIR/migrated.meta"
  done < <(repo_identity_urls)
  while IFS= read -r url; do
    dv manager status "$url" --json | jq -e 'length==0'
  done < <(repo_identity_distinct_urls)
  dv manager start "$REPO" | jq -e '.identity=="github.com/example/widget" and .session_id=="legacy-session"'
  test ! -e "$CASE_DIR/hermes/calls"
  dv manager note https://github.com/example/widget "$CASE_DIR/brief"
  dv manager stop ssh://git@github.com:22/example/widget
  dv manager status --json | jq -e 'length==1 and (.[0].enabled|not) and .[0].session_id=="legacy-session"'
}

case_manager_identity_legacy_busy() {
  manager_identity_legacy_setup
  repo_identity_libraries
  manager_lock "$LEGACY_DIR"
  printf 'running job\n' > "$LEGACY_DIR/run.lock/job"
  cp -R "$LEGACY_DIR/run.lock" "$CASE_DIR/lock.before"
  test "$(manager_dir https://github.com/example/widget)" = "$LEGACY_DIR"
  cmp "$CASE_DIR/legacy.before/meta.json" "$LEGACY_DIR/meta.json"
  diff -r "$CASE_DIR/lock.before" "$LEGACY_DIR/run.lock"
  manager_unlock "$LEGACY_DIR"
  test "$(manager_dir https://github.com/example/widget)" = "$LEGACY_DIR"
  jq -e '.identity=="github.com/example/widget" and .session_id=="legacy-session"' "$LEGACY_DIR/meta.json"
}

case_manager_identity_legacy_precedence() {
  manager_identity_legacy_setup
  local key=github.com/example/widget dir
  dir="$DV_HOME/managers/$(printf '%s' "$key" | cksum | awk '{print $1 "-" $2}')"
  mkdir -p "$dir"
  jq --arg key "$key" '.identity=$key | .session_id="current-session"' "$LEGACY_DIR/meta.json" > "$dir/meta.json"
  dv manager status https://github.com/example/widget --json | jq -e 'length==1 and .[0].session_id=="current-session"'
  diff -r "$CASE_DIR/legacy.before" "$LEGACY_DIR"
  # A checksum collision must fail without falling back or overwriting state.
  jq '.identity="github.com/another/widget"' "$dir/meta.json" > "$CASE_DIR/collision.meta"
  cp "$CASE_DIR/collision.meta" "$dir/meta.json"
  if dv manager status https://github.com/example/widget --json; then return 1; fi
  cmp "$CASE_DIR/collision.meta" "$dir/meta.json"
  diff -r "$CASE_DIR/legacy.before" "$LEGACY_DIR"
}

case_manager_identity_legacy_ambiguous() {
  manager_identity_legacy_setup
  local key=https://GitHub.Com:443/Example/Widget dir
  dir="$DV_HOME/managers/$(printf '%s' "$key" | cksum | awk '{print $1 "-" $2}')"
  mkdir -p "$dir"
  jq --arg key "$key" '.identity=$key | .session_id="other-legacy-session"' "$LEGACY_DIR/meta.json" > "$dir/meta.json"
  cp "$dir/meta.json" "$CASE_DIR/other.meta"
  if dv manager status https://github.com/example/widget --json; then
    printf 'ambiguous legacy registrations must not select a session\n' >&2
    return 1
  fi
  cmp "$CASE_DIR/other.meta" "$dir/meta.json"
  diff -r "$CASE_DIR/legacy.before" "$LEGACY_DIR"
}

case_manager_identity_suffix() {
  manager_setup
  # A normalized identity can itself end in .git (a repo named widget.git).
  git -C "$REPO" remote add origin https://github.com/example/widget.git.git
  dv manager start "$REPO"
  dv manager status https://github.com/example/widget --json | jq -e 'length==0'
  dv manager status https://github.com/example/widget.git.git --json | jq -e 'length==1'
  # The old raw identity already removed the transport suffix once as well.
  local key=ssh://git@github.com:22/Example/Other.git dir
  dir="$DV_HOME/managers/$(printf '%s' "$key" | cksum | awk '{print $1 "-" $2}')"
  mkdir -p "$dir"
  jq -cn --arg key "$key" --arg repo "$REPO" \
    '{identity:$key,repo:$repo,enabled:true,session_id:"suffix-session"}' > "$dir/meta.json"
  dv manager status https://github.com/example/other --json | jq -e 'length==0'
  dv manager status https://github.com/example/other.git.git --json |
    jq -e 'length==1 and .[0].identity=="github.com/example/other.git" and .[0].session_id=="suffix-session"'
  dv manager status https://github.com/example/other.git.git --json | jq -e 'length==1'
}
