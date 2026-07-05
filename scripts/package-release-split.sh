#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${AURAL_CONFIGURATION:-release}"
RELEASE_DIR="${AURAL_RELEASE_DIR:-$ROOT_DIR/.build/$CONFIGURATION}"
PART_SIZE="${AURAL_RELEASE_PART_SIZE:-1900m}"
DMG_PATH="${1:-}"

if [[ -z "$DMG_PATH" ]]; then
  DMG_PATH="$("$ROOT_DIR/scripts/package-local-dmg.sh")"
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

mkdir -p "$RELEASE_DIR"
RELEASE_DIR="$(cd "$RELEASE_DIR" && pwd -P)"
DMG_PATH="$(cd "$(dirname "$DMG_PATH")" && pwd -P)/$(basename "$DMG_PATH")"
DMG_BASENAME="$(basename "$DMG_PATH")"
SPLIT_PREFIX="$RELEASE_DIR/$DMG_BASENAME.part-"

rm -f "$SPLIT_PREFIX"*
split -b "$PART_SIZE" "$DMG_PATH" "$SPLIT_PREFIX"

(
  cd "$RELEASE_DIR"
  shasum -a 256 "$DMG_BASENAME" "$DMG_BASENAME".part-* > SHA256SUMS.txt
)

echo "release dir: $RELEASE_DIR"
echo "dmg: $DMG_PATH"
echo "parts:"
find "$RELEASE_DIR" -maxdepth 1 -type f -name "$DMG_BASENAME.part-*" | sort
echo "checksums: $RELEASE_DIR/SHA256SUMS.txt"
echo
echo "merge and verify:"
echo "cat $DMG_BASENAME.part-* > $DMG_BASENAME && shasum -a 256 -c SHA256SUMS.txt"
