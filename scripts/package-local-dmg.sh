#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${AURAL_CONFIGURATION:-release}"
RELEASE_DIR="$ROOT_DIR/.build/$CONFIGURATION"
APP_DIR="$RELEASE_DIR/Aural.app"
KEEP_COUNT="${AURAL_PACKAGE_KEEP_COUNT:-3}"
CODE_SIGN_IDENTITY="${AURAL_CODESIGN_IDENTITY:-}"

if [[ ! -d "$APP_DIR" ]]; then
  echo "app bundle not found: $APP_DIR" >&2
  echo "run scripts/build-local-app.sh --include-runtime first" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo "0.1.0")"
STAMP="$(date +%Y%m%d-%H%M%S)"
DMG_PATH="${AURAL_DMG_OUTPUT:-$RELEASE_DIR/Aural-$VERSION-$STAMP.dmg}"
STAGING_DIR="$(mktemp -d "$RELEASE_DIR/aural-dmg-stage.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

ditto "$APP_DIR" "$STAGING_DIR/Aural.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create -volname Aural -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
if [[ -n "$CODE_SIGN_IDENTITY" ]]; then
  codesign --force --timestamp --sign "$CODE_SIGN_IDENTITY" "$DMG_PATH" >/dev/null
fi
hdiutil verify "$DMG_PATH"

"$ROOT_DIR/scripts/prune-release-packages.sh" --dir "$RELEASE_DIR" --keep "$KEEP_COUNT"

echo "$DMG_PATH"
