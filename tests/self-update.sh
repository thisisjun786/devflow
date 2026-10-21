#!/usr/bin/env bash
# Every update uses a disposable checkout and a local bare origin.
update_fixture() {
  watch_fixture
  export DV_AUTO_UPDATE=1 DV_PULL_HOSTS='' DV_RECONCILE_INTERVAL=1800
  UPDATE_ROOT="$CASE_DIR/devflow checkout"
  UPDATE_SEED="$CASE_DIR/publisher"
  mkdir "$UPDATE_SEED"
  cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/templates" "$ROOT/hosts" "$ROOT/config.example.sh" "$UPDATE_SEED/"
  git init -q -b main "$UPDATE_SEED"
  git -C "$UPDATE_SEED" config user.name Test
  git -C "$UPDATE_SEED" config user.email test@example.invalid
  git -C "$UPDATE_SEED" add .
  git -C "$UPDATE_SEED" commit -qm initial
  git init -q --bare "$CASE_DIR/update.git"
  git -C "$CASE_DIR/update.git" symbolic-ref HEAD refs/heads/main
  git -C "$UPDATE_SEED" remote add origin "$CASE_DIR/update.git"
  git -C "$UPDATE_SEED" push -qu origin main
  git clone -q "$CASE_DIR/update.git" "$UPDATE_ROOT"
  UPDATE_OLD=$(git -C "$UPDATE_ROOT" rev-parse HEAD)
}
update_publish() {
  # A changed command proves this invocation reloaded code after pulling.
  sed 's/dv manager start/updated-command dv manager start/' "$UPDATE_SEED/bin/dv" > "$CASE_DIR/new-dv"
  cat "$CASE_DIR/new-dv" > "$UPDATE_SEED/bin/dv"
  git -C "$UPDATE_SEED" add .
  git -C "$UPDATE_SEED" commit -qm update
  git -C "$UPDATE_SEED" push -q origin main
  UPDATE_NEW=$(git -C "$UPDATE_SEED" rev-parse HEAD)
}
update_wait_head() {
  local attempt
  for attempt in {1..100}; do
    if [ "$(git -C "$UPDATE_ROOT" rev-parse HEAD)" = "$UPDATE_NEW" ]; then return 0; fi
    sleep 0.1
  done
  printf 'Checkout did not reach published head\n' >&2
  return 1
}
update_wait_watcher() {
  local attempt
  for attempt in {1..100}; do
    if jq -e --arg head "$1" --argjson pid "$watcher" '.commit==$head and .pid==$pid' "$DV_HOME/watch-version.json" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
  done
  printf 'Watcher did not load expected commit\n' >&2
  return 1
}
update_wait_idle() {
  local attempt
  for attempt in {1..100}; do
    if [ -f "$UPDATE_ROOT/.git/devflow-update.last" ] && [ ! -d "$UPDATE_ROOT/.git/devflow-update.lock" ]; then return 0; fi
    sleep 0.1
  done
  printf 'Initial update attempt did not finish\n' >&2
  return 1
}
case_update_cli() {
  update_fixture; update_publish
  mkdir "$CASE_DIR/links"
  ln -s "$UPDATE_ROOT/bin/dv" "$CASE_DIR/links/dv"
  "$CASE_DIR/links/dv" help > "$CASE_DIR/help"
  test "$(git -C "$UPDATE_ROOT" rev-parse HEAD)" = "$UPDATE_NEW"
  grep '^updated-command dv manager start' "$CASE_DIR/help"
  # Another call within five minutes must neither fetch nor move HEAD.
  update_publish
  "$CASE_DIR/links/dv" help > /dev/null
  test "$(git -C "$UPDATE_ROOT" rev-parse HEAD)" != "$UPDATE_NEW"
  printf '0\n' > "$UPDATE_ROOT/.git/devflow-update.last"
  "$CASE_DIR/links/dv" help > /dev/null
  test "$(git -C "$UPDATE_ROOT" rev-parse HEAD)" = "$UPDATE_NEW"
}
case_update_dirty() {
  update_fixture; update_publish
  printf 'keep\n' > "$UPDATE_ROOT/operator-file"
  "$UPDATE_ROOT/bin/dv" help > /dev/null 2> "$CASE_DIR/warning"
  test "$(git -C "$UPDATE_ROOT" rev-parse HEAD)" = "$UPDATE_OLD"
  test "$(cat "$UPDATE_ROOT/operator-file")" = keep
  grep -i 'dirty' "$CASE_DIR/warning"
}
case_update_landed() {
  update_fixture
  export DV_WORKER_GATE=1 DV_MAX_WORKERS=1
  dv-kick probe BUSY-1 '' "$DV_HOST" old
  "$UPDATE_ROOT/bin/dv-watch" > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  wait_file "$DV_HOME/pending/0.pid"
  update_wait_idle
  local worker_pid
  worker_pid=$(cat "$DV_HOME/pending/0.pid")
  update_publish
  mkdir "$DV_STATE/UP-1"
  jq -cn --arg repo "$UPDATE_ROOT" --arg host "$DV_HOST" '{repo:$repo,host:$host}' > "$DV_STATE/UP-1/meta"
  dv-kick landed UP-1 '' "$DV_HOST" "$UPDATE_NEW"
  update_wait_head
  update_wait_watcher "$UPDATE_NEW"
  test "$(cat "$DV_HOME/watch.pid")" = "$watcher"
  test "$(cat "$DV_HOME/cursor")" = 2
  test "$(cat "$DV_HOME/pending/0.pid")" = "$worker_pid"
  kill -0 "$worker_pid"
  test ! -f "$DV_HOME/pending/1.pid"
  touch "$DV_HOME/release"
  wait_seen 2
  test "$(find "$DV_HOME/workers" -name '*.started' | wc -l | tr -d ' ')" = 2
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  test ! -e "$DV_HOME/.watch-lock"
}
case_update_safety() {
  update_fixture
  export DV_RECONCILE_INTERVAL=1
  "$UPDATE_ROOT/bin/dv-watch" > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  update_wait_idle
  update_publish
  update_wait_head
  update_wait_watcher "$UPDATE_NEW"
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
}
case_update_guard() {
  update_fixture; update_publish
  git -C "$UPDATE_ROOT" checkout -qb feature
  "$UPDATE_ROOT/bin/dv" help > /dev/null
  test "$(git -C "$UPDATE_ROOT" rev-parse HEAD)" = "$UPDATE_OLD"
  test ! -e "$UPDATE_ROOT/.git/devflow-update.last"
  git -C "$UPDATE_ROOT" checkout -q --detach main
  "$UPDATE_ROOT/bin/dv" help > /dev/null
  test "$(git -C "$UPDATE_ROOT" rev-parse HEAD)" = "$UPDATE_OLD"
  git -C "$UPDATE_ROOT" checkout -q main
  git -C "$UPDATE_ROOT" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm local
  local ahead
  ahead=$(git -C "$UPDATE_ROOT" rev-parse HEAD)
  "$UPDATE_ROOT/bin/dv" help > /dev/null 2> "$CASE_DIR/warning"
  test "$(git -C "$UPDATE_ROOT" rev-parse HEAD)" = "$ahead"
  grep 'not a fast-forward' "$CASE_DIR/warning"
}
case_update_offline() {
  update_fixture; update_publish
  mv "$CASE_DIR/update.git" "$CASE_DIR/offline.git"
  "$UPDATE_ROOT/bin/dv" help > "$CASE_DIR/help" 2> "$CASE_DIR/warning"
  grep 'fetch failed' "$CASE_DIR/warning"
  grep 'dv manager start' "$CASE_DIR/help"
  test "$(git -C "$UPDATE_ROOT" rev-parse HEAD)" = "$UPDATE_OLD"
  mv "$CASE_DIR/offline.git" "$CASE_DIR/update.git"
  "$UPDATE_ROOT/bin/dv" help > /dev/null
  test "$(git -C "$UPDATE_ROOT" rev-parse HEAD)" = "$UPDATE_OLD"
  printf '0\n' > "$UPDATE_ROOT/.git/devflow-update.last"
  "$UPDATE_ROOT/bin/dv" help > /dev/null
  test "$(git -C "$UPDATE_ROOT" rev-parse HEAD)" = "$UPDATE_NEW"
}
case_update_watch_dirty() {
  update_fixture
  "$UPDATE_ROOT/bin/dv-watch" > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  update_wait_idle
  printf 'keep\n' >> "$UPDATE_ROOT/config.example.sh"
  cp "$UPDATE_ROOT/config.example.sh" "$CASE_DIR/config.before"
  update_publish
  mkdir "$DV_STATE/UP-1"
  jq -cn --arg repo "$UPDATE_ROOT" --arg host "$DV_HOST" '{repo:$repo,host:$host}' > "$DV_STATE/UP-1/meta"
  dv-kick landed UP-1 '' "$DV_HOST" "$UPDATE_NEW"
  wait_seen 1
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  test "$(git -C "$UPDATE_ROOT" rev-parse HEAD)" = "$UPDATE_OLD"
  cmp "$UPDATE_ROOT/config.example.sh" "$CASE_DIR/config.before"
  grep 'dirty checkout' "$CASE_DIR/watch.log"
}
case_update_host() {
  host_setup
  update_fixture
  "$UPDATE_ROOT/bin/dv-watch" > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  update_wait_watcher "$UPDATE_OLD"
  update_wait_idle
  # The installed CLI may already have new files while the watcher is still
  # running old functions. Report its recorded commit, not checkout HEAD.
  update_publish
  git -C "$UPDATE_ROOT" fetch -q origin
  DV_AUTO_UPDATE=0 "$UPDATE_ROOT/bin/dv" host check --json > "$CASE_DIR/check.json"
  jq -e --arg old "$UPDATE_OLD" --arg new "$UPDATE_NEW" '.watcher | .running and .status=="outdated" and .commit==$old and .origin_main==$new' "$CASE_DIR/check.json"
  DV_AUTO_UPDATE=0 "$UPDATE_ROOT/bin/dv" host check > "$CASE_DIR/check.txt"
  grep "watcher: outdated commit=$UPDATE_OLD origin/main=$UPDATE_NEW" "$CASE_DIR/check.txt"
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  DV_AUTO_UPDATE=0 "$UPDATE_ROOT/bin/dv" host check --json > "$CASE_DIR/stopped.json"
  jq -e '.watcher | .running==false and .status=="not-running" and .commit==null' "$CASE_DIR/stopped.json"
}
case_update_managed() {
  update_fixture
  export DV_MANAGER_HOST=$DV_HOST DV_WORKER_CMD='' DV_HERMES_BIN="$ROOT/tests/fixtures/manager-hermes"
  mkdir "$CASE_DIR/hermes"
  # Resolve a remote landing through the manager's trusted submission record.
  mkdir -p "$DV_HOME/submissions/UP-1"
  jq -cn --arg repo "$UPDATE_ROOT" '{repo:$repo,host:"remote-host"}' > "$DV_HOME/submissions/UP-1/task.json"
  DV_AUTO_UPDATE=0 "$UPDATE_ROOT/bin/dv" manager start "$UPDATE_ROOT" > /dev/null
  "$UPDATE_ROOT/bin/dv-watch" > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  update_wait_idle
  update_publish
  dv-kick landed UP-1 '' remote-host "$UPDATE_NEW"
  update_wait_head
  update_wait_watcher "$UPDATE_NEW"
  test "$(cat "$DV_HOME/cursor")" = 1
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
}
update_git_fixture() {
  export UPDATE_REAL_GIT
  UPDATE_REAL_GIT=$(command -v git)
  mkdir "$CASE_DIR/git-bin"
  ln -s "$ROOT/tests/fixtures/update-git" "$CASE_DIR/git-bin/git"
  export PATH="$CASE_DIR/git-bin:$PATH"
}
case_update_parallel() {
  update_fixture; update_publish; update_git_fixture
  local pids='' pid
  for _ in 1 2 3 4; do
    "$UPDATE_ROOT/bin/dv" help > /dev/null & pids="$pids $!"
  done
  for pid in $pids; do wait "$pid"; done
  test "$(git -C "$UPDATE_ROOT" rev-parse HEAD)" = "$UPDATE_NEW"
  test "$(wc -l < "$CASE_DIR/fetches" | tr -d ' ')" = 1
  test ! -e "$UPDATE_ROOT/.git/devflow-update.lock"
}
case_update_timeout() {
  update_fixture; update_publish; update_git_fixture
  export UPDATE_FETCH_HANG=1
  local before after
  before=$(date +%s)
  "$UPDATE_ROOT/bin/dv" help > "$CASE_DIR/help" 2> "$CASE_DIR/warning"
  after=$(date +%s)
  test $((after - before)) -lt 20
  grep 'fetch failed' "$CASE_DIR/warning"
  grep 'dv manager start' "$CASE_DIR/help"
  test "$(git -C "$UPDATE_ROOT" rev-parse HEAD)" = "$UPDATE_OLD"
  test ! -e "$UPDATE_ROOT/.git/devflow-update.lock"
}
case_update_unrelated() {
  update_fixture; update_git_fixture
  "$UPDATE_ROOT/bin/dv-watch" > "$CASE_DIR/watch.log" 2>&1 & watcher=$!
  update_wait_idle
  update_publish
  dv-kick landed OTHER-1 '' "$DV_HOST" "$UPDATE_NEW"
  wait_seen 1
  touch "$DV_HOME/stop"; wait "$watcher"; watcher=''
  test "$(wc -l < "$CASE_DIR/fetches" | tr -d ' ')" = 1
  test "$(git -C "$UPDATE_ROOT" rev-parse HEAD)" = "$UPDATE_OLD"
}
