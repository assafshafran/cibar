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

# App icon, drawn by the app itself so it always matches the menu bar glyph.
ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
"$BIN" --render-icon "$ICONSET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BuildBar</string>
  <key>CFBundleDisplayName</key><string>BuildBar</string>
  <key>CFBundleIdentifier</key><string>local.buildbar.app</string>
  <key>CFBundleExecutable</key><string>BuildBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Sign with a stable identity when one exists, so the Keychain "Always Allow" survives rebuilds.
# (Ad-hoc signatures change on every build and macOS then asks for the Keychain again.)
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk '{print $2}')}"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
else
  echo "No Apple Development identity found: signing ad-hoc (Keychain will ask again after each rebuild)"
  codesign --force --sign - "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x BuildBar 2>/dev/null || true
  rm -rf "$HOME/Applications/BuildBar.app"
  cp -R "$APP" "$HOME/Applications/BuildBar.app"
  open "$HOME/Applications/BuildBar.app"
  echo "Installed to ~/Applications/BuildBar.app"
fi
