#!/usr/bin/env python3

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from itn_postprocess import apply_itn_to_transcript


def find_project_root():
    for parent in Path(__file__).resolve().parents:
        if (parent / "tools" / "qwen3_asr_transcribe.py").exists():
            return parent
    return Path(__file__).resolve().parents[2]


PROJECT_ROOT = find_project_root()
DEFAULT_RUNTIME_PYTHON = PROJECT_ROOT / ".venv-asr" / "bin" / "python"
DEFAULT_ASR_SCRIPT = PROJECT_ROOT / "tools" / "qwen3_asr_transcribe.py"
DEFAULT_MODEL = Path.home() / ".local" / "share" / "asr-models" / "qwen3-asr-1.7b-4bit"


def emit(event):
    print(json.dumps(event, ensure_ascii=False), flush=True)


def write_error(output_dir, message):
    output_dir.mkdir(parents=True, exist_ok=True)
    error_log_path = output_dir / "error.log"
    error_log_path.write_text(
        f"{datetime.now(timezone.utc).isoformat()} {message}\n",
        encoding="utf-8",
    )
    return error_log_path


def fail(request, output_dir, code, message):
    error_log_path = write_error(output_dir, message)
    emit(
        {
            "type": "failed",
            "request_id": request.get("request_id"),
            "task_id": request.get("task_id"),
            "error_code": code,
            "error_log_path": str(error_log_path),
        }
    )


def clean_asr_template_artifacts(text):
    clean = str(text or "").strip()
    clean = re.sub(
        r"(?is)^\s*(?:language\s*)?(?:Chinese|English|Japanese|Cantonese|Mandarin|zh|en|ja|yue)?\s*<asr_text>\s*",
        "",
        clean,
    )
    clean = re.sub(r"(?is)</asr_text>\s*", "", clean)
    clean = re.sub(r"(?s)<\|[^|>]+?\|>\s*", "", clean)
    return clean.strip()


def build_segments(record, duration_sec):
    raw_segments = record.get("segments") or []
    segments = []
    for item in raw_segments:
        text = clean_asr_template_artifacts(item.get("text") or "")
        if not text:
            continue
        start = item.get("start", item.get("start_sec", 0.0))
        end = item.get("end", item.get("end_sec", duration_sec or 0.0))
        segments.append(
            {
                "start_sec": float(start or 0.0),
                "end_sec": float(end or 0.0),
                "text": text,
            }
        )

    if segments:
        return segments

    text = clean_asr_template_artifacts(record.get("text") or "")
    if not text:
        return []
    return [
        {
            "start_sec": 0.0,
            "end_sec": float(duration_sec or 0.0),
            "text": text,
        }
    ]


def parse_json_record(stdout):
    records = []
    for line in stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        try:
            records.append(json.loads(stripped))
        except json.JSONDecodeError:
            continue
    return records[-1] if records else None


def run_asr(request, output_dir):
    runtime_python = Path(os.environ.get("AURAL_DEV_ASR_PYTHON", str(DEFAULT_RUNTIME_PYTHON))).expanduser()
    asr_script = Path(os.environ.get("AURAL_DEV_ASR_SCRIPT", str(DEFAULT_ASR_SCRIPT))).expanduser()
    model_path = Path(os.environ.get("AURAL_DEV_ASR_MODEL", str(DEFAULT_MODEL))).expanduser()
    audio_path = Path(request["audio_path"]).expanduser()
    raw_output_dir = output_dir / "raw-asr"
    raw_output_dir.mkdir(parents=True, exist_ok=True)

    if not audio_path.exists():
        raise RuntimeError(f"audio file not found: {audio_path}")
    if not runtime_python.exists():
        raise RuntimeError(f"runtime python not found: {runtime_python}")
    if not asr_script.exists():
        raise RuntimeError(f"asr script not found: {asr_script}")
    if not model_path.exists():
        raise RuntimeError(f"model path not found: {model_path}")

    pipeline = request.get("pipeline") or "vad_chunked"
    if pipeline == "auto":
        pipeline = "vad_chunked"

    command = [
        str(runtime_python),
        str(asr_script),
        str(audio_path),
        "--model",
        str(model_path),
        "--language",
        request.get("language") or "auto",
        "--out-dir",
        str(raw_output_dir),
        "--pipeline",
        pipeline,
        "--target-sec",
        "120",
        "--max-sec",
        "180",
        "--min-sec",
        "20",
        "--overlap-sec",
        "0",
        "--max-tokens-per-chunk",
        "4096",
        "--json",
    ]

    emit(
        {
            "type": "progress",
            "request_id": request["request_id"],
            "task_id": request["task_id"],
            "stage": "transcribing",
            "completed_segments": 0,
            "total_segments": 1,
        }
    )
    proc = subprocess.run(command, text=True, capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "asr runtime failed")

    record = parse_json_record(proc.stdout)
    if not record:
        raise RuntimeError("asr runtime produced no JSON record")
    if record.get("error"):
        raise RuntimeError(str(record["error"]))
    return record


def transcribe(request):
    output_dir = Path(request["output_dir"]).expanduser()
    output_dir.mkdir(parents=True, exist_ok=True)

    try:
        record = run_asr(request, output_dir)
        duration_sec = (
            record.get("duration_sec")
            or (record.get("segmentation") or {}).get("duration_sec")
            or record.get("audio_duration_sec")
            or 0.0
        )
        segments = build_segments(record, duration_sec)
        if not segments:
            raise RuntimeError("asr runtime produced empty transcript")

        transcript = {
            "task_id": request["task_id"],
            "audio_duration_sec": float(duration_sec or 0.0),
            "created_at": datetime.now(timezone.utc).isoformat(),
            "segments": segments,
            "text": "\n".join(segment["text"] for segment in segments).strip(),
        }
        transcript = apply_itn_to_transcript(transcript, record.get("language") or request.get("language") or "auto")
        transcript_path = output_dir / "transcript.json"
        transcript_path.write_text(
            json.dumps(transcript, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

        emit(
            {
                "type": "completed",
                "request_id": request["request_id"],
                "task_id": request["task_id"],
                "transcript_path": str(transcript_path),
                "duration_sec": transcript["audio_duration_sec"],
            }
        )
    except Exception as exc:
        fail(request, output_dir, "asr_runtime_error", repr(exc))


def main():
    for line in sys.stdin:
        if not line.strip():
            continue
        request = json.loads(line)
        if request.get("type") != "transcribe":
            fail(request, Path(request.get("output_dir", ".")), "unsupported_request", "unsupported request")
            continue
        transcribe(request)


if __name__ == "__main__":
    main()
