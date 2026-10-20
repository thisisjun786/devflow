#!/usr/bin/env bash
# Regression cases use only isolated homes, fake agents and local Git remotes.
# shellcheck disable=SC2016,SC2154
case_question_async() {
  question_record_setup
  question_codex_call functions.request_user_input_async "$CASE_DIR/exact-question.json" async-1
  wait_questions 1
  question_pending true
  sleep 1.2
  test "$(question_count)" = 1
  jq -cn '{type:"response_item",payload:{type:"function_call_output",call_id:"unrelated",output:"ok"}}' >> "$codex_record"
  sleep 1.2
  test "$(question_count)" = 1
  jq -cn '{type:"response_item",payload:{type:"function_call_output",call_id:"async-1",output:"answered"}}' >> "$codex_record"
  for _ in {1..100}; do question_pending false >/dev/null && break; sleep 0.05; done
  question_pending false
  question_codex_call functions.request_user_input_async "$CASE_DIR/exact-question.json" async-2
  wait_questions 2
  question_finish
}
case_question_answered() {
  question_record_setup
  question_codex_call request_user_input "$CASE_DIR/exact-question.json" answered
  jq -cn '{type:"response_item",payload:{type:"function_call_output",call_id:"answered",output:"JSON"}}' >> "$codex_record"
  question_state blocked
  wait_questions 1
  jq -se '.[0].message=="screen fallback"' "$DV_STATE/Q-1/events.log"
  question_finish
}
case_question_during_grace() {
  question_record_setup
  question_state blocked
  for _ in {1..100}; do
    if jq -se 'any(.[]; .[0:2]==["agent","wait"] and .[4]=="idle")' "$CASE_DIR/herdr/calls" >/dev/null; then break; fi
    sleep 0.01
  done
  question_codex_call request_user_input "$CASE_DIR/exact-question.json" late-record
  wait_questions 1
  jq -se --slurpfile expected "$CASE_DIR/exact-question.json" '.[0].message|fromjson==$expected[0]' "$DV_STATE/Q-1/events.log"
  sleep 1.2
  test "$(question_count)" = 1
  question_finish
}
case_question_claude_answered() {
  question_record_setup claude
  jq -cn --arg id "$question_session" '{sessionId:$id,type:"assistant",message:{content:[{type:"tool_use",id:"q1",name:"AskUserQuestion",input:{questions:[{question:"stale"}]}}]}}' > "$claude_record"
  jq -cn --arg id "$question_session" '{sessionId:$id,type:"user",message:{content:[{type:"tool_result",tool_use_id:"q1",content:"answer"}]}}' >> "$claude_record"
  question_state blocked
  wait_questions 1
  jq -se '.[0].message=="screen fallback"' "$DV_STATE/Q-1/events.log"
  question_finish
}
case_question_delivery_failure() {
  export DV_KICK=false
  question_setup
  question_state blocked
  wait_questions 1
  jq -se '.[0].delivered==false' "$DV_STATE/Q-1/events.log"
  question_pending false
  test ! -e "$DV_STATE/Q-1/question.pending"
  question_finish
}
case_question_stderr() {
  cat > "$CASE_DIR/sentinel-env" <<'ENV'
mktemp() {
  case "$*" in *'/.question.'*) printf 'sentinel diagnostic\n' >&2 ;; esac
  command mktemp "$@"
}
ENV
  export BASH_ENV="$CASE_DIR/sentinel-env"
  question_setup
  question_state blocked
  wait_questions 1
  if grep -q 'sentinel diagnostic' "$qdir/output"; then return 1; fi
  grep -F 'sentinel diagnostic' "$DV_STATE/Q-1/question.log"
  question_finish
}
case_question_tmux_off() {
  needs_tmux; repo tmux-questions
  export DV_AGENT_CMD_codex='' DV_CODEX_BIN="$ROOT/tests/fixtures/interactive" DV_CLAUDE_BIN="$ROOT/tests/fixtures/interactive"
  dv start "$REPO" QT-1 flags --mode exec; wait_done QT-1
  jq -e 'index("tools.experimental_request_user_input.enabled=false")!=null' "$DV_STATE/QT-1/args.json"
  dv start "$REPO" QT-2 flags --agent claude
  wait_file "$DV_STATE/QT-2/events.log"
  jq -e 'index("--disallowedTools") as $i | $i!=null and .[$i+1]=="AskUserQuestion"' "$DV_STATE/QT-2/args.json"
}
case_codex_trust_alias() {
  mkdir "$CASE_DIR/physical"
  ln -s "$CASE_DIR/physical" "$CASE_DIR/alias"
  DV_TEST_TMP="$CASE_DIR/alias/" bash "$ROOT/tests/run.sh" --case codex_repo_trust
}
case_claude_trust_alias() {
  mkdir "$CASE_DIR/physical"
  ln -s "$CASE_DIR/physical" "$CASE_DIR/alias"
  export DV_WORK="$CASE_DIR/alias//work"
  case_claude_start
}
case_host_descendant_timeout() {
  source "$ROOT/lib/host.sh"
  local started=$SECONDS output rc=0
  output=$(host_limit 1 bash -c 'trap "exit 0" TERM; bash -c '\''trap "" TERM; sleep 4; echo escaped'\'' & wait') || rc=$?
  printf 'elapsed=%s exit=%s output=%s\n' "$((SECONDS - started))" "$rc" "$output"
  test "$((SECONDS - started))" -lt 4
  test -z "$output"
}
case_host_npm_failure() {
  host_setup
  "$HOST_DV" host sync > "$CASE_DIR/first.txt"
  if [ "${1:-}" = symlink ]; then
    mv "$HOME/node" "$HOME/old-node"
    ln -s "$HOME/old-node" "$HOME/node"
  fi
  host_fake "$HOME/node/bin/claude" 0.0.0
  cp -R "$HOME/node/." "$CASE_DIR/node-before"
  if HOST_NPM_FAIL=1 "$HOST_DV" host sync > "$CASE_DIR/failed.txt" 2>&1; then return 1; fi
  diff -r "$CASE_DIR/node-before" "$HOME/node"
  "$HOST_DV" host sync > "$CASE_DIR/after.txt"
  "$HOME/node/bin/claude" --version | grep 2.1.304
  "$HOME/node/bin/pnpm" --version | grep 10.33.3
  test -n "$(find "$HOME" -name 'node.dv-backup.*' -type d -print)"
}
case_host_npm_failure_symlink() { case_host_npm_failure symlink; }
case_host_checksum() {
  host_setup
  local name version install scope
  cp "$CASE_DIR/host-root/hosts/tools.tsv" "$CASE_DIR/tools.tsv"
  while IFS=$'\t' read -r name version install scope; do
    case "$install" in archive|binary) ;; *) continue ;; esac
    printf '%s\t%s\t%s\t%s\n' "$name" "$version" "$install" "$scope" > "$CASE_DIR/host-root/hosts/tools.tsv"
    if HOST_BAD_CHECKSUM=1 "$HOST_DV" host sync > "$CASE_DIR/checksum-$name.txt" 2>&1; then
      printf 'Accepted invalid checksum: %s\n' "$name"; return 1
    fi
    grep -i checksum "$CASE_DIR/checksum-$name.txt"
  done < "$CASE_DIR/tools.tsv"
  test ! -e "$HOME/node"
  test ! -e "$HOME/.local/go/go"
}
case_host_path_newline() {
  host_setup
  printf 'export USER_SETTING=keep' > "$HOME/.profile"
  "$HOST_DV" host sync > "$CASE_DIR/sync.txt"
  grep -Fx 'export USER_SETTING=keep' "$HOME/.profile"
  grep -Fx '# BEGIN devflow PATH' "$HOME/.profile"
  cp "$HOME/.profile" "$CASE_DIR/once"
  "$HOST_DV" host sync > /dev/null
  cmp "$CASE_DIR/once" "$HOME/.profile"
}
case_host_auth_override() {
  host_setup
  export DV_CLAUDE_BIN="$HOME/custom/claude-wrapper" DV_DEVIN_BIN="$HOME/custom/devin-wrapper"
  mkdir -p "$HOME/custom"
  printf '#!/usr/bin/env bash\nprintf '\''{"loggedIn":true}\n'\''\n' > "$DV_CLAUDE_BIN"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$DV_DEVIN_BIN"
  chmod +x "$DV_CLAUDE_BIN" "$DV_DEVIN_BIN"
  "$HOST_DV" host check --json > "$CASE_DIR/auth.json"
  jq -e '.auth.claude.login=="logged-in" and .auth.claude.ssh=="logged-in" and .auth.devin.login=="unavailable" and .auth.devin.ssh=="unavailable"' "$CASE_DIR/auth.json"
}
case_host_npm_origin() {
  host_setup
  "$HOST_DV" host sync > /dev/null
  host_fake "$HOME/system/npm" 11.6.2
  rm "$HOME/node/bin/npm"
  ln -s "$HOME/system/npm" "$HOME/node/bin/npm"
  "$HOST_DV" host check --json > "$CASE_DIR/npm.json"
  jq -e '.tools[] | select(.name=="npm") | .login.status!="ok" and .ssh.status!="ok"' "$CASE_DIR/npm.json"
  "$HOST_DV" host sync > "$CASE_DIR/repair.txt"
  test ! -L "$HOME/node/bin/npm"
}
case_pr_body_update() {
  needs_tmux; repo public-update remote; start PU-1; wait_done PU-1
  printf 'First public body.\n\nCloses #1\n' > "$DV_STATE/PU-1/pr.md"
  DV_POLISH=1 dv pr PU-1
  wait_pr_ready PU-1
  # A supplied public body must never be handed to the polish worker.
  test ! -e "$DV_STATE/PU-1/pr-body.orig.md"
  printf 'Updated public body.\n\nCloses #1\n' > "$DV_STATE/PU-1/pr.md"
  dv pr PU-1
  wait_pr_ready PU-1
  cmp "$DV_STATE/PU-1/pr.md" "$GH_STUB_DIR/live-body"
  test "$(grep -c '^pr edit ' "$GH_STUB_DIR/calls")" = 1
  dv pr PU-1
  wait_pr_ready PU-1
  test "$(grep -c '^pr edit ' "$GH_STUB_DIR/calls")" = 1
  cp "$DV_STATE/PU-1/pr-body.md" "$CASE_DIR/last-body"
  printf 'Retry this body.\n' > "$DV_STATE/PU-1/pr.md"
  touch "$GH_STUB_DIR/edit-fail"
  if dv pr PU-1; then return 1; fi
  cmp "$CASE_DIR/last-body" "$DV_STATE/PU-1/pr-body.md"
  rm "$GH_STUB_DIR/edit-fail"
  dv pr PU-1
  wait_pr_ready PU-1
  cmp "$DV_STATE/PU-1/pr.md" "$GH_STUB_DIR/live-body"
  mkdir "$DV_STATE/PU-1/.polish"
  printf 'owned by an earlier polish\n' > "$DV_STATE/PU-1/.polish/original"
  printf 'Wait for earlier polish.\n' > "$DV_STATE/PU-1/pr.md"
  if dv pr PU-1; then return 1; fi
  test -s "$DV_STATE/PU-1/.polish/original"
  test ! -e "$DV_STATE/PU-1/.operation"
  rm "$DV_STATE/PU-1/.polish/original"
  rmdir "$DV_STATE/PU-1/.polish"
  dv pr PU-1
  wait_pr_ready PU-1
  cmp "$DV_STATE/PU-1/pr.md" "$GH_STUB_DIR/live-body"
}
