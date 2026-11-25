#!/bin/bash
# Build CIBar for other people: a universal build, signed with Developer ID and the hardened runtime,
# in a .dmg that is notarised by Apple and stapled.
#
#   scripts/release.sh             # -> dist/CIBar-<version>.dmg and dist/CIBar.dmg
#   scripts/release.sh --publish   # the same, then GitHub release v<version> with CIBar.dmg
#                                  # (notes from docs/release-notes/v<version>.md)
#   NOTARY_ID=<id> scripts/release.sh [--publish]
#                                  # resume after notarisation gave up: reuse the built dmg and wait for
#                                  # that submission (xcrun notarytool history lists the ids)
#
# Needs: a "Developer ID Application" certificate in the keychain, and notarytool credentials stored
# under a keychain profile (xcrun notarytool store-credentials <name> ...), named in NOTARY_PROFILE or
# in a local, untracked .release.env (NOTARY_PROFILE=<name>). The version is in ./VERSION.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ -f "$ROOT/.release.env" ]] && source "$ROOT/.release.env"
MODE="${1:-}"
PROFILE="${NOTARY_PROFILE:-}"
[[ -n "$PROFILE" ]] || { echo "Set NOTARY_PROFILE (or put NOTARY_PROFILE=<name> in .release.env)." >&2; exit 1; }
REPO="${REPO:-cibar-dev/cibar}"
OUT="$ROOT/dist"
VERSION="$(tr -d '[:space:]' < VERSION)"
NAME="CIBar-$VERSION"

log() { printf '\n==> %s\n' "$*"; }
jsonget() { /usr/bin/python3 -I -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2],""))
except Exception: print("")' "$1" "$2"; }

# Sign by hash: the keychain can hold two copies of the same certificate, which codesign calls ambiguous.
HASH=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $2}')
[[ -n "$HASH" ]] || { echo "No Developer ID Application certificate in the keychain." >&2; exit 1; }

if [[ "$MODE" == "--publish" ]]; then
  [[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first: a release is built from what's committed." >&2; exit 1; }
  [[ -f "$ROOT/docs/release-notes/v$VERSION.md" ]] || { echo "Write docs/release-notes/v$VERSION.md first." >&2; exit 1; }
  gh release view "v$VERSION" --repo "$REPO" > /dev/null 2>&1 && { echo "v$VERSION is already released. Bump ./VERSION." >&2; exit 1; }
fi

if [[ -n "${NOTARY_ID:-}" ]]; then
  [[ -f "$OUT/$NAME.dmg" ]] || { echo "NOTARY_ID is set but $OUT/$NAME.dmg isn't there." >&2; exit 1; }
  ID="$NOTARY_ID"
  log "Resuming with $OUT/$NAME.dmg and submission $ID"
else
  log "Building CIBar $VERSION, universal, signed with Developer ID"
  ARCHS="arm64 x86_64" SIGN_IDENTITY="$HASH" TIMESTAMP=1 "$ROOT/scripts/build-app.sh" > "$OUT.release-build.log" 2>&1 \
    || { tail -20 "$OUT.release-build.log"; exit 1; }
  APP="$OUT/CIBar.app"
  lipo -info "$APP/Contents/MacOS/CIBar"
  codesign --verify --deep --strict --verbose=2 "$APP"

  log "Making the disk image"
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$OUT/$NAME.dmg"
  hdiutil create -volname "CIBar" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$NAME.dmg" > /dev/null
  rm -rf "$STAGE"
  codesign --force --timestamp --sign "$HASH" "$OUT/$NAME.dmg"

  log "Sending to Apple to be notarised (usually a few minutes)"
  # Upload, then poll: a single long --wait dies when the connection drops; polling survives that.
  ID=""
  for attempt in 1 2 3; do
    xcrun notarytool submit "$OUT/$NAME.dmg" --keychain-profile "$PROFILE" --output-format json > "$OUT/$NAME.notary.json" || true
    ID=$(jsonget "$OUT/$NAME.notary.json" id)
    [[ -n "$ID" ]] && break
    echo "Upload failed (try $attempt of 3); trying again in 30 seconds." >&2
    sleep 30
  done
  [[ -n "$ID" ]] || { echo "Notarisation: the upload didn't reach Apple." >&2; exit 1; }
fi

echo "Submission $ID; checking every 30 seconds for up to two hours."
STATUS=""
for _ in $(seq 1 240); do
  xcrun notarytool info "$ID" --keychain-profile "$PROFILE" --output-format json > "$OUT/$NAME.notary.json" 2>/dev/null || true
  STATUS=$(jsonget "$OUT/$NAME.notary.json" status)
  [[ "$STATUS" == "Accepted" || "$STATUS" == "Invalid" || "$STATUS" == "Rejected" ]] && break
  sleep 30
done
if [[ "$STATUS" != "Accepted" ]]; then
  echo "Notarisation: ${STATUS:-no answer} (submission $ID). Apple's log:" >&2
  xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
  exit 1
fi

log "Stapling the ticket"
xcrun stapler staple "$OUT/$NAME.dmg"
xcrun stapler validate "$OUT/$NAME.dmg"

log "Checking Gatekeeper accepts it"
spctl --assess --type open --context context:primary-signature --verbose=2 "$OUT/$NAME.dmg"
MOUNT=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$OUT/$NAME.dmg" > /dev/null
spctl --assess --type execute --verbose=2 "$MOUNT/CIBar.app"
hdiutil detach "$MOUNT" > /dev/null

# The same file under the stable name the site links to (releases/latest/download/CIBar.dmg).
cp "$OUT/$NAME.dmg" "$OUT/CIBar.dmg"

if [[ "$MODE" == "--publish" ]]; then
  log "Publishing v$VERSION on GitHub"
  gh release create "v$VERSION" "$OUT/CIBar.dmg" --repo "$REPO" --title "CIBar $VERSION" \
    --notes-file "$ROOT/docs/release-notes/v$VERSION.md" --target main
fi

log "Done: $OUT/$NAME.dmg"
