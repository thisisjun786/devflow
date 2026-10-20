#!/usr/bin/env bash
# jq filters intentionally use literal dollars.
# shellcheck disable=SC2016
herdr_bin() {
  if command -v herdr >/dev/null 2>&1; then command -v herdr
  elif [ -x "$HOME/.local/bin/herdr" ]; then printf '%s\n' "$HOME/.local/bin/herdr"
  else return 1; fi
}
herdr_cmd() {
  local bin
  bin=$(herdr_bin) || { printf 'dv: herdr is unavailable\n' >&2; return 1; }
  "$bin" "$@"
}
herdr_start() {
  local launcher=$1 reply workspace pane
  reply=$(herdr_cmd workspace create --label "$SESSION" --cwd "$WT" --no-focus) || return 1
  workspace=$(printf '%s\n' "$reply" | jq -er '.result.workspace.workspace_id | select(type=="string" and length>0)') || return 1
  # Record ownership before waiting, so clean can remove a partial startup.
  meta_set --arg workspace "$workspace" '.herdr_workspace=$workspace'
  pane=$(printf '%s\n' "$reply" | jq -er '.result.root_pane.pane_id | select(type=="string" and length>0)') || return 1
  meta_set --arg pane "$pane" '.herdr_pane=$pane'
  # Match a prompt marker in the fresh pane without depending on line endings
  # or right-prompt decorations. Verified against herdr 0.9.1's Rust matcher.
  herdr_cmd pane wait-output "$pane" --regex '[$#%>❯➜›]' --source recent-unwrapped --timeout "$((DV_START_WAIT * 1000))" >/dev/null || return 1
  # agent start uses canonical executables; pane run preserves configured binaries,
  # DV_* environment and the _agent exit/done wrapper in the pane's own foreground.
  # This command is silent on success; its exit status is the acknowledgement.
  herdr_cmd pane run "$pane" "$launcher"
}
herdr_send_text() {
  local text=$1 reply rc attempt
  for attempt in 1 2; do
    rc=0
    reply=$(herdr_cmd agent prompt "$HERDR_PANE" "$text" 2>&1) || rc=$?
    if printf '%s\n' "$reply" | jq -e '.error.code=="agent_blocked"' >/dev/null 2>&1 && [ "$attempt" = 1 ]; then
      # A blocked submission sends no input. Wait, then make exactly one retry.
      herdr_cmd agent wait "$HERDR_PANE" --until idle --until 'done' --until working --timeout "$((DV_START_WAIT * 1000))" >/dev/null || true
      continue
    fi
    if [ "$rc" = 0 ] && printf '%s\n' "$reply" | jq -e '.error==null and .result.type=="agent_prompted"' >/dev/null 2>&1; then return 0; fi
    printf 'dv: herdr prompt failed: %s\n' "$reply" >&2
    return 1
  done
}
herdr_read() {
  local pane=$1; shift
  herdr_cmd pane read "$pane" --source recent-unwrapped "$@"
}
herdr_snapshot() {
  [ -n "$HERDR_PANE" ] || return 0
  local tmp
  tmp=$(mktemp "$S/.log.XXXXXX") || return 1
  if herdr_read "$HERDR_PANE" > "$tmp"; then mv "$tmp" "$S/log"
  else rm -f "$tmp"; return 1; fi
}
herdr_info() {
  local reply
  if reply=$(herdr_cmd agent get "$1") && printf '%s\n' "$reply" | jq -e '.result.agent | type=="object"' >/dev/null; then
    printf '%s\n' "$reply" | jq -c '.result.agent'
  else
    herdr_cmd pane get "$1" | jq -ec '.result.pane | select(type=="object")'
  fi
}
herdr_clean() {
  local workspace reply rc=0
  workspace=$(jq -er '.herdr_workspace | select(type=="string" and length>0)' "$S/meta") || return 0
  reply=$(herdr_cmd workspace get "$workspace" 2>&1) || rc=$?
  if printf '%s\n' "$reply" | jq -e '.error.code=="workspace_not_found"' >/dev/null 2>&1; then
    meta_set 'del(.herdr_workspace,.herdr_pane)'
    return 0
  fi
  [ "$rc" = 0 ] || return 1
  # A saved id alone is insufficient if the server has reused it for another label.
  printf '%s\n' "$reply" | jq -e --arg workspace "$workspace" --arg label "$SESSION" \
    '.result.workspace | .workspace_id==$workspace and .label==$label' >/dev/null || return 1
  herdr_snapshot || printf 'dv: warning: could not capture herdr log for %s\n' "$ISSUE" >&2
  reply=$(herdr_cmd workspace close "$workspace") || return 1
  printf '%s\n' "$reply" | jq -e '.result!=null and .error==null' >/dev/null || return 1
  meta_set 'del(.herdr_workspace,.herdr_pane)'
}
