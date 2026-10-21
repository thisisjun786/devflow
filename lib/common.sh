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
# shellcheck source=lib/claude.sh
source "$DV_ROOT/lib/claude.sh"
# shellcheck source=lib/codex.sh
source "$DV_ROOT/lib/codex.sh"
# shellcheck source=lib/codex-exec.sh
source "$DV_ROOT/lib/codex-exec.sh"
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
  BACKEND=$(jq -r '.backend // "tmux"' "$S/meta")
  HERDR_PANE=$(jq -r '.herdr_pane // empty' "$S/meta")
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
owned_lock() {
  local path=$1 owner=$2 tries=0 holder
  while :; do
    # mkdir alone is not an ownership claim: uutils 0.8.0 can report success
    # to both concurrent creators. A hard link gives exactly one caller owner.
    mkdir "$path" 2>/dev/null || true
    if { printf '%s\n' "$owner" > "$path/pid-$owner"; } 2>/dev/null; then
      if ln "$path/pid-$owner" "$path/owner" 2>/dev/null; then return 0; fi
      rm "$path/pid-$owner" 2>/dev/null || true
    fi
    holder=$(cat "$path/owner" 2>/dev/null) || holder=''
    if [[ "$holder" =~ ^[1-9][0-9]*$ ]] && ! kill -0 "$holder" 2>/dev/null; then
      owned_unlock "$path" "$holder"
    fi
    tries=$((tries+1)); [ "$tries" -lt 100 ] || return 1
    sleep 0.1
  done
}
owned_unlock() {
  local path=$1 owner=$2
  # Only the remover of this exact owner's marker may unlink the claim.
  # This also elects a single reaper when several callers find a dead owner.
  if rm "$path/pid-$owner" 2>/dev/null; then
    rm "$path/owner"
    # A contender may already have populated the directory for its next claim.
    rmdir "$path" 2>/dev/null || true
  fi
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
  # Transports pass the original ID verbatim, including a question's episode.
  local id=${6:-} token=${7:-} episode=${8:-}
  if [ -z "$id" ]; then
    # Reconciliation calls with its source status row in scope, including on a
    # remote host. Read that row, never the watcher's unrelated local state.
    if [ "$1" = 'done' ] && [ -z "$episode" ] && [ -n "${row:-}" ]; then
      episode=$(printf '%s\n' "$row" | jq -r --arg issue "$2" --arg host "$4" --arg head "$5" \
        'select(.issue==$issue and .host==$host and .head==$head) | .done_episode // empty') || episode=''
    fi
    id="$4:$2:$1:$5"
    [ -z "$token" ] || id="$id:$token"
    [ -z "$episode" ] || id="$id:revive:$episode"
    if [ "$1" = question ]; then id="$id:${DV_QUESTION_EPISODE:-$(now):$$:$RANDOM}"; fi
  fi
  jq -cn --arg kind "$1" --arg issue "$2" --arg message "$3" --arg host "$4" --arg head "$5" \
    --arg id "$id" --arg token "$token" --argjson time "${9:-$(now)}" \
    '{id:$id,kind:$kind,issue:$issue,message:$message,host:$host,head:$head,time:$time} +
    (if $token=="" then {} else {token:$token} end)'
}
send_text() {
  local text=$1 buffer="dv-$ISSUE-$$"
  if [ "$BACKEND" = herdr ]; then herdr_send_text "$text"; return; fi
  tmux_dv has-session -t "=$SESSION" 2>/dev/null || { printf 'dv: agent tmux is not alive\n' >&2; return 1; }
  printf '%s' "$text" | tmux_dv load-buffer -b "$buffer" - || return 1
  tmux_dv paste-buffer -d -p -b "$buffer" -t "$SESSION:0.0" || return 1
  sleep "$DV_SEND_DELAY"
  tmux_dv send-keys -t "$SESSION:0.0" Enter
}
read_session() {
  if [ "$BACKEND" = herdr ]; then herdr_read "$HERDR_PANE"
  else tmux_dv capture-pane -p -t "$SESSION:0.0"; fi
}
session_enter() {
  if [ "$BACKEND" = herdr ]; then herdr_cmd pane send-keys "$HERDR_PANE" Enter >/dev/null
  else tmux_dv send-keys -t "$SESSION:0.0" Enter; fi
}
# shellcheck source=lib/metrics.sh
source "$DV_ROOT/lib/metrics.sh"
