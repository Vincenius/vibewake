#!/bin/bash
# Build VibeWake.app and install it to ~/Applications.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="VibeWake"
DEST="${VIBEWAKE_DEST:-$HOME/Applications}"
BUNDLE="build/$APP_NAME.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp integrations/pi/vibewake.ts "$BUNDLE/Contents/Resources/pi-extension.ts"

cat > "$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>com.vibewake.app</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$BUNDLE"

# Replace the installed copy (stop a running instance first).
launchctl bootout "gui/$(id -u)/com.vibewake.app" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true
mkdir -p "$DEST"
rm -rf "$DEST/$APP_NAME.app"
cp -R "$BUNDLE" "$DEST/"
echo "✓ Built $DEST/$APP_NAME.app"
