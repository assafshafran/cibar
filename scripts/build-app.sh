#!/bin/bash
# Builds CIBar.app into ./dist (and, with --install, copies it to ~/Applications and launches it).
#   ARCHS="arm64 x86_64"  build a universal binary (scripts/release.sh does)
#   SIGN_IDENTITY=<hash>  sign with this identity (default: your Apple Development certificate, else ad hoc)
#   TIMESTAMP=1           add a secure timestamp to the signature (needed for notarisation)
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_FLAGS=""; for a in ${ARCHS:-arm64}; do ARCH_FLAGS="$ARCH_FLAGS --arch $a"; done
swift build -c release $ARCH_FLAGS
BIN="$(swift build -c release $ARCH_FLAGS --show-bin-path)/CIBar"
APP="dist/CIBar.app"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILDNO="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CIBar"

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
  <key>CFBundleName</key><string>CIBar</string>
  <key>CFBundleDisplayName</key><string>CIBar</string>
  <key>CFBundleIdentifier</key><string>dev.cibar.app</string>
  <key>CFBundleExecutable</key><string>CIBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILDNO}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Sign with a stable identity when one exists (falls back to ad-hoc).
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk '{print $2}')}"
if [[ -n "$IDENTITY" ]]; then
  TS=""; [[ "${TIMESTAMP:-}" == "1" ]] && TS="--timestamp"
  codesign --force $TS --options runtime --sign "$IDENTITY" "$APP"
else
  echo "No Apple Development identity found: signing ad-hoc"
  codesign --force --sign - "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x CIBar 2>/dev/null || true
  rm -rf "$HOME/Applications/CIBar.app"
  cp -R "$APP" "$HOME/Applications/CIBar.app"
  open "$HOME/Applications/CIBar.app"
  echo "Installed to ~/Applications/CIBar.app"
fi
