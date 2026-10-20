#!/usr/bin/env bash
# Sourced by run.sh: exercise the scheduler with bids and awards confined to files.
bidding_order_setup() {
  repo order; bidding_functions
  export DV_MANAGER_HOST=lina-os
  local host
  for host in $DV_HOSTS; do
    mkdir -p "$CASE_DIR/hosts/$host"
    printf '{"status":"submitted","score":100}\n' > "$CASE_DIR/hosts/$host/bid.json"
  done
  # bid_limit invokes this fake transport in a child; no SSH or agent is started.
  bid_rpc() {
    local host=$1 command=$2
    printf '%s %s\n' "$host" "$command" >> "$CASE_DIR/order.calls"
    case "$command" in
      bid) cat "$CASE_DIR/hosts/$host/bid.json" ;;
      _award)
        if [ -f "$CASE_DIR/hosts/$host/reject-award" ]; then
          # Real _award reads the request before rejecting. Drain it here too
          # so the scheduler producer cannot race an early-closing fake RPC.
          cat >/dev/null
          jq -cn '{status:"rejected",reason:"full"}'
        else jq '{token,status:"working",head:"fake-head"}'; fi ;;
      *) return 1 ;;
    esac
  }
}
bidding_order_run() {
  local dir="$DV_HOME/submissions/$1"
  mkdir -p "$dir"
  jq -n --arg repo "$REPO" --arg issue "$1" \
    '{issue:$issue,repo:$repo,agent:"codex",status:"submitted",host:null,attempts:[]}' > "$dir/task.json"
  bid_schedule_one "$dir"
}
case_bid_order_ties() {
  local suffix expected host round=0
  for suffix in '-linux' ''; do
    export DV_HOSTS="gos$suffix lina-os go2$suffix amd$suffix hx$suffix gos$suffix"
    if [ "$round" = 0 ]; then bidding_order_setup
    else
      for host in $DV_HOSTS; do
        mkdir -p "$CASE_DIR/hosts/$host"
        printf '{"status":"submitted","score":100}\n' > "$CASE_DIR/hosts/$host/bid.json"
        rm -f "$CASE_DIR/hosts/$host/reject-award"
      done
    fi
    expected="hx$suffix amd$suffix go2$suffix lina-os gos$suffix"
    for host in $expected; do
      round=$((round+1))
      bidding_order_run "ORDER-$round"
      jq -e --arg expected "$expected" \
        'map(.host)==($expected|split(" "))' "$DV_HOME/submissions/ORDER-$round/bids.json"
      jq -e --arg host "$host" '.status=="working" and .host==$host' "$DV_HOME/submissions/ORDER-$round/task.json"
      touch "$CASE_DIR/hosts/$host/reject-award"
    done
  done
}
case_bid_order_fallback() {
  export DV_HOSTS='gos-linux lina-os hx-linux go2-linux'
  bidding_order_setup
  printf '{"status":"submitted","score":200}\n' > "$CASE_DIR/hosts/go2-linux/bid.json"
  printf '{"status":"submitted","score":999}\n' > "$CASE_DIR/hosts/lina-os/bid.json"
  printf '{"status":"submitted","score":9999}\n' > "$CASE_DIR/hosts/gos-linux/bid.json"
  bidding_order_run SCORE
  jq -e 'map(.host)==["go2-linux","hx-linux","lina-os","gos-linux"]' "$DV_HOME/submissions/SCORE/bids.json"
  jq -e '.host=="go2-linux"' "$DV_HOME/submissions/SCORE/task.json"
  # Unavailable workers leave the manager ahead of gos, even at a lower score.
  printf '{"status":"rejected","score":200}\n' > "$CASE_DIR/hosts/go2-linux/bid.json"
  printf '{"status":"rejected","score":100}\n' > "$CASE_DIR/hosts/hx-linux/bid.json"
  bidding_order_run MANAGER
  jq -e '.status=="working" and .host=="lina-os"' "$DV_HOME/submissions/MANAGER/task.json"
  touch "$CASE_DIR/hosts/lina-os/reject-award"
  bidding_order_run LAST
  jq -e '.status=="working" and .host=="gos-linux" and .attempts==["lina-os","gos-linux"]' "$DV_HOME/submissions/LAST/task.json"
}
case_bid_order_probes() {
  export DV_HOSTS='gos-linux lina-os go2-linux amd-linux hx-linux gos-linux'
  bidding_order_setup
  bidding_order_run PROBES
  test "$(awk '$2=="bid" {print $1}' "$CASE_DIR/order.calls" | paste -sd ' ' -)" = 'go2-linux amd-linux hx-linux lina-os gos-linux'
  # Custom managers retain their service protection; gos is still last.
  DV_MANAGER_HOST=amd-linux
  test "$(bid_hosts | awk '!seen[$0]++' | paste -sd ' ' -)" = 'go2-linux hx-linux lina-os amd-linux gos-linux'
  DV_MANAGER_HOST=gos-linux
  test "$(bid_hosts | awk '!seen[$0]++' | paste -sd ' ' -)" = 'go2-linux amd-linux hx-linux lina-os gos-linux'
}
