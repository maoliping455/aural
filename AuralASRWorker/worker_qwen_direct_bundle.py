#!/usr/bin/env python3

import inspect
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from itn_postprocess import apply_itn_to_transcript


RESOURCES_ROOT = Path(__file__).resolve().parents[1]
MODEL_ROOT = RESOURCES_ROOT / "asr-models" / "qwen3-asr-1.7b-4bit"


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


def normalize_language(language):
    if language == "auto":
        return None
    if language and language.startswith("zh"):
        return "zh"
    if language and language.startswith("en"):
        return "en"
    if language and language.startswith("ja"):
        return "ja"
    return language or None


def output_text(result):
    segments = getattr(result, "segments", None)
    if isinstance(result, str):
        return result
    text = getattr(result, "text", None)
    if isinstance(text, str):
        if segments and text.lstrip().startswith(("[", "{", "```json")):
            segment_text = " ".join(
                str(item.get("text", "")).strip()
                for item in segments
                if isinstance(item, dict) and item.get("text")
            ).strip()
            if segment_text:
                return segment_text
        return text
    if isinstance(result, dict):
        result_segments = result.get("segments")
        if result_segments:
            segment_text = " ".join(
                str(item.get("text", "")).strip()
                for item in result_segments
                if isinstance(item, dict) and item.get("text")
            ).strip()
            if segment_text:
                return segment_text
        value = result.get("text") or result.get("transcription") or result.get("result")
        if isinstance(value, str):
            return value
    return str(result)


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


def generate_one(model, audio_path, language):
    signature = inspect.signature(model.generate)
    kwargs = {"max_tokens": 8192, "verbose": False}
    if "language" in signature.parameters:
        kwargs["language"] = language
    if "source_lang" in signature.parameters:
        kwargs["source_lang"] = language or "en"
    if "target_lang" in signature.parameters:
        kwargs["target_lang"] = language or "en"
    if "audio" in signature.parameters:
        return model.generate(audio=str(audio_path), **kwargs)
    return model.generate(str(audio_path), **kwargs)


def split_text_into_paragraphs(text, target_chars=55, max_chars=110):
    clean = re.sub(r"\s+", " ", text).strip()
    if not clean:
        return []

    strong_pattern = re.compile(r"[^。！？!?；;]+[。！？!?；;]?")
    weak_pattern = re.compile(r"[^，,、]+[，,、]?")
    strong_units = [item.group(0).strip() for item in strong_pattern.finditer(clean) if item.group(0).strip()]
    if not strong_units:
        strong_units = [clean]

    sentences = []
    for unit in strong_units:
        if len(unit) <= target_chars:
            sentences.append(unit)
            continue
        weak_units = [item.group(0).strip() for item in weak_pattern.finditer(unit) if item.group(0).strip()]
        sentences.extend(weak_units or [unit])

    paragraphs = []
    current = ""
    for sentence in sentences:
        if not current:
            current = sentence
            continue
        if len(current) + len(sentence) <= target_chars:
            current += sentence
            continue
        paragraphs.append(current)
        current = sentence

    if current:
        paragraphs.append(current)

    result = []
    for paragraph in paragraphs:
        result.extend(split_long_paragraph(paragraph, max_chars))

    return [item for item in result if item]


def split_long_paragraph(paragraph, max_chars):
    paragraph = paragraph.strip()
    if not paragraph:
        return []
    if len(paragraph) <= max_chars:
        return [paragraph]

    result = []
    start = 0
    min_split = max(20, int(max_chars * 0.55))
    while start < len(paragraph):
        end = min(start + max_chars, len(paragraph))
        if end >= len(paragraph):
            item = paragraph[start:].strip()
            if item:
                result.append(item)
            break

        window = paragraph[start:end]
        split_at = -1
        for match in re.finditer(r"\s+", window):
            if match.start() >= min_split:
                split_at = match.start()

        if split_at < 0:
            for offset in range(len(window) - 1, min_split, -1):
                if window[offset] in ",.;:!?，。；：！？、":
                    split_at = offset + 1
                    break

        if split_at <= 0:
            split_at = len(window)

        tail = paragraph[start + split_at :].strip()
        if tail and len(tail) < 12:
            split_at = len(paragraph) - start

        item = paragraph[start : start + split_at].strip()
        if item:
            result.append(item)
        start += split_at
        while start < len(paragraph) and paragraph[start].isspace():
            start += 1

    return result


def allocate_segments(paragraphs, duration_sec):
    if not paragraphs:
        return []
    if duration_sec <= 0:
        return [
            {
                "start_sec": 0.0,
                "end_sec": 0.0,
                "text": paragraphs[0],
            }
        ] + [
            {
                "start_sec": 0.0,
                "end_sec": 0.0,
                "text": paragraph,
            }
            for paragraph in paragraphs[1:]
        ]

    weights = [max(len(re.sub(r"\s+", "", paragraph)), 1) for paragraph in paragraphs]
    total_weight = sum(weights)
    segments = []
    cursor = 0.0
    for index, (paragraph, weight) in enumerate(zip(paragraphs, weights)):
        if index == len(paragraphs) - 1:
            end = duration_sec
        else:
            end = cursor + duration_sec * weight / total_weight
        segments.append(
            {
                "start_sec": round(cursor, 3),
                "end_sec": round(max(end, cursor), 3),
                "text": paragraph,
            }
        )
        cursor = end
    return segments


def transcribe(request):
    output_dir = Path(request["output_dir"]).expanduser()
    output_dir.mkdir(parents=True, exist_ok=True)

    try:
        audio_path = Path(request["audio_path"]).expanduser()
        if not audio_path.exists():
            raise RuntimeError(f"audio file not found: {audio_path}")
        if not MODEL_ROOT.exists():
            raise RuntimeError(f"bundled model not found: {MODEL_ROOT}")

        emit(
            {
                "type": "progress",
                "request_id": request["request_id"],
                "task_id": request["task_id"],
                "stage": "loading",
                "completed_segments": 0,
                "total_segments": 1,
            }
        )

        from mlx_audio.stt import load

        started_load = time.time()
        model = load(str(MODEL_ROOT))
        load_sec = time.time() - started_load

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

        language = normalize_language(request.get("language") or "auto")
        result = generate_one(model, audio_path, language)
        text = clean_asr_template_artifacts(output_text(result))
        if not text:
            raise RuntimeError("asr runtime produced empty transcript")
        text, cleanup = collapse_repeated_sentences(text)

        duration_sec = float(request.get("duration_sec") or 0.0)
        paragraphs = split_text_into_paragraphs(text)
        segments = allocate_segments(paragraphs, duration_sec)
        transcript = {
            "task_id": request["task_id"],
            "audio_duration_sec": duration_sec,
            "created_at": datetime.now(timezone.utc).isoformat(),
            "segments": segments,
            "text": text,
            "metadata": {
                "pipeline": "direct_single_pass_text_segments",
                "timestamp_method": "text_length_proportional",
                "load_sec": load_sec,
                "asr_cleanup": {
                    "enabled": True,
                    "rule": "collapse_consecutive_identical_sentences_min4_keep1",
                    "changed_chunk_count": 1 if cleanup.get("changed") else 0,
                    "removed_repetition_count": cleanup.get("removed_repetitions", 0),
                },
            },
        }
        transcript = apply_itn_to_transcript(transcript, language)
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
                "duration_sec": duration_sec,
            }
        )
    except Exception as exc:
        fail(request, output_dir, "asr_runtime_error", repr(exc))


def main():
    os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
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
