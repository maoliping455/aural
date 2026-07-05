#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${AURAL_CONFIGURATION:-release}"
PACKAGE_DIR="${AURAL_PACKAGE_DIR:-$ROOT_DIR/.build/$CONFIGURATION}"
KEEP_COUNT="${AURAL_PACKAGE_KEEP_COUNT:-3}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      PACKAGE_DIR="$2"
      shift 2
      ;;
    --keep)
      KEEP_COUNT="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ ! "$KEEP_COUNT" =~ ^[0-9]+$ || "$KEEP_COUNT" -lt 1 ]]; then
  echo "keep count must be a positive integer: $KEEP_COUNT" >&2
  exit 2
fi

if [[ ! -d "$PACKAGE_DIR" ]]; then
  exit 0
fi

PACKAGE_DIR="$(cd "$PACKAGE_DIR" && pwd -P)"

packages=()
while IFS= read -r package; do
  [[ -n "$package" ]] || continue
  packages+=("$package")
done < <(
  while IFS= read -r -d '' package; do
    printf '%s\t%s\n' "$(stat -f '%m' "$package")" "$package"
  done < <(
    find "$PACKAGE_DIR" -maxdepth 1 -type f \
      \( -name 'Aural-*.dmg' -o -name 'Aural-*.pkg' -o -name 'Aural-*.zip' \) \
      -print0
  ) | sort -rn | cut -f2-
)

if [[ "${#packages[@]}" -le "$KEEP_COUNT" ]]; then
  echo "release packages: kept ${#packages[@]} file(s), nothing to prune"
  exit 0
fi

for ((index = KEEP_COUNT; index < ${#packages[@]}; index++)); do
  rm -f -- "${packages[$index]}"
  echo "removed old release package: ${packages[$index]}"
done

echo "release packages: kept latest $KEEP_COUNT file(s)"
