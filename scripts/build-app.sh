#!/bin/bash
# Builds BuildBar.app into ./dist (and, with --install, copies it to ~/Applications and launches it).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/BuildBar"
APP="dist/BuildBar.app"
VERSION="${VERSION:-1.0.0}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BuildBar"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BuildBar</string>
  <key>CFBundleDisplayName</key><string>BuildBar</string>
  <key>CFBundleIdentifier</key><string>local.buildbar.app</string>
  <key>CFBundleExecutable</key><string>BuildBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x BuildBar 2>/dev/null || true
  rm -rf "$HOME/Applications/BuildBar.app"
  cp -R "$APP" "$HOME/Applications/BuildBar.app"
  open "$HOME/Applications/BuildBar.app"
  echo "Installed to ~/Applications/BuildBar.app"
fi
