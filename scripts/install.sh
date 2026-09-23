#!/bin/bash
# One-shot setup: build app, allow `pmset disablesleep` without password,
# install agent integrations + login item, and start VibeWake.
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="${VIBEWAKE_DEST:-$HOME/Applications}"
APP="$DEST/VibeWake.app"

./scripts/build-app.sh

# sudoers rule: only these two exact commands are allowed without a password.
RULE="$(whoami) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
if ! sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1; then
  echo "→ Installing /etc/sudoers.d/vibewake (needed to stay awake with the lid closed)"
  TMP="$(mktemp)"
  echo "$RULE" > "$TMP"
  sudo /usr/sbin/visudo -cf "$TMP"
  sudo /usr/bin/install -m 0440 -o root -g wheel "$TMP" /etc/sudoers.d/vibewake
  rm -f "$TMP"
fi
echo "✓ Lid-closed support enabled"

"$APP/Contents/MacOS/VibeWake" install

launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.vibewake.app.plist" 2>/dev/null \
  || launchctl kickstart -k "gui/$(id -u)/com.vibewake.app"
echo "✓ VibeWake is running (look for the moon in your menu bar)"
