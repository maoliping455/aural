#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/release/Aural.app"
WORK_DIR="$ROOT_DIR/.build/direct-worker-smoke"
PYTHON="$APP_DIR/Contents/Resources/runtime/bin/python3"
WORKER="$APP_DIR/Contents/Resources/AuralASRWorker/worker_qwen_direct_bundle.py"
MODEL_ROOT="${AURAL_MODEL_ROOT:-$HOME/Library/Application Support/Aural/Models}"
MODEL_PROFILE="${AURAL_MODEL_PROFILE:-balanced}"

if [[ ! -x "$PYTHON" ]]; then
  echo "packaged python not found: $PYTHON" >&2
  exit 1
fi
if [[ ! -f "$WORKER" ]]; then
  echo "direct worker not found: $WORKER" >&2
  exit 1
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

say -v Tingting -o "$WORK_DIR/input.aiff" \
  '今天测试 Aural 本地转写。拖入音频后自动生成文字。界面保持简洁，结果保存在本机。'
afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK_DIR/input.aiff" "$WORK_DIR/input.wav"

REQUEST_ID="$(uuidgen)"
TASK_ID="$(uuidgen)"
printf '{"type":"transcribe","request_id":"%s","task_id":"%s","audio_path":"%s","output_dir":"%s","language":"auto","pipeline":"direct_single_pass","duration_sec":7.0}\n' \
  "$REQUEST_ID" \
  "$TASK_ID" \
  "$WORK_DIR/input.wav" \
  "$WORK_DIR/task" \
  | env -i PATH=/usr/bin:/bin HOME="$HOME" AURAL_MODEL_ROOT="$MODEL_ROOT" AURAL_MODEL_PROFILE="$MODEL_PROFILE" AURAL_ALIGNMENT_ENABLED=0 "$PYTHON" "$WORKER" \
  | tee "$WORK_DIR/events.jsonl"

"$PYTHON" - <<PY
import json
from pathlib import Path
root = Path("$WORK_DIR")
events = [json.loads(line) for line in (root / "events.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]
if events[-1]["type"] != "completed":
    raise SystemExit("direct worker did not complete")
transcript = json.loads((root / "task" / "transcript.json").read_text(encoding="utf-8"))
segments = transcript.get("segments") or []
if not segments:
    raise SystemExit("transcript has no segments")
if segments[0]["start_sec"] != 0:
    raise SystemExit("first segment must start at 0")
if transcript.get("metadata", {}).get("timestamp_method") != "text_length_proportional":
    raise SystemExit("unexpected timestamp method")
print("direct bundle worker smoke passed")
PY

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
