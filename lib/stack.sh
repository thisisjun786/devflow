#!/usr/bin/env bash
# jq variables are literal; ISSUE is loaded by the caller.
# shellcheck disable=SC2016,SC2153
# Stacks use the normal land lock and the watcher's durable, bounded worker queue.
stack_land_gate() {
  local pr=$1 head=$2 snapshot body local_body='' dependencies dependency state base_head current
  local merge_commit merged_commits=''
  snapshot=$(cd "$WT" && gh pr view "$pr" --json body,headRefOid,baseRefName,state) || return 1
  body=$(printf '%s\n' "$snapshot" | jq -er '.body | select(type=="string")') || return 1
  [ ! -f "$S/pr.md" ] || local_body=$(cat "$S/pr.md") || return 1
  dependencies=$(jq -cn --arg body "$body" --arg local_body "$local_body" '
    [($body,$local_body) | split("\n")[] |
      capture("^[ \\t]*Depends on #(?<number>[1-9][0-9]*)[ \\t\\r]*$") | .number] | unique') || return 1
  [ "$dependencies" != '[]' ] || return 0
  [ "$BRANCH" != "$BASE" ] || fail 'cannot push the base branch'
  printf '%s\n' "$snapshot" | jq -e --arg base "$BASE" '.baseRefName==$base and .state=="OPEN"' >/dev/null || fail 'PR base/state mismatch'
  current=$(printf '%s\n' "$snapshot" | jq -er .headRefOid) || return 1
  if [ "$current" != "$head" ]; then
    # Recover only our own merge after an interrupted/failed push. Never push
    # over an unrelated remote update or silently accept a changed local head.
    if ! jq -e --arg head "$head" '.stack_update_head==$head' "$S/meta" >/dev/null ||
      ! git -C "$WT" merge-base --is-ancestor "$current" "$head"; then fail 'PR head mismatch'; fi
  fi
  meta_set --arg head "$head" --argjson dependencies "$dependencies" \
    '.status="waiting-base" | .stack_head=(.stack_head // $head) | .stack_dependencies=$dependencies'
  git -C "$WT" merge-base --is-ancestor "$(jq -r .stack_head "$S/meta")" "$head" || fail 'stack head is no longer an ancestor'
  for dependency in $(printf '%s\n' "$dependencies" | jq -r '.[]'); do
    state=$(cd "$WT" && gh pr view "${pr%/*}/$dependency" --json state,mergeCommit) || return 1
    if [ "$(printf '%s\n' "$state" | jq -er .state)" != MERGED ]; then
      printf 'dv: waiting-base: PR #%s is not merged\n' "$dependency" >&2
      return 75 # Wait for another landed event, not continuous dependency polls.
    fi
    merge_commit=$(printf '%s\n' "$state" | jq -er '.mergeCommit.oid | select(type=="string" and test("^[0-9a-f]{40,64}$"))') || return 1
    merged_commits="$merged_commits $merge_commit"
  done
  # Capture an immutable commit, not FETCH_HEAD shared by sibling worktrees.
  git -C "$WT" fetch origin "$BASE:refs/remotes/origin/$BASE" || return 1
  base_head=$(git -C "$WT" rev-parse "refs/remotes/origin/$BASE") || return 1
  for merge_commit in $merged_commits; do
    # GitHub records the resulting merge/squash commit or final rebased commit.
    # MERGED into a different branch alone does not satisfy this stack's base.
    if ! git -C "$WT" merge-base --is-ancestor "$merge_commit" "$base_head"; then
      printf 'dv: waiting-base: dependency merge %s is absent from origin/%s\n' "$merge_commit" "$BASE" >&2
      return 75
    fi
  done
  if ! git -C "$WT" merge --no-edit "$base_head"; then
    if git -C "$WT" rev-parse -q --verify MERGE_HEAD >/dev/null && [ ! -e "$S/stack-conflict.sent" ]; then
      printf 'Resolve the existing merge of origin/%s in this worktree, commit and push with dv pr %s, wait for green CI, and finish with dv done %s. Preserve review-fix.sent; do not request another review or force push. Stack ordering and landing remain dv responsibilities.\n' \
        "$BASE" "$ISSUE" "$ISSUE" > "$S/stack-conflict.pending"
    fi
    return 1
  fi
  require_clean "$WT"
  head=$(git -C "$WT" rev-parse HEAD) || return 1
  meta_set --arg head "$head" '.stack_update_head=$head'
  if [ "$current" != "$head" ]; then
    git -C "$WT" push origin "$BRANCH:refs/heads/$BRANCH" || return 1
  fi
  meta_set --arg head "$head" '.head=$head'
  # cmd_land now queries CI again and pins the merge to this updated head.
}
stack_conflict_send() {
  [ -f "$S/stack-conflict.pending" ] && [ ! -e "$S/stack-conflict.sent" ] || return 0
  # Reserve the single request while still holding land's operation lock.
  mv "$S/stack-conflict.pending" "$S/stack-conflict.sent"
  rmdir "$S/.operation"
  trap - EXIT
  "$DV_ROOT/bin/dv" send "$ISSUE" "$(cat "$S/stack-conflict.sent")" > "$S/stack-conflict.log" 2>&1 || {
    printf 'dv: stack conflict request failed; see stack-conflict.log\n' >&2
    return 1
  }
}
cmd_stack_land() {
  [ "$#" = 2 ] || fail 'usage: dv _stack-land ISSUE approved-head'
  load_issue "$1"
  case "$(jq -r .status "$S/meta")" in landed|cancelled) return 0 ;; esac
  # Old queue entries cannot authorize a different stack episode.
  jq -e --arg head "$2" '.stack_head==$head' "$S/meta" >/dev/null || return 0
  cmd_land "$1"
}
stack_worker() {
  local event=$1 host issue head remote
  host=$(printf '%s\n' "$event" | jq -er .host) || return 1
  issue=$(printf '%s\n' "$event" | jq -er .issue) || return 1
  head=$(printf '%s\n' "$event" | jq -er .head) || return 1
  if [ "$host" = "$DV_HOST" ]; then "$DV_ROOT/bin/dv" _stack-land "$issue" "$head"
  else
    remote=$(shell_join dv _stack-land "$issue" "$head")
    ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$host" "$remote"
  fi
}
stack_deferred() {
  local record=$1 rc=$2 slot=${1%.json}
  [ "$rc" = 75 ] || return 1
  jq -e '.kind=="stack-land"' "$record" >/dev/null || return 1
  # Unlike completion, deferral must not mark the stable event ID as seen.
  # A later base landing (or status reconciliation) can enqueue it again.
  rm -f "$record" "$slot.pid" "$slot.exit" "$slot.retry"
}
stack_queue_host() {
  local host=$1 rows=$2 row issue head event id slot key
  while IFS= read -r row; do
    issue=$(printf '%s\n' "$row" | jq -er .issue) || return 1
    head=$(printf '%s\n' "$row" | jq -er .stack_head) || return 1
    event=$(event_json stack-land "$issue" 'Resume stacked land' "$host" "$head") || return 1
    id=$(printf '%s\n' "$event" | jq -r .id) || return 1
    grep -Fxq -- "$id" "$DV_HOME/seen" && continue
    key=$(printf '%s\n' "$id" | cksum | awk '{print $1 "-" $2}')
    slot="$DV_HOME/pending/stack-$key"
    [ ! -f "$slot.json" ] || continue
    printf '%s\n' "$event" > "$slot.json.tmp" || return 1
    mv "$slot.json.tmp" "$slot.json" || return 1
  done < <(printf '%s\n' "$rows" | jq -c '.[] | select(.stack_head!=null and .status!="landed" and .status!="cancelled")')
}
stack_landed_event() {
  [ "$(printf '%s\n' "$1" | jq -r .kind)" = landed ] || return 0
  local host rows result=0
  # Scan each configured host; dependency PRs are always resolved in the
  # candidate's own repository. Unrelated landed events cannot bypass a base.
  for host in $(printf '%s\n' "$DV_HOST $DV_HOSTS" | tr ' ' '\n' | sort -u); do
    if [ "$host" = "$DV_HOST" ]; then
      rows=$("$DV_ROOT/bin/dv" status --json) || continue
    else
      rows=$(ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$host" 'dv status --json') || continue
    fi
    # An unavailable host is retried by the existing status reconciliation;
    # it must not hold the landed queue cursor and unrelated stacks hostage.
    printf '%s\n' "$rows" | jq -e 'type=="array"' >/dev/null || continue
    stack_queue_host "$host" "$rows" || result=1
  done
  return "$result"
}
