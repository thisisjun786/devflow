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
  meta_set --arg head "$head" --argjson dependencies "$dependencies" --argjson at "$(now)" \
    '.stack_waiting_since=(if .status=="waiting-base" then (.stack_waiting_since // $at) else $at end) |
     .status="waiting-base" | .stack_head=(.stack_head // $head) | .stack_dependencies=$dependencies'
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
  [ "$(jq -r .status "$S/meta")" = ready ] || return 0
  cmd_land "$1"
}
stack_resume_key() {
  jq -c '[.started,.stack_waiting_since,.stack_head,.head,.start_head,.stack_dependencies]' |
    cksum | awk '{print $1 "-" $2}'
}
cmd_stack_resume() {
  [ "$#" = 2 ] || fail 'usage: dv _stack-resume ISSUE episode'
  load_issue "$1"
  owned_lock "$S/.stack-resume-lock" "$$" || return 1
  trap 'owned_unlock "$S/.stack-resume-lock" "$$"' EXIT
  mkdir "$S/.operation" 2>/dev/null || return 1
  trap 'rmdir "$S/.operation"; owned_unlock "$S/.stack-resume-lock" "$$"' EXIT
  [ "$(jq -r .status "$S/meta")" = waiting-base ] || return 0
  [ "$(stack_resume_key < "$S/meta")" = "$2" ] || return 0
  local key=$2 pr dependency state commit commits='' base_head since prompt rc=0
  require_worktree
  pr=$(jq -er .url "$S/pr.json") || return 1
  jq -e '.stack_dependencies | type=="array" and length>0 and
    all(.[]; tostring | test("^[1-9][0-9]*$"))' "$S/meta" >/dev/null || return 1
  # Observe missing timestamps without inventing an old waiting duration.
  if ! jq -e '.stack_waiting_since | type=="number"' "$S/meta" >/dev/null; then
    meta_set --argjson at "$(now)" '.stack_waiting_since=$at'
    key=$(stack_resume_key < "$S/meta") || return 1
  fi
  for dependency in $(jq -r '.stack_dependencies[]' "$S/meta"); do
    state=$(cd "$WT" && gh pr view "${pr%/*}/$dependency" --json state,mergeCommit) || return 1
    [ "$(printf '%s\n' "$state" | jq -er .state)" = MERGED ] || return 75
    commit=$(printf '%s\n' "$state" | jq -er '.mergeCommit.oid | select(type=="string" and test("^[0-9a-f]{40,64}$"))') || return 1
    commits="$commits $commit"
  done
  git -C "$WT" fetch origin "$BASE:refs/remotes/origin/$BASE" || return 1
  base_head=$(git -C "$WT" rev-parse "refs/remotes/origin/$BASE") || return 1
  for commit in $commits; do git -C "$WT" merge-base --is-ancestor "$commit" "$base_head" || return 75; done
  # Do not revive a PR that was closed/merged or retargeted independently.
  state=$(cd "$WT" && gh pr view "$pr" --json state,baseRefName) || return 1
  printf '%s\n' "$state" | jq -e --arg base "$BASE" '.state=="OPEN" and .baseRefName==$base' >/dev/null || return 75
  since=$(jq -r .stack_waiting_since "$S/meta")
  if [ $(( $(now) - since )) -gt "$DV_STALL_AFTER" ] &&
    ! jq -e --arg key "$key" '.stack_stalled_key==$key' "$S/meta" >/dev/null; then
    cmd_kick stalled "$ISSUE" bases-merged
    meta_set --arg key "$key" '.stack_stalled_key=$key'
  fi
  # Reserve before delivery to avoid duplicates after an uncertain exit, but
  # report an interrupted send instead of silently treating it as accepted.
  if jq -e --arg key "$key" '.stack_resume.key==$key' "$S/meta" >/dev/null; then
    if [ "$(jq -r .stack_resume.status "$S/meta")" = sending ]; then
      meta_set '.stack_resume.status="uncertain"'
      cmd_kick blocked "$ISSUE" 'Stack resume acknowledgement missing; inspect stack-resume.log before retrying'
    fi
    return 75
  fi
  prompt="All stack dependencies are merged into origin/$BASE. Resume this job in its existing worktree: merge origin/$BASE, resolve any conflict while preserving local work, rerun the required checks, commit changes, run dv pr $ISSUE, wait for green CI on the current head, and finish with dv done $ISSUE. Preserve review-fix.sent and handled reviews; do not request another review or force push."
  meta_set --arg key "$key" --arg base "$base_head" --argjson at "$(now)" \
    '.stack_resume={key:$key,base:$base,status:"sending",at:$at}'
  # dv send owns its own operation lock; keep only the resume reservation.
  rmdir "$S/.operation"
  trap 'owned_unlock "$S/.stack-resume-lock" "$$"' EXIT
  "$DV_ROOT/bin/dv" send "$ISSUE" "$prompt" > "$S/stack-resume.log" 2>&1 || rc=$?
  if [ "$rc" != 0 ]; then
    meta_set '.stack_resume.status="failed"'
    cmd_kick blocked "$ISSUE" 'Stack resume delivery failed; inspect stack-resume.log before retrying'
    return 75
  fi
  # A fast worker may already have published pr/ready. Do not overwrite it.
  meta_set '.stack_resume.status="sent" | if .status=="waiting-base" then .status="running" else . end'
}
stack_worker() {
  local event=$1 host issue head remote command=_stack-land
  host=$(printf '%s\n' "$event" | jq -er .host) || return 1
  issue=$(printf '%s\n' "$event" | jq -er .issue) || return 1
  head=$(printf '%s\n' "$event" | jq -er .head) || return 1
  if [ "$(printf '%s\n' "$event" | jq -r .kind)" = stack-resume ]; then command=_stack-resume; fi
  if [ "$host" = "$DV_HOST" ]; then "$DV_ROOT/bin/dv" "$command" "$issue" "$head"
  else
    remote=$(shell_join dv "$command" "$issue" "$head")
    ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$host" "$remote"
  fi
}
stack_deferred() {
  local record=$1 rc=$2 slot=${1%.json}
  [ "$rc" = 75 ] || return 1
  jq -e '.kind=="stack-land" or .kind=="stack-resume"' "$record" >/dev/null || return 1
  # Unlike completion, deferral must not mark the stable event ID as seen.
  # A later base landing (or status reconciliation) can enqueue it again.
  rm -f "$record" "$slot.pid" "$slot.exit" "$slot.retry"
}
stack_queue_host() {
  local host=$1 rows=$2 row issue head event id slot key kind
  while IFS= read -r row; do
    issue=$(printf '%s\n' "$row" | jq -er .issue) || return 1
    kind=stack-land; id=''
    if [ "$(printf '%s\n' "$row" | jq -r .status)" = waiting-base ]; then
      kind=stack-resume
      head=$(printf '%s\n' "$row" | stack_resume_key) || return 1
    else
      head=$(printf '%s\n' "$row" | jq -er .stack_head) || return 1
      # Completion after a resume is a fresh attempt, even if an older
      # watcher already consumed an event for this same land approval.
      key=$(printf '%s\n' "$row" | jq -r '[.head // .start_head, .done_at // 0] | map(tostring) | join(":")') || return 1
      id="$host:$issue:stack-land:$head:$key"
    fi
    event=$(event_json "$kind" "$issue" 'Resume stacked job' "$host" "$head" "$id") || return 1
    id=$(printf '%s\n' "$event" | jq -r .id) || return 1
    grep -Fxq -- "$id" "$DV_HOME/seen" && continue
    key=$(printf '%s\n' "$id" | cksum | awk '{print $1 "-" $2}')
    slot="$DV_HOME/pending/stack-$key"
    [ ! -f "$slot.json" ] || continue
    printf '%s\n' "$event" > "$slot.json.tmp" || return 1
    mv "$slot.json.tmp" "$slot.json" || return 1
  done < <(printf '%s\n' "$rows" | jq -c '.[] | select(.status=="waiting-base" or
    (.stack_head!=null and .status=="ready"))')
}
stack_landed_event() {
  case "$(printf '%s\n' "$1" | jq -r .kind)" in landed|done) ;; *) return 0 ;; esac
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
