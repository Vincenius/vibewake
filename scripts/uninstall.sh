#!/bin/bash
# Remove VibeWake, its integrations, the sudoers rule, and restore normal sleep.
set -uo pipefail

DEST="${VIBEWAKE_DEST:-$HOME/Applications}"
APP="$DEST/VibeWake.app"

[ -x "$APP/Contents/MacOS/VibeWake" ] && "$APP/Contents/MacOS/VibeWake" uninstall
pkill -x VibeWake 2>/dev/null
sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null || sudo /usr/bin/pmset -a disablesleep 0
WAKE="$HOME/.vibewake/state/scheduled-wake"
[ -f "$WAKE" ] && sudo -n /usr/bin/pmset schedule cancel wake "$(cat "$WAKE")" 2>/dev/null || true
sudo rm -f /etc/sudoers.d/vibewake
rm -rf "$APP" "$HOME/.vibewake"
echo "✓ VibeWake removed"
