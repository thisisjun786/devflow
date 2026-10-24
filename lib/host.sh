#!/usr/bin/env bash
# Host setup is independent of bidding and delivery. Never source/eval the TSV.
# Shell snippets expand in the child; PATH changes in subshells are intentional.
# shellcheck disable=SC2016,SC2030,SC2031
# shellcheck source=lib/dsh-host.sh
source "$(dirname "${BASH_SOURCE[0]}")/dsh-host.sh"
host_rows() {
  awk -F '\t' -v host="$DV_HOST" '
    /^#/ || /^[[:space:]]*$/ {next}
    NF != 4 || $1 !~ /^[a-z0-9-]+$/ || $2 !~ /^[a-z0-9.]+$/ ||
      $3 !~ /^(archive|binary|node|npm|apt|check)$/ || $4 !~ /^[A-Za-z0-9_-]+$/ {bad=1; next}
    seen[$1]++ {bad=1; next}
    $4=="all" || $4==host {print}
    END {if (bad) exit 1}
  ' "$DV_ROOT/hosts/tools.tsv"
}
host_command() {
  case "$1" in codex-cli) echo codex ;; claude-code) echo claude ;; *) printf '%s\n' "$1" ;; esac
}
host_limit() (
  local seconds=$1 child timer rc=0
  shift
  # Bash job control assigns a separate group, including inherited stdout
  # holders. A direct-child kill cannot bound command substitution otherwise.
  set -m
  "$@" & child=$!
  (
    set +m
    sleep "$seconds"
    kill -TERM -- "-$child" 2>/dev/null || exit
    sleep 1
    kill -KILL -- "-$child" 2>/dev/null || true
  ) </dev/null >/dev/null 2>&1 & timer=$!
  set +m
  wait "$child" || rc=$?
  # The leader may exit before descendants, including after TERM.
  kill -KILL -- "-$child" 2>/dev/null || true
  kill -TERM -- "-$timer" 2>/dev/null || true
  wait "$timer" 2>/dev/null || true
  return "$rc"
)
host_shell_path() {
  local mode=$1 output shell=${DV_HOST_SHELL:-${SHELL:-/bin/bash}}
  local args=(-i "HOME=$HOME" "USER=${USER:-}" "LOGNAME=${LOGNAME:-}" "SHELL=$shell"
    'PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin')
  # SSH invokes the account shell with -c, not -lc. SSH_CLIENT also enables
  # bash's sshd startup-file behavior. No network/self-SSH is needed to probe it.
  if [ "$mode" = ssh ]; then args+=('SSH_CLIENT=127.0.0.1 1 22' 'SHLVL=0'); fi
  local flag=-lc
  [ "$mode" != ssh ] || flag=-c
  output=$(host_limit 10 env "${args[@]}" "$shell" "$flag" 'printf "\n__DV_HOST_PATH__%s\n" "$PATH"' 2>/dev/null) || return 1
  printf '%s\n' "$output" | sed -n 's/^__DV_HOST_PATH__//p' | tail -n 1
}
host_resolve() { (PATH=$1; command -v "$2" 2>/dev/null) || true; }
host_version() {
  local bin=$1 name=$2 output
  case "$name" in go) set -- version ;; gitleaks) set -- version ;; tmux) set -- -V ;; *) set -- --version ;; esac
  output=$(host_limit 8 "$bin" "$@" 2>/dev/null) || return 1
  output=$(printf '%s\n' "$output" | sed -nE 's/^[^0-9]*([0-9]+(\.[0-9]+)+([a-z][0-9]*)?).*/\1/p' | head -n 1)
  [ -n "$output" ] || return 1
  printf '%s\n' "$output"
}
host_measure() {
  local name=$1 expected=$2 path=$3 bin version='' status=missing reason=''
  bin=$(host_resolve "$path" "$(host_command "$name")")
  if [ -n "$bin" ] && [ -x "$bin" ]; then
    version=$(PATH="$path" host_version "$bin" "$name") || true
    status=wrong-version
    if [ -n "$version" ] && { [ "$expected" = system ] || [ "$expected" = bundled ] || [ "$version" = "$expected" ]; }; then status=ok; fi
    # A standalone install must not remain tied to an old checkout's binary.
    if [ "$name" = gitleaks ] && [ -L "$bin" ]; then status=wrong-version; reason=symlink; fi
    if [ "$name" = npm ] && [ "$expected" = bundled ] && ! host_npm_bundled "$bin" "$path"; then
      status=wrong-version; reason=not-bundled
    fi
  fi
  jq -cn --arg path "$bin" --arg version "$version" --arg status "$status" --arg reason "$reason" \
    '{path:$path,version:$version,status:$status,reason:$reason}'
}
host_auth() {
  local name=$1 path=$2 bin output
  bin=$(agent_bin "$name") || bin=$name
  bin=$(host_resolve "$path" "$bin")
  if [ -z "$bin" ] || [ ! -x "$bin" ]; then echo missing; return; fi
  if output=$(PATH="$path" host_limit 10 agent_auth_probe "$name" "$bin" 2>/dev/null); then
    # Claude can return JSON with loggedIn=false without a failing exit status.
    if [ "$name" = claude ] && printf '%s' "$output" | jq -e '.loggedIn==false' >/dev/null 2>&1; then
      echo unavailable
    else echo logged-in; fi
  else echo unavailable; fi
}
host_realpath() {
  local path=$1 count=0 target
  while [ -L "$path" ]; do
    count=$((count + 1)); [ "$count" -le 40 ] || return 1
    target=$(readlink "$path") || return 1
    case "$target" in /*) path=$target ;; *) path="$(dirname "$path")/$target" ;; esac
  done
  [ -e "$path" ] || return 1
  printf '%s/%s\n' "$(cd "$(dirname "$path")" && pwd -P)" "$(basename "$path")"
}
host_npm_bundled() {
  local bin=$1 path=$2 actual prefix node pinned
  actual=$(host_realpath "$bin") || return 1
  prefix=$(cd "$HOME/node" && pwd -P) || return 1
  case "$actual" in "$prefix/bin/npm"|"$prefix/lib/node_modules/npm/"*) ;; *) return 1 ;; esac
  node=$(host_resolve "$path" node)
  [ "$(host_realpath "$node")" = "$prefix/bin/node" ] || return 1
  pinned=$(host_rows | awk -F '\t' '$1=="node" {print $2}') || return 1
  [ -n "$pinned" ] && [ "$(host_version "$node" node)" = "$pinned" ]
}
host_codex_launcher() {
  local path=$1 proxy=$2 bin status=missing actual expected
  bin=$(host_resolve "$path" "$DV_CODEX_BIN")
  if [ -n "$bin" ] && [ -x "$bin" ]; then
    status=ok
    if [ "$proxy" = true ]; then
      actual=$(host_realpath "$bin") || actual=''
      expected=$(host_realpath "$HOME/.opencodex/bin/codex") || expected=''
      if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then status=wrong-launcher; fi
    fi
  fi
  jq -cn --arg path "$bin" --arg status "$status" '{path:$path,status:$status}'
}
host_probe_codex() (
  local bin=$1 path=$2 dir rc=0
  tmp_agent_environment
  tmp_make dir dv-host-probe || exit 1
  trap 'rm -rf "$dir"' EXIT
  cd "$dir" || exit 1
  # Keep provider/auth settings, avoid proxy autostart and persistent sessions.
  PATH="$path" OCX_SHIM_BYPASS=1 host_limit 60 "$bin" exec --ephemeral --skip-git-repo-check \
    --sandbox read-only --disable hooks --disable shell_tool -c 'approval_policy="never"' \
    -c 'web_search="disabled"' 'Reply with exactly OK. Do not use any tools.' </dev/null >/dev/null 2>&1 || rc=$?
  exit "$rc"
)
host_omp_compaction() {
  local path=$1 bin value=null status=missing output
  [[ "$DV_OMP_COMPACT_TOKENS" =~ ^[1-9][0-9]{0,8}$ ]] || fail 'DV_OMP_COMPACT_TOKENS must be a positive integer (at most 9 digits)'
  bin=$(host_resolve "$path" "$DV_OMP_BIN")
  if [ -n "$bin" ] && [ -x "$bin" ]; then
    status=unavailable
    if output=$(PATH="$path" host_limit 10 "$bin" config get compaction.thresholdTokens --json 2>/dev/null) &&
      printf '%s\n' "$output" | jq -e '.key=="compaction.thresholdTokens" and has("value") and
        ((.value|type)=="number" or .value==null)' >/dev/null 2>&1; then
      value=$(printf '%s\n' "$output" | jq -c .value)
      status=mismatch
      [ "$value" != "$DV_OMP_COMPACT_TOKENS" ] || status=ok
    fi
  fi
  jq -cn --arg path "$bin" --argjson value "$value" --arg status "$status" \
    '{path:$path,value:$value,status:$status}'
}
host_omp_compaction_sync() {
  local measured status bin
  measured=$(host_omp_compaction "$PATH") || return 1
  status=$(printf '%s\n' "$measured" | jq -r .status)
  case "$status" in
    missing|ok) return 0 ;;
    unavailable) fail 'could not read omp compaction.thresholdTokens; configuration unchanged' ;;
  esac
  bin=$(printf '%s\n' "$measured" | jq -r .path)
  host_limit 10 "$bin" config set compaction.thresholdTokens "$DV_OMP_COMPACT_TOKENS" ||
    fail 'could not set omp compaction.thresholdTokens'
}
host_check() {
  local json=0 probe=0 rows login_path ssh_path name version install scope login ssh tools_json auth='{}' result
  local proxy=false codex_login codex_ssh probe_result='{"status":"not-requested"}' rc=0 bin
  local omp_login omp_ssh dsh_probe=0 dsh_probe_result=not-requested dsh_info
  for arg in "$@"; do
    case "$arg" in --json) json=1 ;; --probe-codex) probe=1 ;; --probe-dsh) dsh_probe=1 ;; *) fail 'usage: dv host check [--json] [--probe-codex] [--probe-dsh]' ;; esac
  done
  rows=$(host_rows) || fail 'invalid hosts/tools.tsv'
  login_path=$(host_shell_path login) || fail 'login shell probe failed'
  ssh_path=$(host_shell_path ssh) || fail 'non-interactive SSH shell probe failed'
  if [ -z "$login_path" ] || [ -z "$ssh_path" ]; then fail 'shell did not return PATH'; fi
  tools_json=$(
    while IFS=$'\t' read -r name version install scope; do
      [ -n "$name" ] || continue
      login=$(host_measure "$name" "$version" "$login_path")
      ssh=$(host_measure "$name" "$version" "$ssh_path")
      jq -cn --arg name "$name" --arg expected "$version" --arg install "$install" --arg scope "$scope" \
        --argjson login "$login" --argjson ssh "$ssh" \
        '{name:$name,expected:$expected,install:$install,scope:$scope,login:$login,ssh:$ssh}'
    done <<< "$rows"
  )
  for name in gh codex claude devin omp agy grok cursor; do
    login=$(host_auth "$name" "$login_path"); ssh=$(host_auth "$name" "$ssh_path")
    auth=$(printf '%s' "$auth" | jq --arg name "$name" --arg login "$login" --arg ssh "$ssh" '. + {($name):{login:$login,ssh:$ssh}}')
  done
  if [ -d "$HOME/.opencodex" ] || [ -n "${OPENCODEX_API_AUTH_TOKEN:-}" ] ||
    grep -Eq 'opencodex|OPENCODEX_API_AUTH_TOKEN' "${CODEX_HOME:-$HOME/.codex}/config.toml" 2>/dev/null; then proxy=true; fi
  codex_login=$(host_codex_launcher "$login_path" "$proxy")
  codex_ssh=$(host_codex_launcher "$ssh_path" "$proxy")
  omp_login=$(host_omp_compaction "$login_path") || return 1
  omp_ssh=$(host_omp_compaction "$ssh_path") || return 1
  dsh_info=$(PATH="$ssh_path" host_dsh_check) || return 1
  if [ "$dsh_probe" = 1 ]; then
    if PATH="$ssh_path" host_probe_dsh; then dsh_probe_result=ready
    else dsh_probe_result=failed; rc=1; fi
  fi
  if [ "$probe" = 1 ]; then
    bin=$(printf '%s' "$codex_ssh" | jq -r .path)
    if [ "$(printf '%s' "$codex_ssh" | jq -r .status)" != ok ]; then
      probe_result='{"status":"unavailable"}'; rc=1
    else
      host_probe_codex "$bin" "$ssh_path" || rc=$?
      probe_result=$(jq -cn --argjson rc "$rc" '{status:(if $rc==0 then "ready" else "failed" end),exit:$rc}')
    fi
  fi
  result=$(printf '%s\n' "$tools_json" | jq -s --arg host "$DV_HOST" --arg shell "${DV_HOST_SHELL:-${SHELL:-/bin/bash}}" \
    --arg configured "$DV_CODEX_BIN" --argjson proxy "$proxy" --argjson auth "$auth" \
    --argjson login "$codex_login" --argjson ssh "$codex_ssh" --argjson probe "$probe_result" --argjson onboarding "$(claude_onboarding)" \
    --argjson watcher "$(self_update_watch_status)" --argjson disk "$(disk_info)" --argjson tmp "$(tmp_quota_info)" --argjson limits "$(job_host_info)" \
    --argjson omp_login "$omp_login" --argjson omp_ssh "$omp_ssh" --argjson compact_tokens "$DV_OMP_COMPACT_TOKENS" \
    --argjson dsh "$dsh_info" --arg dsh_probe "$dsh_probe_result" \
    '{host:$host,shell:$shell,tools:.,auth:$auth,watcher:$watcher,tmp:$tmp,job_limits:$limits,codex:{configured:$configured,proxy:$proxy,login:$login,ssh:$ssh,probe:$probe},claude:{onboarding:$onboarding},
      omp:{compaction:{expected:$compact_tokens,login:$omp_login,ssh:$omp_ssh}},dsh:($dsh+{probe:$dsh_probe})} + $disk')
  if [ "$json" = 1 ]; then printf '%s\n' "$result"
  else
    printf 'Host: %s (local login / non-interactive SSH shell startup)\n' "$DV_HOST"
    printf '%s\n' "$result" | jq -r '.job_limits | "Job limits: \(.mode) systemd-run=\(.systemd_run_available) MemoryMax=\(.memory_max) TasksMax=\(.tasks_max) MemorySwapMax=\(.memory_swap_max) nproc=\(.nproc_limit // "unavailable") launchd=\(.launchd_max) pattern=\(.launchd_pattern)"'
    printf '%s\n' "$result" | jq -r '.watcher | "watcher: \(.status) commit=\(.commit) origin/main=\(.origin_main)"'
    printf '%s\n' "$result" | jq -r '.tmp | "/tmp user usage: \(.usage_kb // "unknown") / \(.quota_kb // "unknown") KiB (\(.percent // "unknown")%; \(.source))", (if .warning then "WARNING: /tmp user usage exceeds 80% of quota (\(.source))" else empty end)'
    printf '%s\n' "$result" | jq -r '"Disk available: \(.disk_available_gb // "unknown") GiB (\(.work_root))\nCache disk available: \(.cache_disk_available_gb // "unknown") GiB (\(.go_cache_path // "unavailable"))\nGo build cache: \(.cache_sizes_kb.go_build // "unknown") KiB; total ~/.cache: \(.cache_sizes_kb.total // "unknown") KiB"'
    printf '%s\n' "$result" | jq -r '.tools[] | "\(.name) expected=\(.expected)\n  login: \(.login.status) \(.login.version) \(.login.path) \(.login.reason)\n  ssh:   \(.ssh.status) \(.ssh.version) \(.ssh.path) \(.ssh.reason)"'
    printf '%s\n' "$result" | jq -r '.auth | to_entries[] | "auth \(.key): login=\(.value.login) ssh=\(.value.ssh)"'
    printf '%s\n' "$result" | jq -r '.claude.onboarding | "claude onboarding: hasCompletedOnboarding=\(.hasCompletedOnboarding) skipDangerousModePermissionPrompt=\(.skipDangerousModePermissionPrompt)"'
    printf '%s\n' "$result" | jq -r '.dsh | "dsh version=\(.version) expected=\(.expected) node>=24.9=\(.node_ready) profile=\(.profile) present=\(.profile_present) key_present=\(.key_present) jail=\(.jail.status) (\(.jail.reason)) probe=\(.probe)"'
    printf '%s\n' "$result" | jq -r '.omp.compaction |
      "omp compaction.thresholdTokens expected=\(.expected)\n  login: \(.login.status) \(.login.value // "unset")\n  ssh:   \(.ssh.status) \(.ssh.value // "unset")",
      (if any(.login,.ssh; .status=="mismatch" or .status=="unavailable") then
        "WARNING: omp compaction.thresholdTokens differs or is unavailable; run dv host sync" else empty end)'
    printf '%s\n' "$result" | jq -r '.codex | "DV_CODEX_BIN=\(.configured) proxy=\(.proxy)\n  login: \(.login.status) \(.login.path)\n  ssh:   \(.ssh.status) \(.ssh.path)\n  codex probe: \(.probe.status)"'
  fi
  [ "$rc" = 0 ]
}
host_path_block() {
  # macOS: non-login SSH shells also need Homebrew (tmux, shellcheck, flock).
  local brew=''
  [ -z "${1:-}" ] || brew="$1/bin:$1/sbin:"
  printf '%s\n' '# BEGIN devflow PATH' 'export GOROOT="$HOME/.local/go/go"' 'export GOPATH="$HOME/.local/go"' \
    "export PATH=\"\$HOME/.opencodex/bin:\$HOME/node/bin:\$GOROOT/bin:\$GOPATH/bin:\$HOME/.local/bin:$brew\$PATH\"" '# END devflow PATH'
}
host_path_validate() {
  local file=$1
  [ ! -L "$file" ] || fail "refusing shell-file symlink: $file"
  [ ! -e "$file" ] || [ -f "$file" ] || fail "not a regular file: $file"
  [ -e "$file" ] || return 0
  awk '
    $0=="# BEGIN devflow PATH" {if (inside) bad=1; inside=1}
    $0=="# END devflow PATH" {if (!inside) bad=1; inside=0}
    END {if (inside || bad) exit 1}
  ' "$file" || fail "unbalanced devflow PATH markers: $file"
}
host_path_update() {
  local file=$1 brew=${2:-} tmp
  host_path_validate "$file"
  tmp=$(mktemp "$HOME/.dv-path.XXXXXX")
  if [ -f "$file" ]; then
    cp -p "$file" "$tmp"
    # Only remove blocks owned by devflow, including duplicates of those blocks.
    awk '$0=="# BEGIN devflow PATH" {inside=1; next}
      $0=="# END devflow PATH" {inside=0; next} !inside {print}' "$file" > "$tmp"
  fi
  host_path_block "$brew" >> "$tmp"
  if [ -f "$file" ] && cmp -s "$file" "$tmp"; then rm "$tmp"
  else mv "$tmp" "$file"; printf 'PATH: %s\n' "$file"; fi
}
host_target() {
  case "$1" in
    go) printf '%s/.local/go/go/bin/go\n' "$HOME" ;;
    node|npm|claude-code|pnpm) printf '%s/node/bin/%s\n' "$HOME" "$(host_command "$1")" ;;
    *) printf '%s/.local/bin/%s\n' "$HOME" "$(host_command "$1")" ;;
  esac
}
host_publish() {
  local source=$1 target=$2 backup=''
  mkdir -p "$(dirname "$target")"
  if [ -e "$target" ] || [ -L "$target" ]; then
    backup=$(mktemp -d "$target.dv-backup.XXXXXX") || fail 'cannot reserve backup'
    rmdir "$backup"
    mv "$target" "$backup"
  fi
  if ! mv "$source" "$target"; then
    [ -z "$backup" ] || mv "$backup" "$target"
    fail "install failed: $target"
  fi
  [ -z "$backup" ] || printf 'Kept previous install: %s\n' "$backup"
}
host_download_verify() {
  local name=$1 version=$2 url=$3 file=$4 metadata=$5 checksum_url expected actual asset
  asset=${url##*/}
  case "$name" in
    go) checksum_url='https://go.dev/dl/?mode=json&include=all' ;;
    node) checksum_url="${url%/*}/SHASUMS256.txt" ;;
    uv) checksum_url="$url.sha256" ;;
    gh) checksum_url="${url%/*}/gh_${version}_checksums.txt" ;;
    gitleaks) checksum_url="${url%/*}/gitleaks_${version}_checksums.txt" ;;
    herdr) checksum_url="https://api.github.com/repos/herdrdev/herdr/releases/tags/v$version" ;;
    *) fail "no checksum source for $name" ;;
  esac
  curl --fail --location --silent --show-error --connect-timeout 15 --max-time 300 --output "$metadata" "$checksum_url"
  case "$name" in
    go) expected=$(jq -er --arg asset "$asset" '[.[].files[] | select(.filename==$asset) | .sha256] | select(length==1) | .[0]' "$metadata") || fail "missing checksum: $asset" ;;
    herdr) expected=$(jq -er --arg asset "$asset" '[.assets[] | select(.name==$asset) | .digest | select(startswith("sha256:")) | ltrimstr("sha256:")] | select(length==1) | .[0]' "$metadata") || fail "missing checksum: $asset" ;;
    *) expected=$(awk -v asset="$asset" '$2==asset || $2=="*"asset {print $1}' "$metadata") ;;
  esac
  [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || fail "invalid checksum: $asset"
  if command -v sha256sum >/dev/null; then actual=$(sha256sum "$file")
  else actual=$(shasum -a 256 "$file"); fi
  [ "${actual%% *}" = "$expected" ] || fail "checksum mismatch: $asset"
}
host_download_install() {
  local name=$1 version=$2 stage=$3 arch=$4 os=${5:-linux} url file source target machine node_arch leaks_arch uv_target
  machine=$arch; node_arch=$arch; leaks_arch=$arch
  case "$arch" in amd64) machine=x86_64; node_arch=x64; leaks_arch=x64 ;; arm64) machine=aarch64 ;; esac
  # The same pinned releases publish macOS assets under these names.
  uv_target="$machine-unknown-linux-gnu"
  [ "$os" != darwin ] || uv_target="$machine-apple-darwin"
  case "$os:$name" in
    *:go) url="https://go.dev/dl/go$version.$os-$arch.tar.gz"; source="$stage/go/bin/go"; target="$HOME/.local/go/go" ;;
    *:node) url="https://nodejs.org/dist/v$version/node-v$version-$os-$node_arch.tar.gz"; source="$stage/node-v$version-$os-$node_arch/bin/node"; target="$HOME/node" ;;
    *:uv) url="https://github.com/astral-sh/uv/releases/download/$version/uv-$uv_target.tar.gz"; source="$stage/uv-$uv_target/uv" ;;
    linux:gh) url="https://github.com/cli/cli/releases/download/v$version/gh_${version}_linux_$arch.tar.gz"; source="$stage/gh_${version}_linux_$arch/bin/gh" ;;
    darwin:gh) url="https://github.com/cli/cli/releases/download/v$version/gh_${version}_macOS_$arch.zip"; source="$stage/gh_${version}_macOS_$arch/bin/gh" ;;
    *:gitleaks) url="https://github.com/gitleaks/gitleaks/releases/download/v$version/gitleaks_${version}_${os}_$leaks_arch.tar.gz"; source="$stage/gitleaks" ;;
    linux:herdr) url="https://github.com/herdrdev/herdr/releases/download/v$version/herdr-linux-$machine"; source="$stage/herdr" ;;
    darwin:herdr) url="https://github.com/herdrdev/herdr/releases/download/v$version/herdr-macos-$machine"; source="$stage/herdr" ;;
    *) fail "no installer for $name" ;;
  esac
  file="$stage/download"
  curl --fail --location --silent --show-error --connect-timeout 15 --max-time 300 --output "$file" "$url"
  host_download_verify "$name" "$version" "$url" "$file" "$stage/checksum"
  if [ "$name" = herdr ]; then mv "$file" "$source"; chmod +x "$source"
  elif [ "${url%.zip}" != "$url" ]; then unzip -q "$file" -d "$stage"
  else tar -xzf "$file" -C "$stage"; fi
  [ "$(host_version "$source" "$name")" = "$version" ] || fail "downloaded $name has unexpected version"
  case "$name" in
    go) host_publish "$stage/go" "$target" ;;
    node) [ -x "$(dirname "$source")/npm" ] || fail 'node archive missing npm'
      host_publish "$(dirname "$(dirname "$source")")" "$target" ;;
    *) host_publish "$source" "$(host_target "$name")"
      if [ "$name" = uv ] && [ -x "$(dirname "$source")/uvx" ]; then host_publish "$(dirname "$source")/uvx" "$HOME/.local/bin/uvx"; fi ;;
  esac
}
host_brew_prefix() {
  local brew
  brew=$(command -v brew 2>/dev/null) || brew=''
  # Homebrew's default prefix also covers a later install by the operator.
  if [ -z "$brew" ]; then
    case "$1" in arm64) brew=/opt/homebrew/bin/brew ;; *) brew=/usr/local/bin/brew ;; esac
  fi
  brew=$(dirname "$(dirname "$brew")")
  # The prefix is written into shell startup files.
  [[ "$brew" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail "unsupported Homebrew prefix: $brew"
  printf '%s\n' "$brew"
}
host_sync() (
  [ "$#" = 0 ] || fail 'usage: dv host sync'
  local rows name version install scope target current arch os brew='' stage lock package missing_apt=''
  case "$(uname -s)" in
    Linux) os=linux ;; Darwin) os=darwin ;;
    *) fail 'host sync supports Linux and macOS only; check is available on other systems' ;;
  esac
  case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) fail "unsupported $(uname -s) architecture" ;; esac
  [ "$os" = linux ] || brew=$(host_brew_prefix "$arch")
  rows=$(host_rows) || fail 'invalid hosts/tools.tsv'
  host_path_validate "$HOME/.profile"; host_path_validate "$HOME/.zshenv"
  mkdir -p "$HOME/.local/state/devflow-host"
  lock="$HOME/.local/state/devflow-host/sync.lock"
  mkdir "$lock" 2>/dev/null || fail "host sync already running: $lock"
  stage=''
  trap '[ -z "$stage" ] || rm -rf "$stage"; rmdir "$lock"' EXIT
  export PATH="$HOME/node/bin:$HOME/.local/go/go/bin:$HOME/.local/bin:$PATH"
  while IFS=$'\t' read -r name version install scope; do
    [ -n "$name" ] || continue
    case "$install" in
      apt) command -v "$name" >/dev/null || missing_apt="$missing_apt $name"; continue ;;
      check) printf 'Check only: %s (%s); use dv host check\n' "$name" "$version"; continue ;;
    esac
    target=$(host_target "$name"); current=''
    if [ -x "$target" ]; then current=$(host_version "$target" "$name") || true; fi
    # npm belongs to the node distribution: repair the archive if it is broken.
    if [ "$name" = node ] && { ! host_version "$HOME/node/bin/npm" npm >/dev/null || ! host_npm_bundled "$HOME/node/bin/npm" "$PATH"; }; then current=''; fi
    if [ -n "$current" ] && { [ "$version" = bundled ] || [ "$current" = "$version" ]; } &&
      { [ "$name" != gitleaks ] || [ ! -L "$target" ]; }; then continue; fi
    printf 'Install: %s %s\n' "$name" "$version"
    case "$install" in
      archive|binary)
        stage=$(mktemp -d "$HOME/.local/.dv-host.XXXXXX")
        host_download_install "$name" "$version" "$stage" "$arch" "$os"
        rm -rf "$stage"; stage='' ;;
      npm)
        [ -x "$HOME/node/bin/npm" ] || fail 'install node/npm first'
        package=$name; [ "$name" != claude-code ] || package=@anthropic-ai/claude-code
        stage=$(mktemp -d "$HOME/.local/.dv-host.XXXXXX")
        # Copy the contents even when the live prefix itself is a symlink.
        cp -R "$HOME/node/." "$stage/node"
        PATH="$stage/node/bin:$PATH" "$stage/node/bin/npm" install --global --prefix "$stage/node" "$package@$version"
        [ "$(host_version "$stage/node/bin/$(host_command "$name")" "$name")" = "$version" ] || fail "installed $name has unexpected version"
        host_publish "$stage/node" "$HOME/node"
        rm -rf "$stage"; stage='' ;;
      node) fail 'npm missing from node; restore the pinned node archive before retrying' ;;
      *) fail "unsupported installer: $install" ;;
    esac
  done <<< "$rows"
  host_dsh_sync
  host_omp_compaction_sync
  host_path_update "$HOME/.profile" "$brew"; host_path_update "$HOME/.zshenv" "$brew"
  if [ -z "$missing_apt" ]; then :
  elif [ "$os" = darwin ]; then
    # Homebrew names the sqlite3 command's formula sqlite.
    printf 'Operator action (not executed): brew install%s\n' "$(printf '%s' "$missing_apt" | sed 's/ sqlite3/ sqlite/')"
  else printf 'Operator action (not executed): sudo apt-get install%s\n' "$missing_apt"; fi
  printf 'Sync complete. Run dv host check in a fresh shell; check-only tools/auth may still need operator action.\n'
)
cmd_host() {
  [ "$#" -gt 0 ] || fail 'usage: dv host check [--json] [--probe-codex] | sync'
  local action=$1; shift
  case "$action" in check) host_check "$@" ;; sync) host_sync "$@" ;; *) fail "unknown host action: $action" ;; esac
}
