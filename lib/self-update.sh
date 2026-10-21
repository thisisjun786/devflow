#!/usr/bin/env bash
# Update only the checkout containing this executable, never an issue worktree.
self_update_head() { git -C "$DV_ROOT" rev-parse HEAD 2>/dev/null || true; }
self_update_warn() { printf 'dv: self-update: %s\n' "$*" >&2; }
self_update() (
  [ "$DV_AUTO_UPDATE" = 1 ] || return 0
  local interval=${1:-300} root gitdir last=0 current target dirty
  root=$(git -C "$DV_ROOT" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ "$(cd "$root" && pwd -P)" = "$(cd "$DV_ROOT" && pwd -P)" ] || return 0
  [ "$(git -C "$DV_ROOT" symbolic-ref --quiet --short HEAD)" = main ] || return 0
  git -C "$DV_ROOT" config --get remote.origin.url >/dev/null || return 0
  gitdir=$(cd "$DV_ROOT" && cd "$(git rev-parse --git-dir)" && pwd -P) || return 0
  owned_lock "$gitdir/devflow-update.lock" "$$" || return 0
  trap 'owned_unlock "$gitdir/devflow-update.lock" "$$"' EXIT
  [ ! -f "$gitdir/devflow-update.last" ] || last=$(cat "$gitdir/devflow-update.last")
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if [ "$interval" -gt 0 ] && [ "$last" -le "$(now)" ] && [ $(( $(now) - last )) -lt "$interval" ]; then return 0; fi
  # Failed/offline attempts are throttled too. Nothing on stdout: callers may
  # be producing JSON or a protocol response.
  now > "$gitdir/devflow-update.last" || return 0
  if ! bid_limit 10 env GIT_TERMINAL_PROMPT=0 git -C "$DV_ROOT" fetch --quiet --no-tags origin \
    refs/heads/main:refs/remotes/origin/main; then
    self_update_warn 'fetch failed; keeping the current checkout'; return 0
  fi
  current=$(self_update_head)
  target=$(git -C "$DV_ROOT" rev-parse refs/remotes/origin/main) || return 0
  [ "$current" != "$target" ] || return 0
  dirty=$(git -C "$DV_ROOT" status --porcelain) || return 0
  if [ -n "$dirty" ]; then self_update_warn 'dirty checkout; update deferred'; return 0; fi
  # Recheck after the network operation. Never switch branches, reset, stash,
  # or merge divergent history, even if an operator changed it during fetch.
  [ "$(git -C "$DV_ROOT" symbolic-ref --quiet --short HEAD)" = main ] || return 0
  if ! git -C "$DV_ROOT" merge-base --is-ancestor "$current" "$target"; then
    self_update_warn 'main is not a fast-forward; update deferred'; return 0
  fi
  if git -C "$DV_ROOT" merge --ff-only --no-edit "$target" >/dev/null; then
    self_update_warn "updated $current -> $target"
  else
    self_update_warn 'fast-forward failed; update deferred'
  fi
)
self_update_landed() {
  local event=$1 repo identity
  [ "$(jq -r .kind <<< "$event")" = landed ] || return 1
  repo=$(manager_event_repo "$event" 2>/dev/null) || return 1
  identity=$(manager_identity "$DV_ROOT") || return 1
  [ "$(manager_identity "$repo")" = "$identity" ]
}
self_update_watch_version() {
  local commit=$1 tmp
  tmp=$(mktemp "$DV_HOME/.watch-version.XXXXXX")
  jq -cn --argjson pid "$$" --arg root "$DV_ROOT" --arg commit "$commit" \
    '{pid:$pid,checkout:$root,commit:$commit}' > "$tmp"
  mv "$tmp" "$DV_HOME/watch-version.json"
}
self_update_watch_status() {
  local record='{}' pid root=$DV_ROOT commit='' target='' running=false status=not-running
  if [ -f "$DV_HOME/watch-version.json" ]; then
    record=$(jq -ce 'select(type=="object")' "$DV_HOME/watch-version.json" 2>/dev/null) || record='{}'
  fi
  pid=$(jq -r '.pid // empty' <<< "$record")
  if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ "$(cat "$DV_HOME/watch.pid" 2>/dev/null)" = "$pid" ] &&
    kill -0 "$pid" 2>/dev/null && ps -p "$pid" -o args= 2>/dev/null | grep -q '[ /]dv-watch'; then
    running=true
    root=$(jq -r '.checkout' <<< "$record")
    commit=$(jq -r '.commit // ""' <<< "$record")
    status=unknown
  fi
  target=$(git -C "$root" rev-parse refs/remotes/origin/main 2>/dev/null) || target=''
  if [ "$running" = true ] && [ -n "$commit" ] && [ -n "$target" ]; then
    if [ "$commit" = "$target" ]; then status=current; else status=outdated; fi
  fi
  jq -cn --argjson running "$running" --arg commit "$commit" --arg target "$target" --arg root "$root" --arg status "$status" \
    '{running:$running,commit:(if $commit=="" then null else $commit end),origin_main:(if $target=="" then null else $target end),checkout:$root,status:$status}'
}
