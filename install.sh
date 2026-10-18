#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mac=0; watch=0
for arg in "$@"; do
  case "$arg" in --host) mac=0 ;; --mac) mac=1 ;; --watch) watch=1 ;; *) echo "Unknown option: $arg" >&2; exit 1 ;; esac
done
linux_watch=0
if [ "$watch" = 1 ] && [ "$mac" = 0 ]; then linux_watch=1; watch=0; fi
mkdir -p "$HOME/.local/bin" "$HOME/.config/devflow"
link() {
  local source=$1 target=$2
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then return; fi
  if [ -e "$target" ] || [ -L "$target" ]; then printf 'Refusing to replace existing path: %s\n' "$target" >&2; exit 1; fi
  ln -s "$source" "$target"
}
for file in "$ROOT"/bin/*; do link "$file" "$HOME/.local/bin/$(basename "$file")"; done
if [ ! -e "$HOME/.config/devflow/config.sh" ]; then cp "$ROOT/config.example.sh" "$HOME/.config/devflow/config.sh"; fi
if [ "$mac" = 1 ] || [ "$linux_watch" = 1 ]; then
  skill_parent="$HOME/.hermes/profiles/sion/skills/software-development"
  mkdir -p "$skill_parent"
  link "$ROOT/skills/devflow" "$skill_parent/devflow"
fi
missing=0
for tool in git gh tmux jq; do
  if ! command -v "$tool" >/dev/null; then printf 'Missing: %s — install with your package manager.\n' "$tool"; missing=$((missing + 1)); fi
done
if { [ "$mac" = 1 ] || [ "$linux_watch" = 1 ]; } && ! command -v hermes >/dev/null; then echo 'Missing: hermes — install Hermes and configure the sion profile.'; missing=$((missing + 1)); fi
if [ "$watch" = 1 ]; then
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.local/state/devflow-mac"
  plist="$HOME/Library/LaunchAgents/dev.devflow.watch.plist"
  # A returning operator may have edited paths or schedule by hand: keep their file.
  if [ -e "$plist" ]; then
    printf 'Kept existing LaunchAgent: %s (remove it to regenerate)\n' "$plist"
    # A watcher that dies silently leaves the queue unread until someone notices. Say so instead of failing quietly.
    if ! grep -q '<key>KeepAlive</key>' "$plist"; then
      printf 'WARNING: %s has no KeepAlive; a crashed dv-watch stays down. Remove the file and re-run to regenerate.\n' "$plist"
    fi
  else
    # XML escaping also supports home/checkout paths containing spaces and ampersands.
    xml() { printf '%s' "$1" | sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>dev.devflow.watch</string>
<key>ProgramArguments</key><array><string>$(xml "$HOME/.local/bin/dv-watch")</string></array>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>$(xml "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")</string></dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>10</integer>
<key>StandardOutPath</key><string>$(xml "$HOME/.local/state/devflow-mac/watch.stdout.log")</string>
<key>StandardErrorPath</key><string>$(xml "$HOME/.local/state/devflow-mac/watch.stderr.log")</string>
</dict></plist>
PLIST
  fi
  # Printed for the operator to execute, not evaluated during installation.
  # shellcheck disable=SC2016
  printf 'Register manually: launchctl bootstrap gui/$(id -u) %q\n' "$plist"
fi
if [ "$linux_watch" = 1 ]; then
  # The watcher host runs Hermes: a systemd user unit, restarted on crash, stopped for good by $DV_HOME/stop.
  unit_dir="$HOME/.config/systemd/user" state="$HOME/.local/state/devflow-mac"
  mkdir -p "$unit_dir" "$state"
  unit="$unit_dir/dev.devflow.watch.service"
  if [ -e "$unit" ]; then
    printf 'Kept existing unit: %s (remove it to regenerate)\n' "$unit"
  else
    cat > "$unit" <<UNIT
[Unit]
Description=devflow dv-watch (finish events -> Hermes sion worker)
After=network-online.target

[Service]
Environment="PATH=$HOME/.local/bin:$HOME/node/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart="$HOME/.local/bin/dv-watch"
Restart=on-failure
RestartSec=10
StandardOutput=append:$state/watch.stdout.log
StandardError=append:$state/watch.stderr.log

[Install]
WantedBy=default.target
UNIT
  fi
  # Printed for the operator, not run during installation.
  printf 'Register manually: systemctl --user daemon-reload && systemctl --user enable --now dev.devflow.watch.service\n'
  if command -v loginctl >/dev/null && [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != yes ]; then
    printf 'WARNING: lingering is off; the watcher stops at logout. Run: loginctl enable-linger %s\n' "$(id -un)"
  fi
  printf 'Set DV_KICK_HOST to this host (%s) in ~/.config/devflow/config.sh on every dv host.\n' "$(hostname -s)"
fi
printf 'Installed links. Add ~/.local/bin to PATH; edit ~/.config/devflow/config.sh. Missing dependencies: %s\n' "$missing"
