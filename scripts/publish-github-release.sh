#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${AURAL_GITHUB_REPO:-maoliping455/aural}"
TAG="${AURAL_RELEASE_TAG:-v0.1.0}"
TITLE="${AURAL_RELEASE_TITLE:-Aural 0.1.0}"
CONFIGURATION="${AURAL_CONFIGURATION:-release}"
RELEASE_DIR="${AURAL_RELEASE_DIR:-$ROOT_DIR/.build/$CONFIGURATION}"
RELEASE_DIR="$(cd "$RELEASE_DIR" && pwd -P)"

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI not found. Install it first: brew install gh" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not authenticated. Run: gh auth login --hostname github.com --git-protocol ssh --web --scopes repo" >&2
  exit 1
fi

parts=()
while IFS= read -r part; do
  parts+=("$part")
done < <(find "$RELEASE_DIR" -maxdepth 1 -type f -name 'Aural-0.1.0-*.dmg.part-*' | sort)
if [[ "${#parts[@]}" -eq 0 ]]; then
  echo "No split release assets found in $RELEASE_DIR" >&2
  echo "Run scripts/package-release-split.sh .build/release/Aural-0.1.0-<timestamp>.dmg first." >&2
  exit 1
fi

assets=("${parts[@]}")
assets+=("$RELEASE_DIR/SHA256SUMS.txt")
assets+=("$ROOT_DIR/THIRD_PARTY_NOTICES.md")
assets+=("$ROOT_DIR/RELEASE_NOTES.md")

for asset in "${assets[@]}"; do
  if [[ ! -f "$asset" ]]; then
    echo "Release asset missing: $asset" >&2
    exit 1
  fi
done

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "${assets[@]}" --repo "$REPO" --clobber
else
  gh release create "$TAG" "${assets[@]}" \
    --repo "$REPO" \
    --target main \
    --title "$TITLE" \
    --notes-file "$ROOT_DIR/RELEASE_NOTES.md"
fi

gh release view "$TAG" --repo "$REPO"
