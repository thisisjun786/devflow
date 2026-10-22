#!/usr/bin/env bash
# Self-contained QA jobs until the general task-job backend is available.
# Job metadata globals are deliberately scoped to each runner/CLI subshell.
# shellcheck disable=SC2016,SC2030,SC2031
qa_alive() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] && kill -0 "$1" 2>/dev/null &&
    [ "$(ps -p "$1" -o stat= 2>/dev/null | cut -c 1)" != Z ]
}
qa_job_id() {
  local repository=$1 head=$2 slug key
  slug=$(printf '%s' "$repository" | tr -c 'A-Za-z0-9_-' '-')
  key=$(printf '%s' "$repository" | cksum | awk '{print $1}')
  printf 'QA-%s-%s-%s\n' "$slug" "$key" "${head:0:12}"
}
qa_enqueue() {
  local event=$1 repo key dir remote base='' issue host tmp head token record=''
  issue=$(jq -er '.issue | select(test("^[A-Za-z0-9][A-Za-z0-9_-]*$"))' <<< "$event") || return 0
  host=$(jq -r .host <<< "$event"); head=$(jq -r .head <<< "$event"); token=$(jq -r '.token // ""' <<< "$event")
  # Operator-owned job records are the repository allowlist. A remote queue
  # or status response cannot nominate a repository or grant QA authority.
  if [ "$host" = "$DV_HOST" ] && [ -f "$DV_STATE/$issue/meta" ]; then
    record=$(jq -ce --arg host "$host" --arg head "$head" --arg token "$token" \
      'select(.host==$host and .status=="landed" and .head==$head and (.award_token // "")==$token)' \
      "$DV_STATE/$issue/meta") || record=''
  elif [ -f "$DV_HOME/submissions/$issue/task.json" ] && [ -n "$token" ]; then
    record=$(jq -ce --arg host "$host" --arg head "$head" --arg token "$token" \
      'select(.host==$host and .status=="completed" and .head==$head and .token==$token)' \
      "$DV_HOME/submissions/$issue/task.json") || record=''
  fi
  if [ -z "$record" ]; then
    printf 'Ignoring QA event without an authorized landed job: %s\n' "$issue"
    return 0
  fi
  repo=$(jq -er .repo <<< "$record") || return 1
  base=$(jq -r '.base // ""' <<< "$record")
  key=$(manager_identity "$repo") || return 1
  case "$key" in github.com/*/*) ;; *) return 0 ;; esac
  remote="https://$key.git"
  if [ -d "$repo" ]; then
    remote=$(git -C "$repo" ls-remote --get-url origin) || return 1
  fi
  dir="$DV_HOME/qa/$(printf '%s' "$key" | cksum | awk '{print $1 "-" $2}')"
  mkdir -p "$dir"
  if [ -f "$dir/identity" ]; then [ "$(cat "$dir/identity")" = "$key" ] || return 1
  else printf '%s\n' "$key" > "$dir/identity"; fi
  # The watcher is the sole writer. Arrivals replace only the pending request,
  # never the immutable request owned by a running QA process.
  tmp=$(mktemp "$dir/.pending.XXXXXX") || return 1
  jq -cn --argjson event "$event" --arg repo "${key#github.com/}" --arg remote "$remote" --arg base "$base" \
    '{event:$event,repository:$repo,remote:$remote,base:$base}' > "$tmp"
  mv "$tmp" "$dir/pending.json"
}
qa_recover() {
  local marker dir runner child
  for marker in "$DV_HOME"/qa/*/pid; do
    [ -f "$marker" ] || continue
    dir=$(dirname "$marker")
    runner=$(cat "$dir/runner.pid" 2>/dev/null) || runner=$(cat "$marker")
    child=$(cat "$dir/child.pid" 2>/dev/null || true)
    if qa_alive "$runner" || qa_alive "$child"; then
      case " $pids " in *" $runner "*) ;; *) active=$((active + 1)) ;; esac
    fi
  done
}
qa_dispatch() {
  local request dir pid child
  for request in "$DV_HOME"/qa/*/pending.json; do
    [ "$active" -lt "$DV_MAX_WORKERS" ] || break
    [ -f "$request" ] || continue
    dir=$(dirname "$request")
    if [ -f "$dir/pid" ]; then
      pid=$(cat "$dir/pid"); child=$(cat "$dir/child.pid" 2>/dev/null || true)
      if qa_alive "$pid" || qa_alive "$child"; then continue; fi
      # An interrupted job is retained for inspection, never restarted with
      # uncertain external effects. A later landing may start the latest head.
      rm -f "$dir/pid" "$dir/child.pid" "$dir/claim" "$dir/runner.pid"
    fi
    mv "$request" "$dir/running.json"
    printf '%s\n' "$$" > "$dir/pid"
    "$DV_ROOT/bin/dv" _qa-run "$dir" >> "$dir/log" 2>&1 &
    pid=$!
    printf '%s\n' "$pid" > "$dir/runner.pid"
    pids="$pids $pid"; active=$((active + 1))
  done
}
qa_settings() (
  local line key value
  cd "$1" || exit 1
  if [ -f .devflow ]; then
    # Opt-in discovery is data, not permission to execute repository code on
    # the watcher. Read only literal QA assignments; never source .devflow.
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?(DV_QA|DV_QA_AGENT)= ]]; then
        key=${BASH_REMATCH[2]}
        value=$(printf '%s' "${line#*=}" | sed 's/[[:space:]]*#.*$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$value" in \"*\") value=${value#\"}; value=${value%\"} ;; \'*\') value=${value#\'}; value=${value%\'} ;; esac
        if [ "$key" = DV_QA ]; then DV_QA=$value; else DV_QA_AGENT=$value; fi
      fi
    done < .devflow
  fi
  case "$DV_QA" in 0|1) ;; *) fail 'DV_QA must be 0 or 1' ;; esac
  case "$DV_QA_AGENT" in codex|claude) ;; *) fail 'DV_QA_AGENT must be codex or claude' ;; esac
  jq -cn --arg enabled "$DV_QA" --arg agent "$DV_QA_AGENT" '{enabled:($enabled=="1"),agent:$agent}'
)
qa_merged_pr() {
  local repository=$1 head=$2 base=${3:-} result attempt reason
  # GitHub can associate the merge commit with its PR after the landed event.
  # Keep the latest-base selection for coalesced jobs, but bound the wait.
  for attempt in 1 2 3 4 5 6; do
    if ! result=$(gh api "repos/$repository/commits/$head/pulls"); then
      reason='request failed'
    elif ! result=$(jq -cs --arg base "$base" '
      if length==1 and (.[0]|type)=="array" then .[0]
      else error("expected a PR array") end |
      [.[] | select(.merged_at!=null and ($base=="" or .base.ref==$base))] |
      sort_by(.merged_at) | last' <<< "$result"); then
      reason='invalid PR response'
    elif [ "$result" != null ]; then
      printf '%s\n' "$result"; return 0
    else
      reason='no merged PR'
    fi
    printf 'QA pr lookup: %s for %s at %s (attempt %s/6)\n' "$reason" "$repository" "$head" "$attempt" >&2
    [ "$attempt" = 6 ] || sleep 5
  done
  return 1
}
qa_milestone() {
  local repository=$1 pr=$2 result
  result=$(jq -c '.milestone // empty' <<< "$pr")
  if [ -n "$result" ]; then printf '%s\n' "$result"; return; fi
  # Closing issues carry the milestone when the PR itself has none. Refuse
  # ambiguity rather than silently attributing findings to a later milestone.
  # gh 2.46 does not expose closingIssuesReferences through pr view --json.
  result=$(gh api graphql --paginate -f owner="${repository%%/*}" -f name="${repository#*/}" \
    -F number="$(jq -r .number <<< "$pr")" -f query='
      query($owner:String!, $name:String!, $number:Int!, $endCursor:String) {
        repository(owner:$owner, name:$name) {
          pullRequest(number:$number) {
            closingIssuesReferences(first:100, after:$endCursor) {
              nodes { number milestone { number title } }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
      }') || return 1
  result=$(jq -sce 'if length==0 or any(.[]; (.errors | length)>0 or
      (.data.repository.pullRequest.closingIssuesReferences.nodes | type)!="array")
    then error("QA milestone: invalid closing issues response")
    else [.[].data.repository.pullRequest.closingIssuesReferences.nodes[].milestone // empty] | unique_by(.number) end' <<< "$result") || return 1
  case "$(jq length <<< "$result")" in
    0) printf 'null\n' ;;
    1) jq -c '.[0]' <<< "$result" ;;
    *) fail 'QA milestone: multiple distinct milestones on closing issues' ;;
  esac
}
qa_run_cleanup() {
  local rc=$? reason
  trap - EXIT INT TERM
  if [ -n "${qa_child:-}" ]; then bid_stop_tree "$qa_child"; wait "$qa_child" 2>/dev/null || true; fi
  reason=${qa_failure_reason:-"QA failed at $qa_step (exit $rc); inspect log before retrying"}
  if [ "$rc" != 0 ]; then
    printf '%s\n' "$reason" >&2
    if [ -z "${S:-}" ] || [ ! -f "$S/meta" ]; then
      jq -n --arg reason "$reason" '{status:"blocked",failure_reason:$reason}' > "$qa_dir/meta"
    fi
  fi
  if [ -n "${S:-}" ] && [ -f "$S/meta" ]; then
    printf '%s\n' "$rc" > "$S/agent.exit"
    if [ "$rc" != 0 ]; then
      meta_set --arg reason "$reason" '.status="blocked" | .failure_reason=$reason'
      [ -n "${qa_failure_reason:-}" ] || cmd_kick blocked "$ISSUE" "$reason"
    fi
  fi
  printf '%s\n' "$rc" > "$qa_dir/exit"
  rm -f "$qa_dir/child.pid"
  # Retain the reservation until the process really exits. The watcher checks
  # liveness, so a restart cannot overlap a finishing child.
  exit "$rc"
}
cmd__qa_run() (
  [ "$#" = 1 ] || fail 'usage: dv _qa-run <qa-directory>'
  local qa_dir=$1 qa_child='' scratch repository remote base head settings agent pr milestone prompt
  local S='' ISSUE='' WT='' qa_step='request'
  local qa_failure_reason='' rc session='' new_session instruction attempt=0 output
  local args=()
  [ "$(dirname "$qa_dir")" = "$DV_HOME/qa" ] || fail 'invalid QA directory'
  [ "$(cat "$qa_dir/pid")" = "$PPID" ] || fail 'QA runner has no parent reservation'
  (set -C; printf '%s\n' "$$" > "$qa_dir/claim") 2>/dev/null || fail 'QA reservation already claimed'
  printf '%s\n' "$$" > "$qa_dir/pid"
  trap qa_run_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  repository=$(jq -er .repository "$qa_dir/running.json")
  remote=$(jq -er .remote "$qa_dir/running.json")
  base=$(jq -r .base "$qa_dir/running.json")
  if [ -z "$base" ]; then
    # A remote job may target dev while origin/HEAD names a release branch.
    head=$(jq -er .event.head "$qa_dir/running.json")
    qa_step='pr lookup'
    pr=$(qa_merged_pr "$repository" "$head")
    base=$(jq -er '.base.ref // empty' <<< "$pr")
  fi
  qa_step='checkout'
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/dv-qa.XXXXXX")
  printf '%s\n' "$scratch" > "$qa_dir/scratch"
  git clone --quiet --no-hardlinks --no-checkout "$remote" "$scratch/source"
  git -C "$scratch/source" checkout --quiet --detach "refs/remotes/origin/$base"
  head=$(git -C "$scratch/source" rev-parse HEAD)
  qa_step='settings'
  settings=$(qa_settings "$scratch/source")
  if ! jq -e .enabled <<< "$settings" >/dev/null; then
    printf 'QA disabled: %s\n' "$repository"
    # This pristine clone is ours; no agent has run and no user work exists.
    rm -rf "$scratch"
    exit 0
  fi
  qa_step='job setup'
  ISSUE=$(qa_job_id "$repository" "$head"); valid_issue "$ISSUE"
  S="$DV_STATE/$ISSUE"
  if [ -e "$S" ]; then
    printf 'QA head already reserved: %s\n' "$ISSUE"
    rm -rf "$scratch"; S=''; exit 0
  fi
  mkdir "$S"
  WT="$scratch/source"
  git -C "$WT" checkout --quiet -b "$ISSUE"
  agent=$(jq -r .agent <<< "$settings")
  jq -n --arg issue "$ISSUE" --arg repo "https://github.com/$repository.git" --arg repository "$repository" --arg wt "$WT" --arg base "$base" \
    --arg head "$head" --arg host "$DV_HOST" --arg agent "$agent" --arg scratch "$scratch" --argjson started "$(now)" \
    '{issue:$issue,kind:"qa",repo:$repo,repository:$repository,worktree:$wt,branch:$issue,base:$base,head:$head,start_head:$head,
      host:$host,agent:$agent,backend:"qa",status:"running",started:$started,scratch:$scratch}' > "$S/meta"
  printf '%s\n' "$$" > "$S/agent.pid"
  # Select the most recent merged PR for this base, including a newer merge
  # coalesced while a prior QA run held the repository reservation.
  qa_step='pr lookup'
  pr=$(qa_merged_pr "$repository" "$head" "$base")
  meta_set --argjson pr "$pr" '.pr=$pr.number'
  qa_step='milestone'
  milestone=$(qa_milestone "$repository" "$pr")
  meta_set --argjson milestone "$milestone" '.milestone=$milestone'
  qa_step='agent setup'
  mkdir -m 700 "$scratch/home" "$scratch/state" "$scratch/out"
  prompt="$S/brief.md"
  cat "$DV_ROOT/templates/qa-prompt.md" > "$prompt"
  printf '\nJob: %s\nRepository: %s\nHead: %s\nMilestone: %s\nIsolated product home/state/output: %s/{home,state,out}\nReport: %s/report.md\n' \
    "$ISSUE" "$repository" "$head" "$(jq -r '.title // "none"' <<< "$milestone")" "$scratch" "$S" >> "$prompt"
  export DV_ISSUE="$ISSUE" DV_QA_SCRATCH="$scratch"
  instruction=$(cat "$prompt")
  while :; do
  attempt=$((attempt + 1)); output="$S/agent-$attempt.log"
  export DV_AGENT_INSTRUCTION="$instruction"
  if [ -n "$DV_QA_AGENT_CMD" ]; then
    (cd "$WT" && bash -c "$DV_QA_AGENT_CMD \"\$@\"" dv-qa "$prompt") > "$output" 2>&1 & qa_child=$!
  elif [ "$agent" = codex ]; then
    codex_environment || fail 'Codex environment unavailable'
    args=("$DV_CODEX_BIN" -m "$DV_CODEX_MODEL" -c "model_reasoning_effort=\"$DV_CODEX_EFFORT\""
      --disable hooks -c 'plugins."crw@crw".enabled=false' exec)
    if [ -n "$session" ]; then args+=(resume --json --dangerously-bypass-approvals-and-sandbox "$session")
    else args+=(--json --dangerously-bypass-approvals-and-sandbox); fi
    (cd "$WT" && "${args[@]}" "$instruction") > "$output" 2>&1 & qa_child=$!
  else
    # The QA workspace is isolated; preserve it and include the original brief
    # on continuation even when the CLI does not persist a provider session.
    (cd "$WT" && "$DV_CLAUDE_BIN" --model "$DV_CLAUDE_MODEL" --dangerously-skip-permissions \
      --no-session-persistence -p "$instruction") > "$output" 2>&1 & qa_child=$!
  fi
  printf '%s\n' "$qa_child" > "$qa_dir/child.pid"
  qa_step='agent'
  rc=0; wait "$qa_child" || rc=$?; qa_child=''
  rm -f "$qa_dir/child.pid"
  cat "$output" >> "$S/log"
  if capacity_output_error "$output" "$rc"; then
    new_session=$(jq -Rr 'fromjson? | select(.type=="thread.started") | .thread_id // empty' "$output" | tail -n 1)
    [ -z "$new_session" ] || session=$new_session
    if ! capacity_wait; then
      qa_failure_reason=$(jq -r .failure_reason "$S/meta")
      exit 1
    fi
    instruction="Continue the interrupted request in this worktree. Preserve existing changes and findings; do not start over.
$(cat "$prompt")"
    continue
  fi
  capacity_clear
  [ "$rc" = 0 ] || exit "$rc"
  break
  done
  [ -f "$S/done.json" ] || fail 'QA exited without dv done'
)
qa_load() {
  load_issue "$1"
  [ "$(jq -r '.kind // empty' "$S/meta")" = qa ] || fail 'not a QA job'
}
qa_open_issues() {
  gh api --paginate "repos/$(jq -r .repository "$S/meta")/issues?state=open&per_page=100" | jq -sc 'add | map(select(.pull_request==null))'
}
qa_finding() (
  [ "$#" = 2 ] || fail 'usage: dv qa finding ISSUE finding.json'
  qa_load "$1"; issue_lock
  local finding=$2 data title kind repository marker match issues body result milestone
  data=$(jq -ce 'select((.kind=="bug" or .kind=="feature") and
    ([.title,.steps,.expected,.actual,.evidence] | all(.[]; type=="string" and length>0)))' "$finding") || fail 'invalid QA finding'
  title=$(jq -r .title <<< "$data"); kind=$(jq -r .kind <<< "$data")
  repository=$(jq -r .repository "$S/meta"); milestone=$(jq -r .milestone.number "$S/meta")
  marker="<!-- devflow-qa:$ISSUE:$(printf '%s' "$data" | cksum | awk '{print $1 "-" $2}') -->"
  if [ -f "$S/findings.jsonl" ] && jq -se --arg marker "$marker" 'any(.[]; .marker==$marker)' "$S/findings.jsonl" >/dev/null; then return; fi
  # Search all open titles before any write; the agent can supply match after
  # keyword search when titles differ. A supplied match must still be open.
  issues=$(qa_open_issues)
  match=$(jq -r --arg title "$title" --argjson data "$data" '[.[] | select(
    if $data.match!=null then .number==$data.match
    else (.title|ascii_downcase)==($title|ascii_downcase) end)] | first | .number // empty' <<< "$issues")
  if jq -e '.match!=null' <<< "$data" >/dev/null && [ -z "$match" ]; then fail 'matching issue is no longer open'; fi
  body=$(mktemp "$S/.finding.XXXXXX")
  {
    printf '%s\n\n' "$marker"
    printf 'QA at `%s` · milestone **%s**\n\n' "$(jq -r .head "$S/meta")" "$(jq -r '.milestone.title // "none"' "$S/meta")"
    jq -r '"## Steps\n"+.steps+"\n\n## Expected\n"+.expected+"\n\n## Actual\n"+.actual+"\n\n## Evidence\n"+.evidence' <<< "$data"
  } > "$body"
  # Create only missing labels; never overwrite a repository's existing label.
  gh label create qa -R "$repository" --color 7057ff --description 'Real-use QA finding' 2>/dev/null || gh label list -R "$repository" --json name --jq '.[].name' | grep -Fxq qa
  gh label create "$kind" -R "$repository" --color d73a4a --description 'QA finding type' 2>/dev/null || gh label list -R "$repository" --json name --jq '.[].name' | grep -Fxq "$kind"
  if [ -n "$match" ]; then
    local milestone_args=()
    if [ "$milestone" != null ]; then milestone_args=(--milestone "$(jq -r .milestone.title "$S/meta")"); fi
    gh issue edit "$match" -R "$repository" --add-label "qa,$kind" ${milestone_args[@]+"${milestone_args[@]}"}
    result=$(gh api --paginate "repos/$repository/issues/$match/comments?per_page=100" | jq -sc --arg marker "$marker" 'add | any(.[]; (.body // "")|contains($marker))')
    if [ "$result" != true ]; then gh issue comment "$match" -R "$repository" --body-file "$body"; fi
    result="https://github.com/$repository/issues/$match"
  else
    # API gives an unambiguous number and preserves the current milestone.
    result=$(jq -n --arg title "$title" --rawfile body "$body" --arg kind "$kind" --argjson milestone "$milestone" \
      '{title:$title,body:$body,labels:["qa",$kind]} + (if $milestone==null then {} else {milestone:$milestone} end)' |
      gh api --method POST "repos/$repository/issues" --input -)
    result=$(jq -er .html_url <<< "$result")
  fi
  jq -cn --arg marker "$marker" --arg url "$result" --arg match "$match" \
    '{marker:$marker,url:$url,action:(if $match=="" then "opened" else "commented" end)}' >> "$S/findings.jsonl"
  # Publish after GitHub and the finding receipt commit, before QA completion.
  # A matching issue's new qa label can also change scheduling priority.
  if [ -z "$match" ]; then cmd_kick issue-opened "$ISSUE" "$result"
  else cmd_kick issue-edited "$ISSUE" "$result"; fi
  rm "$body"
  printf '%s\n' "$result"
)
qa_done() (
  qa_load "$1"; issue_lock
  local repository pr marker comments body head
  [ -s "$S/report.md" ] || fail 'QA needs report.md with journeys and findings'
  head=$(jq -r .head "$S/meta")
  [ "$(git -C "$WT" rev-parse HEAD)" = "$head" ] || fail 'QA must not commit fixes'
  git -C "$WT" diff --quiet HEAD -- || fail 'QA must not change tracked product files'
  [ ! -f "$S/done.json" ] || return 0
  repository=$(jq -r .repository "$S/meta"); pr=$(jq -r .pr "$S/meta")
  marker="<!-- devflow-qa-summary:$ISSUE -->"
  body="$S/summary.md"
  { printf '%s\n\n' "$marker"; cat "$S/report.md"; printf '\nTested head: `%s`\n\n' "$head"
    [ ! -f "$S/findings.jsonl" ] || jq -r '"- "+.action+": "+.url' "$S/findings.jsonl"
  } > "$body"
  comments=$(gh api --paginate "repos/$repository/issues/$pr/comments?per_page=100" | jq -sc --arg marker "$marker" 'add | any(.[]; (.body // "")|contains($marker))')
  if [ "$comments" != true ]; then gh pr comment "$pr" -R "$repository" --body-file "$body"; fi
  jq -n --arg head "$head" --arg report "$S/report.md" --argjson time "$(now)" '{head:$head,report:$report,done_at:$time}' > "$S/done.json"
  meta_set --argjson time "$(now)" '.status="done" | .done_at=$time'
  cmd_kick 'done' "$ISSUE" 'QA complete; findings enter the current milestone queue'
)
cmd_qa() {
  local action=${1:-}; [ "$#" = 0 ] || shift
  case "$action" in
    finding) qa_finding "$@" ;;
    status)
      local request dir pending running pid child
      [ "$#" = 0 ] || [ "$*" = --json ] || fail 'usage: dv qa status [--json]'
      {
        for request in "$DV_HOME"/qa/*/running.json "$DV_HOME"/qa/*/pending.json; do
          [ -f "$request" ] || continue
          dir=$(dirname "$request"); pending=false; running=false
          # Emit one row per repository; pending contains the latest identity.
          if [ -f "$dir/pending.json" ]; then
            [ "$request" = "$dir/pending.json" ] || continue
            pending=true
          fi
          pid=$(cat "$dir/pid" 2>/dev/null || true); child=$(cat "$dir/child.pid" 2>/dev/null || true)
          if qa_alive "$pid" || qa_alive "$child"; then running=true; fi
          jq --argjson pending "$pending" --argjson running "$running" '{repository,base,pending:$pending,running:$running}' "$request"
        done
      } | jq -s . ;;
    search)
      [ "$#" = 2 ] || fail 'usage: dv qa search ISSUE keywords'
      qa_load "$1"
      gh issue list -R "$(jq -r .repository "$S/meta")" --state open --search "$2" --limit 100 --json number,title,url,milestone,labels ;;
    *) fail 'usage: dv qa status|search|finding' ;;
  esac
}
