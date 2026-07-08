#!/usr/bin/env python3

import importlib.util
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True

ROOT_DIR = Path(__file__).resolve().parents[1]
RUNTIME_PYTHON = ROOT_DIR / ".build" / "release" / "Aural.app" / "Contents" / "Resources" / "runtime" / "bin" / "python3"
DEV_PYTHON = Path(os.environ["AURAL_DEV_PYTHON"]).expanduser() if os.environ.get("AURAL_DEV_PYTHON") else None

if not os.environ.get("AURAL_SEGMENTED_VALIDATION_BOOTSTRAPPED"):
    for candidate in [RUNTIME_PYTHON, DEV_PYTHON]:
        if (
            candidate is not None
            and candidate.is_file()
            and os.access(candidate, os.X_OK)
            and Path(sys.executable).resolve() != candidate.resolve()
        ):
            env = dict(os.environ)
            env["AURAL_SEGMENTED_VALIDATION_BOOTSTRAPPED"] = "1"
            os.execve(str(candidate), [str(candidate), __file__], env)

import numpy as np


WORKER_PATH = ROOT_DIR / "AuralASRWorker" / "worker_qwen_segmented_bundle.py"
sys.path.insert(0, str(WORKER_PATH.parent))

spec = importlib.util.spec_from_file_location("worker_qwen_segmented_bundle", WORKER_PATH)
worker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(worker)

from itn_postprocess import normalize_spaced_acronyms

if normalize_spaced_acronyms("我觉得都都O K的，A I也可以。") != "我觉得都都OK的，AI也可以。":
    raise SystemExit("spaced acronym cleanup should merge uppercase letter acronyms")
if normalize_spaced_acronyms("保留A B测试和C P U") != "保留AB测试和CPU":
    raise SystemExit("spaced acronym cleanup should not depend on acronym whitelist")
if normalize_spaced_acronyms("不要影响ABCword") != "不要影响ABCword":
    raise SystemExit("spaced acronym cleanup should preserve normal English boundaries")


class DummyGenerateModel:
    def __init__(self):
        self.kwargs = None

    def generate(
        self,
        audio,
        max_tokens,
        verbose,
        chunk_duration=None,
        repetition_penalty=None,
        repetition_context_size=None,
        language=None,
        system_prompt=None,
    ):
        self.kwargs = {
            "audio": audio,
            "max_tokens": max_tokens,
            "verbose": verbose,
            "chunk_duration": chunk_duration,
            "repetition_penalty": repetition_penalty,
            "repetition_context_size": repetition_context_size,
            "language": language,
            "system_prompt": system_prompt,
        }
        return "ok"


dummy_model = DummyGenerateModel()
worker.generate_one(dummy_model, Path("sample.wav"), "zh", system_prompt="prompt")
if dummy_model.kwargs["chunk_duration"] != 30.0:
    raise SystemExit(f"segmented ASR should request 30s generation chunks: {dummy_model.kwargs}")
if dummy_model.kwargs["repetition_penalty"] != 1.10:
    raise SystemExit(f"segmented ASR should request conservative repetition penalty: {dummy_model.kwargs}")
if dummy_model.kwargs["repetition_context_size"] != 32:
    raise SystemExit(f"segmented ASR should request repetition context size: {dummy_model.kwargs}")

previous_profile = os.environ.get("AURAL_MODEL_PROFILE")
os.environ["AURAL_MODEL_PROFILE"] = "accurate"
try:
    accurate_model = DummyGenerateModel()
    worker.generate_one(accurate_model, Path("sample.wav"), "zh")
    if accurate_model.kwargs["repetition_penalty"] is not None:
        raise SystemExit(f"accurate ASR should not request default repetition penalty: {accurate_model.kwargs}")
finally:
    if previous_profile is None:
        os.environ.pop("AURAL_MODEL_PROFILE", None)
    else:
        os.environ["AURAL_MODEL_PROFILE"] = previous_profile

sample_rate = 16000
duration_sec = 260
t = np.linspace(0, duration_sec, sample_rate * duration_sec, endpoint=False)
speech = 0.15 * np.sin(2 * np.pi * 220 * t).astype("float32")
samples = speech.copy()

samples[sample_rate * 115 : sample_rate * 121] = 0
samples[sample_rate * 236 : sample_rate * 242] = 0

default_segments, _ = worker.build_audio_segments(samples, sample_rate)
if len(default_segments) < 3:
    raise SystemExit(f"default 60/90 segmentation should produce multiple chunks: {default_segments}")
for segment in default_segments:
    length = segment["end_sec"] - segment["start_sec"]
    if length > worker.OUTER_CHUNK_MAX_SEC + 0.001:
        raise SystemExit(f"default segment exceeds max chunk duration: {segment}")

segments, duration = worker.build_audio_segments(
    samples,
    sample_rate,
    target_sec=120,
    max_sec=180,
    min_sec=20,
)

if round(duration) != duration_sec:
    raise SystemExit(f"unexpected duration: {duration}")
if len(segments) < 2:
    raise SystemExit(f"expected at least 2 segments, got {segments}")
if segments[0]["start_sec"] != 0:
    raise SystemExit(f"first segment should start at 0: {segments}")
if segments[-1]["end_sec"] != round(duration, 3):
    raise SystemExit(f"last segment should end at duration: {segments[-1]}")
for left, right in zip(segments, segments[1:]):
    if left["end_sec"] > right["start_sec"]:
        raise SystemExit(f"segments overlap: {left} {right}")

speech_intervals = worker.detect_speech_intervals(samples, sample_rate)
if len(speech_intervals) < 3:
    raise SystemExit(f"expected speech intervals around synthetic silences, got {speech_intervals}")
if worker.speech_duration(speech_intervals) >= duration_sec:
    raise SystemExit(f"speech duration should exclude silence: {speech_intervals}")

paragraph_segments = worker.allocate_paragraph_segments(
    ["第一段文字。", "第二段文字稍微长一点。"],
    10,
    20,
)
if paragraph_segments[0]["start_sec"] != 10 or paragraph_segments[-1]["end_sec"] != 20:
    raise SystemExit(f"paragraph allocation broke bounds: {paragraph_segments}")

speech_weighted_segments, used_fallback = worker.allocate_paragraph_segments_by_speech(
    ["第一段文字。", "第二段文字。"],
    10,
    20,
    [
        {"start_sec": 10, "end_sec": 14},
        {"start_sec": 16, "end_sec": 20},
    ],
)
if used_fallback:
    raise SystemExit("speech-weighted allocation should not fallback")
if speech_weighted_segments[0]["end_sec"] != 14 or speech_weighted_segments[1]["start_sec"] != 16:
    raise SystemExit(f"speech-weighted allocation should skip silence: {speech_weighted_segments}")

fallback_segments, used_fallback = worker.allocate_paragraph_segments_by_speech(
    ["第一段文字。", "第二段文字。"],
    10,
    20,
    [],
)
if not used_fallback or fallback_segments[0]["start_sec"] != 10 or fallback_segments[-1]["end_sec"] != 20:
    raise SystemExit(f"empty speech intervals should fallback: {fallback_segments}")

print("segmented worker validation passed")
