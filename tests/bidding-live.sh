#!/usr/bin/env bash
# Opt-in from lina-os: real SSH hosts, isolated scratch state, fake agents only.
# Remote scripts are literal; validated run paths expand on the manager.
# shellcheck disable=SC2016,SC2029
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ "$(hostname -s)" = lina-os ] || { echo 'Run this smoke test on lina-os.' >&2; exit 1; }
for tool in ssh tar git jq tmux; do command -v "$tool" >/dev/null; done
real_ssh=$(command -v ssh)
live_root=$(mktemp -d /tmp/df21-live.XXXXXX)
remote_hosts='hx-linux go2-linux'
created='' watcher=''
printf 'live-root=%s\n' "$live_root"
# Every remote command below uses only this run's paths and tmux socket.
remote() { local host=$1; shift; "$real_ssh" -o BatchMode=yes -o ConnectTimeout=5 "$host" "$(printf '%q ' "$@")"; }
cleanup_host='set -e
r=$1
export DV_CONFIG="$r/config"
for meta in "$r"/state/*/meta; do
  [ -f "$meta" ] || continue
  issue=$(jq -r .issue "$meta")
  "$r/source/bin/dv" clean "$issue"
done
# dv clean refuses dirty worktrees; set -e preserves the whole run on failure.
rm -rf "$r"
'
cleanup() {
  local rc=$? host clean_rc=0
  trap - EXIT
  if [ -n "$watcher" ]; then
    touch "$live_root/home/stop"
    wait "$watcher" || clean_rc=1
  fi
  for host in $created; do
    if remote "$host" bash -c "$cleanup_host" df21-clean "$live_root"; then printf 'CLEAN %s\n' "$host"
    else clean_rc=1; printf 'RETAINED %s:%s\n' "$host" "$live_root" >&2; fi
  done
  if bash -c "$cleanup_host" df21-clean "$live_root"; then printf 'CLEAN lina-os\n'
  else clean_rc=1; printf 'RETAINED lina-os:%s\n' "$live_root" >&2; fi
  [ "$clean_rc" = 0 ] || rc=1
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$live_root/source" "$live_root/client" "$live_root/home"
tar -C "$ROOT" -cf - bin lib templates config.example.sh | tar -C "$live_root/source" -xf -
git init -q -b main "$live_root/repo"
git -C "$live_root/repo" -c user.name=DF21-smoke -c user.email=df21@example.invalid commit -qm scratch --allow-empty
cat > "$live_root/config" <<CONFIG
DV_HOST=lina-os
DV_MANAGER_HOST=lina-os
DV_HOSTS='hx-linux go2-linux lina-os'
DV_PULL_HOSTS='hx-linux go2-linux'
DV_STATE='$live_root/state'
DV_WORK='$live_root/work'
DV_HOME='$live_root/home'
DV_REPO_ROOT='$live_root/clones'
DV_MAX_JOBS=1
DV_MIN_MEMORY_MB=0
DV_HERDR=0
DV_TMUX_SOCKET='$(basename "$live_root")'
DV_AGENT_CMD_codex='echo DF21-LIVE; exec sleep 600'
DV_KICK='$live_root/source/bin/dv-kick'
DV_KICK_HOST=lina-os
DV_WORKER_CMD=true
DV_WATCH_INTERVAL=0.2
DV_RECONCILE_INTERVAL=99999
DV_POLISH=0
CONFIG
for host in $remote_hosts; do
  remote "$host" bash -c 'set -e; command -v bash; command -v git; command -v jq; command -v tmux; mkdir "$1"' df21-prepare "$live_root"
  created="$created $host"
  tar -C "$live_root" -cf - source repo config | remote "$host" tar -C "$live_root" -xf -
  remote "$host" bash -c 'printf "\nDV_HOST=%s\nDV_PULL_HOSTS=\nDV_KICK_HOST=%s\n" "$2" "$2" >> "$1/config"' df21-config "$live_root" "$host"
done
# Keep normal user config/installed binaries untouched, including the pull stream.
# Only this watcher sees this SSH adapter; it still uses the real existing SSH keys.
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  printf 'real_ssh=%q\nlive_root=%q\n' "$real_ssh" "$live_root"
  cat <<'ADAPTER'
opts=()
while [ "$#" -gt 0 ]; do
  case "$1" in -o) opts+=("$1" "$2"); shift 2 ;; -*) opts+=("$1"); shift ;; *) break ;; esac
done
host=$1; shift
command=$(printf '%q ' env "DV_CONFIG=$live_root/config" "PATH=$live_root/source/bin:/usr/local/bin:/usr/bin:/bin" bash -c "$*")
exec "$real_ssh" "${opts[@]}" "$host" "$command"
ADAPTER
} > "$live_root/client/ssh"
chmod +x "$live_root/client/ssh"
export DV_CONFIG="$live_root/config" PATH="$live_root/source/bin:$live_root/client:$PATH"
printf 'Scratch smoke only; no agent work.\n' > "$live_root/brief.md"
dv-watch > "$live_root/watch.log" 2>&1 & watcher=$!
wait_working() {
  local issue=$1 deadline=$(( $(date +%s) + 90 ))
  until dv queue "$issue" --json | jq -e '.[0].status=="working"' >/dev/null; do
    [ "$(date +%s)" -lt "$deadline" ] || { cat "$live_root/watch.log"; dv queue --json; return 1; }
    sleep 0.5
  done
}
# Exactly three disposable issues, with capacity one on each real host.
dv submit "$live_root/repo" DF21-LIVE-1 first --brief "$live_root/brief.md"
wait_working DF21-LIVE-1
first_host=$(dv queue DF21-LIVE-1 --json | jq -r '.[0].host')
# The winning host must now refuse another job because its one slot is full.
ssh "$first_host" "dv bid --json --repo $live_root/repo --agent codex" | jq -e '.status=="rejected" and .free_slots==0'
dv submit "$live_root/repo" DF21-LIVE-2 second --brief "$live_root/brief.md"
wait_working DF21-LIVE-2
dv submit "$live_root/repo" DF21-LIVE-3 third --brief "$live_root/brief.md"
wait_working DF21-LIVE-3
dv queue --json | tee "$live_root/result.json"
jq -e 'length==3 and all(.[]; .status=="working") and ([.[].host]|unique|sort)==["go2-linux","hx-linux","lina-os"]' "$live_root/result.json"
jq -e 'map(select(.issue=="DF21-LIVE-3"))[0].host=="lina-os"' "$live_root/result.json"
for issue in DF21-LIVE-1 DF21-LIVE-2 DF21-LIVE-3; do
  host=$(dv queue "$issue" --json | jq -r '.[0].host')
  if [ "$host" = lina-os ]; then dv status "$issue" --json | jq -e '.[0].alive'
  else ssh "$host" "dv status $issue --json" | jq -e '.[0].alive'; fi
  printf 'PASS %s running on %s\n' "$issue" "$host"
done
printf 'PASS real-host spread and full-host spillover (fake agents); cleanup follows\n'
