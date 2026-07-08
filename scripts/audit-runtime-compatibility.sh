#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${1:-$ROOT_DIR/.build/release/Aural.app}"
MIN_MACOS="${AURAL_RUNTIME_MIN_MACOS:-14.0}"
RUNTIME_DIR="$APP_DIR/Contents/Resources/runtime"

if [[ ! -d "$RUNTIME_DIR" ]]; then
  echo "runtime not found: $RUNTIME_DIR" >&2
  exit 1
fi

version_gt() {
  /usr/bin/env python3 - "$1" "$2" <<'PY'
import sys

def parse(value):
    parts = [int(p) for p in value.split(".") if p != ""]
    return tuple((parts + [0, 0, 0])[:3])

raise SystemExit(0 if parse(sys.argv[1]) > parse(sys.argv[2]) else 1)
PY
}

failures=0

check_version() {
  local version="$1"
  local source="$2"
  local kind="$3"
  if version_gt "$version" "$MIN_MACOS"; then
    failures=$((failures + 1))
    echo "incompatible $kind target macOS $version > $MIN_MACOS: $source" >&2
  fi
}

echo "runtime compatibility target: macOS $MIN_MACOS+"

while IFS= read -r wheel_file; do
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    if [[ "$tag" =~ macosx_([0-9]+)_([0-9]+)_ ]]; then
      check_version "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}" "$wheel_file ($tag)" "wheel"
    fi
  done < <(awk '/^Tag: / {print $2}' "$wheel_file")
done < <(find "$RUNTIME_DIR/.venv/lib" -path '*/site-packages/*.dist-info/WHEEL' -type f 2>/dev/null | sort)

while IFS= read -r binary; do
  while IFS= read -r minos; do
    [[ -n "$minos" ]] || continue
    check_version "$minos" "$binary" "Mach-O"
  done < <(otool -l "$binary" 2>/dev/null | awk '/minos / {print $2}')
done < <(
  find "$RUNTIME_DIR" -type f 2>/dev/null | while IFS= read -r path; do
    if file "$path" 2>/dev/null | grep -q 'Mach-O'; then
      echo "$path"
    fi
  done | sort
)

while IFS= read -r metallib; do
  while IFS= read -r version; do
    [[ -n "$version" ]] || continue
    check_version "$version" "$metallib" "Metal library"
  done < <(strings "$metallib" 2>/dev/null | grep -Eo 'macosx[0-9]+\.[0-9]+' | sed 's/^macosx//' | sort -u)
done < <(find "$RUNTIME_DIR" -name '*.metallib' -type f 2>/dev/null | sort)

if [[ "$failures" -gt 0 ]]; then
  echo
  echo "runtime compatibility audit failed with $failures issue(s)." >&2
  echo "Rebuild the Python runtime with wheels targeting macOS $MIN_MACOS or lower." >&2
  exit 1
fi

echo "runtime compatibility audit passed"
