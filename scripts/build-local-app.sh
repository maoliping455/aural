#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="release"
INCLUDE_RUNTIME=0
INCLUDE_MODEL=0
INCLUDE_HOMEBREW_FFMPEG=0
VENV_SOURCE="${AURAL_VENV_SOURCE:-}"
PYTHON_BASE_SOURCE="${AURAL_PYTHON_BASE_SOURCE:-}"
MODEL_SOURCE="${AURAL_MODEL_SOURCE:-}"
ALIGNER_MODEL_SOURCE="${AURAL_ALIGNER_MODEL_SOURCE:-}"
FFMPEG_SOURCE="${AURAL_FFMPEG_SOURCE:-}"
FFPROBE_SOURCE="${AURAL_FFPROBE_SOURCE:-}"
ITN_FST_SOURCE="${AURAL_ITN_FST_SOURCE:-}"
CODE_SIGN_IDENTITY="${AURAL_CODESIGN_IDENTITY:-}"
CODE_SIGN_ENTITLEMENTS="${AURAL_CODESIGN_ENTITLEMENTS:-}"
CODE_SIGN_REQUIRE_DEVELOPER_ID="${AURAL_CODESIGN_REQUIRE_DEVELOPER_ID:-0}"
APP_DIR="$ROOT_DIR/.build/$CONFIGURATION/Aural.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

dependency_prefixes() {
  if command -v brew >/dev/null 2>&1; then
    brew --prefix 2>/dev/null || true
  fi
  echo "/usr/local"
}

homebrew_refs_for() {
  local binary="$1"
  local refs
  refs="$(otool -L "$binary" 2>/dev/null | awk 'NR > 1 {print $1}')"

  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    while IFS= read -r prefix; do
      [[ -n "$prefix" ]] || continue
      case "$ref" in
        "$prefix"/*)
          echo "$ref"
          break
          ;;
      esac
    done < <(dependency_prefixes)
  done <<< "$refs"
}

copy_homebrew_binary_with_deps() {
  local source_binary="$1"
  local target_binary="$2"
  local bin_dir="$3"
  local lib_dir="$4"

  mkdir -p "$bin_dir" "$lib_dir"
  cp "$(realpath "$source_binary")" "$target_binary"
  chmod +w "$target_binary"
  chmod +x "$target_binary"

  local processed_file_list="$lib_dir/.processed-files"
  : > "$processed_file_list"

  while true; do
    local changed=0
    while IFS= read -r current_file; do
      [[ -f "$current_file" ]] || continue
      if grep -Fxq "$current_file" "$processed_file_list"; then
        continue
      fi
      echo "$current_file" >> "$processed_file_list"

      local relative_prefix="@loader_path"
      case "$current_file" in
        "$bin_dir"/*)
          relative_prefix="@loader_path/../lib"
          ;;
        "$lib_dir"/*.dylib)
          install_name_tool -id "@loader_path/$(basename "$current_file")" "$current_file" 2>/dev/null || true
          ;;
      esac

      while IFS= read -r ref; do
        [[ -n "$ref" ]] || continue
        local lib_name
        lib_name="$(basename "$ref")"
        local lib_dest="$lib_dir/$lib_name"
        if [[ ! -f "$lib_dest" ]]; then
          cp "$(realpath "$ref")" "$lib_dest"
          chmod +w "$lib_dest"
          changed=1
        fi
        install_name_tool -change "$ref" "$relative_prefix/$lib_name" "$current_file" 2>/dev/null || true
      done < <(homebrew_refs_for "$current_file")
    done < <(find "$bin_dir" "$lib_dir" -type f \( -perm -111 -o -name '*.dylib' \) | sort)

    if [[ "$changed" -eq 0 ]]; then
      break
    fi
  done

  rm -f "$processed_file_list"
}

is_macho_file() {
  local path="$1"
  file "$path" 2>/dev/null | grep -q 'Mach-O'
}

sign_nested_macho_payload() {
  local root_dir="$1"
  local identity="$2"

  while IFS= read -r binary; do
    [[ -f "$binary" ]] || continue
    if ! is_macho_file "$binary"; then
      continue
    fi
    chmod +w "$binary" 2>/dev/null || true
    codesign --force --options runtime --timestamp --sign "$identity" "$binary" >/dev/null
  done < <(
    find "$root_dir" -type f \( -perm -111 -o -name '*.dylib' -o -name '*.so' \) | sort
  )
}

normalize_python_runtime_install_names() {
  local runtime_dir="$1"
  local libpython="$runtime_dir/cpython/lib/libpython3.12.dylib"

  if [[ -f "$libpython" ]]; then
    chmod +w "$libpython" 2>/dev/null || true
    install_name_tool -id "@rpath/libpython3.12.dylib" "$libpython"
  fi
}

prune_runtime_payload() {
  local runtime_dir="$1"
  [[ -d "$runtime_dir/.venv/lib" ]] || return 0

  while IFS= read -r site_packages_dir; do
    local patterns=(
      'rapidocr*'
      'onnxruntime*'
      'opencv_python*'
      'cv2'
      'pyclipper*'
      'shapely*'
      'Shapely*'
      'torch'
      'torch-*dist-info'
      'torchgen'
      'functorch'
      'torchaudio'
      'torchaudio-*dist-info'
      'torchcodec'
      'torchcodec-*dist-info'
      'torch_complex'
      'torch_complex-*dist-info'
      'pyarrow'
      'pyarrow-*dist-info'
      'pandas'
      'pandas-*dist-info'
      'sklearn'
      'scikit_learn-*dist-info'
      'scipy'
      'scipy-*dist-info'
      'llvmlite'
      'llvmlite-*dist-info'
      'numba'
      'numba-*dist-info'
      'sherpa_onnx'
      'sherpa_onnx-*dist-info'
      'sherpa_onnx_core-*dist-info'
      'datasets'
      'datasets-*dist-info'
      'funasr'
      'funasr-*dist-info'
      'yt_dlp'
      'yt_dlp-*dist-info'
      'librosa'
      'librosa-*dist-info'
    )

    local pattern
    for pattern in "${patterns[@]}"; do
      while IFS= read -r item; do
        rm -rf "$item"
      done < <(find "$site_packages_dir" -maxdepth 1 -name "$pattern" -print)
    done

    find "$site_packages_dir" -type d \( -name test -o -name tests \) -prune -exec rm -rf {} +
  done < <(find "$runtime_dir/.venv/lib" -type d -name site-packages)

  find "$runtime_dir" -name '__pycache__' -type d -prune -exec rm -rf {} +
  find "$runtime_dir" -name '*.pyc' -type f -delete
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-runtime)
      INCLUDE_RUNTIME=1
      shift
      ;;
    --include-model)
      INCLUDE_MODEL=1
      shift
      ;;
    --include-homebrew-ffmpeg)
      INCLUDE_HOMEBREW_FFMPEG=1
      shift
      ;;
    --venv-source)
      VENV_SOURCE="$2"
      shift 2
      ;;
    --python-base-source)
      PYTHON_BASE_SOURCE="$2"
      shift 2
      ;;
    --model-source)
      MODEL_SOURCE="$2"
      shift 2
      ;;
    --aligner-model-source)
      ALIGNER_MODEL_SOURCE="$2"
      shift 2
      ;;
    --itn-fst-source)
      ITN_FST_SOURCE="$2"
      shift 2
      ;;
    --codesign-identity)
      CODE_SIGN_IDENTITY="$2"
      shift 2
      ;;
    --codesign-entitlements)
      CODE_SIGN_ENTITLEMENTS="$2"
      shift 2
      ;;
    --require-developer-id)
      CODE_SIGN_REQUIRE_DEVELOPER_ID=1
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION" --product aural-ui-prototype

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR/AuralASRWorker" "$RESOURCES_DIR/runtime" "$RESOURCES_DIR/asr-models" "$RESOURCES_DIR/aligner-models"

cp "$ROOT_DIR/.build/$CONFIGURATION/aural-ui-prototype" "$MACOS_DIR/Aural"
chmod +x "$MACOS_DIR/Aural"

cp "$ROOT_DIR/AuralASRWorker/worker_stub.py" "$RESOURCES_DIR/AuralASRWorker/worker_stub.py"
cp "$ROOT_DIR/AuralASRWorker/worker_qwen_bundle.py" "$RESOURCES_DIR/AuralASRWorker/worker_qwen_bundle.py"
cp "$ROOT_DIR/AuralASRWorker/worker_qwen_segmented_bundle.py" "$RESOURCES_DIR/AuralASRWorker/worker_qwen_segmented_bundle.py"
cp "$ROOT_DIR/AuralASRWorker/worker_qwen_direct_bundle.py" "$RESOURCES_DIR/AuralASRWorker/worker_qwen_direct_bundle.py"
cp "$ROOT_DIR/AuralASRWorker/worker_qwen_dev.py" "$RESOURCES_DIR/AuralASRWorker/worker_qwen_dev.py"
cp "$ROOT_DIR/AuralASRWorker/itn_postprocess.py" "$RESOURCES_DIR/AuralASRWorker/itn_postprocess.py"
cp "$ROOT_DIR/AuralASRWorker/alignment_postprocess.py" "$RESOURCES_DIR/AuralASRWorker/alignment_postprocess.py"
cp "$ROOT_DIR/AuralASRWorker/model_resource_prepare.py" "$RESOURCES_DIR/AuralASRWorker/model_resource_prepare.py"
chmod +x "$RESOURCES_DIR/AuralASRWorker/"*.py

mkdir -p "$RESOURCES_DIR/itn"
rm -rf "$RESOURCES_DIR/itn/custom_wetext_fsts"
if [[ -n "$ITN_FST_SOURCE" && -d "$ITN_FST_SOURCE" ]]; then
  ditto "$ITN_FST_SOURCE" "$RESOURCES_DIR/itn/custom_wetext_fsts"
else
  mkdir -p "$RESOURCES_DIR/itn/custom_wetext_fsts"
  touch "$RESOURCES_DIR/itn/custom_wetext_fsts/.keep"
  echo "warning: AURAL_ITN_FST_SOURCE not set or missing; packaged ITN will fall back to raw text." >&2
fi

if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

touch "$RESOURCES_DIR/runtime/.keep"
touch "$RESOURCES_DIR/asr-models/.keep"
touch "$RESOURCES_DIR/aligner-models/.keep"

if [[ "$INCLUDE_RUNTIME" -eq 1 ]]; then
  if [[ -z "$VENV_SOURCE" ]]; then
    echo "AURAL_VENV_SOURCE or --venv-source is required with --include-runtime" >&2
    exit 1
  fi
  if [[ ! -x "$VENV_SOURCE/bin/python" ]]; then
    echo "venv python not found: $VENV_SOURCE/bin/python" >&2
    exit 1
  fi
  if [[ -z "$PYTHON_BASE_SOURCE" ]]; then
    PYTHON_BASE_SOURCE="$("$VENV_SOURCE/bin/python" - <<'PY'
import sys
print(sys.base_prefix)
PY
)"
  fi
  if [[ ! -x "$PYTHON_BASE_SOURCE/bin/python3.12" ]]; then
    echo "python base not found or unsupported: $PYTHON_BASE_SOURCE" >&2
    exit 1
  fi

  rm -rf "$RESOURCES_DIR/runtime/.venv" "$RESOURCES_DIR/runtime/cpython"
  ditto "$VENV_SOURCE" "$RESOURCES_DIR/runtime/.venv"
  ditto "$PYTHON_BASE_SOURCE" "$RESOURCES_DIR/runtime/cpython"
  prune_runtime_payload "$RESOURCES_DIR/runtime"
  normalize_python_runtime_install_names "$RESOURCES_DIR/runtime"

  mkdir -p "$RESOURCES_DIR/runtime/bin"
  rm -f "$RESOURCES_DIR/runtime/.venv/bin/python" \
        "$RESOURCES_DIR/runtime/.venv/bin/python3" \
        "$RESOURCES_DIR/runtime/.venv/bin/python3.12"
  ln -s ../../cpython/bin/python3.12 "$RESOURCES_DIR/runtime/.venv/bin/python"
  ln -s python "$RESOURCES_DIR/runtime/.venv/bin/python3"
  ln -s python "$RESOURCES_DIR/runtime/.venv/bin/python3.12"

  cat > "$RESOURCES_DIR/runtime/bin/python3" <<'PYWRAPPER'
#!/usr/bin/env bash
set -euo pipefail
RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONHOME="$RUNTIME_DIR/cpython"
export PYTHONPATH="$RUNTIME_DIR/.venv/lib/python3.12/site-packages${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1
exec "$RUNTIME_DIR/cpython/bin/python3.12" "$@"
PYWRAPPER
  chmod +x "$RESOURCES_DIR/runtime/bin/python3"
  ln -sf python3 "$RESOURCES_DIR/runtime/bin/python"

  bash "$ROOT_DIR/scripts/audit-runtime-compatibility.sh" "$APP_DIR"
fi

if [[ "$INCLUDE_HOMEBREW_FFMPEG" -eq 1 ]]; then
  mkdir -p "$RESOURCES_DIR/runtime/bin" "$RESOURCES_DIR/runtime/lib"
  if [[ -z "$FFMPEG_SOURCE" ]]; then
    FFMPEG_SOURCE="$(command -v ffmpeg || true)"
  fi
  if [[ -z "$FFPROBE_SOURCE" ]]; then
    FFPROBE_SOURCE="$(command -v ffprobe || true)"
  fi
  if [[ ! -x "$FFMPEG_SOURCE" || ! -x "$FFPROBE_SOURCE" ]]; then
    echo "ffmpeg/ffprobe not found; set AURAL_FFMPEG_SOURCE and AURAL_FFPROBE_SOURCE or install them for this optional path" >&2
    exit 1
  fi
  copy_homebrew_binary_with_deps \
    "$FFMPEG_SOURCE" \
    "$RESOURCES_DIR/runtime/bin/ffmpeg" \
    "$RESOURCES_DIR/runtime/bin" \
    "$RESOURCES_DIR/runtime/lib"
  copy_homebrew_binary_with_deps \
    "$FFPROBE_SOURCE" \
    "$RESOURCES_DIR/runtime/bin/ffprobe" \
    "$RESOURCES_DIR/runtime/bin" \
    "$RESOURCES_DIR/runtime/lib"
fi

if [[ "$INCLUDE_MODEL" -eq 1 ]]; then
  if [[ -z "$MODEL_SOURCE" ]]; then
    echo "AURAL_MODEL_SOURCE or --model-source is required with --include-model" >&2
    exit 1
  fi
  if [[ -z "$ALIGNER_MODEL_SOURCE" ]]; then
    echo "AURAL_ALIGNER_MODEL_SOURCE or --aligner-model-source is required with --include-model" >&2
    exit 1
  fi
  if [[ ! -d "$MODEL_SOURCE" ]]; then
    echo "model source not found: $MODEL_SOURCE" >&2
    exit 1
  fi
  if [[ ! -d "$ALIGNER_MODEL_SOURCE" ]]; then
    echo "aligner model source not found: $ALIGNER_MODEL_SOURCE" >&2
    exit 1
  fi
  MODEL_SOURCE="$(realpath "$MODEL_SOURCE")"
  ALIGNER_MODEL_SOURCE="$(realpath "$ALIGNER_MODEL_SOURCE")"
  rm -rf "$RESOURCES_DIR/asr-models/qwen3-asr-1.7b-4bit"
  ditto "$MODEL_SOURCE" "$RESOURCES_DIR/asr-models/qwen3-asr-1.7b-4bit"
  rm -rf "$RESOURCES_DIR/aligner-models/qwen3-forcedaligner-0.6b-4bit-mlx"
  ditto "$ALIGNER_MODEL_SOURCE" "$RESOURCES_DIR/aligner-models/qwen3-forcedaligner-0.6b-4bit-mlx"
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>Aural</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.maoliping455.aural</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Aural</string>
  <key>CFBundleDisplayName</key>
  <string>Aural</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST

find "$APP_DIR" -name '__pycache__' -type d -prune -exec rm -rf {} +
find "$APP_DIR" -name '*.pyc' -type f -delete

if command -v codesign >/dev/null 2>&1; then
  if [[ -n "$CODE_SIGN_IDENTITY" ]]; then
    sign_nested_macho_payload "$APP_DIR" "$CODE_SIGN_IDENTITY"
    codesign_args=(--force --deep --options runtime --timestamp --sign "$CODE_SIGN_IDENTITY")
    if [[ -n "$CODE_SIGN_ENTITLEMENTS" ]]; then
      if [[ ! -f "$CODE_SIGN_ENTITLEMENTS" ]]; then
        echo "codesign entitlements not found: $CODE_SIGN_ENTITLEMENTS" >&2
        exit 1
      fi
      codesign_args+=(--entitlements "$CODE_SIGN_ENTITLEMENTS")
    fi
    codesign "${codesign_args[@]}" "$APP_DIR" >/dev/null
  else
    if [[ "$CODE_SIGN_REQUIRE_DEVELOPER_ID" == "1" ]]; then
      echo "AURAL_CODESIGN_IDENTITY or --codesign-identity is required for a Developer ID release build" >&2
      exit 1
    fi
    codesign --force --deep --sign - "$APP_DIR" >/dev/null
  fi
fi

echo "$APP_DIR"
