#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${AURAL_CONFIGURATION:-release}"
RELEASE_DIR="${AURAL_RELEASE_DIR:-$ROOT_DIR/.build/$CONFIGURATION}"
NOTARYTOOL_PROFILE="${AURAL_NOTARYTOOL_PROFILE:-AuralNotaryProfile}"

if [[ $# -gt 1 ]]; then
  echo "usage: scripts/notarize-release-dmg.sh [path/to/Aural.dmg]" >&2
  exit 2
fi

if [[ $# -eq 1 ]]; then
  DMG_PATH="$1"
else
  shopt -s nullglob
  candidates=("$RELEASE_DIR"/Aural-0.1.0-*.dmg)
  shopt -u nullglob
  if [[ "${#candidates[@]}" -eq 0 ]]; then
    echo "No release DMG found in $RELEASE_DIR" >&2
    echo "Run scripts/package-local-dmg.sh first." >&2
    exit 1
  fi
  DMG_PATH="${candidates[0]}"
  for candidate in "${candidates[@]}"; do
    if [[ "$candidate" -nt "$DMG_PATH" ]]; then
      DMG_PATH="$candidate"
    fi
  done
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "Release DMG not found: $DMG_PATH" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun not found. Install Xcode command line tools before notarizing." >&2
  exit 1
fi

echo "Using release DMG: $DMG_PATH"
echo "Using notarytool profile: $NOTARYTOOL_PROFILE"

xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARYTOOL_PROFILE" \
  --wait

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --verbose=4 "$DMG_PATH"

echo "$DMG_PATH"
