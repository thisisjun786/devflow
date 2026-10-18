#!/usr/bin/env bash
# Sourced after each entry point resolves its symlink to the checkout.
DV_ROOT=$(cd "$(dirname "$DV_ENTRY")/.." && pwd)
DV_CONFIG=${DV_CONFIG:-$HOME/.config/devflow/config.sh}
if [ -f "$DV_CONFIG" ]; then
  # shellcheck source=/dev/null
  source "$DV_CONFIG"
fi
# shellcheck source=config.example.sh
source "$DV_ROOT/config.example.sh"
export DV_CONFIG DV_ROOT DV_STATE DV_WORK DV_HOME DV_HOST
export PATH="$DV_ROOT/bin:$PATH"
fail() { printf 'dv: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || fail "missing dependency: $1"; }
valid_issue() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || fail 'invalid issue identifier'; }
now() { date +%s; }
tmux_dv() {
  if [ -n "$DV_TMUX_SOCKET" ]; then tmux -L "$DV_TMUX_SOCKET" "$@"; else tmux "$@"; fi
}
load_issue() {
  valid_issue "${1:-}"
  ISSUE=$1; S="$DV_STATE/$ISSUE"
  [ -f "$S/meta" ] || fail "unknown issue: $ISSUE"
  REPO=$(jq -er .repo "$S/meta")
  WT=$(jq -er .worktree "$S/meta")
  BRANCH=$(jq -er .branch "$S/meta")
  export BASE
  BASE=$(jq -er .base "$S/meta")
  SESSION="dv-$ISSUE"
}
meta_set() {
  local tries=0 tmp
  until mkdir "$S/.meta-lock" 2>/dev/null; do
    tries=$((tries + 1)); [ "$tries" -lt 100 ] || fail "metadata busy: $ISSUE"
    sleep 0.1
  done
  tmp=$(mktemp "$S/.meta.XXXXXX")
  if jq "$@" "$S/meta" > "$tmp"; then mv "$tmp" "$S/meta"; rmdir "$S/.meta-lock"
  else rm -f "$tmp"; rmdir "$S/.meta-lock"; fail 'metadata update failed'; fi
}
issue_lock() {
  mkdir "$S/.operation" 2>/dev/null || fail "operation already running: $ISSUE"
  trap 'rmdir "$S/.operation" 2>/dev/null || true' EXIT
}
require_worktree() {
  [ -d "$WT" ] || fail 'worktree is missing'
  [ "$(git -C "$WT" symbolic-ref --short HEAD)" = "$BRANCH" ] || fail 'worktree branch changed'
}
require_clean() { [ -z "$(git -C "$1" status --porcelain)" ] || fail "uncommitted files: $1"; }
is_github() {
  local url
  url=$(git -C "$REPO" config --get remote.origin.url) || return 1
  [[ "$url" =~ ^(https?://|ssh://git@|git@)github\.com[:/] ]]
}
shell_join() { printf '%q ' "$@"; }
# One compact JSON line is shared by SSH, the queue, and the reconciliation path.
event_json() {
  jq -cn --arg kind "$1" --arg issue "$2" --arg message "$3" --arg host "$4" --arg head "$5" \
    --argjson time "$(now)" '{id:([$host,$issue,$kind,$head]|join(":")),kind:$kind,issue:$issue,message:$message,host:$host,head:$head,time:$time}'
}
send_text() {
  local text=$1 buffer="dv-$ISSUE-$$"
  tmux_dv has-session -t "=$SESSION" 2>/dev/null || fail 'agent tmux is not alive'
  printf '%s' "$text" | tmux_dv load-buffer -b "$buffer" -
  tmux_dv paste-buffer -d -p -b "$buffer" -t "$SESSION:0.0"
  sleep "$DV_SEND_DELAY"
  tmux_dv send-keys -t "$SESSION:0.0" Enter
}
