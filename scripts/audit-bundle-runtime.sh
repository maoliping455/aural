#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${1:-$ROOT_DIR/.build/release/Aural.app}"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

if [[ ! -d "$APP_DIR" ]]; then
  echo "app bundle not found: $APP_DIR" >&2
  exit 1
fi

echo "bundle: $APP_DIR"
du -sh "$APP_DIR" "$RESOURCES_DIR/runtime" "$RESOURCES_DIR/asr-models/qwen3-asr-1.7b-4bit" 2>/dev/null || true

echo
echo "codesign:"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo
echo "python imports:"
"$RESOURCES_DIR/runtime/bin/python3" - <<'PY'
import importlib.util
import sys

required = ["mlx_audio", "mlx", "numpy", "soundfile", "scipy", "modelscope", "huggingface_hub"]
optional = ["silero_vad", "torch"]
missing_required = []

for name in required + optional:
    spec = importlib.util.find_spec(name)
    print(f"{name}: {'ok' if spec else 'missing'}")
    if name in required and not spec:
        missing_required.append(name)

if missing_required:
    raise SystemExit(f"missing required runtime imports: {', '.join(missing_required)}")
PY

echo
echo "runtime compatibility:"
bash "$ROOT_DIR/scripts/audit-runtime-compatibility.sh" "$APP_DIR"

echo
echo "external dynamic library references:"
found_external=0
while IFS= read -r binary; do
  refs="$(otool -L "$binary" 2>/dev/null | awk 'NR > 1 {print $1}' | grep -E '^/(Users|opt/homebrew)' || true)"
  if [[ -n "$refs" ]]; then
    found_external=1
    echo "$binary"
    echo "$refs" | sed 's/^/  /'
  fi
done < <(find "$RESOURCES_DIR/runtime/bin" "$RESOURCES_DIR/runtime/lib" -type f \( -perm -111 -o -name '*.dylib' \) 2>/dev/null | sort)

if [[ "$found_external" -eq 0 ]]; then
  echo "none"
else
  echo
  echo "warning: external references remain; this bundle is not fully redistributable yet." >&2
fi
