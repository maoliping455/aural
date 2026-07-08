#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 /path/to/venv [macosx_14_0_arm64]" >&2
  exit 2
fi

VENV_DIR="$1"
TARGET_PLATFORM="${2:-macosx_14_0_arm64}"
PYTHON="$VENV_DIR/bin/python"

if [[ ! -x "$PYTHON" ]]; then
  echo "venv python not found: $PYTHON" >&2
  exit 1
fi

read -r PY_VERSION PY_ABI MLX_VERSION MLX_METAL_VERSION < <("$PYTHON" - <<'PY'
import importlib.metadata as md
import sys

python_version = f"{sys.version_info.major}{sys.version_info.minor}"
abi = f"cp{python_version}"
try:
    mlx_version = md.version("mlx")
except md.PackageNotFoundError:
    mlx_version = "0.31.2"
try:
    mlx_metal_version = md.version("mlx-metal")
except md.PackageNotFoundError:
    mlx_metal_version = mlx_version
print(python_version, abi, mlx_version, mlx_metal_version)
PY
)

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aural-mlx-wheels.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "target platform: $TARGET_PLATFORM"
echo "mlx: $MLX_VERSION"
echo "mlx-metal: $MLX_METAL_VERSION"

"$PYTHON" -m pip download \
  --dest "$TMP_DIR" \
  --only-binary=:all: \
  --implementation cp \
  --python-version "$PY_VERSION" \
  --abi "$PY_ABI" \
  --platform "$TARGET_PLATFORM" \
  --no-deps \
  "mlx==$MLX_VERSION" \
  "mlx-metal==$MLX_METAL_VERSION"

MLX_WHEEL="$(find "$TMP_DIR" -maxdepth 1 -name "mlx-${MLX_VERSION}-*.whl" | head -1)"
MLX_METAL_WHEEL="$(find "$TMP_DIR" -maxdepth 1 -name "mlx_metal-${MLX_METAL_VERSION}-*.whl" | head -1)"

if [[ -z "$MLX_WHEEL" || -z "$MLX_METAL_WHEEL" ]]; then
  echo "failed to download target MLX wheels" >&2
  find "$TMP_DIR" -maxdepth 1 -type f -print >&2
  exit 1
fi

"$PYTHON" -m pip install --force-reinstall --no-deps "$MLX_WHEEL" "$MLX_METAL_WHEEL"

"$PYTHON" - <<'PY'
import importlib.metadata as md
import pathlib

for package in ("mlx", "mlx-metal"):
    dist = md.distribution(package)
    wheel = pathlib.Path(dist._path) / "WHEEL"
    tags = [
        line.split(":", 1)[1].strip()
        for line in wheel.read_text().splitlines()
        if line.startswith("Tag:")
    ]
    print(f"{package} {dist.version}: {', '.join(tags)}")
PY
