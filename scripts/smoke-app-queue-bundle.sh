#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/release/Aural.app"
WORK_DIR="$ROOT_DIR/.build/app-queue-smoke"
PYTHON="$APP_DIR/Contents/Resources/runtime/bin/python3"
SEGMENTED_WORKER="$APP_DIR/Contents/Resources/AuralASRWorker/worker_qwen_segmented_bundle.py"
VAD_WORKER="$APP_DIR/Contents/Resources/AuralASRWorker/worker_qwen_bundle.py"
DIRECT_WORKER="$APP_DIR/Contents/Resources/AuralASRWorker/worker_qwen_direct_bundle.py"
FFMPEG="$APP_DIR/Contents/Resources/runtime/bin/ffmpeg"
ALIGNER_MODEL="$APP_DIR/Contents/Resources/aligner-models/qwen3-forcedaligner-0.6b-4bit-mlx"
MODEL_ROOT="${AURAL_MODEL_ROOT:-$HOME/Library/Application Support/Aural/Models}"
MODEL_PROFILE="${AURAL_MODEL_PROFILE:-balanced}"
CACHED_ALIGNER_MODEL="$MODEL_ROOT/qwen3-forcedaligner-0.6b-4bit-mlx"
export AURAL_MODEL_ROOT="$MODEL_ROOT"
export AURAL_MODEL_PROFILE="$MODEL_PROFILE"

if [[ -n "${AURAL_SMOKE_WORKER:-}" ]]; then
  WORKER="$AURAL_SMOKE_WORKER"
  EXPECTED_TIMESTAMP_METHOD="${AURAL_EXPECTED_TIMESTAMP_METHOD:-}"
elif [[ "${AURAL_SMOKE_USE_VAD:-0}" == "1" && -x "$FFMPEG" && -f "$VAD_WORKER" ]]; then
  WORKER="$VAD_WORKER"
  EXPECTED_TIMESTAMP_METHOD="vad_chunked_segments"
elif [[ "${AURAL_SMOKE_USE_DIRECT:-0}" != "1" && -f "$SEGMENTED_WORKER" ]]; then
  WORKER="$SEGMENTED_WORKER"
  if [[ -d "$ALIGNER_MODEL" || -d "$CACHED_ALIGNER_MODEL" ]]; then
    EXPECTED_TIMESTAMP_METHOD="qwen3_forced_aligner_paragraph"
    export AURAL_ALIGNMENT_ENABLED=1
  else
    EXPECTED_TIMESTAMP_METHOD="vad_speech_weighted_paragraph"
    export AURAL_ALIGNMENT_ENABLED=0
  fi
else
  WORKER="$DIRECT_WORKER"
  EXPECTED_TIMESTAMP_METHOD="text_length_proportional"
  export AURAL_ALIGNMENT_ENABLED=0
fi

if [[ ! -x "$PYTHON" ]]; then
  echo "packaged python not found: $PYTHON" >&2
  exit 1
fi
if [[ ! -f "$WORKER" ]]; then
  echo "worker not found: $WORKER" >&2
  exit 1
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
echo "worker=$WORKER"

say -v Tingting -o "$WORK_DIR/input.aiff" \
  '今天测试 Aural 本地队列。拖入音频后复制到本地，然后调用包内模型转写。'
afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK_DIR/input.aiff" "$WORK_DIR/input.wav"

swift run aural-e2e \
  --data-root "$WORK_DIR/data" \
  --worker "$WORKER" \
  --python "$PYTHON" \
  --expect done \
  "$WORK_DIR/input.wav" \
  | tee "$WORK_DIR/e2e.log"

grep -q 'status=转写完成' "$WORK_DIR/e2e.log"
grep -q '^segments=' "$WORK_DIR/e2e.log"
TRANSCRIPT_PATH="$(awk -F= '/^transcript=/{print substr($0, index($0, "=") + 1)}' "$WORK_DIR/e2e.log" | tail -1)"
if [[ -n "$EXPECTED_TIMESTAMP_METHOD" ]]; then
  python3 - "$TRANSCRIPT_PATH" "$EXPECTED_TIMESTAMP_METHOD" <<'PY'
import json
import sys

path = sys.argv[1]
expected = sys.argv[2]
with open(path, encoding="utf-8") as handle:
    transcript = json.load(handle)
metadata = transcript.get("metadata") or {}
actual = metadata.get("timestamp_method")
if actual != expected:
    raise SystemExit(f"unexpected timestamp_method: {actual!r}, expected {expected!r}")
if expected == "vad_chunked_segments" and "vad" not in str(metadata.get("pipeline", "")):
    raise SystemExit(f"unexpected VAD pipeline metadata: {metadata!r}")
print(f"timestamp_method={actual}")
PY
fi

printf 'this is not a wav file\n' > "$WORK_DIR/bad.wav"
swift run aural-e2e \
  --data-root "$WORK_DIR/failure-data" \
  --worker "$WORKER" \
  --python "$PYTHON" \
  --expect failed \
  "$WORK_DIR/bad.wav" \
  | tee "$WORK_DIR/e2e-failure.log"

grep -q 'status=转写失败' "$WORK_DIR/e2e-failure.log"
grep -q '^error_log=' "$WORK_DIR/e2e-failure.log"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
