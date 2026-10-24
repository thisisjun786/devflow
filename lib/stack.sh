#!/usr/bin/env bash
# jq variables are literal; ISSUE is loaded by the caller.
# shellcheck disable=SC2016,SC2153
# Stacks use the normal land lock and the watcher's durable, bounded worker queue.
stack_waiting_base() {
  meta_set --argjson at "$(now)" \
    '.stack_waiting_since=(if .status=="waiting-base" then (.stack_waiting_since // $at) else $at end) |
     .status="waiting-base"'
}
stack_completion() {
  local head=$1
  # Match both the worker episode and the actual worktree head. Our own base
  # merges may advance that head, but unrelated commits need a fresh done.
  jq -e --arg head "$head" --slurpfile meta "$S/meta" '
    $meta[0] as $m |
    (.head | type=="string" and length>0) and
    ((.episode // "")==($m.done_episode // "")) and
    (.head==$m.head or (.head==$m.stack_update_from and $m.head==$m.stack_update_head)) and
    ($head==.head or ($head==$m.stack_update_head and .head==$m.stack_update_from))
  ' "$S/done.json" >/dev/null 2>&1
}
stack_land_gate() {
  local pr=$1 head=$2 snapshot body local_body='' dependencies dependency state base_head current
  local merge_commit merged_commits='' update_from=$head
  # cmd_land holds the operation lock here. Recheck after the automatic
  # caller's initial check in case another operation changed the episode.
  if [ "${STACK_AUTOMATIC:-0}" = 1 ]; then
    [ "$(jq -r .status "$S/meta")" = ready ] && stack_completion "$head" || return 75
  fi
  snapshot=$(cd "$WT" && gh pr view "$pr" --json body,headRefOid,baseRefName,state) || return 1
  body=$(printf '%s\n' "$snapshot" | jq -er '.body | select(type=="string")') || return 1
  [ ! -f "$S/pr.md" ] || local_body=$(cat "$S/pr.md") || return 1
  dependencies=$(jq -cn --arg body "$body" --arg local_body "$local_body" '
    [($body,$local_body) | split("\n")[] |
      select(test("^[ \\t]*Depends on[ \\t]+#[1-9][0-9]*(?:[ \\t]*[.,;][ \\t]*#[1-9][0-9]*)*[ \\t]*[.,;]?[ \\t\\r]*$")) |
      match("#([1-9][0-9]*)"; "g") | .captures[0].string] | unique') || return 1
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
    '.stack_head=(.stack_head // $head) | .stack_dependencies=$dependencies'
  git -C "$WT" merge-base --is-ancestor "$(jq -r .stack_head "$S/meta")" "$head" || fail 'stack head is no longer an ancestor'
  for dependency in $(printf '%s\n' "$dependencies" | jq -r '.[]'); do
    state=$(cd "$WT" && gh pr view "${pr%/*}/$dependency" --json state,mergeCommit) || return 1
    if [ "$(printf '%s\n' "$state" | jq -er .state)" != MERGED ]; then
      stack_waiting_base
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
      stack_waiting_base
      printf 'dv: waiting-base: dependency merge %s is absent from origin/%s\n' "$merge_commit" "$BASE" >&2
      return 75
    fi
  done
  # Recover an owned merge whose process stopped before review handoff.
  # Its old completion cannot authorize the new head, even if dependencies
  # are already present and the fast path below would otherwise accept it.
  if [ "$current" = "$head" ] && stack_completion "$head" &&
    [ "$(jq -r .head "$S/done.json")" != "$head" ]; then
    stack_waiting_base
    meta_set '.stack_review_pending=true'
    return 75
  fi
  # A pushed head that already contains every dependency merge and still
  # merges cleanly with the base needs no base update. Merging a moving base on
  # each attempt resets CI so it never lands. A conflicting base keeps the
  # update path so the conflict reaches the agent.
  if [ "$current" = "$head" ] && [ "$(jq -r .status "$S/meta")" = ready ] && stack_completion "$head" &&
    git -C "$WT" merge-tree --write-tree "$head" "$base_head" >/dev/null 2>&1; then
    local present=1
    for merge_commit in $merged_commits; do
      git -C "$WT" merge-base --is-ancestor "$merge_commit" "$head" || { present=0; break; }
    done
    [ "$present" = 0 ] || return 0
  fi
  # Preserve unfinished pr/running/waiting-base states. Only completion for
  # this episode can restore ready after waiting on a dependency.
  if stack_completion "$head"; then
    update_from=$(jq -er .head "$S/done.json") || return 1
    meta_set '.status="ready"'
  fi
  if ! git -C "$WT" merge --no-edit "$base_head"; then
    if git -C "$WT" rev-parse -q --verify MERGE_HEAD >/dev/null && [ ! -e "$S/stack-conflict.sent" ]; then
      printf 'Resolve the existing merge of origin/%s in this worktree, commit and push with dv pr %s, wait for green CI, and finish with dv done %s. Preserve pr-loop.json round counts; wait for a clean current-head Codex review with dv pr-wait --foreground. Do not force push. Stack ordering and landing remain dv responsibilities.\n' \
        "$BASE" "$ISSUE" "$ISSUE" > "$S/stack-conflict.pending"
    fi
    return 1
  fi
  require_clean "$WT"
  head=$(git -C "$WT" rev-parse HEAD) || return 1
  meta_set --arg head "$head" --arg from "$update_from" \
    '.stack_update_head=$head | .stack_update_from=$from'
  if [ "$current" != "$head" ]; then
    git -C "$WT" push origin "$BRANCH:refs/heads/$BRANCH" || return 1
  fi
  meta_set --arg head "$head" '.head=$head'
  # An automatic merge changes the reviewed head after the worker has
  # finished. Reuse the stack continuation so a worker owns CI and any
  # new P0/P1 fixes; an idle App Server cannot be revived by pr-wait alone.
  if [ "$head" != "$update_from" ] && stack_completion "$head"; then
    stack_waiting_base
    meta_set '.stack_review_pending=true'
    return 75
  fi
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
stack_review_send() {
  jq -e '.stack_review_pending==true' "$S/meta" >/dev/null || return 0
  local key
  key=$(stack_resume_key < "$S/meta") || return 1
  rmdir "$S/.operation"
  trap - EXIT
  "$DV_ROOT/bin/dv" _stack-resume "$ISSUE" "$key"
}
cmd_stack_land() {
  [ "$#" = 2 ] || fail 'usage: dv _stack-land ISSUE approved-head'
  load_issue "$1"
  case "$(jq -r .status "$S/meta")" in landed|cancelled) return 0 ;; esac
  # Old queue entries cannot authorize a different stack episode.
  jq -e --arg head "$2" '.stack_head==$head' "$S/meta" >/dev/null || return 0
  [ "$(jq -r .status "$S/meta")" = ready ] || return 0
  stack_completion "$(git -C "$WT" rev-parse HEAD)" || return 0
  STACK_AUTOMATIC=1 cmd_land "$1"
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
  prompt="All stack dependencies are merged into origin/$BASE. Resume this job in its existing worktree: merge origin/$BASE, resolve any conflict while preserving local work, rerun the required checks, commit changes, run dv pr $ISSUE, wait for green CI on the current head, and finish with dv done $ISSUE. Preserve pr-loop.json round counts; wait for a clean current-head Codex review with dv pr-wait --foreground. Do not force push."
  meta_set --arg key "$key" --arg base "$base_head" --argjson at "$(now)" \
    '.stack_resume={key:$key,base:$base,status:"sending",at:$at} | .done_episode=("stack-"+$key)'
  # Keep the operation lock through delivery: a reconciler can otherwise
  # claim it between this reservation and dv send, stranding the resume.
  # Isolate send's failure/launch traps without releasing our parent locks.
  (trap - EXIT; send_locked "$prompt") > "$S/stack-resume.log" 2>&1 || rc=$?
  if [ "$rc" != 0 ]; then
    meta_set '.stack_resume.status="failed"'
    cmd_kick blocked "$ISSUE" 'Stack resume delivery failed; inspect stack-resume.log before retrying'
    return 75
  fi
  # A fast worker may already have published pr/ready. Do not overwrite it.
  meta_set '.stack_resume.status="sent" | del(.stack_review_pending) | if .status=="waiting-base" then .status="running" else . end'
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
  local host=$1 rows=$2 row issue head event id slot key kind tmp
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
      key=$(printf '%s\n' "$row" | jq -r '[.head // .start_head, .done_at // 0, .done_episode // ""] | map(tostring) | join(":")') || return 1
      id="$host:$issue:stack-land:$head:$key"
    fi
    event=$(event_json "$kind" "$issue" 'Resume stacked job' "$host" "$head" "$id") || return 1
    id=$(printf '%s\n' "$event" | jq -r .id) || return 1
    grep -Fxq -- "$id" "$DV_HOME/seen" && continue
    key=$(printf '%s\n' "$id" | cksum | awk '{print $1 "-" $2}')
    slot="$DV_HOME/pending/stack-$key"
    [ ! -f "$slot.json" ] || continue
    # Reconciliation and landed scans run beside each other: write a private
    # temp file and publish with a no-clobber link, so one producer wins and
    # an event already consumed (seen) is not recreated.
    tmp=$(mktemp "$slot.json.XXXXXX") || return 1
    printf '%s\n' "$event" > "$tmp" || { rm -f "$tmp"; return 1; }
    if ! grep -Fxq -- "$id" "$DV_HOME/seen"; then ln "$tmp" "$slot.json" 2>/dev/null || true; fi
    rm -f "$tmp"
  done < <(printf '%s\n' "$rows" | jq -c '.[] | select(.status=="waiting-base" or
    (.stack_head!=null and .status=="ready"))')
}
stack_landed_event() {
  case "$(printf '%s\n' "$1" | jq -r .kind)" in landed|done) ;; *) return 0 ;; esac
  # Remote status takes seconds to minutes per host. The scan only enqueues
  # durable stack slots (deduplicated by id), so run it beside the queue
  # instead of holding the cursor; status reconciliation remains the backstop.
  # One scan at a time; an event during a scan asks for one more pass.
  touch "$DV_HOME/stack-scan.again"
  # A lock left by a killed watcher has no live owner; take it over. The owner
  # pid is written just after the fork, so a lock without one is still fresh.
  if [ -f "$DV_HOME/stack-scan.lock/pid" ] && ! kill -0 "$(cat "$DV_HOME/stack-scan.lock/pid" 2>/dev/null || echo 0)" 2>/dev/null; then
    rm -rf "$DV_HOME/stack-scan.lock"
  fi
  if mkdir "$DV_HOME/stack-scan.lock" 2>/dev/null; then
    (
      trap 'rm -rf "$DV_HOME/stack-scan.lock"' EXIT
      while rm "$DV_HOME/stack-scan.again" 2>/dev/null; do stack_landed_scan || true; done
    ) >> "$DV_HOME/stack.log" 2>&1 &
    # Bash 3.2 has no BASHPID: the parent records the scan owner.
    printf '%s\n' "$!" > "$DV_HOME/stack-scan.lock/pid" 2>/dev/null || true
  fi
  return 0
}
stack_landed_scan() {
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
