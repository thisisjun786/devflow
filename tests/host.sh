#!/usr/bin/env bash
# Shell snippets are deliberately expanded by the isolated child shell.
# shellcheck disable=SC2016
host_setup() {
  export HOME="$CASE_DIR/host home" HOST_FIXTURES="$ROOT/tests/fixtures"
  export DV_HOST_SHELL="$HOST_FIXTURES/host-shell"
  mkdir -p "$HOME" "$CASE_DIR/host-bin" "$HOME/system"
  printf 'export PATH="$HOME/system:/usr/bin:/bin"\n' > "$HOME/.profile"
  cp "$HOME/.profile" "$HOME/.zshenv"
  for tool in gh codex claude devin; do host_fake "$HOME/system/$tool" 0.0.0; done
  ln -s "$HOST_FIXTURES/host-curl" "$CASE_DIR/host-bin/curl"
  printf '#!/usr/bin/env bash\ncase "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac\n' > "$CASE_DIR/host-bin/uname"
  chmod +x "$CASE_DIR/host-bin/uname"
  printf '#!/usr/bin/env bash\nexit 99\n' > "$CASE_DIR/host-bin/sudo"
  chmod +x "$CASE_DIR/host-bin/sudo"
  export PATH="$CASE_DIR/host-bin:$PATH"
  # Copy the checkout so host-scoped rows can be tested without changing source.
  mkdir "$CASE_DIR/host-root"
  cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/hosts" "$ROOT/config.example.sh" "$CASE_DIR/host-root/"
  HOST_DV="$CASE_DIR/host-root/bin/dv"
}
host_fake() {
  mkdir -p "$(dirname "$1")"
  sed "s/@VERSION@/$2/" "$HOST_FIXTURES/host-tool" > "$1"
  chmod +x "$1"
}
case_host_check() {
  host_setup
  printf 'export PATH="$HOME/system:/usr/bin:/bin"\n' > "$HOME/.profile"
  printf 'export PATH="$HOME/ssh:$HOME/system:/usr/bin:/bin"\n' > "$HOME/.zshenv"
  host_fake "$HOME/system/node" 24.20.0
  host_fake "$HOME/ssh/node" 22.0.0
  host_fake "$HOME/system/gh" 2.46.0
  host_fake "$HOME/system/claude" 2.1.304
  printf 'optional\t1.0.0\tcheck\tother-host\n' >> "$CASE_DIR/host-root/hosts/tools.tsv"
  "$HOST_DV" host check --json > "$CASE_DIR/check.json"
  jq -e '.tools[] | select(.name=="node") | .login.status=="ok" and .ssh.status=="wrong-version" and (.ssh.path|endswith("/ssh/node"))' "$CASE_DIR/check.json"
  jq -e '.tools[] | select(.name=="uv") | .login.status=="missing"' "$CASE_DIR/check.json"
  jq -e '.auth.gh.login=="logged-in" and .auth.claude.login=="unavailable" and all(.tools[]; .name!="optional")' "$CASE_DIR/check.json"
  "$HOST_DV" host check > "$CASE_DIR/check.txt"
  grep 'wrong-version' "$CASE_DIR/check.txt"
  if grep 'private auth detail' "$CASE_DIR/check.json" "$CASE_DIR/check.txt"; then return 1; fi
  test ! -e "$HOME/downloads"
  test ! -e "$HOME/.local"
}
case_host_sync() {
  host_setup
  printf '# user profile\nexport USER_SETTING=keep\n' > "$HOME/.profile"
  printf '# user zshenv\n' > "$HOME/.zshenv"
  cp "$HOME/.profile" "$CASE_DIR/profile.before"
  mkdir -p "$HOME/.local/bin" "$HOME/old"
  host_fake "$HOME/old/gitleaks" 8.30.1
  ln -s "$HOME/old/gitleaks" "$HOME/.local/bin/gitleaks"
  cp "$HOME/old/gitleaks" "$CASE_DIR/old.before"
  "$HOST_DV" host sync > "$CASE_DIR/sync.txt"
  test ! -L "$HOME/.local/bin/gitleaks"
  cmp "$HOME/old/gitleaks" "$CASE_DIR/old.before"
  grep -F '# user profile' "$HOME/.profile"
  test "$(grep -c '^# BEGIN devflow PATH$' "$HOME/.profile")" = 1
  test "$(grep -c '^# BEGIN devflow PATH$' "$HOME/.zshenv")" = 1
  cp "$HOME/.profile" "$CASE_DIR/profile.after"
  cp "$HOME/.zshenv" "$CASE_DIR/zshenv.after"
  cp "$HOME/downloads" "$CASE_DIR/downloads.after"
  cp "$HOME/installs" "$CASE_DIR/installs.after"
  "$HOST_DV" host sync > "$CASE_DIR/sync2.txt"
  cmp "$HOME/.profile" "$CASE_DIR/profile.after"
  cmp "$HOME/.zshenv" "$CASE_DIR/zshenv.after"
  cmp "$HOME/downloads" "$CASE_DIR/downloads.after"
  cmp "$HOME/installs" "$CASE_DIR/installs.after"
  "$HOST_DV" host check --json > "$CASE_DIR/after.json"
  jq -e 'all(.tools[] | select(.install!="apt" and .install!="check"); .login.status=="ok" and .ssh.status=="ok")' "$CASE_DIR/after.json"
  test ! -e "$HOME/.opencodex"
  test ! -e "$HOME/.local/bin/devin"
  bash -c 'source "$HOME/.profile"; test "$GOROOT" = "$HOME/.local/go/go"; test "$GOPATH" = "$HOME/.local/go"; test "$(command -v node)" = "$HOME/node/bin/node"'
  if command -v zsh >/dev/null; then
    env -i HOME="$HOME" PATH=/usr/bin:/bin zsh -c 'test "$(command -v node)" = "$HOME/node/bin/node"'
  fi
}
case_host_sync_failure() {
  host_setup
  printf '# keep\n' > "$HOME/.profile"
  cp "$HOME/.profile" "$CASE_DIR/before"
  if HOST_DOWNLOAD_FAIL=1 "$HOST_DV" host sync > "$CASE_DIR/failure.txt" 2>&1; then return 1; fi
  cmp "$HOME/.profile" "$CASE_DIR/before"
  test ! -e "$HOME/.local/go/go"
  if HOST_BAD_VERSION=0.0.0 "$HOST_DV" host sync > "$CASE_DIR/bad.txt" 2>&1; then return 1; fi
  test ! -e "$HOME/.local/go/go"
}
case_host_path_guard() {
  host_setup
  printf '# BEGIN devflow PATH\nuser data\n' > "$HOME/.profile"
  cp "$HOME/.profile" "$CASE_DIR/before"
  if "$HOST_DV" host sync > "$CASE_DIR/guard.txt" 2>&1; then return 1; fi
  cmp "$HOME/.profile" "$CASE_DIR/before"
  test ! -e "$HOME/downloads"
}
case_host_codex() {
  host_setup
  host_fake "$HOME/.opencodex/bin/codex" 0.163.0
  host_fake "$HOME/system/codex" 0.163.0
  export DV_CODEX_BIN=codex
  "$HOST_DV" host check --json > "$CASE_DIR/raw.json"
  jq -e '.codex.proxy==true and .codex.login.status=="wrong-launcher" and (.codex.login.path|endswith("/system/codex")) and .codex.probe.status=="not-requested"' "$CASE_DIR/raw.json"
  test ! -e "$HOME/probes"
  export DV_CODEX_BIN="$HOME/.opencodex/bin/codex"
  "$HOST_DV" host check --json --probe-codex > "$CASE_DIR/probe.json"
  jq -e '.codex.login.status=="ok" and .codex.probe.status=="ready"' "$CASE_DIR/probe.json"
  test "$(wc -l < "$HOME/probes" | tr -d ' ')" = 1
  grep -- '--ephemeral' "$HOME/probes"
  grep -- '--sandbox read-only' "$HOME/probes"
  if HOST_PROBE_EXIT=7 "$HOST_DV" host check --probe-codex --json > "$CASE_DIR/failed.json"; then return 1; fi
  jq -e '.codex.probe.status=="failed" and .codex.probe.exit==7' "$CASE_DIR/failed.json"
  if grep 'private provider detail' "$CASE_DIR/failed.json"; then return 1; fi
}
case_host_repair() {
  host_setup
  "$HOST_DV" host sync > "$CASE_DIR/first.txt"
  # Missing bundled npm requires repairing node even when node's version matches.
  rm "$HOME/node/bin/npm"
  "$HOST_DV" host sync > "$CASE_DIR/repair.txt"
  test -x "$HOME/node/bin/npm"
  grep 'Install: node 24.20.0' "$CASE_DIR/repair.txt"
  # A wrong existing binary survives a failed replacement; settings are intact.
  host_fake "$HOME/.local/bin/uv" 0.0.0
  cp "$HOME/.local/bin/uv" "$CASE_DIR/uv.before"
  cp "$HOME/.profile" "$CASE_DIR/profile.before"
  if HOST_DOWNLOAD_FAIL=1 "$HOST_DV" host sync > "$CASE_DIR/failed.txt" 2>&1; then return 1; fi
  cmp "$HOME/.local/bin/uv" "$CASE_DIR/uv.before"
  cmp "$HOME/.profile" "$CASE_DIR/profile.before"
  "$HOST_DV" host sync > "$CASE_DIR/recovered.txt"
  "$HOME/.local/bin/uv" --version | grep 0.11.32
}
case_host_path_preserve() {
  host_setup
  printf '# user before\n# BEGIN devflow PATH\nold\n# END devflow PATH\n# user middle\n# BEGIN devflow PATH\nold2\n# END devflow PATH\n# user after\n' > "$HOME/.zshenv"
  chmod 640 "$HOME/.zshenv"
  "$HOST_DV" host sync > "$CASE_DIR/first.txt"
  test "$(grep -c '^# BEGIN devflow PATH$' "$HOME/.zshenv")" = 1
  grep '^# user' "$HOME/.zshenv" > "$CASE_DIR/user-lines"
  printf '# user before\n# user middle\n# user after\n' > "$CASE_DIR/expected"
  cmp "$CASE_DIR/expected" "$CASE_DIR/user-lines"
  cp "$HOME/.profile" "$CASE_DIR/profile.before"
  rm "$HOME/.profile"
  ln -s "$CASE_DIR/profile.before" "$HOME/.profile"
  if "$HOST_DV" host sync > "$CASE_DIR/link.txt" 2>&1; then return 1; fi
  test -L "$HOME/.profile"
}
case_host_real_shells() {
  host_setup
  export DV_HOST_SHELL=/bin/bash
  # Real bash SSH startup reads .bashrc, which the operator can use to source profile.
  printf '. "$HOME/.profile"\n' > "$HOME/.bashrc"
  export DV_ENTRY="$ROOT/bin/dv"
  # shellcheck source=lib/common.sh
  source "$ROOT/lib/common.sh"
  # shellcheck source=lib/host.sh
  source "$ROOT/lib/host.sh"
  path=$(host_shell_path ssh)
  test "$path" = "$HOME/system:/usr/bin:/bin"
  if command -v zsh >/dev/null; then
    export DV_HOST_SHELL
    DV_HOST_SHELL=$(command -v zsh)
    path=$(host_shell_path ssh)
    test "$path" = "$HOME/system:/usr/bin:/bin"
    path=$(host_shell_path login)
    test "$path" = "$HOME/system:/usr/bin:/bin"
  fi
}
