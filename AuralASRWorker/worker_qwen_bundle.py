#!/usr/bin/env python3

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from itn_postprocess import apply_itn_to_transcript


RESOURCES_ROOT = Path(__file__).resolve().parents[1]
RUNTIME_ROOT = RESOURCES_ROOT / "runtime"
ASR_MODEL_DIRECTORIES = {
    "fast": "qwen3-asr-0.6b-4bit",
    "balanced": "qwen3-asr-1.7b-4bit",
    "accurate": "qwen3-asr-1.7b-bf16",
}


def resolve_asr_model_root():
    override = os.environ.get("AURAL_ASR_MODEL")
    if override:
        return Path(override).expanduser()
    profile = os.environ.get("AURAL_MODEL_PROFILE", "balanced")
    directory = ASR_MODEL_DIRECTORIES.get(profile, ASR_MODEL_DIRECTORIES["balanced"])
    model_root = os.environ.get("AURAL_MODEL_ROOT")
    if model_root:
        return Path(model_root).expanduser() / directory
    return RESOURCES_ROOT / "asr-models" / directory


def emit(event):
    print(json.dumps(event, ensure_ascii=False), flush=True)


def fail(request, output_dir, code, message):
    output_dir.mkdir(parents=True, exist_ok=True)
    error_log_path = output_dir / "error.log"
    error_log_path.write_text(
        f"{datetime.now(timezone.utc).isoformat()} {message}\n",
        encoding="utf-8",
    )
    emit(
        {
            "type": "failed",
            "request_id": request.get("request_id"),
            "task_id": request.get("task_id"),
            "error_code": code,
            "error_log_path": str(error_log_path),
        }
    )


def first_existing(candidates):
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


def resolve_runtime_python():
    return first_existing(
        [
            RUNTIME_ROOT / "bin" / "python3",
            RUNTIME_ROOT / "bin" / "python",
            RUNTIME_ROOT / ".venv" / "bin" / "python",
        ]
    )


def resolve_asr_script():
    return first_existing(
        [
            RUNTIME_ROOT / "qwen3_asr_transcribe.py",
            RUNTIME_ROOT / "tools" / "qwen3_asr_transcribe.py",
        ]
    )


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


def repeat_key(text):
    return re.sub(r"[\s,.;:!?，。；：！？、\"'（）()]+", "", str(text or "")).lower()


def sentence_units(text):
    units = re.findall(r"[^。！？!?；;\n]+[。！？!?；;]?", str(text or ""))
    return [unit.strip() for unit in units if unit.strip()]


def collapse_repeated_sentences(text, min_run=4, keep=1):
    units = sentence_units(text)
    if len(units) < min_run:
        return text, {"changed": False, "removed_repetitions": 0}

    result = []
    removed = 0
    index = 0
    while index < len(units):
        key = repeat_key(units[index])
        end = index + 1
        while end < len(units) and key and repeat_key(units[end]) == key:
            end += 1

        count = end - index
        if key and count >= min_run:
            result.extend(units[index : index + keep])
            removed += count - keep
        else:
            result.extend(units[index:end])
        index = end

    if removed <= 0:
        return text, {"changed": False, "removed_repetitions": 0}
    return "".join(result), {"changed": True, "removed_repetitions": removed}


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
        text, _ = collapse_repeated_sentences(text)
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
    text, _ = collapse_repeated_sentences(text)
    return [{"start_sec": 0.0, "end_sec": float(duration_sec or 0.0), "text": text}]


def build_metadata(record):
    metadata = {
        "pipeline": record.get("pipeline") or record.get("mode") or "vad_chunked",
        "timestamp_method": "vad_chunked_segments",
    }
    if record.get("segmentation"):
        metadata["segmentation"] = record["segmentation"]
    return metadata


def run_asr(request, output_dir):
    runtime_python = resolve_runtime_python()
    asr_script = resolve_asr_script()
    audio_path = Path(request["audio_path"]).expanduser()
    raw_output_dir = output_dir / "raw-asr"
    raw_output_dir.mkdir(parents=True, exist_ok=True)

    if not audio_path.exists():
        raise RuntimeError(f"audio file not found: {audio_path}")
    if runtime_python is None:
        raise RuntimeError(f"bundled runtime python not found under {RUNTIME_ROOT}")
    if asr_script is None:
        raise RuntimeError(f"bundled ASR script not found under {RUNTIME_ROOT}")
    model_root = resolve_asr_model_root()
    if not model_root.exists():
        raise RuntimeError(f"local ASR model not found: {model_root}")

    pipeline = request.get("pipeline") or "vad_chunked"
    if pipeline == "auto":
        pipeline = "vad_chunked"

    command = [
        str(runtime_python),
        str(asr_script),
        str(audio_path),
        "--model",
        str(model_root),
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
    env = dict(os.environ)
    env["PATH"] = f"{RUNTIME_ROOT / 'bin'}:{env.get('PATH', '')}"
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    proc = subprocess.run(command, text=True, capture_output=True, env=env)
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
            "metadata": build_metadata(record),
        }
        transcript["metadata"]["asr_cleanup"] = {
            "enabled": True,
            "rule": "collapse_consecutive_identical_sentences_min4_keep1",
        }
        transcript = apply_itn_to_transcript(transcript, request.get("language") or "auto")
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
