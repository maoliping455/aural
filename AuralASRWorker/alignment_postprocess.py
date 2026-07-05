#!/usr/bin/env python3

import gc
import json
import os
import re
import time
from datetime import datetime, timezone
from pathlib import Path


ALIGNER_MODEL_NAME = "mlx-community/Qwen3-ForcedAligner-0.6B-4bit"
ALIGNER_MODEL_DIRNAME = "qwen3-forcedaligner-0.6b-4bit-mlx"


def resolve_resources_root():
    return Path(__file__).resolve().parents[1]


def resolve_aligner_model_root():
    override = os.environ.get("AURAL_ALIGNER_MODEL")
    if override:
        return Path(override).expanduser()
    return resolve_resources_root() / "aligner-models" / ALIGNER_MODEL_DIRNAME


def release_mlx_memory():
    gc.collect()
    try:
        import mlx.core as mx

        mx.clear_cache()
    except Exception:
        pass


def normalize_for_alignment(text):
    value = str(text or "").lower()
    return "".join(char for char in value if char.isalnum())


def detect_aligner_language(text):
    value = str(text or "")
    if re.search(r"[\u3040-\u30ff]", value):
        return "Japanese"
    if re.search(r"[\u3400-\u4dbf\u4e00-\u9fff]", value):
        return "Chinese"
    if re.search(r"[A-Za-z]", value):
        return "English"
    return "Chinese"


def requested_aligner_language(language):
    if not language or language == "auto":
        return None
    lowered = str(language).lower()
    if lowered.startswith(("zh", "cmn")):
        return "Chinese"
    if lowered.startswith("yue"):
        return "Cantonese"
    if lowered.startswith("en"):
        return "English"
    if lowered.startswith(("ja", "jp")):
        return "Japanese"
    if lowered.startswith("ko"):
        return "Korean"
    if lowered.startswith("fr"):
        return "French"
    if lowered.startswith("de"):
        return "German"
    if lowered.startswith("it"):
        return "Italian"
    if lowered.startswith("pt"):
        return "Portuguese"
    if lowered.startswith("ru"):
        return "Russian"
    if lowered.startswith("es"):
        return "Spanish"
    return None


def language_for_chunk(language, text):
    return requested_aligner_language(language) or detect_aligner_language(text)


def result_segments(result):
    if isinstance(result, dict):
        segments = result.get("segments") or result.get("items") or []
    else:
        segments = getattr(result, "segments", None) or getattr(result, "items", None) or []

    normalized = []
    for item in segments:
        if isinstance(item, dict):
            text = item.get("text", "")
            start = item.get("start", item.get("start_time"))
            end = item.get("end", item.get("end_time"))
        else:
            text = getattr(item, "text", "")
            start = getattr(item, "start", getattr(item, "start_time", None))
            end = getattr(item, "end", getattr(item, "end_time", None))

        try:
            start = float(start)
            end = float(end)
        except (TypeError, ValueError):
            continue
        if end < start:
            continue
        normalized.append(
            {
                "text": str(text),
                "start_sec": round(start, 3),
                "end_sec": round(end, 3),
                "duration_sec": round(max(end - start, 0.0), 3),
                "norm_len": len(normalize_for_alignment(text)),
            }
        )
    return normalized


def clamp(value, lower, upper):
    return max(lower, min(upper, value))


def globalize_items(items, chunk, global_start_index):
    chunk_start = float(chunk["start_sec"])
    chunk_end = float(chunk["end_sec"])
    result = []
    for offset, item in enumerate(items):
        start = clamp(chunk_start + float(item["start_sec"]), chunk_start, chunk_end)
        end = clamp(chunk_start + float(item["end_sec"]), chunk_start, chunk_end)
        if end < start:
            end = start
        result.append(
            {
                "index": global_start_index + offset,
                "chunk_index": int(chunk["index"]),
                "text": item["text"],
                "start_sec": round(start, 3),
                "end_sec": round(end, 3),
                "duration_sec": round(max(end - start, 0.0), 3),
                "norm_len": item.get("norm_len", 0),
            }
        )
    return result


def alignment_quality(items, chunk):
    usable_items = [item for item in items if item.get("norm_len", 0) > 0]
    usable_count = len(usable_items)
    if usable_count <= 0:
        return {"ok": False, "reason": "no_usable_items", "usable_item_count": 0}

    zero_duration_count = sum(
        1 for item in usable_items if float(item.get("duration_sec", 0.0)) <= 0.005
    )
    zero_duration_ratio = zero_duration_count / usable_count

    max_same_time_run = 1
    current_run = 1
    previous_key = None
    for item in usable_items:
        key = (round(float(item["start_sec"]), 2), round(float(item["end_sec"]), 2))
        if key == previous_key:
            current_run += 1
        else:
            current_run = 1
            previous_key = key
        max_same_time_run = max(max_same_time_run, current_run)

    span_start = min(float(item["start_sec"]) for item in usable_items)
    span_end = max(float(item["end_sec"]) for item in usable_items)
    aligned_span_sec = max(span_end - span_start, 0.0)
    chunk_duration_sec = max(float(chunk["end_sec"]) - float(chunk["start_sec"]), 0.0)
    coverage_ratio = aligned_span_sec / chunk_duration_sec if chunk_duration_sec > 0 else 0.0

    metrics = {
        "usable_item_count": usable_count,
        "zero_duration_count": zero_duration_count,
        "zero_duration_ratio": round(zero_duration_ratio, 4),
        "max_same_time_run": max_same_time_run,
        "coverage_ratio": round(coverage_ratio, 4),
    }

    if usable_count >= 20 and zero_duration_ratio >= 0.35:
        return {**metrics, "ok": False, "reason": "excessive_zero_duration_items"}
    if max_same_time_run >= 12:
        return {**metrics, "ok": False, "reason": "timestamp_collapse"}
    if chunk_duration_sec >= 20 and coverage_ratio < 0.25:
        return {**metrics, "ok": False, "reason": "low_alignment_coverage"}
    return {**metrics, "ok": True, "reason": "ok"}


def paragraph_segments_from_items(paragraphs, items, global_item_start):
    if not paragraphs or not items:
        return None

    paragraph_lengths = [len(normalize_for_alignment(paragraph)) for paragraph in paragraphs]
    if sum(paragraph_lengths) <= 0:
        return None

    usable_items = [item for item in items if item.get("norm_len", 0) > 0]
    if not usable_items:
        return None

    if len(paragraphs) == 1:
        return [
            {
                "start_sec": round(float(usable_items[0]["start_sec"]), 3),
                "end_sec": round(float(usable_items[-1]["end_sec"]), 3),
                "text": paragraphs[0],
                "alignment_item_start": usable_items[0]["index"],
                "alignment_item_end": usable_items[-1]["index"] + 1,
            }
        ]

    segments = []
    item_cursor = 0
    for paragraph_index, paragraph in enumerate(paragraphs):
        while item_cursor < len(items) and items[item_cursor].get("norm_len", 0) <= 0:
            item_cursor += 1
        if item_cursor >= len(items):
            return None

        start_item_index = item_cursor
        if paragraph_index == len(paragraphs) - 1:
            end_item_index = len(items) - 1
        else:
            target_len = max(paragraph_lengths[paragraph_index], 1)
            accumulated = 0
            end_item_index = item_cursor
            while end_item_index < len(items):
                accumulated += max(items[end_item_index].get("norm_len", 0), 0)
                if accumulated >= target_len:
                    break
                end_item_index += 1
            if end_item_index >= len(items):
                return None

        start_sec = float(items[start_item_index]["start_sec"])
        end_sec = float(items[end_item_index]["end_sec"])
        if end_sec < start_sec:
            return None

        segments.append(
            {
                "start_sec": round(start_sec, 3),
                "end_sec": round(end_sec, 3),
                "text": paragraph,
                "alignment_item_start": items[start_item_index]["index"],
                "alignment_item_end": items[end_item_index]["index"] + 1,
            }
        )
        item_cursor = end_item_index + 1

    for left, right in zip(segments, segments[1:]):
        if left["end_sec"] > right["start_sec"]:
            return None
    return segments


def fallback_segments(chunk_records):
    segments = []
    for chunk in chunk_records:
        segments.extend(chunk.get("fallback_segments") or [])
    return segments


def metadata(
    status,
    *,
    enabled=True,
    language=None,
    chunk_count=0,
    failed_chunk_count=0,
    aligned_chunk_count=0,
    wall_sec=0.0,
    alignment_path=None,
    error=None,
    quality=None,
):
    model_root = resolve_aligner_model_root()
    result = {
        "enabled": enabled,
        "engine": "qwen3_forced_aligner",
        "runtime": "mlx_audio",
        "model": ALIGNER_MODEL_NAME,
        "model_path": str(model_root),
        "language": language,
        "level": "char_or_word",
        "status": status,
        "chunk_count": chunk_count,
        "aligned_chunk_count": aligned_chunk_count,
        "failed_chunk_count": failed_chunk_count,
        "wall_sec": round(wall_sec, 3),
    }
    if alignment_path:
        result["alignment_path"] = alignment_path
    if error:
        result["error"] = str(error)[:500]
    if quality:
        result["quality"] = quality
    return result


def refine_segments_with_alignment(chunk_records, output_dir, language=None, progress_callback=None):
    started_at = time.time()
    output_dir = Path(output_dir)
    model_root = resolve_aligner_model_root()
    chunk_count = len(chunk_records)

    if progress_callback:
        progress_callback(0, chunk_count)

    if not chunk_records:
        return {
            "segments": [],
            "timestamp_method": None,
            "metadata": metadata("skipped_empty_transcript", enabled=False, chunk_count=0),
            "alignment_path": None,
        }

    if not model_root.exists():
        return {
            "segments": fallback_segments(chunk_records),
            "timestamp_method": None,
            "metadata": metadata(
                "error_fallback_estimated",
                enabled=False,
                chunk_count=chunk_count,
                failed_chunk_count=chunk_count,
                wall_sec=time.time() - started_at,
                error=f"aligner model not found: {model_root}",
            ),
            "alignment_path": None,
        }

    try:
        from mlx_audio.stt import load

        model = load(str(model_root))
    except Exception as exc:
        return {
            "segments": fallback_segments(chunk_records),
            "timestamp_method": None,
            "metadata": metadata(
                "error_fallback_estimated",
                enabled=False,
                chunk_count=chunk_count,
                failed_chunk_count=chunk_count,
                wall_sec=time.time() - started_at,
                error=repr(exc),
            ),
            "alignment_path": None,
        }

    refined_segments = []
    alignment_items = []
    alignment_chunks = []
    aligned_chunk_count = 0
    failed_chunk_count = 0
    failure_reasons = []
    last_language = None

    try:
        for chunk in chunk_records:
            chunk_language = language_for_chunk(language, chunk.get("text", ""))
            last_language = chunk_language
            chunk_status = "ok"
            chunk_error = None
            chunk_items_start = len(alignment_items)
            try:
                result = model.generate(
                    audio=str(chunk["audio_path"]),
                    text=chunk["text"],
                    language=chunk_language,
                    verbose=False,
                )
                local_items = result_segments(result)
                global_items = globalize_items(local_items, chunk, len(alignment_items))
                quality = alignment_quality(global_items, chunk)
                if not quality.get("ok"):
                    raise RuntimeError(
                        "alignment quality rejected: "
                        f"{quality.get('reason')} "
                        f"zero_duration_ratio={quality.get('zero_duration_ratio')} "
                        f"max_same_time_run={quality.get('max_same_time_run')} "
                        f"coverage_ratio={quality.get('coverage_ratio')}"
                    )
                paragraph_segments = paragraph_segments_from_items(
                    chunk.get("paragraphs") or [chunk["text"]],
                    global_items,
                    0,
                )
                if not paragraph_segments:
                    raise RuntimeError("alignment produced no usable paragraph boundaries")

                refined_segments.extend(paragraph_segments)
                alignment_items.extend(global_items)
                aligned_chunk_count += 1
            except Exception as exc:
                chunk_status = "error_fallback_estimated"
                chunk_error = repr(exc)
                failure_reasons.append(chunk_error)
                failed_chunk_count += 1
                refined_segments.extend(chunk.get("fallback_segments") or [])

            alignment_chunks.append(
                {
                    "index": int(chunk["index"]),
                    "start_sec": round(float(chunk["start_sec"]), 3),
                    "end_sec": round(float(chunk["end_sec"]), 3),
                    "language": chunk_language,
                    "status": chunk_status,
                    "alignment_item_start": chunk_items_start,
                    "alignment_item_end": len(alignment_items),
                    **({"error": chunk_error[:500]} if chunk_error else {}),
                }
            )
            if progress_callback:
                progress_callback(int(chunk["index"]), chunk_count)
    finally:
        del model
        release_mlx_memory()

    if aligned_chunk_count <= 0:
        return {
            "segments": fallback_segments(chunk_records),
            "timestamp_method": None,
            "metadata": metadata(
                "error_fallback_estimated",
                chunk_count=chunk_count,
                failed_chunk_count=failed_chunk_count,
                wall_sec=time.time() - started_at,
                language=last_language,
                error=failure_reasons[0] if failure_reasons else "all alignment chunks failed",
                quality={"rejected_chunk_count": failed_chunk_count},
            ),
            "alignment_path": None,
        }

    status = "ok" if failed_chunk_count == 0 else "partial_fallback_estimated"
    alignment_path = output_dir / "alignment.json"
    persisted_items = [
        {key: value for key, value in item.items() if key != "norm_len"}
        for item in alignment_items
    ]
    alignment_payload = {
        "version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "model": ALIGNER_MODEL_NAME,
        "runtime": "mlx_audio",
        "status": status,
        "chunks": alignment_chunks,
        "items": persisted_items,
    }
    alignment_path.write_text(
        json.dumps(alignment_payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    return {
        "segments": refined_segments,
        "timestamp_method": "qwen3_forced_aligner_paragraph",
        "metadata": metadata(
            status,
            language=last_language,
            chunk_count=chunk_count,
            failed_chunk_count=failed_chunk_count,
            aligned_chunk_count=aligned_chunk_count,
            wall_sec=time.time() - started_at,
            alignment_path="alignment.json",
            quality={"rejected_chunk_count": failed_chunk_count},
        ),
        "alignment_path": str(alignment_path),
    }
