#!/usr/bin/env bash
# Contract-net requests live on the manager; bids never write state or clone.
# shellcheck disable=SC2016
# shellcheck source=lib/host-capacity.sh
source "$(dirname "${BASH_SOURCE[0]}")/host-capacity.sh"
bid_stop_tree() {
  local pid=$1 child
  # Freeze each parent before enumerating children so it cannot fork another
  # pipe holder during cancellation. Only this invocation's descendants qualify.
  kill -STOP "$pid" 2>/dev/null || return 0
  for child in $(ps -e -o pid= -o ppid= | awk -v parent="$pid" '$2==parent {print $1}'); do
    bid_stop_tree "$child"
  done
  kill -KILL "$pid" 2>/dev/null || true
}
bid_limit() (
  # A fast probe can cancel the timer before its TERM trap is installed.
  # Isolate inherited EXIT cleanup before forking either child, so a timer's
  # early termination cannot remove its caller's state or release its lock.
  trap - EXIT
  local seconds=$1 pid timer rc=0; shift
  "$@" <&0 & pid=$!
  (
    trap 'kill "$sleeper" 2>/dev/null || true; exit 0' TERM
    sleep "$seconds" & sleeper=$!
    wait "$sleeper"
    bid_stop_tree "$pid"
  ) > /dev/null 2>&1 & timer=$!
  wait "$pid" 2>/dev/null || rc=$?
  kill "$timer" 2>/dev/null || true
  wait "$timer" 2>/dev/null || true
  return "$rc"
)
bid_rpc() (
  local host=$1; shift
  if [ "$host" = "$DV_HOST" ]; then exec "$DV_ROOT/bin/dv" "$@"
  else exec ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" "$(shell_join dv "$@")"; fi
)
bid_cores() {
  local cores
  cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
  [[ "$cores" =~ ^[1-9][0-9]*$ ]] || cores=1
  printf '%s\n' "$cores"
}
bid_resources() {
  local cores load memory cache cache_free=null
  cores=$(bid_cores)
  load=$(portable_load5)
  memory=$(portable_memory_mb)
  cache=$(disk_cache_path) || cache=''
  [ -z "$cache" ] || cache_free=$(disk_available_gb "$cache" || echo null)
  jq -cn --argjson cores "$cores" --argjson load "${load:-null}" --argjson memory "${memory:-null}" \
    --argjson disk "$(disk_available_gb || echo null)" --arg cache "$cache" --argjson cache_free "$cache_free" --argjson heavy "$(heavy_snapshot)" \
    '{cores:$cores,load5:$load,memory_available_mb:$memory,disk_available_gb:$disk,heavy:$heavy,
      go_cache_path:(if $cache=="" then null else $cache end),cache_disk_available_gb:$cache_free}'
}
bid_remote_repo() {
  [[ "$1" =~ ^https?://[^/]+/.+ ]] || [[ "$1" =~ ^ssh://.+ ]] || [[ "$1" =~ ^git@[^:]+:.+ ]]
}
bid_repo() {
  # Return the existing clone or the deterministic destination for an award.
  local repo=$1 name origin
  BID_CLONED=false; BID_REPO=''; BID_REPO_OK=false
  if [ -d "$repo" ] && git -C "$repo" rev-parse --show-toplevel >/dev/null 2>&1; then
    BID_REPO=$(cd "$repo" && git rev-parse --show-toplevel); BID_CLONED=true; BID_REPO_OK=true
  elif bid_remote_repo "$repo"; then
    name=${repo##*/}; name=${name%.git}
    [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || return 0
    BID_REPO="$DV_REPO_ROOT/$name"
    if [ -e "$BID_REPO" ]; then
      origin=$(git -C "$BID_REPO" config --get remote.origin.url 2>/dev/null || true)
      if [ "${origin%.git}" = "${repo%.git}" ]; then BID_CLONED=true; BID_REPO_OK=true; fi
    else BID_REPO_OK=true; fi
  fi
}
bid_active() {
  local path revived backend
  for path in "$DV_STATE"/*/meta; do
    [ -f "$path" ] || continue
    [ ! -f "$(dirname "$path")/agent.exit" ] || continue
    # A backend that lost its processes without an exit record no longer holds
    # the slot; its state stays for inspection until dv clean.
    backend=$(jq -r '.backend // "tmux"' "$path" 2>/dev/null) || backend=''
    case "$backend" in
      exec) codex_exec_alive "$(dirname "$path")" || continue ;;
      qa) qa_job_alive "$(dirname "$path")" || continue ;;
    esac
    revived=$(cat "$(dirname "$path")/revive/id" 2>/dev/null) || revived=''
    # Release on this run's completion before its done event wakes scheduling;
    # historical or manual completions must still leave the revival counted.
    jq -c --arg revived "$revived" 'select(.cleaned_at==null and
      (.status=="waiting-capacity" or (if $revived!="" then .done_episode!=$revived and .status!="landed" and .status!="cancelled" and .status!="closed" and .status!="parked"
       else .done_at==null and (.status=="running" or .status=="pr" or .status=="ready" or .status=="input-required") end)))' "$path"
  done | jq -s length
}
bid_agent() {
  local agent=$1 override bin probe
  override="DV_AGENT_CMD_$agent"; override=${!override}
  [ -z "$override" ] || return 0 # explicit trusted custom launcher
  [ "$agent" != codex ] || codex_environment || return 1
  probe="DV_AGENT_READY_$agent"; probe=${!probe}
  if [ -n "$probe" ]; then bid_limit "$DV_BID_TIMEOUT" bash -c "$probe" >/dev/null 2>&1; return; fi
  bin=$(agent_bin "$agent")
  command -v "$bin" >/dev/null || return 1
  bid_limit "$DV_BID_TIMEOUT" agent_auth_probe "$agent" "$bin" >/dev/null 2>&1
}
bid_settings() {
  disk_settings
  host_capacity_settings
  [[ "$DV_BID_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || fail 'DV_BID_TIMEOUT must be a positive integer'
  [[ "$DV_AWARD_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || fail 'DV_AWARD_TIMEOUT must be a positive integer'
  [[ "$DV_MIN_MEMORY_MB" =~ ^[0-9]+$ ]] || fail 'DV_MIN_MEMORY_MB must be a nonnegative integer'
  if ! [[ "$DV_TARGET_LOAD" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
    ! jq -en --argjson target "$DV_TARGET_LOAD" '$target>0' >/dev/null; then
    fail 'DV_TARGET_LOAD must be positive'
  fi
}
bid_capacity() {
  local resources=$1 active=$2 ceiling=null model reserve=null
  bid_settings
  if [ -n "$DV_MAX_JOBS" ]; then
    [[ "$DV_MAX_JOBS" =~ ^[1-9][0-9]*$ ]] || fail 'DV_MAX_JOBS must be a positive integer'
    ceiling=$DV_MAX_JOBS
  fi
  jq -e '(.cores|type=="number" and .>0) and (.load5|type=="number" and .>=0) and
    (.memory_available_mb|type=="number" and .>=0)' <<< "$resources" >/dev/null || fail 'host resources unavailable'
  model=$(host_capacity_current "$resources" "$active") || return 1
  if [ "$DV_HOST" = lina-os ]; then reserve=$(jq '[1,(.cores/2|floor)]|max' <<< "$resources"); fi
  jq --argjson ceiling "$ceiling" --argjson active "$active" --argjson target "$DV_TARGET_LOAD" \
    --argjson memory "$DV_MIN_MEMORY_MB" --argjson model "$model" --argjson reserve "$reserve" '
    . + {max_jobs:$ceiling,active:$active,target_load:$target,manager_limit:$reserve,
      learned_cap:([$active,($model.target_cap // $model.learned_cap)]|max),capacity_model:$model,
      memory_slots:(if $memory==0 then ($model.target_cap // $model.learned_cap) else (.memory_available_mb/$memory|floor) end)} |
    .effective_slots=([$active,([.learned_cap,.max_jobs,.manager_limit,.memory_slots,
      (if .load5>=.cores*$target then $active else null end)]|map(select(.!=null))|min)]|max) |
    .capacity=.effective_slots | .free_slots=([0,(.capacity-.active)]|max) |
    .capacity_reason=(if .memory_available_mb<$memory then "low memory"
      elif .load5>=.cores*$target then "high load"
      elif .max_jobs!=null and .active>=.max_jobs then "full"
      elif $memory>0 and .memory_slots<=.active then "low memory"
      elif .manager_limit!=null and .active>=.manager_limit then "manager reserve"
      elif .free_slots==0 then "learned capacity" else "" end)' <<< "$resources"
}
bid_work_writable() {
  local path=$DV_WORK
  # Stay read-only: missing components can be created only below a writable,
  # searchable directory. Files and dangling symlinks are not usable ancestors.
  while [ ! -e "$path" ] && [ ! -L "$path" ]; do
    [ "$path" != / ] && [ "$path" != . ] || return 1
    path=$(dirname "$path")
  done
  [ -d "$path" ] && [ -w "$path" ] && [ -x "$path" ]
}
# A host may refuse whole repositories (DV_BID_REJECT_REPOS="owner/name ..."), so
# work for one repo can be steered off a host without a per-issue pin (a Mac kept
# for app work stops taking Core jobs). Matches a remote URL or a clone's origin.
bid_repo_rejected() {
  local repo=$1 url=$1 slug entry
  [ -n "$DV_BID_REJECT_REPOS" ] || return 1
  if [ -d "$repo" ]; then url=$(git -C "$repo" config --get remote.origin.url 2>/dev/null) || return 1; fi
  # GitHub owner and repository names are case-insensitive.
  slug=$(printf '%s\n' "$url" | sed -E 's#^(https?://|ssh://)?(git@)?github\.com[:/]##; s#\.git$##; s#/+$##' | tr '[:upper:]' '[:lower:]')
  for entry in $DV_BID_REJECT_REPOS; do
    entry=$(printf '%s' "${entry%.git}" | tr '[:upper:]' '[:lower:]')
    [ "$entry" != "$slug" ] || return 0
  done
  return 1
}
cmd_bid() {
  bid_settings
  local repo='' agent=$DV_AGENT kind=code json=0 resources ready=false backend=false trust=true root writable=false excluded=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --repo|--agent|--kind) [ "$#" -ge 2 ] || fail 'missing bid value'
        case "$1" in --repo) repo=$2 ;; --agent) agent=$2 ;; --kind) kind=$2 ;; esac; shift 2 ;;
      *) fail 'usage: dv bid --json [--repo REPO] [--agent codex|claude|devin|omp|agy|grok|cursor]' ;;
    esac
  done
  known_agent "$agent" || fail 'unknown agent'
  case "$kind" in code|qa) ;; *) fail 'unknown bid kind' ;; esac
  resources=$(bid_capacity "$(bid_resources)" "$(bid_active)") || return 1
  if bid_work_writable; then writable=true; fi
  bid_repo "$repo"
  [ -n "$repo" ] || BID_REPO_OK=true
  if [ -n "$repo" ] && bid_repo_rejected "$repo"; then excluded=true; fi
  if [ "$kind" = qa ] && [ -n "$DV_QA_AGENT_CMD" ]; then ready=true
  elif bid_agent "$agent"; then ready=true; fi
  if [ "$agent" = codex ] && [ -z "$DV_AGENT_CMD_codex" ] && [ -n "$repo" ]; then
    root=$BID_REPO
    if [ "$BID_CLONED" = true ]; then root=$(codex_repo_root "$BID_REPO") || root=''; fi
    if ! codex_repo_allowed "$root" 2>/dev/null; then trust=false; fi
  fi
  if { [ "$DV_HERDR" != 0 ] && herdr_bin >/dev/null; } || command -v tmux >/dev/null; then backend=true; fi
  if [ "$agent" = codex ] && [ -z "$DV_AGENT_CMD_codex" ]; then
    case "$(codex_default_mode "$agent")" in auto|exec) backend=true ;; esac
  fi
  [ "$kind" != qa ] || backend=true
  printf '%s\n' "$resources" | jq --arg host "$DV_HOST" --arg repo "$BID_REPO" --argjson cloned "$BID_CLONED" \
    --argjson repo_ok "$BID_REPO_OK" --argjson ready "$ready" --argjson backend "$backend" --argjson trust "$trust" \
    --argjson min_disk "$DV_MIN_DISK_GB" --argjson writable "$writable" --argjson excluded "$excluded" \
    '. + {host:$host,repo:$repo,repo_cloned:$cloned,agent_ready:$ready} |
    ([.disk_available_gb,.cache_disk_available_gb]|map(select(.!=null))|min) as $disk |
    .reason=(if $excluded then "repository excluded by DV_BID_REJECT_REPOS" elif .free_slots==0 then .capacity_reason elif $writable|not then "worktree dir not writable" elif $ready|not then "agent unavailable or logged out" elif $repo_ok|not then "repository unavailable" elif $trust|not then "repository not in DV_TRUSTED_REPOS" elif $backend|not then "terminal backend unavailable" elif .disk_available_gb==null or (.go_cache_path!=null and .cache_disk_available_gb==null) then "disk unavailable" elif $disk<$min_disk then "low disk" else "" end) |
    .status=(if .reason=="" then "submitted" else "rejected" end) |
    # Keep normal-load scores; each core-equivalent above 1.5 costs 100 more.
    .score=(100*.free_slots/([1,.capacity]|max) - 20*.load5/.cores - 100*([0,(.load5/.cores-1.5)]|max) + ([64,(.memory_available_mb/1024)]|min) + (if .repo_cloned then 20 else 0 end) -
      (if $min_disk>0 and $disk!=null then [0,20*(2*$min_disk-$disk)/$min_disk]|max else 0 end))' |
    if [ "$json" = 1 ]; then cat; else jq -r '[.host,.status,(.free_slots|tostring),(.score|tostring),.reason,.learned_cap,.effective_slots,("heavy="+(.heavy.in_use|tostring)+"/"+(.heavy.slots|tostring)+" waiting="+(.heavy.waiting|tostring))]|@tsv'; fi
}
# Without --agent, a brief line "Route: writing|small" selects DV_ROUTE_WRITING
# or DV_ROUTE_SMALL; "Route: default", no line or an empty target keep DV_AGENT.
submit_route() {
  local route target
  route=$(sed -n '/^Route:/{s/^Route:[[:space:]]*//;s/[[:space:]]*$//;p;q;}' "$1")
  case "$route" in
    ''|default) return 0 ;;
    writing) target=$DV_ROUTE_WRITING ;;
    small) target=$DV_ROUTE_SMALL ;;
    *) fail "unknown brief line Route: $route (writing, small or default)" ;;
  esac
  [ -n "$target" ] || return 0
  printf 'dv: Route: %s selects --agent %s\n' "$route" "$target" >&2
  agent=$target
}
cmd_submit() {
  [ "$#" -ge 3 ] || fail 'usage: dv submit REPO ISSUE slug --brief FILE [--agent AGENT] [--mode MODE] [--base BASE]'
  local repo=$1 issue=$2 slug=$3 brief='' agent='' mode=$DV_MODE base='' request origin
  shift 3; valid_issue "$issue"
  [[ "$slug" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || fail 'invalid slug'
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || fail 'missing submit value'
    case "$1" in --brief) brief=$2 ;; --agent) agent=$2 ;; --mode) mode=$2 ;; --base) base=$2 ;; *) fail 'unknown submit option' ;; esac
    shift 2
  done
  [ -f "$brief" ] || fail 'brief file not found'
  if [ -z "$agent" ]; then
    agent=$DV_AGENT
    # Codex-only modes keep the configured Codex agent.
    case "$mode" in ''|goal) submit_route "$brief" ;; esac
  fi
  [ -n "$mode" ] || mode=$(codex_default_mode "$agent")
  case "$agent:$mode" in codex:auto|codex:goal|codex:exec) ;; *:goal) known_agent "$agent" || fail 'invalid agent/mode' ;; *) fail 'invalid agent/mode' ;; esac
  [ -z "$base" ] || git check-ref-format "refs/heads/$base" >/dev/null || fail 'invalid base'
  if [ -d "$repo" ]; then
    repo=$(cd "$repo" && git rev-parse --show-toplevel)
    origin=$(git -C "$repo" config --get remote.origin.url 2>/dev/null || true)
    if bid_remote_repo "$origin"; then repo=$origin; fi
  fi
  request=$(jq -cn --arg issue "$issue" --arg repo "$repo" --arg slug "$slug" --arg agent "$agent" --arg mode "$mode" --arg base "$base" --rawfile brief "$brief" \
    '{issue:$issue,repo:$repo,slug:$slug,agent:$agent,mode:$mode,base:$base,brief:$brief}')
  printf '%s\n' "$request" | bid_rpc "$DV_MANAGER_HOST" _submit
}
bid_request_valid() {
  jq -e 'type=="object" and (.issue|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9_-]*$")) and
    (.slug|type=="string" and test("^[a-zA-Z0-9][a-zA-Z0-9-]*$")) and (.repo|type=="string" and length>0 and (startswith("-")|not)) and
    (.brief|type=="string") and (.base|type=="string") and
    ((.agent=="codex" and (.mode=="auto" or .mode=="goal" or .mode=="exec")) or
      (.agent as $agent | ["claude","devin","omp","agy","grok","cursor"] | index($agent) != null) and .mode=="goal") and
    (if .kind=="qa" then (.agent=="codex" or .agent=="claude") and .qa.remote==.repo and .qa.base==.base and
      (.qa.repository|type=="string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
      (.qa.head|type=="string" and test("^[0-9a-f]{40}$")) and
      (.qa.prs|type=="array" and length>0)
     else (.kind==null or .kind=="code") end)' >/dev/null
}
cmd__submit() {
  [ "$DV_HOST" = "$DV_MANAGER_HOST" ] || fail 'submit must be received by the manager'
  local request issue dir tmp
  request=$(cat); printf '%s\n' "$request" | bid_request_valid || fail 'invalid request'
  issue=$(printf '%s\n' "$request" | jq -r .issue)
  mkdir -p "$DV_HOME/submissions"
  dir="$DV_HOME/submissions/$issue"
  mkdir "$dir" || fail 'submission already exists'
  tmp=$(mktemp "$dir/.task.XXXXXX")
  printf '%s\n' "$request" | jq --argjson time "$(now)" '.+{status:"submitted",submitted_at:$time,host:null,attempts:[]}' > "$tmp"
  mv "$tmp" "$dir/task.json"
  "$DV_ROOT/bin/dv-kick" submitted "$issue" 'Awaiting bids' "$DV_HOST"
  printf '%s submitted\n' "$issue"
}
cmd_queue() {
  if [ "$DV_HOST" != "$DV_MANAGER_HOST" ]; then bid_rpc "$DV_MANAGER_HOST" queue "$@"; return; fi
  if [ "${1:-}" = --summary ]; then shift; autofill_summary "$@"; return; fi
  local issue='' json=0 arg path
  for arg in "$@"; do case "$arg" in --json) json=1 ;; *) [ -z "$issue" ] || fail 'one issue only'; valid_issue "$arg"; issue=$arg ;; esac; done
  { for path in "$DV_HOME"/submissions/*/task.json; do
      [ -f "$path" ] || continue
      [ -z "$issue" ] || [ "$(basename "$(dirname "$path")")" = "$issue" ] || continue
      jq 'del(.brief)' "$path"
    done; } | jq -s 'sort_by(.submitted_at,.issue)' |
    if [ "$json" = 1 ]; then cat; else jq -r '.[]|[.issue,.status,(.host//""),(.reason//"")]|@tsv'; fi
}
bid_task_set() {
  local dir=$1 tmp; shift
  tmp=$(mktemp "$dir/.task.XXXXXX")
  jq "$@" "$dir/task.json" > "$tmp" && mv "$tmp" "$dir/task.json"
}
bid_lock() {
  local path=$1 owner=${2:-} tries=0
  if [ -n "$owner" ]; then owned_lock "$path" "$owner"; return; fi
  until mkdir "$path" 2>/dev/null; do
    tries=$((tries+1)); [ "$tries" -lt 100 ] || return 1; sleep 0.1
  done
}
cmd_cancel() (
  [ "$#" = 1 ] || fail 'usage: dv cancel ISSUE'
  if [ "$DV_HOST" != "$DV_MANAGER_HOST" ]; then bid_rpc "$DV_MANAGER_HOST" cancel "$@"; exit; fi
  valid_issue "$1"
  local dir="$DV_HOME/submissions/$1"
  [ -f "$dir/task.json" ] || fail 'unknown submission'
  bid_lock "$DV_HOME/.schedule-lock" "${BASHPID:-$$}" || fail 'scheduler busy'
  trap 'owned_unlock "$DV_HOME/.schedule-lock" "${BASHPID:-$$}"' EXIT
  jq -e '.status=="submitted" and .host==null' "$dir/task.json" >/dev/null || fail 'only unassigned submissions can be canceled'
  bid_task_set "$dir" '.status="canceled"'
  "$DV_ROOT/bin/dv-kick" canceled "$1" 'Submission canceled' "$DV_HOST"
)
cmd__receipt() {
  [ "$#" = 2 ] || fail 'usage: dv _receipt ISSUE token'
  valid_issue "$1"
  local dir="$DV_STATE/.awards/$1" receipt exited=false
  [ ! -f "$DV_STATE/$1/agent.exit" ] || exited=true
  for receipt in "$dir/receipt.json" "$dir"/failed.*/receipt.json; do
    [ -f "$receipt" ] || continue
    if jq -e --arg token "$2" '.token==$token' "$receipt" >/dev/null; then
      jq --argjson exited "$exited" '.+{exited:$exited}' "$receipt"; return
    fi
  done
  if [ -d "$dir" ]; then return 1; fi
  jq -cn '{status:"absent"}'
}
cmd__award() (
  bid_settings
  local request issue dir token deadline repo agent mode slug base bid rc=0 status head history='' retry=false kind error message
  request=$(cat); printf '%s\n' "$request" | bid_request_valid || fail 'invalid award'
  issue=$(printf '%s\n' "$request" | jq -r .issue)
  token=$(printf '%s\n' "$request" | jq -er '.token|select(type=="string")')
  deadline=$(printf '%s\n' "$request" | jq -er '.deadline|select(type=="number" and .==floor and .>0)')
  mkdir -p "$DV_STATE/.awards"
  bid_lock "$DV_STATE/.admission-lock" "$$" || fail 'host admission busy'
  trap 'owned_unlock "$DV_STATE/.admission-lock" "$$"' EXIT
  dir="$DV_STATE/.awards/$issue"
  if [ -e "$dir" ]; then
    if ! jq -e --arg token "$token" '.token!=$token and .status=="failed"' "$dir/receipt.json" >/dev/null; then
      cmd__receipt "$issue" "$token"; exit
    fi
    [ "$(now)" -lt "$deadline" ] || fail 'award expired before admission'
    # A later round may retry a confirmed, cleaned startup failure. Preserve all
    # prior state and receipts; never reuse an uncertain or still-owned worktree.
    if [ -f "$DV_STATE/$issue/meta" ]; then
      jq -e '.status=="failed"' "$DV_STATE/$issue/meta" >/dev/null || fail 'previous start needs inspection'
      [ ! -e "$(jq -r .worktree "$DV_STATE/$issue/meta")" ] || fail 'previous worktree still exists'
    fi
    retry=true
  fi
  [ "$(now)" -lt "$deadline" ] || fail 'award expired before admission'
  [ "$retry" = true ] || [ ! -e "$DV_STATE/$issue" ] || fail 'issue already exists on this host'
  repo=$(printf '%s\n' "$request" | jq -r .repo); agent=$(printf '%s\n' "$request" | jq -r .agent)
  kind=$(jq -r '.kind // "code"' <<< "$request")
  bid=$(cmd_bid --json --repo "$repo" --agent "$agent" --kind "$kind")
  printf '%s\n' "$bid" | jq -e '.status=="submitted"' >/dev/null || { printf '%s\n' "$bid"; exit; }
  [ "$(now)" -lt "$deadline" ] || fail 'award expired before admission'
  # Rejected/expired retries leave the last receipt and state in place.
  if [ "$retry" = true ]; then
    history=$(mktemp -d "$dir/failed.XXXXXX")
    mv "$dir/receipt.json" "$dir/request.json" "$dir/brief.md" "$history/"
    [ ! -f "$dir/startup.err" ] || mv "$dir/startup.err" "$history/"
    [ ! -e "$DV_STATE/$issue" ] || mv "$DV_STATE/$issue" "$history/state"
  fi
  mkdir -p "$dir"
  printf '%s\n' "$request" > "$dir/request.json"
  printf '%s\n' "$request" | jq -r .brief > "$dir/brief.md"
  printf '%s\n' "$request" | jq '{token,status:"starting"}' > "$dir/receipt.json"
  : > "$dir/startup.err"
  if [ "$kind" = qa ]; then
    qa_award "$request" "$dir"
    exit
  fi
  if ! printf '%s\n' "$bid" | jq -e .repo_cloned >/dev/null; then
    {
      if mkdir -p "$DV_REPO_ROOT"; then
        bid_limit "$DV_AWARD_TIMEOUT" git clone -- "$repo" "$(printf '%s\n' "$bid" | jq -r .repo)" >&2 || rc=$?
      else rc=$?; fi
    } 2>> "$dir/startup.err"
  fi
  repo=$(printf '%s\n' "$bid" | jq -r .repo)
  mode=$(printf '%s\n' "$request" | jq -r .mode); slug=$(printf '%s\n' "$request" | jq -r .slug); base=$(printf '%s\n' "$request" | jq -r .base)
  # Keep any branch left by the earlier attempt; a retry gets its own branch.
  [ -z "$history" ] || slug="$slug-retry-${history##*.}"
  local args=(start "$repo" "$issue" "$slug" --agent "$agent" --mode "$mode" --brief "$dir/brief.md")
  [ -z "$base" ] || args+=(--base "$base")
  if [ "$rc" = 0 ] && [ "$(now)" -lt "$deadline" ]; then
    # The wrapper writes agent.started only after startup has been confirmed.
    DV_ADMISSION_OWNER="$$" DV_AWARD_TOKEN="$token" "$DV_ROOT/bin/dv" "${args[@]}" >&2 2>> "$dir/startup.err" || rc=$?
  else rc=1; fi
  cat "$dir/startup.err" >&2
  while [ "$rc" = 0 ] && [ "$(now)" -lt "$deadline" ]; do
    if [ -f "$DV_STATE/$issue/agent.exit" ]; then
      [ "$(cat "$DV_STATE/$issue/agent.exit")" = 0 ] || rc=1
      break
    fi
    [ ! -f "$DV_STATE/$issue/agent.started" ] || break
    if [ -f "$DV_STATE/$issue/meta" ] && jq -e '.status=="start-failed"' "$DV_STATE/$issue/meta" >/dev/null; then rc=1; break; fi
    sleep 0.1
  done
  status=failed; head=''
  if [ "$rc" = 0 ] && [ -f "$DV_STATE/$issue/agent.started" ]; then status=working; fi
  if [ "$status" = failed ] && [ -f "$DV_STATE/$issue/meta" ]; then
    # Retain dirty worktrees and their terminal; an uncertain start cannot be reassigned.
    if ! "$DV_ROOT/bin/dv" clean "$issue" >&2; then status=input-required; fi
    # meta_set uses these globals from common.sh.
    # shellcheck disable=SC2034
    S="$DV_STATE/$issue"
    # shellcheck disable=SC2034
    ISSUE=$issue
    meta_set --arg status "$status" '.status=$status'
  fi
  [ ! -f "$DV_STATE/$issue/meta" ] || head=$(jq -r '.head // .start_head' "$DV_STATE/$issue/meta")
  jq -n --arg status "$status" --arg token "$token" --arg head "$head" '{status:$status,token:$token,head:$head}' > "$dir/.receipt"
  mv "$dir/.receipt" "$dir/receipt.json"
  if [ "$status" = failed ]; then
    local logs=("$dir/startup.err")
    [ ! -f "$DV_STATE/$issue/log" ] || logs+=("$DV_STATE/$issue/log")
    # Git progress can precede the diagnostic; asynchronous agent failures can
    # appear only in the issue log. Fall back to the first nonempty line.
    error=$(awk 'NF && first=="" {first=$0}
      tolower($0) ~ /(^|[^[:alnum:]_])(error|fatal|failed|denied|cannot|not found)([^[:alnum:]_]|$)/ {print; found=1; exit}
      END {if (!found) print first}' "${logs[@]}")
    message='Award startup failed; safe to reassign'
    [ -z "$error" ] || message="$message: $error"
    DV_AWARD_TOKEN="$token" "$DV_ROOT/bin/dv" kick failed "$issue" "$message" >&2
  fi
  cat "$dir/receipt.json"
)
bid_hosts() {
  local host
  # Resident-service hosts follow workers; gos is the final fallback after both.
  for host in $DV_HOSTS; do
    case "$host" in gos|gos-linux) continue ;; esac
    [ "$host" = "$DV_MANAGER_HOST" ] || [ "$host" = lina-os ] || printf '%s\n' "$host"
  done
  for host in $DV_HOSTS; do
    case "$host" in gos|gos-linux) continue ;; esac
    if [ "$host" = "$DV_MANAGER_HOST" ] || [ "$host" = lina-os ]; then printf '%s\n' "$host"; fi
  done
  for host in $DV_HOSTS; do
    case "$host" in gos|gos-linux) printf '%s\n' "$host" ;; esac
  done
}
bid_publish_change() {
  [ -n "$DV_AUTOFILL_REPOS" ] || return 0
  local repo=$1 bids=$2 dir="$DV_HOME/autofill/bids" key tmp
  mkdir -p "$dir"
  key=$(printf '%s' "$repo" | cksum | awk '{print $1 "-" $2}')
  tmp=$(mktemp "$dir/.bid.XXXXXX") || return 1
  jq 'map({host,status,capacity:(.effective_slots // .capacity),active,free_slots,reason}) | sort_by(.host)' "$bids" > "$tmp" || { rm -f "$tmp"; return 1; }
  if [ -f "$dir/$key.json" ] && cmp -s "$tmp" "$dir/$key.json"; then rm "$tmp"; return 0; fi
  mv "$tmp" "$dir/$key.json"
  # A committed change to schedulable capacity is an event. Scores/load noise
  # alone cannot form a feedback loop, and the public bid command stays read-only.
  "$DV_ROOT/bin/dv-kick" bid-changed FLEET "$repo" "$DV_HOST"
}
bid_schedule_one() {
  local dir=$1 host repo agent bids rows row token deadline reply rc status rank hosts
  local kind_args=()
  bid_settings
  jq -e '.status=="submitted"' "$dir/task.json" >/dev/null || return 0
  if jq -e '.host!=null' "$dir/task.json" >/dev/null; then
    host=$(jq -r .host "$dir/task.json"); token=$(jq -r .token "$dir/task.json")
    reply=$(bid_limit "$DV_BID_TIMEOUT" bid_rpc "$host" _receipt "$(basename "$dir")" "$token" < /dev/null 2>> "$dir/dispatch.log") || reply='{}'
    status=$(printf '%s\n' "$reply" | jq -r '.status//"unknown"' 2>/dev/null || echo unknown)
    case "$status" in
      working) bid_task_set "$dir" '.status="working"|del(.reason)'; return ;;
      failed) bid_task_set "$dir" '.host=null' || return ;;
      absent)
        deadline=$(jq -r .deadline "$dir/task.json")
        if [ "$(now)" -ge "$deadline" ]; then bid_task_set "$dir" '.host=null|del(.reason)' || return
        else bid_task_set "$dir" '.reason="Award may still arrive before its deadline"'; return; fi ;;
      *) bid_task_set "$dir" '.status="input-required"|.reason="Interrupted award; awaiting host outcome"'; return ;;
    esac
  fi
  # Attempts belong to this event's round. Resolve a pinned receipt above before
  # clearing them so an uncertain start cannot be dispatched a second time.
  bid_task_set "$dir" '.attempts=[]' || return
  repo=$(jq -r .repo "$dir/task.json"); agent=$(jq -r .agent "$dir/task.json")
  if jq -e '.kind=="qa"' "$dir/task.json" >/dev/null; then kind_args=(--kind qa); fi
  bids=$(mktemp "$dir/.bids.XXXXXX")
  hosts=$(bid_hosts | awk '!seen[$0]++')
  for host in $hosts; do
    [[ "$host" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || continue
    if jq -e --arg host "$host" '.attempts|index($host)!=null' "$dir/task.json" >/dev/null; then continue; fi
    if reply=$(bid_limit "$DV_BID_TIMEOUT" bid_rpc "$host" bid --json --repo "$repo" --agent "$agent" ${kind_args[@]+"${kind_args[@]}"} < /dev/null 2>> "$dir/dispatch.log") &&
      printf '%s\n' "$reply" | jq -e 'type=="object" and (.score|type=="number") and (.status=="submitted" or .status=="rejected")' >/dev/null 2>&1; then
      case "$host" in hx|hx-linux) rank=0 ;; amd|amd-linux) rank=1 ;; go2|go2-linux) rank=2 ;; lina-os) rank=3 ;; gos|gos-linux) rank=4 ;; *) rank=5 ;; esac
      printf '%s\n' "$reply" | jq -c --arg host "$host" --arg manager "$DV_MANAGER_HOST" --argjson rank "$rank" \
        --arg last "${DV_MANAGER_LAST:-1}" \
        '.host=$host | .rank=$rank | .manager=(if $last!="0" and ($host==$manager or $host=="lina-os") then 1 else 0 end)' >> "$bids"
    else jq -cn --arg host "$host" '{host:$host,status:"rejected",reason:"no valid bid response"}' >> "$bids"; fi
  done
  # Keep scores within each group, but never let gos outrank the manager.
  jq -s 'sort_by((if .host=="gos" or .host=="gos-linux" then 2 else .manager end),-(.score//0),.rank,.host)' "$bids" > "$dir/bids.json" || return
  rm "$bids"
  bid_publish_change "$repo" "$dir/bids.json" || return
  rows=$(jq -c '.[]|select(.status=="submitted")' "$dir/bids.json")
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    host=$(printf '%s\n' "$row" | jq -r .host)
    token="$(now)-$$-$RANDOM"; deadline=$(( $(now) + DV_AWARD_TIMEOUT ))
    bid_task_set "$dir" --arg host "$host" --arg token "$token" --argjson deadline "$deadline" '.host=$host|.token=$token|.deadline=$deadline|.attempts+=[$host]' || return
    rc=0
    # Give the RPC the request file directly. An early reply must not be hidden
    # by a request producer's SIGPIPE; transport failures still recover below.
    reply=$(bid_limit "$((DV_AWARD_TIMEOUT + 2))" bid_rpc "$host" _award < "$dir/task.json" 2>> "$dir/dispatch.log") || rc=$?
    if [ "$rc" != 0 ] || ! printf '%s\n' "$reply" | jq -e --arg token "$token" '.status=="rejected" or (.token==$token and (.status=="working" or .status=="failed" or .status=="input-required"))' >/dev/null 2>&1; then
      # An SSH reply can be lost after a start. Recover its receipt before failover.
      reply=$(bid_limit "$DV_BID_TIMEOUT" bid_rpc "$host" _receipt "$(basename "$dir")" "$token" < /dev/null 2>> "$dir/dispatch.log") || reply='{}'
    fi
    status=$(printf '%s\n' "$reply" | jq -r '.status // "unknown"' 2>/dev/null || echo unknown)
    case "$status" in
      working) bid_task_set "$dir" --arg head "$(printf '%s\n' "$reply" | jq -r '.head//""')" '.status="working"|.head=$head|del(.reason)'; return ;;
      failed) bid_task_set "$dir" '.host=null' || return ;;
      rejected) bid_task_set "$dir" '.host=null' || return; continue ;;
      absent)
        # A delayed SSH invocation must expire before an absent receipt is safe.
        if [ "$(now)" -ge "$deadline" ]; then bid_task_set "$dir" '.host=null' || return
        else bid_task_set "$dir" '.reason="Award may still arrive before its deadline"'; return; fi ;;
      *) bid_task_set "$dir" '.status="input-required"|.reason="Start acknowledgement missing or unsafe to clean; retain assignment until a host event"'; return ;;
    esac
  done <<< "$rows"
  bid_task_set "$dir" '.reason="Waiting for an eligible host; rebid on done/failed/landed"'
}
bid_event() (
  local line=$1 kind issue host dir path head receipt token status event_token
  kind=$(printf '%s\n' "$line" | jq -r .kind)
  # parked and closed jobs release their slots like completed ones.
  case "$kind" in submitted|done|failed|landed|question|blocked|parked|closed) ;; *) exit 0 ;; esac
  [ "$DV_HOST" = "$DV_MANAGER_HOST" ] || exit 0
  mkdir -p "$DV_HOME/submissions"
  # Same owned protocol as autofill: a killed holder (reboot, SIGTERM) is
  # reclaimed instead of leaving an ownerless directory that blocks the queue.
  bid_lock "$DV_HOME/.schedule-lock" "${BASHPID:-$$}" || return 1
  trap 'owned_unlock "$DV_HOME/.schedule-lock" "${BASHPID:-$$}"' EXIT
  issue=$(printf '%s\n' "$line" | jq -r .issue); valid_issue "$issue"
  host=$(printf '%s\n' "$line" | jq -r .host); head=$(printf '%s\n' "$line" | jq -r '.head//""')
  event_token=$(printf '%s\n' "$line" | jq -r '.token//""')
  dir="$DV_HOME/submissions/$issue"
  # Legacy failures have no attempt identity, so only scoped failures can mutate it.
  if [ -f "$dir/task.json" ] && jq -e --arg host "$host" --arg token "$event_token" --arg kind "$kind" \
    '(.status=="working" or .status=="input-required" or (.status=="submitted" and .host!=null)) and
    (($kind!="failed" and $kind!="blocked") or $token!="") and
    (if $token!="" then .token==$token else .host==$host end)' "$dir/task.json" >/dev/null; then
    case "$kind" in
      done|landed) bid_task_set "$dir" --arg head "$head" '.status="completed"|.head=$head|del(.reason)' ;;
      blocked)
        if jq -e '.kind=="qa"' "$dir/task.json" >/dev/null; then
          bid_task_set "$dir" '.status="failed"|.reason="QA blocked; inspect its report and log"'
        fi ;;
      failed)
        token=$(jq -r .token "$dir/task.json")
        host=$(jq -r .host "$dir/task.json")
        receipt=$(bid_limit "$DV_BID_TIMEOUT" bid_rpc "$host" _receipt "$issue" "$token" < /dev/null 2>> "$dir/dispatch.log") || receipt='{}'
        status=$(printf '%s\n' "$receipt" | jq -r '.status//"unknown"' 2>/dev/null || echo unknown)
        case "$status" in
          failed) bid_task_set "$dir" '.status="submitted"|.host=null' ;;
          working)
            # A failure queued by the previous round must not fail a live retry.
            if printf '%s\n' "$receipt" | jq -e '.exited' >/dev/null; then bid_task_set "$dir" '.status="failed"'; fi ;;
          *) bid_task_set "$dir" '.status="input-required"|.reason="Failure needs a confirmed startup outcome before reassignment"' ;;
        esac ;;
      question) bid_task_set "$dir" '.status="input-required"' ;;
    esac
  fi
  case "$kind" in
    submitted) [ ! -f "$dir/task.json" ] || bid_schedule_one "$dir" ;;
    done|failed|landed|parked|closed)
      while IFS= read -r path; do [ -z "$path" ] || bid_schedule_one "$path"; done < <(
        for path in "$DV_HOME"/submissions/*/task.json; do [ ! -f "$path" ] || jq -r --arg path "$(dirname "$path")" '[.submitted_at,$path]|@tsv' "$path"; done | sort -n | cut -f2-)
      ;;
  esac
)
