#!/usr/bin/env python3

import os
import re
from pathlib import Path


RULE_VERSION = "20260702"
ENGINE = "wetext_rules_conservative_fst"
MODE = "conservative"

_NORMALIZERS = {}


def resolve_resources_root():
    return Path(__file__).resolve().parents[1]


def resolve_fst_root():
    candidates = []
    override = os.environ.get("AURAL_ITN_FST_ROOT")
    if override:
        candidates.append(Path(override).expanduser())

    resources_root = resolve_resources_root()
    candidates.append(resources_root / "itn" / "custom_wetext_fsts")
    return next((candidate for candidate in candidates if candidate.exists()), candidates[0])


def requested_language(language):
    if not language or language == "auto":
        return None
    lowered = language.lower()
    if lowered.startswith("zh"):
        return "zh"
    if lowered.startswith("ja") or lowered.startswith("jp"):
        return "ja"
    if lowered.startswith("en"):
        return "en"
    if lowered.startswith("yue"):
        return "yue"
    return None


def detect_language(text):
    if re.search(r"[\u3040-\u30ff]", text):
        return "ja"
    if re.search(r"[\u3400-\u4dbf\u4e00-\u9fff]", text):
        return "zh"
    if re.search(r"[A-Za-z]", text):
        return "en"
    return "zh"


def language_for_text(text, language):
    return requested_language(language) or detect_language(text)


def fst_path_for_language(language):
    root = resolve_fst_root()
    if language == "zh":
        return root / "zh" / "itn" / "tagger_no_standalone.fst"
    if language == "ja":
        return root / "ja" / "itn" / "tagger_no_standalone.fst"
    if language == "en":
        return root / "en" / "itn" / "tagger_rules_conservative.fst"
    return None


def normalizer_for_language(language):
    if language in _NORMALIZERS:
        return _NORMALIZERS[language]

    fst_path = fst_path_for_language(language)
    if fst_path is None:
        raise RuntimeError(f"unsupported_itn_language:{language}")
    if not fst_path.exists():
        raise RuntimeError(f"itn_fst_missing:{fst_path}")

    from kaldifst import TextNormalizer

    normalizer = TextNormalizer(str(fst_path))
    _NORMALIZERS[language] = normalizer
    return normalizer


def normalize_text(text, language):
    clean = text.strip()
    if not clean:
        return clean

    from wetext.utils import postprocess, preprocess, reorder, verbalize

    normalizer = normalizer_for_language(language)
    normalized_input = preprocess(clean, traditional_to_simple=False)
    tagged = normalizer(normalized_input).strip()
    reordered = reorder(tagged, language, "itn")
    output = verbalize(reordered, language, "itn")
    return postprocess(output).strip() or clean


def normalize_spaced_acronyms(text):
    def replace(match):
        compact = re.sub(r"\s+", "", match.group(0))
        if 2 <= len(compact) <= 8 and compact.isupper():
            return compact
        return match.group(0)

    return re.sub(r"(?<![A-Za-z])(?:[A-Z]\s+){1,7}[A-Z](?![a-z])", replace, text)


def apply_itn(text, language):
    raw_text = text or ""
    normalized_text = raw_text
    resolved_language = language_for_text(raw_text, language)

    metadata = {
        "enabled": True,
        "mode": MODE,
        "engine": ENGINE,
        "language": resolved_language,
        "rule_version": RULE_VERSION,
        "status": "ok",
    }

    if resolved_language == "yue":
        metadata["enabled"] = False
        metadata["status"] = "skipped_unsupported_language"
        return normalized_text, metadata

    if resolved_language not in {"zh", "ja", "en"}:
        metadata["enabled"] = False
        metadata["status"] = "skipped_unknown_language"
        return normalized_text, metadata

    try:
        normalized_text = normalize_text(raw_text, resolved_language)
    except Exception as exc:  # noqa: BLE001 - transcript should survive ITN fallback.
        metadata["status"] = f"error_fallback_raw:{type(exc).__name__}:{exc}"
        normalized_text = raw_text

    normalized_text = normalize_spaced_acronyms(normalized_text)

    return normalized_text, metadata


def apply_itn_to_transcript(transcript, language=None):
    segments = transcript.get("segments") or []
    raw_full_text = transcript.get("text") or "\n".join(
        str(segment.get("text", "")).strip()
        for segment in segments
        if str(segment.get("text", "")).strip()
    )
    resolved_language = language_for_text(raw_full_text, language)

    normalized_segments = []
    statuses = []
    for segment in segments:
        raw_segment_text = str(segment.get("text", "")).strip()
        normalized_segment_text, segment_itn = apply_itn(raw_segment_text, resolved_language)
        statuses.append(segment_itn.get("status", "ok"))

        next_segment = dict(segment)
        next_segment["raw_text"] = raw_segment_text
        next_segment["text"] = normalized_segment_text
        normalized_segments.append(next_segment)

    normalized_text = "\n".join(
        str(segment.get("text", "")).strip()
        for segment in normalized_segments
        if str(segment.get("text", "")).strip()
    )
    if not normalized_segments:
        normalized_text, full_itn = apply_itn(raw_full_text, resolved_language)
        statuses.append(full_itn.get("status", "ok"))

    status = "ok" if statuses and all(item == "ok" for item in statuses) else (statuses[0] if statuses else "ok")
    itn_metadata = {
        "enabled": True,
        "mode": MODE,
        "engine": ENGINE,
        "language": resolved_language,
        "rule_version": RULE_VERSION,
        "status": status,
    }
    if resolved_language == "yue":
        itn_metadata["enabled"] = False
        itn_metadata["status"] = "skipped_unsupported_language"
    elif resolved_language not in {"zh", "ja", "en"}:
        itn_metadata["enabled"] = False
        itn_metadata["status"] = "skipped_unknown_language"
    elif any(item.startswith("error_fallback_raw") for item in statuses):
        itn_metadata["status"] = next(item for item in statuses if item.startswith("error_fallback_raw"))

    next_transcript = dict(transcript)
    next_transcript["segments"] = normalized_segments
    next_transcript["raw_text"] = raw_full_text
    next_transcript["normalized_text"] = normalized_text
    next_transcript["text"] = normalized_text
    next_transcript["itn"] = itn_metadata
    metadata = dict(next_transcript.get("metadata") or {})
    metadata["itn"] = itn_metadata
    next_transcript["metadata"] = metadata
    return next_transcript
