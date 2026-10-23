#!/usr/bin/env bash
# Measured host capacity is separate from provider-capacity retry state.
# shellcheck disable=SC2016
host_capacity_settings() {
  if ! [[ "$DV_HOST_CAPACITY_WINDOW" =~ ^[1-9][0-9]*$ ]] || [ "$DV_HOST_CAPACITY_WINDOW" -lt 3600 ]; then
    fail 'DV_HOST_CAPACITY_WINDOW must be at least 3600 seconds'
  fi
}
host_capacity_initial() {
  local resources=$1 active=$2 cores seed=1 source=bootstrap
  cores=$(jq -er .cores <<< "$resources") || return 1
  # Cold-start seeds are the owner's measured knees, not core-count guesses.
  # Unknown hosts start with one slot; existing work is always retained.
  case "$DV_HOST:$cores" in
    hx:24|hx-linux:24) seed=14; source=owner-measurement ;;
    amd:16|amd-linux:16|go2:16|go2-linux:16) seed=12; source=owner-measurement ;;
    gos:8|gos-linux:8) seed=6; source=owner-measurement ;;
    lina-os:*) seed=$((cores / 2)); [ "$seed" -gt 0 ] || seed=1; source=manager-reserve ;;
  esac
  jq -cn --arg host "$DV_HOST" --arg source "$source" --argjson cores "$cores" --argjson seed "$seed" --argjson active "$active" \
    '{version:1,host:$host,cores:$cores,target_cap:$seed,learned_cap:([$seed,$active]|max),computed_at:null,
      observed_cap:null,sample_count:0,curve:[],source:$source}'
}
host_capacity_current() {
  local resources=$1 active=$2 path="$DV_STATE/.host-capacity/cap.json" cores
  cores=$(jq -er .cores <<< "$resources") || return 1
  if [ -f "$path" ]; then
    jq -ce --arg host "$DV_HOST" --argjson cores "$cores" '
      select(.version==1 and .host==$host and .cores==$cores and
        (.learned_cap|type=="number" and .>=0 and .==floor) and
        (.target_cap==null or (.target_cap|type=="number" and .>=0 and .==floor)) and
        (.computed_at==null or (.computed_at|type=="number")))' "$path" || {
      printf 'dv: invalid host capacity state; preserving %s\n' "$path" >&2; return 1;
    }
  else host_capacity_initial "$resources" "$active"; fi
}
host_capacity_record() (
  local resources=$1 active=$2 dir="$DV_STATE/.host-capacity" time state tmp samples cap cutoff
  host_capacity_settings
  time=$(now); cutoff=$((time - DV_HOST_CAPACITY_WINDOW))
  jq -e '(.cores|type=="number" and .>0) and (.load5|type=="number" and .>=0) and
    (.memory_available_mb|type=="number" and .>=0)' <<< "$resources" >/dev/null || return 1
  mkdir -p "$dir"
  owned_lock "$dir/lock" "$$" || return 1
  trap 'owned_unlock "$dir/lock" "$$"' EXIT
  state=$(host_capacity_current "$resources" "$active") || return 1
  tmp=$(mktemp -d "$dir/.sample.XXXXXX") || return 1
  trap 'rm -rf "$tmp"; owned_unlock "$dir/lock" "$$"' EXIT
  # Append a complete, short JSON row while holding the only writer lock.
  jq -cn --arg host "$DV_HOST" --argjson at "$time" --argjson active "$active" --argjson resources "$resources" \
    '{host:$host,time:$at,active:$active,cores:$resources.cores,load5:$resources.load5,memory_available_mb:$resources.memory_available_mb}' > "$tmp/row"
  samples="$dir/samples.jsonl"
  if [ -f "$samples" ]; then
    # Validate only at recomputation; every tick remains an append, not a full
    # history rewrite. On malformed data preserve both the cap and history.
    if jq -e --argjson time "$time" '.computed_at==null or $time-.computed_at>=3600' <<< "$state" >/dev/null; then
      jq -e -s 'all(.[]; (.host|type=="string") and (.cores|type=="number" and .>0) and
        (.time|type=="number" and .==floor) and (.active|type=="number" and .>=0 and .==floor) and
        (.load5|type=="number" and .>=0) and (.memory_available_mb|type=="number" and .>=0))' "$samples" >/dev/null || return 1
    fi
  fi
  cat "$tmp/row" >> "$samples" || return 1
  if jq -e '.computed_at==null' <<< "$state" >/dev/null; then
    # Give cold starts one full observation hour before replacing the seed.
    jq --argjson at "$time" --argjson window "$DV_HOST_CAPACITY_WINDOW" \
      '.computed_at=$at | .window_seconds=$window' <<< "$state" > "$tmp/cap"
    mv "$tmp/cap" "$dir/cap.json"
  elif jq -e --argjson time "$time" '$time-.computed_at>=3600' <<< "$state" >/dev/null; then
    jq -c --arg host "$DV_HOST" --argjson cutoff "$cutoff" --argjson time "$time" --argjson cores "$(jq -r .cores <<< "$resources")" \
      'select(.host==$host and .cores==$cores and .time>=$cutoff and .time<=$time)' "$samples" > "$tmp/recent" || return 1
    cap=$(jq -s --argjson previous "$state" --argjson active "$active" --argjson target "$DV_TARGET_LOAD" \
      --argjson time "$time" --argjson window "$DV_HOST_CAPACITY_WINDOW" '
      [group_by(.active)[] | {jobs:.[0].active,samples:length,
        p75_load:([.[].load5]|sort|.[((length*0.75|ceil)-1)])}] as $curve |
      (if any($curve[]; .jobs>0) then
        ([$curve[]|select(.jobs>0 and .p75_load<=$target*$previous.cores)|.jobs]|max // 0)
        else null end) as $observed |
      ($previous.target_cap // $previous.learned_cap) as $previous_target |
      ([($observed // $previous_target),($previous_target+2)]|min) as $target_cap |
      $previous + {computed_at:$time,window_seconds:$window,target_load:$target,sample_count:length,curve:$curve,
        observed_cap:$observed,source:"measured",
        target_cap:$target_cap,learned_cap:([$active,$target_cap]|max)}' "$tmp/recent") || return 1
    printf '%s\n' "$cap" > "$tmp/cap"
    mv "$tmp/recent" "$samples"
    mv "$tmp/cap" "$dir/cap.json"
  fi
  # Include the current sample and the learned model in the RPC result.
  bid_capacity "$resources" "$active"
)
cmd__host_capacity_sample() {
  bid_settings
  host_capacity_record "$(bid_resources)" "$(bid_active)"
}
host_capacity_tick() (
  [ "$DV_HOST" = "$DV_MANAGER_HOST" ] && [ -n "$DV_AUTOFILL_REPOS" ] || return 0
  local host work pid pids='' reply previous key
  mkdir -p "$DV_HOME/autofill/hosts"
  work=$(mktemp -d "$DV_HOME/autofill/.hosts.XXXXXX") || return 1
  trap 'rm -rf "$work"' EXIT
  # Share the watcher's tick; bounded parallel RPCs add no sampling timer or daemon.
  for host in $(printf '%s\n' "$DV_HOST $DV_HOSTS" | tr ' ' '\n' | awk 'NF && !seen[$0]++'); do
    [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
    (
      trap - EXIT
      bid_limit "$DV_BID_TIMEOUT" bid_rpc "$host" _host-capacity-sample < /dev/null > "$work/$host.json"
    ) & pid=$!; pids="$pids $pid"
  done
  for pid in $pids; do wait "$pid" || true; done
  for reply in "$work"/*.json; do
    [ -f "$reply" ] || continue
    if ! jq -e '(.learned_cap|type=="number") and (.effective_slots|type=="number") and
      (.free_slots|type=="number")' "$reply" >/dev/null 2>&1; then continue; fi
    host=$(basename "$reply" .json)
    previous="$DV_HOME/autofill/hosts/$host.json"
    key='[.learned_cap,.effective_slots,.free_slots,.capacity_reason]'
    if [ ! -f "$previous" ] || [ "$(jq -c "$key" "$previous")" != "$(jq -c "$key" "$reply")" ]; then
      mv "$reply" "$previous"
      "$DV_ROOT/bin/dv-kick" bid-changed FLEET "Measured capacity changed on $host" "$DV_HOST"
    else mv "$reply" "$previous"; fi
  done
)
