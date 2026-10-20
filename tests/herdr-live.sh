#!/usr/bin/env bash
# Opt-in integration smoke: only a disposable repo and an echo/sleep fake agent.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if command -v herdr >/dev/null 2>&1; then herdr_bin=$(command -v herdr)
elif [ -x "$HOME/.local/bin/herdr" ]; then herdr_bin="$HOME/.local/bin/herdr"
else printf 'SKIP herdr-live (herdr unavailable)\n'; exit 0; fi
case "$herdr_bin" in /*) ;; *) herdr_bin="$(pwd)/$herdr_bin" ;; esac
smoke_dir=$(mktemp -d "${DV_TEST_TMP:-${TMPDIR:-/tmp}}/dv-herdr-live.XXXXXX")
issue="LIVE-$$-$(date +%s)"
export DV_CONFIG=/dev/null DV_HERDR=1 DV_KICK=true DV_START_WAIT=10
export DV_STATE="$smoke_dir/state" DV_WORK="$smoke_dir/work" DV_HOME="$smoke_dir/home"
export DV_AGENT_CMD_codex='echo SMOKE-OK; sleep 15'
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
cleanup() {
  local rc=$?
  trap - EXIT
  if [ -f "$DV_STATE/$issue/meta" ] && ! "$ROOT/bin/dv" clean "$issue"; then
    printf 'Cleanup failed; retained %s\n' "$smoke_dir" >&2
    exit 1
  fi
  rm -rf "$smoke_dir"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$smoke_dir/bin" "$smoke_dir/repo"
ln -s "$herdr_bin" "$smoke_dir/bin/herdr"
export PATH="$smoke_dir/bin:$PATH"
git -C "$smoke_dir/repo" init -q
git -C "$smoke_dir/repo" -c user.name=Smoke -c user.email=smoke@localhost commit -qm init --allow-empty
"$herdr_bin" --version
printf 'DV_HERDR=%s DV_AGENT_CMD_codex=%s\n' "$DV_HERDR" "$DV_AGENT_CMD_codex"
"$ROOT/bin/dv" start "$smoke_dir/repo" "$issue" smoke --agent codex --mode goal
workspace=$(jq -er '.herdr_workspace' "$DV_STATE/$issue/meta")
pane=$(jq -er '.herdr_pane' "$DV_STATE/$issue/meta")
"$herdr_bin" workspace get "$workspace" | jq -e --arg label "dv-$issue" '.result.workspace.label==$label' >/dev/null
printf 'PASS workspace exists: %s\n' "$workspace"
# A plain substring would also match the echoed launcher before it executes.
end=$(( $(date +%s) + 10 ))
until "$herdr_bin" pane read "$pane" --source recent-unwrapped | grep -Fx SMOKE-OK >/dev/null; do
  [ "$(date +%s)" -lt "$end" ] || { printf 'FAIL fake agent did not run\n' >&2; exit 1; }
  sleep 0.2
done
printf 'PASS fake agent printed SMOKE-OK\n'
"$ROOT/bin/dv" status "$issue" --json > "$smoke_dir/status.json"
cat "$smoke_dir/status.json"
jq -e '.[0] | .backend=="herdr" and .status=="running" and .alive and (.tmux|not)' "$smoke_dir/status.json" >/dev/null
printf 'PASS status alive\n'
"$ROOT/bin/dv" clean "$issue"
if "$herdr_bin" workspace get "$workspace" > "$smoke_dir/get.out" 2> "$smoke_dir/get.err"; then
  printf 'FAIL workspace still exists\n' >&2; exit 1
fi
jq -e '.error.code=="workspace_not_found"' "$smoke_dir/get.err" >/dev/null
test ! -d "$(jq -r .worktree "$DV_STATE/$issue/meta")"
grep -Fx SMOKE-OK "$DV_STATE/$issue/log" >/dev/null
printf 'PASS workspace gone; worktree removed; text log saved\nPASS herdr-live\n'
