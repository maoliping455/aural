#!/usr/bin/env python3

import inspect
import json
import os
import re
import subprocess
import sys
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import soundfile as sf

from alignment_postprocess import refine_segments_with_alignment, release_mlx_memory
from itn_postprocess import apply_itn_to_transcript


RESOURCES_ROOT = Path(__file__).resolve().parents[1]
AFCONVERT = Path("/usr/bin/afconvert")
# The outer worker owns file-level chunking. Do not ask mlx_audio to split again by default:
# short internal windows can hallucinate on music/weak-speech intros.
ASR_GENERATE_CHUNK_DURATION_SEC = None
ASR_GENERATE_MAX_TOKENS = 8192
ASR_GENERATE_REPETITION_PENALTY = 1.0
ASR_GENERATE_REPETITION_CONTEXT_SIZE = 32
ASR_GENERATE_RETRY_CHUNK_DURATION_SEC = None
ASR_GENERATE_RETRY_REPETITION_PENALTY = 1.10
ASR_GENERATE_RETRY_REPETITION_CONTEXT_SIZE = 32
ASR_REPETITION_SIGNAL_MIN_COUNT = 8
ASR_REPETITION_SIGNAL_MIN_COVERAGE = 0.35
OUTER_CHUNK_TARGET_SEC = 60.0
OUTER_CHUNK_MAX_SEC = 90.0
OUTER_CHUNK_MIN_SEC = 10.0
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


def alignment_enabled():
    value = os.environ.get("AURAL_ALIGNMENT_ENABLED", "1").lower()
    return value not in {"0", "false", "no", "off"}


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


def generate_one(model, audio_path, language, system_prompt=None, settings=None):
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
    if system_prompt and "system_prompt" in signature.parameters:
        kwargs["system_prompt"] = system_prompt
    if "audio" in signature.parameters:
        return model.generate(audio=str(audio_path), **kwargs)
    return model.generate(str(audio_path), **kwargs)


def generate_text_with_repetition_retry(model, audio_path, language, system_prompt=None, settings=None):
    settings = settings or asr_generate_settings()
    result = generate_one(model, audio_path, language, system_prompt=system_prompt, settings=settings)
    text = clean_asr_template_artifacts(output_text(result))
    if not text:
        return text, None

    initial_signal = repeated_ngram_signal(text)
    if not settings["repetition_retry_enabled"] or not is_repetition_loop(initial_signal):
        return text, None

    retry_settings = retry_generate_settings(settings)
    retry_result = generate_one(
        model,
        audio_path,
        language,
        system_prompt=system_prompt,
        settings=retry_settings,
    )
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


def progress_event(request, stage, completed_segments=0, total_segments=1):
    return {
        "type": "progress",
        "request_id": request["request_id"],
        "task_id": request["task_id"],
        "stage": stage,
        "completed_segments": completed_segments,
        "total_segments": total_segments,
    }


def split_text_into_paragraphs(text, target_chars=70, max_chars=130):
    clean = re.sub(r"\s+", " ", text).strip()
    if not clean:
        return []

    strong_pattern = re.compile(r"[^。！？!?；;]+[。！？!?；;]?")
    weak_pattern = re.compile(r"[^，,、]+[，,、]?")
    strong_units = [item.group(0).strip() for item in strong_pattern.finditer(clean) if item.group(0).strip()]
    if not strong_units:
        strong_units = [clean]

    units = []
    for unit in strong_units:
        if len(unit) <= target_chars:
            units.append(unit)
        else:
            weak_units = [item.group(0).strip() for item in weak_pattern.finditer(unit) if item.group(0).strip()]
            units.extend(weak_units or [unit])

    paragraphs = []
    current = ""
    for unit in units:
        if not current:
            current = unit
        elif len(current) + len(unit) <= target_chars:
            current += unit
        else:
            paragraphs.append(current)
            current = unit
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


def normalize_to_wav(audio_path, output_dir):
    if not AFCONVERT.is_file():
        raise RuntimeError("/usr/bin/afconvert is required for segmented transcription")
    wav_path = output_dir / "normalized.wav"
    command = [
        str(AFCONVERT),
        "-f",
        "WAVE",
        "-d",
        "LEI16@16000",
        "-c",
        "1",
        str(audio_path),
        str(wav_path),
    ]
    proc = subprocess.run(command, text=True, capture_output=True, timeout=120)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "afconvert failed")
    return wav_path


def frame_rms(samples, frame_size, hop_size):
    if len(samples) <= frame_size:
        return np.array([float(np.sqrt(np.mean(samples * samples) + 1e-12))], dtype=np.float32)

    values = []
    for start in range(0, len(samples) - frame_size + 1, hop_size):
        frame = samples[start : start + frame_size]
        values.append(float(np.sqrt(np.mean(frame * frame) + 1e-12)))
    return np.array(values, dtype=np.float32)


def rms_db_threshold(samples, sample_rate):
    frame_size = max(int(sample_rate * 0.03), 1)
    hop_size = max(int(sample_rate * 0.01), 1)
    rms = frame_rms(samples, frame_size, hop_size)
    if len(rms) == 0:
        return np.array([], dtype=np.float32), -35.0, frame_size, hop_size

    db = 20 * np.log10(np.maximum(rms, 1e-8))
    threshold = min(-35.0, float(np.percentile(db, 35)) + 6.0)
    return db, threshold, frame_size, hop_size


def detect_silence_midpoints(samples, sample_rate, min_silence_sec=0.45):
    db, threshold, _, hop_size = rms_db_threshold(samples, sample_rate)
    if len(db) == 0:
        return []

    silent = db < threshold
    min_frames = max(int(min_silence_sec / 0.01), 1)

    midpoints = []
    start = None
    for index, is_silent in enumerate(silent):
        if is_silent and start is None:
            start = index
        elif not is_silent and start is not None:
            if index - start >= min_frames:
                midpoints.append(((start + index) / 2.0) * hop_size / sample_rate)
            start = None
    if start is not None and len(silent) - start >= min_frames:
        midpoints.append(((start + len(silent)) / 2.0) * hop_size / sample_rate)
    return midpoints


def merge_intervals(intervals, merge_gap_sec=0.28):
    if not intervals:
        return []

    merged = [dict(intervals[0])]
    for interval in intervals[1:]:
        previous = merged[-1]
        if interval["start_sec"] - previous["end_sec"] <= merge_gap_sec:
            previous["end_sec"] = max(previous["end_sec"], interval["end_sec"])
        else:
            merged.append(dict(interval))
    return merged


def detect_speech_intervals(
    samples,
    sample_rate,
    min_speech_sec=0.12,
    merge_gap_sec=0.28,
    padding_sec=0.08,
):
    duration = len(samples) / sample_rate if sample_rate else 0.0
    if duration <= 0:
        return []

    db, threshold, frame_size, hop_size = rms_db_threshold(samples, sample_rate)
    if len(db) == 0:
        return []

    speech = db >= threshold
    min_frames = max(int(min_speech_sec / 0.01), 1)

    intervals = []
    start = None
    for index, is_speech in enumerate(speech):
        if is_speech and start is None:
            start = index
        elif not is_speech and start is not None:
            if index - start >= min_frames:
                intervals.append(
                    {
                        "start_sec": max(0.0, (start * hop_size / sample_rate) - padding_sec),
                        "end_sec": min(duration, ((index * hop_size + frame_size) / sample_rate) + padding_sec),
                    }
                )
            start = None
    if start is not None and len(speech) - start >= min_frames:
        intervals.append(
            {
                "start_sec": max(0.0, (start * hop_size / sample_rate) - padding_sec),
                "end_sec": min(duration, (((len(speech) - 1) * hop_size + frame_size) / sample_rate) + padding_sec),
            }
        )

    cleaned = [
        {
            "start_sec": round(interval["start_sec"], 3),
            "end_sec": round(interval["end_sec"], 3),
        }
        for interval in merge_intervals(intervals, merge_gap_sec)
        if interval["end_sec"] - interval["start_sec"] >= min_speech_sec
    ]
    return cleaned


def choose_cut(start, duration, silence_midpoints, target_sec, max_sec, min_sec):
    target = min(duration, start + target_sec)
    lower = min(duration, start + min_sec)
    upper = min(duration, start + max_sec)
    candidates = [point for point in silence_midpoints if lower <= point <= upper]
    if candidates:
        return min(candidates, key=lambda point: abs(point - target))
    return target if lower <= target <= upper else upper


def build_audio_segments(
    samples,
    sample_rate,
    target_sec=OUTER_CHUNK_TARGET_SEC,
    max_sec=OUTER_CHUNK_MAX_SEC,
    min_sec=OUTER_CHUNK_MIN_SEC,
):
    duration = len(samples) / sample_rate if sample_rate else 0.0
    if duration <= 0:
        return [], duration
    if duration <= max_sec:
        return [{"index": 1, "start_sec": 0.0, "end_sec": round(duration, 3)}], duration

    silence_midpoints = detect_silence_midpoints(samples, sample_rate)
    boundaries = [0.0]
    start = 0.0
    while duration - start > max_sec:
        cut = choose_cut(start, duration, silence_midpoints, target_sec, max_sec, min_sec)
        if cut <= start + 1.0:
            cut = min(duration, start + target_sec)
        boundaries.append(cut)
        start = cut
    if duration > boundaries[-1]:
        boundaries.append(duration)

    if len(boundaries) > 2 and boundaries[-1] - boundaries[-2] < min_sec:
        boundaries.pop(-2)

    return [
        {
            "index": index,
            "start_sec": round(start, 3),
            "end_sec": round(end, 3),
        }
        for index, (start, end) in enumerate(zip(boundaries, boundaries[1:]), 1)
    ], duration


def allocate_paragraph_segments(paragraphs, start_sec, end_sec):
    if not paragraphs:
        return []
    duration = max(end_sec - start_sec, 0.0)
    if duration <= 0 or len(paragraphs) == 1:
        return [{"start_sec": round(start_sec, 3), "end_sec": round(end_sec, 3), "text": paragraphs[0]}]

    weights = [max(len(re.sub(r"\s+", "", paragraph)), 1) for paragraph in paragraphs]
    total_weight = sum(weights)
    cursor = start_sec
    segments = []
    for index, (paragraph, weight) in enumerate(zip(paragraphs, weights)):
        if index == len(paragraphs) - 1:
            end = end_sec
        else:
            end = cursor + duration * weight / total_weight
        segments.append({"start_sec": round(cursor, 3), "end_sec": round(end, 3), "text": paragraph})
        cursor = end
    return segments


def clip_speech_intervals(speech_intervals, start_sec, end_sec):
    clipped = []
    for interval in speech_intervals:
        start = max(start_sec, float(interval["start_sec"]))
        end = min(end_sec, float(interval["end_sec"]))
        if end - start > 0.05:
            clipped.append({"start_sec": round(start, 3), "end_sec": round(end, 3)})
    return clipped


def speech_duration(speech_intervals):
    return sum(max(float(interval["end_sec"]) - float(interval["start_sec"]), 0.0) for interval in speech_intervals)


def time_for_speech_offset(offset, speech_intervals, prefer_end=False):
    total = speech_duration(speech_intervals)
    if not speech_intervals:
        return 0.0
    if offset <= 0:
        return float(speech_intervals[0]["start_sec"])
    if offset >= total:
        return float(speech_intervals[-1]["end_sec"])

    cursor = 0.0
    epsilon = 1e-6
    for index, interval in enumerate(speech_intervals):
        start = float(interval["start_sec"])
        end = float(interval["end_sec"])
        length = max(end - start, 0.0)
        next_cursor = cursor + length
        if offset < next_cursor - epsilon:
            return start + (offset - cursor)
        if abs(offset - next_cursor) <= epsilon:
            if prefer_end or index == len(speech_intervals) - 1:
                return end
            return float(speech_intervals[index + 1]["start_sec"])
        cursor = next_cursor
    return float(speech_intervals[-1]["end_sec"])


def allocate_paragraph_segments_by_speech(paragraphs, start_sec, end_sec, speech_intervals):
    fallback = allocate_paragraph_segments(paragraphs, start_sec, end_sec)
    if not paragraphs:
        return [], True

    clipped = clip_speech_intervals(speech_intervals, start_sec, end_sec)
    total_speech = speech_duration(clipped)
    if total_speech <= 0.2:
        return fallback, True

    if len(paragraphs) == 1:
        return [
            {
                "start_sec": round(float(clipped[0]["start_sec"]), 3),
                "end_sec": round(float(clipped[-1]["end_sec"]), 3),
                "text": paragraphs[0],
            }
        ], False

    weights = [max(len(re.sub(r"\s+", "", paragraph)), 1) for paragraph in paragraphs]
    total_weight = sum(weights)
    cursor = 0.0
    segments = []
    for index, (paragraph, weight) in enumerate(zip(paragraphs, weights)):
        start_offset = cursor
        if index == len(paragraphs) - 1:
            end_offset = total_speech
        else:
            end_offset = min(total_speech, cursor + total_speech * weight / total_weight)

        start = time_for_speech_offset(start_offset, clipped, prefer_end=False)
        end = time_for_speech_offset(end_offset, clipped, prefer_end=True)
        if end < start:
            return fallback, True

        segments.append(
            {
                "start_sec": round(start, 3),
                "end_sec": round(end, 3),
                "text": paragraph,
            }
        )
        cursor = end_offset

    for left, right in zip(segments, segments[1:]):
        if left["end_sec"] > right["start_sec"]:
            return fallback, True
    return segments, False


def write_chunk(samples, sample_rate, segment, chunk_dir):
    start_sample = max(0, int(segment["start_sec"] * sample_rate))
    end_sample = min(len(samples), int(segment["end_sec"] * sample_rate))
    chunk_path = chunk_dir / f"chunk-{segment['index']:04d}.wav"
    sf.write(chunk_path, samples[start_sample:end_sample], sample_rate, subtype="PCM_16")
    return chunk_path


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

        emit(progress_event(request, "preparing"))

        work_dir = output_dir / "audio-segments"
        work_dir.mkdir(parents=True, exist_ok=True)
        emit(progress_event(request, "normalizing"))
        wav_path = normalize_to_wav(audio_path, work_dir)
        emit(progress_event(request, "reading_audio"))
        samples, sample_rate = sf.read(wav_path, dtype="float32")
        if samples.ndim > 1:
            samples = samples[:, 0]
        emit(progress_event(request, "segmenting"))
        speech_intervals = detect_speech_intervals(samples, sample_rate)
        total_speech_sec = round(speech_duration(speech_intervals), 3)
        audio_segments, duration_sec = build_audio_segments(samples, sample_rate)
        if not audio_segments:
            raise RuntimeError("audio segmentation produced no segments")

        emit(progress_event(request, "loading", 0, len(audio_segments)))

        from mlx_audio.stt import load

        started_load = time.time()
        model = load(str(model_root))
        load_sec = time.time() - started_load
        language = normalize_language(request.get("language") or "auto")
        system_prompt = None
        generate_settings = asr_generate_settings()

        transcript_segments = []
        chunk_records = []
        raw_texts = []
        cleanup_events = []
        retry_events = []
        vad_fallback_chunks = 0
        chunk_dir = work_dir / "chunks"
        chunk_dir.mkdir(parents=True, exist_ok=True)
        progress_total = len(audio_segments) * 2
        for segment in audio_segments:
            chunk_path = write_chunk(samples, sample_rate, segment, chunk_dir)
            emit(progress_event(request, "transcribing", segment["index"] - 1, progress_total))
            text, retry_event = generate_text_with_repetition_retry(
                model,
                chunk_path,
                language,
                system_prompt=system_prompt,
                settings=generate_settings,
            )
            if not text:
                continue
            if retry_event:
                retry_events.append(
                    {
                        "chunk_index": segment["index"],
                        "accepted_retry": retry_event["accepted_retry"],
                        "initial_signal": retry_event["initial_signal"],
                        "retry_signal": retry_event["retry_signal"],
                    }
                )
            text, cleanup = collapse_repeated_sentences(text)
            if cleanup.get("changed"):
                cleanup_events.append(
                    {
                        "chunk_index": segment["index"],
                        "removed_repetitions": cleanup["removed_repetitions"],
                    }
                )
            raw_texts.append(text)
            paragraphs = split_text_into_paragraphs(text) or [text]
            paragraph_segments, used_fallback = allocate_paragraph_segments_by_speech(
                paragraphs,
                segment["start_sec"],
                segment["end_sec"],
                speech_intervals,
            )
            if used_fallback:
                vad_fallback_chunks += 1
            transcript_segments.extend(paragraph_segments)
            chunk_records.append(
                {
                    "index": segment["index"],
                    "start_sec": segment["start_sec"],
                    "end_sec": segment["end_sec"],
                    "audio_path": str(chunk_path),
                    "text": text,
                    "paragraphs": paragraphs,
                    "fallback_segments": paragraph_segments,
                }
            )
            emit(
                {
                    "type": "progress",
                    "request_id": request["request_id"],
                    "task_id": request["task_id"],
                    "stage": "transcribing",
                    "completed_segments": segment["index"],
                    "total_segments": progress_total,
                }
            )

        if not transcript_segments:
            raise RuntimeError("asr runtime produced empty transcript")

        del model
        release_mlx_memory()

        fallback_timestamp_method = (
            "vad_speech_weighted_paragraph"
            if vad_fallback_chunks < len(audio_segments)
            else "audio_segmented"
        )
        timestamp_method = fallback_timestamp_method
        alignment_metadata = None

        def emit_alignment_progress(completed_segments, total_segments):
            emit(
                {
                    "type": "progress",
                    "request_id": request["request_id"],
                    "task_id": request["task_id"],
                    "stage": "aligning",
                    "completed_segments": len(audio_segments) + completed_segments,
                    "total_segments": progress_total,
                }
            )

        if alignment_enabled():
            try:
                alignment_result = refine_segments_with_alignment(
                    chunk_records,
                    output_dir,
                    language=language,
                    progress_callback=emit_alignment_progress,
                )
                alignment_metadata = alignment_result.get("metadata")
                if alignment_result.get("timestamp_method"):
                    timestamp_method = alignment_result["timestamp_method"]
                    transcript_segments = alignment_result.get("segments") or transcript_segments
            except Exception as exc:
                alignment_metadata = {
                    "enabled": True,
                    "engine": "qwen3_forced_aligner",
                    "runtime": "mlx_audio",
                    "status": "error_fallback_estimated",
                    "chunk_count": len(chunk_records),
                    "aligned_chunk_count": 0,
                    "failed_chunk_count": len(chunk_records),
                    "error": repr(exc)[:500],
                }
        else:
            alignment_metadata = {
                "enabled": False,
                "engine": "qwen3_forced_aligner",
                "runtime": "mlx_audio",
                "status": "disabled",
                "chunk_count": len(chunk_records),
                "aligned_chunk_count": 0,
                "failed_chunk_count": 0,
            }

        transcript = {
            "task_id": request["task_id"],
            "audio_duration_sec": round(duration_sec, 3),
            "created_at": datetime.now(timezone.utc).isoformat(),
            "segments": transcript_segments,
            "text": "\n".join(raw_texts).strip(),
            "metadata": {
                "pipeline": "macos_afconvert_segmented",
                "timestamp_method": timestamp_method,
                "fallback_timestamp_method": fallback_timestamp_method,
                "segment_count": len(audio_segments),
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
                "audio_chunking": {
                    "target_sec": OUTER_CHUNK_TARGET_SEC,
                    "max_sec": OUTER_CHUNK_MAX_SEC,
                    "min_sec": OUTER_CHUNK_MIN_SEC,
                },
                "alignment": alignment_metadata,
                "vad": {
                    "engine": "rms_dynamic_threshold",
                    "speech_interval_count": len(speech_intervals),
                    "speech_sec": total_speech_sec,
                    "speech_ratio": round(total_speech_sec / duration_sec, 4) if duration_sec else 0.0,
                    "fallback_chunk_count": vad_fallback_chunks,
                },
                "asr_cleanup": {
                    "enabled": True,
                    "rule": "collapse_consecutive_identical_sentences_min4_keep1",
                    "changed_chunk_count": len(cleanup_events),
                    "removed_repetition_count": sum(
                        event["removed_repetitions"] for event in cleanup_events
                    ),
                },
                "asr_repetition_retry": {
                    "enabled": generate_settings["repetition_retry_enabled"],
                    "trigger_rule": "ngram_coverage>=0.35_and_count>=8",
                    "triggered_chunk_count": len(retry_events),
                    "accepted_retry_count": sum(
                        1 for event in retry_events if event["accepted_retry"]
                    ),
                    "events": retry_events,
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
                "duration_sec": transcript["audio_duration_sec"],
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
