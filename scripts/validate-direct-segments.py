#!/usr/bin/env python3

import importlib.util
import sys
from pathlib import Path

sys.dont_write_bytecode = True

ROOT_DIR = Path(__file__).resolve().parents[1]
WORKER_DIR = ROOT_DIR / "AuralASRWorker"
WORKER_PATH = WORKER_DIR / "worker_qwen_direct_bundle.py"
sys.path.insert(0, str(WORKER_DIR))

spec = importlib.util.spec_from_file_location("worker_qwen_direct_bundle", WORKER_PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


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
    ):
        self.kwargs = {
            "audio": audio,
            "max_tokens": max_tokens,
            "verbose": verbose,
            "chunk_duration": chunk_duration,
            "repetition_penalty": repetition_penalty,
            "repetition_context_size": repetition_context_size,
            "language": language,
        }
        return "ok"


dummy_model = DummyGenerateModel()
module.generate_one(dummy_model, Path("sample.wav"), "zh")
if dummy_model.kwargs["chunk_duration"] is not None:
    raise SystemExit(f"direct ASR first pass should not request internal chunks: {dummy_model.kwargs}")
if dummy_model.kwargs["repetition_penalty"] != 1.0:
    raise SystemExit(f"direct ASR should request neutral first-pass repetition penalty: {dummy_model.kwargs}")
if dummy_model.kwargs["repetition_context_size"] != 32:
    raise SystemExit(f"direct ASR should request repetition context size: {dummy_model.kwargs}")


class RepeatingGenerateModel:
    def __init__(self):
        self.kwargs = []
        self.outputs = [
            "嗯" * 40,
            "今天主要讨论的是本地音频转写质量。动态重试只在异常重复时启用。",
        ]

    def generate(
        self,
        audio,
        max_tokens,
        verbose,
        chunk_duration=None,
        repetition_penalty=None,
        repetition_context_size=None,
        language=None,
    ):
        self.kwargs.append(
            {
                "audio": audio,
                "max_tokens": max_tokens,
                "verbose": verbose,
                "chunk_duration": chunk_duration,
                "repetition_penalty": repetition_penalty,
                "repetition_context_size": repetition_context_size,
                "language": language,
            }
        )
        return self.outputs.pop(0)


repeating_model = RepeatingGenerateModel()
retry_text, retry_event = module.generate_text_with_repetition_retry(
    repeating_model,
    Path("sample.wav"),
    "zh",
)
if len(repeating_model.kwargs) != 2:
    raise SystemExit(f"direct ASR should retry abnormal repetition once: {repeating_model.kwargs}")
if repeating_model.kwargs[0]["repetition_penalty"] != 1.0:
    raise SystemExit(f"first pass should use neutral penalty: {repeating_model.kwargs}")
if repeating_model.kwargs[0]["chunk_duration"] is not None:
    raise SystemExit(f"first pass should not request internal chunks: {repeating_model.kwargs}")
if repeating_model.kwargs[1]["repetition_penalty"] != 1.10:
    raise SystemExit(f"retry pass should use stronger repetition penalty: {repeating_model.kwargs}")
if repeating_model.kwargs[1]["chunk_duration"] is not None:
    raise SystemExit(f"retry pass should only change repetition parameters: {repeating_model.kwargs}")
if not retry_event or not retry_event["accepted_retry"] or retry_text.startswith("嗯"):
    raise SystemExit(f"direct ASR should accept non-repeating retry text: {retry_event}, {retry_text}")

text = (
    "今天主要讨论的是本地转写工具的核心范围。"
    "用户拖入音频后，系统自动完成转写，不需要额外设置。"
    "左侧列表负责选择任务和查看状态，右侧保留音频播放和转写内容。"
    "失败时只显示转写失败，不展开复杂错误。"
)

paragraphs = module.split_text_into_paragraphs(text, target_chars=35, max_chars=60)
segments = module.allocate_segments(paragraphs, 42.0)

if len(segments) < 2:
    raise SystemExit("expected at least two text-derived segments")

if segments[0]["start_sec"] != 0.0:
    raise SystemExit("first segment must start at 0")

if abs(segments[-1]["end_sec"] - 42.0) > 0.001:
    raise SystemExit("last segment must end at requested duration")

for previous, current in zip(segments, segments[1:]):
    if current["start_sec"] < previous["end_sec"] - 0.001:
        raise SystemExit("segments must be monotonic")
    if not current["text"]:
        raise SystemExit("segment text must not be empty")

print("direct segment validation passed")
