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
# shellcheck source=lib/job-limits.sh
source "$DV_ROOT/lib/job-limits.sh"
# shellcheck source=lib/search.sh
source "$DV_ROOT/lib/search.sh"
# shellcheck source=lib/capacity.sh
source "$DV_ROOT/lib/capacity.sh"
# shellcheck source=lib/portable.sh
source "$DV_ROOT/lib/portable.sh"
# shellcheck source=lib/heavy.sh
source "$DV_ROOT/lib/heavy.sh"
# shellcheck source=lib/claude.sh
source "$DV_ROOT/lib/claude.sh"
# shellcheck source=lib/codex.sh
source "$DV_ROOT/lib/codex.sh"
# shellcheck source=lib/appserver.sh
source "$DV_ROOT/lib/appserver.sh"
# shellcheck source=lib/codex-exec.sh
source "$DV_ROOT/lib/codex-exec.sh"
export DV_CONFIG DV_ROOT DV_STATE DV_WORK DV_HOME DV_HOST
export PATH="$DV_ROOT/bin:$PATH"
fail() { printf 'dv: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || fail "missing dependency: $1"; }
valid_issue() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || fail 'invalid issue identifier'; }
now() { date +%s; }
# Terminal agents dv can launch. Only Codex also has exec/App Server modes.
known_agent() { case "$1" in codex|claude|devin|omp|agy|grok|cursor) ;; *) return 1 ;; esac; }
agent_bin() {
  case "$1" in
    codex) printf '%s\n' "$DV_CODEX_BIN" ;; claude) printf '%s\n' "$DV_CLAUDE_BIN" ;;
    devin) printf '%s\n' "$DV_DEVIN_BIN" ;; omp) printf '%s\n' "$DV_OMP_BIN" ;;
    agy) printf '%s\n' "$DV_AGY_BIN" ;; grok) printf '%s\n' "$DV_GROK_BIN" ;;
    cursor) printf '%s\n' "$DV_CURSOR_BIN" ;; *) return 1 ;;
  esac
}
# Default read-only login probe. agy, grok and cursor list models only with
# working authentication; cursor-agent status can report a stale login.
agent_auth_probe() {
  case "$1" in
    codex) "$2" login status ;;
    agy|grok|cursor) "$2" models ;;
    omp) omp_provider_ready ;;
    *) "$2" auth status ;;
  esac
}
# omp has no auth status. Require DV_OMP_MODEL's custom provider in models.yml
# and, when its apiKey names a variable, a value for it. Never print the key.
omp_provider_ready() {
  local dir="$HOME/.omp/agent" provider=${DV_OMP_MODEL%%/*} key
  [ -n "$provider" ] && [ "$provider" != "$DV_OMP_MODEL" ] || return 1
  key=$(awk -v provider="$provider" '
    /^[^[:space:]#]/ { inside=($0 ~ /^providers:[[:space:]]*$/); found=0; next }
    inside && match($0, /^  [^[:space:]#][^:]*:/) { found=(substr($0, 3, RLENGTH - 3)==provider); if (found) seen=1; next }
    found && $1=="apiKey:" { gsub(/["\047]/, "", $2); print $2; exit }
    END { if (!seen) exit 1 }' "$dir/models.yml" 2>/dev/null) || return 1
  [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || return 0
  [ -n "${!key:-}" ] || grep -Eq "^(export[[:space:]]+)?$key=[^[:space:]]" "$dir/.env" 2>/dev/null
}
# Where an agent keeps session transcripts: evidence of what it is doing in a
# worktree and context for a revival. dv only reads these paths.
agent_transcript_root() {
  local root=''
  case "$1" in
    codex) root=$DV_CODEX_SESSIONS ;; claude) root=$DV_CLAUDE_SESSIONS ;; omp) root=$DV_OMP_SESSIONS ;;
    agy) root=$DV_AGY_SESSIONS ;; grok) root=$DV_GROK_SESSIONS ;; cursor) root=$DV_CURSOR_SESSIONS ;;
  esac
  [ -n "$root" ] || return 1
  printf '%s\n' "$root"
}
# Each CLI names its per-directory store from the physical working directory.
agent_transcript_dir() {
  local root name
  root=$(agent_transcript_root "$1") || return 1
  case "$1" in
    omp) name="--$(printf '%s' "${2#/}" | tr '/\\:' '---')--" ;;
    claude) name=$(printf '%s' "$2" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g') ;;
    grok) name=$(jq -rn --arg dir "$2" '$dir|@uri') ;;
    cursor) name="$(printf '%s' "$2" | LC_ALL=C sed -E 's/[^A-Za-z0-9]+/-/g; s/^-//; s/-$//')/agent-transcripts" ;;
    *) return 1 ;;
  esac
  printf '%s/%s\n' "$root" "$name"
}
agent_transcript() {
  local dir
  if dir=$(agent_transcript_dir "$1" "$2") && [ -d "$dir" ]; then printf '%s\n' "$dir"; return; fi
  agent_transcript_root "$1"
}
tmux_dv() {
  if [ -n "$DV_TMUX_SOCKET" ]; then tmux -L "$DV_TMUX_SOCKET" "$@"; else tmux "$@"; fi
}
load_issue() {
  valid_issue "${1:-}"
  ISSUE=$1; S="$DV_STATE/$ISSUE"
  [ -f "$S/meta" ] || fail "unknown issue: $ISSUE"
  KIND=$(jq -r '.kind // "code"' "$S/meta")
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
  local path=$1 owner=$2 tries=0 holder parent
  parent=$(dirname "$path")
  while :; do
    # A competing reaper may have finished and removed the parent directory.
    [ -d "$parent" ] || return 1
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
  local path=$1 owner=$2 reaper
  [ "$(cat "$path/owner" 2>/dev/null)" = "$owner" ] || return 0
  # Serialize release of this generation even if its pid marker is missing.
  # This is itself an owned lock, so a killed reaper can also be recovered.
  reaper="$path/reap-$owner"
  owned_lock "$reaper" "$$" || return 0
  # A delayed reaper must never unlink a successor's claim.
  if [ "$(cat "$path/owner" 2>/dev/null)" = "$owner" ]; then
    rm "$path/owner"
    rm -f "$path/pid-$owner"
  fi
  # We are the live, exclusive reaper: release its claim before its marker.
  # Calling owned_unlock here would create another release lock indefinitely.
  rm -f "$reaper/owner" "$reaper/pid-$$"
  rmdir "$reaper" 2>/dev/null || true
  # A contender may already have populated the directory for its next claim.
  rmdir "$path" 2>/dev/null || true
}
require_worktree() {
  [ -d "$WT" ] || fail 'worktree is missing'
  [ "${KIND:-code}" != task ] || return 0
  if [ "${1:-}" = --allow-branch-change ]; then
    # Steering follows the worker's checkout, not its original branch. Still
    # reject a replaced directory or a checkout belonging to another repo.
    local root common expected
    root=$(cd "$WT" && pwd -P)
    [ "$(git -C "$WT" rev-parse --show-toplevel)" = "$root" ] || fail 'worktree path changed'
    common=$(cd "$WT" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
    expected=$(cd "$REPO" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
    [ "$common" = "$expected" ] || fail 'worktree repository changed'
    return 0
  fi
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
    # A job can block more than once at one head (e.g. a scope request after a
    # PR is open). Without the reason in the ID the later event is dropped as
    # already seen. Identical retransmissions still share one ID.
    if [ "$1" = blocked ]; then id="$id:m$(printf '%s' "$3" | cksum | cut -d' ' -f1)"; fi
    case "$1" in
      bid-changed|issue-opened|issue-closed|issue-reopened|issue-edited|issue-labeled|issue-unlabeled|pr-opened|pr-closed)
        # Several findings or open/close episodes can share a job/head. A
        # receipt carries this ID through retries; subsequent mutations differ.
        id="$id:$(now):$$:$RANDOM" ;;
    esac
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
# shellcheck source=lib/disk.sh
source "$DV_ROOT/lib/disk.sh"
# shellcheck source=lib/tmp.sh
source "$DV_ROOT/lib/tmp.sh"
# Collect both the configured disk root and the caller's previous temporary
# root. Unmarked legacy directories are deliberately retained.
tmp_collect "$DV_TMP" "${TMPDIR:-/tmp}"
tmp_environment
