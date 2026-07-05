#!/usr/bin/env python3

import importlib.util
import sys
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[1]
WORKER_PATH = ROOT_DIR / "AuralASRWorker" / "worker_qwen_direct_bundle.py"

spec = importlib.util.spec_from_file_location("worker_qwen_direct_bundle", WORKER_PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

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
