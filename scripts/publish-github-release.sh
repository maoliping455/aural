#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${AURAL_GITHUB_REPO:-maoliping455/aural}"
TAG="${AURAL_RELEASE_TAG:-}"
TITLE="${AURAL_RELEASE_TITLE:-Aural 0.1.0}"
CONFIGURATION="${AURAL_CONFIGURATION:-release}"
RELEASE_DIR="${AURAL_RELEASE_DIR:-$ROOT_DIR/.build/$CONFIGURATION}"
RELEASE_DIR="$(cd "$RELEASE_DIR" && pwd -P)"

cd "$ROOT_DIR"

if [[ -z "$TAG" ]]; then
  echo "AURAL_RELEASE_TAG is required, for example: AURAL_RELEASE_TAG=v0.1.0" >&2
  exit 1
fi

tag_commit="$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" 2>/dev/null || true)"
head_commit="$(git rev-parse HEAD)"
if [[ -z "$tag_commit" ]]; then
  echo "release tag does not exist locally: $TAG" >&2
  exit 1
fi
if [[ "$tag_commit" != "$head_commit" ]]; then
  echo "release tag $TAG does not point at HEAD" >&2
  echo "tag:  $tag_commit" >&2
  echo "HEAD: $head_commit" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI not found. Install it first: brew install gh" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not authenticated. Run: gh auth login --hostname github.com --git-protocol ssh --web --scopes repo" >&2
  exit 1
fi

shopt -s nullglob
if [[ -n "${AURAL_DMG_PATH:-}" ]]; then
  dmg_path="$AURAL_DMG_PATH"
else
  dmg_candidates=("$RELEASE_DIR"/Aural-0.1.0-*.dmg)
  if [[ "${#dmg_candidates[@]}" -eq 0 ]]; then
    echo "No release DMG found in $RELEASE_DIR" >&2
    echo "Run scripts/package-local-dmg.sh first." >&2
    exit 1
  fi

  dmg_path="${dmg_candidates[0]}"
  for candidate in "${dmg_candidates[@]}"; do
    if [[ "$candidate" -nt "$dmg_path" ]]; then
      dmg_path="$candidate"
    fi
  done
fi

if [[ ! -f "$dmg_path" ]]; then
  echo "Release DMG not found: $dmg_path" >&2
  exit 1
fi

echo "Using release DMG: $dmg_path"

hdiutil verify "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl --assess --type open --verbose=4 "$dmg_path"

checksum_file="$RELEASE_DIR/SHA256SUMS.txt"
dmg_basename="$(basename "$dmg_path")"

if [[ "${AURAL_RELEASE_SPLIT:-0}" == "1" ]]; then
  parts=("$dmg_path".part-*)
  shopt -u nullglob
  if [[ "${#parts[@]}" -eq 0 ]]; then
    echo "No split release assets found for $dmg_path" >&2
    echo "Run scripts/package-release-split.sh $dmg_path first." >&2
    exit 1
  fi

  if [[ ! -f "$checksum_file" ]] || ! grep -Fq "$dmg_basename" "$checksum_file"; then
    echo "SHA256SUMS.txt does not include selected DMG: $dmg_basename" >&2
    exit 1
  fi

  assets=("${parts[@]}")
else
  shopt -u nullglob
  (
    cd "$(dirname "$dmg_path")"
    shasum -a 256 "$dmg_basename" > "$checksum_file"
  )
  assets=("$dmg_path")
fi

assets+=("$checksum_file")
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
