#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mac=0; watch=0
for arg in "$@"; do
  case "$arg" in --host) mac=0 ;; --mac) mac=1 ;; --watch) watch=1 ;; *) echo "Unknown option: $arg" >&2; exit 1 ;; esac
done
[ "$watch" = 0 ] || [ "$mac" = 1 ] || { echo '--watch requires --mac' >&2; exit 1; }
mkdir -p "$HOME/.local/bin" "$HOME/.config/devflow"
link() {
  local source=$1 target=$2
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then return; fi
  if [ -e "$target" ] || [ -L "$target" ]; then printf 'Refusing to replace existing path: %s\n' "$target" >&2; exit 1; fi
  ln -s "$source" "$target"
}
for file in "$ROOT"/bin/*; do link "$file" "$HOME/.local/bin/$(basename "$file")"; done
if [ ! -e "$HOME/.config/devflow/config.sh" ]; then cp "$ROOT/config.example.sh" "$HOME/.config/devflow/config.sh"; fi
if [ "$mac" = 1 ]; then
  skill_parent="$HOME/.hermes/profiles/sion/skills/software-development"
  mkdir -p "$skill_parent"
  link "$ROOT/skills/devflow" "$skill_parent/devflow"
fi
missing=0
for tool in git gh tmux jq; do
  if ! command -v "$tool" >/dev/null; then printf 'Missing: %s — install with your package manager.\n' "$tool"; missing=$((missing + 1)); fi
done
if [ "$mac" = 1 ] && ! command -v hermes >/dev/null; then echo 'Missing: hermes — install Hermes and configure the sion profile.'; missing=$((missing + 1)); fi
if [ "$watch" = 1 ]; then
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.local/state/devflow-mac"
  plist="$HOME/Library/LaunchAgents/dev.devflow.watch.plist"
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
<key>StandardOutPath</key><string>$(xml "$HOME/.local/state/devflow-mac/watch.stdout.log")</string>
<key>StandardErrorPath</key><string>$(xml "$HOME/.local/state/devflow-mac/watch.stderr.log")</string>
</dict></plist>
PLIST
  # Printed for the operator to execute, not evaluated during installation.
  # shellcheck disable=SC2016
  printf 'Register manually: launchctl bootstrap gui/$(id -u) %q\n' "$plist"
fi
printf 'Installed links. Add ~/.local/bin to PATH; edit ~/.config/devflow/config.sh. Missing dependencies: %s\n' "$missing"
