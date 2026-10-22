#!/usr/bin/env bash
# Optional real Codex sandbox check. Runs shell fixtures, never a model/agent.
# Usage: bash tests/heavy-sandbox.sh /path/to/codex /writable/evidence/directory
# shellcheck disable=SC2016
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CODEX_TEST_BIN=${1:?provide a Codex CLI with the sandbox command}
EVIDENCE_DIR=${2:?provide an existing writable directory outside the workspace}
case "$CODEX_TEST_BIN" in /*) ;; *) echo 'Use an absolute CLI path' >&2; exit 1 ;; esac
WORKSPACE=$(mktemp -d "$ROOT/.heavy-sandbox.XXXXXX")
STATE=$(mktemp -d "$EVIDENCE_DIR/heavy-sandbox-state.XXXXXX")
cleanup() {
  touch "$STATE/release"
  [ -z "${first:-}" ] || wait "$first" 2>/dev/null || true
  [ -z "${second:-}" ] || wait "$second" 2>/dev/null || true
  rm -rf "$WORKSPACE"
}
trap cleanup EXIT
mkdir "$WORKSPACE/one" "$WORKSPACE/two"
git init -q "$WORKSPACE/one"
git init -q "$WORKSPACE/two"
export DV_CONFIG=/dev/null DV_AUTO_UPDATE=0 DV_STATE="$STATE" DV_HEAVY_SLOTS=1
policy=$(jq -cn --arg state "$STATE" '[$state]')
sandbox() (
  local workspace=$1 roots=$2; shift 2
  cd "$workspace"
  "$CODEX_TEST_BIN" sandbox -c 'sandbox_mode="workspace-write"' \
    -c "sandbox_workspace_write.writable_roots=$roots" -- "$@"
)
# Negative control: the state path really is outside the default workspace.
if sandbox "$WORKSPACE/one" '[]' bash -c 'echo unexpected > "$DV_STATE/denied"' > "$STATE/denied.log" 2>&1; then
  echo 'FAIL: negative control unexpectedly writable' >&2; exit 1
fi
test ! -e "$STATE/denied"
grep -Ei 'permission denied|read-only file system' "$STATE/denied.log"
sandbox "$WORKSPACE/one" "$policy" "$ROOT/bin/dv" heavy -- bash -c \
  'echo first-start >> "$DV_STATE/order"; touch "$DV_STATE/started"; while [ ! -e "$DV_STATE/release" ]; do sleep 0.1; done; sleep 0.1; echo first-end >> "$DV_STATE/order"' \
  > "$STATE/one.out" 2> "$STATE/one.err" & first=$!
for _ in {1..100}; do [ ! -e "$STATE/started" ] || break; sleep 0.1; done
test -e "$STATE/started"
sandbox "$WORKSPACE/two" "$policy" "$ROOT/bin/dv" heavy -- bash -c \
  'echo second-start >> "$DV_STATE/order"; sleep 0.1; echo second-end >> "$DV_STATE/order"' \
  > "$STATE/two.out" 2> "$STATE/two.err" & second=$!
for _ in {1..100}; do
  if grep -q '^waiting for heavy slot 1/1$' "$STATE/two.err"; then break; fi
  sleep 0.1
done
grep '^waiting for heavy slot 1/1$' "$STATE/two.err"
touch "$STATE/release"
wait "$first"; wait "$second"
printf 'first-start\nfirst-end\nsecond-start\nsecond-end\n' > "$STATE/expected"
cmp "$STATE/order" "$STATE/expected"
grep '^waiting for heavy slot 1/1$' "$STATE/two.err"
test -f "$STATE/.heavy/slot-1.lock"
printf 'PASS: denied without writable root; shared state writable with explicit root; two real sandboxes serialize. Evidence: %s\n' "$STATE"
