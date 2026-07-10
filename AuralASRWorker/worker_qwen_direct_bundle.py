#!/usr/bin/env python3

import inspect
import json
import os
import re
import sys
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

from itn_postprocess import apply_itn_to_transcript


RESOURCES_ROOT = Path(__file__).resolve().parents[1]
# Keep the first model pass un-split inside mlx_audio. The outer worker owns chunking.
ASR_GENERATE_CHUNK_DURATION_SEC = None
ASR_GENERATE_MAX_TOKENS = 8192
ASR_GENERATE_REPETITION_PENALTY = 1.0
ASR_GENERATE_REPETITION_CONTEXT_SIZE = 32
ASR_GENERATE_RETRY_CHUNK_DURATION_SEC = None
ASR_GENERATE_RETRY_REPETITION_PENALTY = 1.10
ASR_GENERATE_RETRY_REPETITION_CONTEXT_SIZE = 32
ASR_REPETITION_SIGNAL_MIN_COUNT = 8
ASR_REPETITION_SIGNAL_MIN_COVERAGE = 0.35
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


def env_float(name, default):
    value = os.environ.get(name)
    if value is None or value.strip() == "":
        return default
    if value.strip().lower() in {"0", "false", "no", "off", "none"}:
        return None
    return float(value)


def env_int(name, default):
    value = os.environ.get(name)
    if value is None or value.strip() == "":
        return default
    if value.strip().lower() in {"0", "false", "no", "off", "none"}:
        return None
    return int(value)


def env_bool(name, default):
    value = os.environ.get(name)
    if value is None or value.strip() == "":
        return default
    return value.strip().lower() not in {"0", "false", "no", "off", "none"}


def default_repetition_penalty():
    profile = os.environ.get("AURAL_MODEL_PROFILE", "balanced")
    if profile == "accurate":
        return None
    return ASR_GENERATE_REPETITION_PENALTY


def asr_generate_settings():
    penalty = env_float("AURAL_ASR_REPETITION_PENALTY", default_repetition_penalty())
    context_size = env_int("AURAL_ASR_REPETITION_CONTEXT_SIZE", ASR_GENERATE_REPETITION_CONTEXT_SIZE)
    retry_penalty = env_float(
        "AURAL_ASR_REPETITION_RETRY_PENALTY",
        ASR_GENERATE_RETRY_REPETITION_PENALTY,
    )
    retry_chunk_duration_sec = env_float(
        "AURAL_ASR_REPETITION_RETRY_CHUNK_DURATION_SEC",
        ASR_GENERATE_RETRY_CHUNK_DURATION_SEC,
    )
    retry_context_size = env_int(
        "AURAL_ASR_REPETITION_RETRY_CONTEXT_SIZE",
        ASR_GENERATE_RETRY_REPETITION_CONTEXT_SIZE,
    )
    if penalty is None:
        context_size = None
    if retry_penalty is None:
        retry_context_size = None
    return {
        "chunk_duration_sec": ASR_GENERATE_CHUNK_DURATION_SEC,
        "max_tokens": ASR_GENERATE_MAX_TOKENS,
        "repetition_penalty": penalty,
        "repetition_context_size": context_size,
        "repetition_retry_enabled": env_bool("AURAL_ASR_REPETITION_RETRY", True)
        and retry_penalty is not None,
        "retry_chunk_duration_sec": retry_chunk_duration_sec,
        "retry_repetition_penalty": retry_penalty,
        "retry_repetition_context_size": retry_context_size,
    }


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


def normalized_chars(text):
    return "".join(
        re.findall(r"[A-Za-z0-9\u3400-\u4dbf\u4e00-\u9fff\u3040-\u30ff]+", str(text or ""))
    ).lower()


def repeated_ngram_signal(text, min_len=1, max_len=8):
    norm = normalized_chars(text)
    if len(norm) < 24:
        return {"phrase": "", "count": 0, "coverage": 0.0, "score": 0.0}

    best = {"phrase": "", "count": 0, "coverage": 0.0, "score": 0.0}
    for width in range(min_len, min(max_len, len(norm)) + 1):
        grams = Counter(norm[index : index + width] for index in range(0, len(norm) - width + 1, width))
        for phrase, count in grams.most_common(8):
            if count < ASR_REPETITION_SIGNAL_MIN_COUNT:
                continue
            coverage = len(phrase) * count / max(len(norm), 1)
            score = coverage * min(len(phrase), 4)
            if score > best["score"]:
                best = {
                    "phrase": phrase[:40],
                    "count": count,
                    "coverage": round(coverage, 4),
                    "score": round(score, 4),
                }
    return best


def is_repetition_loop(signal):
    return bool(
        signal.get("coverage", 0.0) >= ASR_REPETITION_SIGNAL_MIN_COVERAGE
        and signal.get("count", 0) >= ASR_REPETITION_SIGNAL_MIN_COUNT
    )


def retry_generate_settings(settings):
    retry_settings = dict(settings)
    retry_settings["chunk_duration_sec"] = settings["retry_chunk_duration_sec"]
    retry_settings["repetition_penalty"] = settings["retry_repetition_penalty"]
    retry_settings["repetition_context_size"] = settings["retry_repetition_context_size"]
    return retry_settings


def generate_one(model, audio_path, language, settings=None):
    signature = inspect.signature(model.generate)
    settings = settings or asr_generate_settings()
    kwargs = {"max_tokens": settings["max_tokens"], "verbose": False}
    if settings["chunk_duration_sec"] is not None and "chunk_duration" in signature.parameters:
        kwargs["chunk_duration"] = settings["chunk_duration_sec"]
    if settings["repetition_penalty"] is not None and "repetition_penalty" in signature.parameters:
        kwargs["repetition_penalty"] = settings["repetition_penalty"]
    if settings["repetition_context_size"] is not None and "repetition_context_size" in signature.parameters:
        kwargs["repetition_context_size"] = settings["repetition_context_size"]
    if "language" in signature.parameters:
        kwargs["language"] = language
    if "source_lang" in signature.parameters:
        kwargs["source_lang"] = language or "en"
    if "target_lang" in signature.parameters:
        kwargs["target_lang"] = language or "en"
    if "audio" in signature.parameters:
        return model.generate(audio=str(audio_path), **kwargs)
    return model.generate(str(audio_path), **kwargs)


def generate_text_with_repetition_retry(model, audio_path, language, settings=None):
    settings = settings or asr_generate_settings()
    result = generate_one(model, audio_path, language, settings=settings)
    text = clean_asr_template_artifacts(output_text(result))
    if not text:
        return text, None

    initial_signal = repeated_ngram_signal(text)
    if not settings["repetition_retry_enabled"] or not is_repetition_loop(initial_signal):
        return text, None

    retry_settings = retry_generate_settings(settings)
    retry_result = generate_one(model, audio_path, language, settings=retry_settings)
    retry_text = clean_asr_template_artifacts(output_text(retry_result))
    retry_signal = repeated_ngram_signal(retry_text)
    accepted = bool(
        retry_text
        and (
            not is_repetition_loop(retry_signal)
            or retry_signal.get("score", 0.0) < initial_signal.get("score", 0.0)
        )
    )
    event = {
        "initial_signal": initial_signal,
        "retry_signal": retry_signal,
        "accepted_retry": accepted,
    }
    if accepted:
        return retry_text, event
    return text, event


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
        model_root = resolve_asr_model_root()
        if not model_root.exists():
            raise RuntimeError(f"local ASR model not found: {model_root}")

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
        model = load(str(model_root))
        load_sec = time.time() - started_load
        generate_settings = asr_generate_settings()

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
        result_text, retry_event = generate_text_with_repetition_retry(
            model,
            audio_path,
            language,
            settings=generate_settings,
        )
        text = result_text
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
                "asr_generate": {
                    "mode": "dynamic_repetition_retry",
                    "chunk_duration_sec": generate_settings["chunk_duration_sec"],
                    "max_tokens": generate_settings["max_tokens"],
                    "repetition_penalty": generate_settings["repetition_penalty"],
                    "repetition_context_size": generate_settings["repetition_context_size"],
                    "retry_on_repetition": generate_settings["repetition_retry_enabled"],
                    "retry_chunk_duration_sec": generate_settings["retry_chunk_duration_sec"],
                    "retry_repetition_penalty": generate_settings["retry_repetition_penalty"],
                    "retry_repetition_context_size": generate_settings["retry_repetition_context_size"],
                },
                "asr_repetition_retry": {
                    "enabled": generate_settings["repetition_retry_enabled"],
                    "trigger_rule": "ngram_coverage>=0.35_and_count>=8",
                    "triggered_chunk_count": 1 if retry_event else 0,
                    "accepted_retry_count": 1 if retry_event and retry_event["accepted_retry"] else 0,
                    "events": [retry_event] if retry_event else [],
                },
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
