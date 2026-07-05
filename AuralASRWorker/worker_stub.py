#!/usr/bin/env python3

import json
import os
import sys
import time
from datetime import datetime, timezone

from itn_postprocess import apply_itn_to_transcript


def emit(event):
    print(json.dumps(event, ensure_ascii=False), flush=True)


def fail(request, output_dir, code):
    os.makedirs(output_dir, exist_ok=True)
    error_log_path = os.path.join(output_dir, "error.log")
    with open(error_log_path, "w", encoding="utf-8") as handle:
        handle.write(f"{datetime.now(timezone.utc).isoformat()} {code}\n")
    emit(
        {
            "type": "failed",
            "request_id": request["request_id"],
            "task_id": request["task_id"],
            "error_code": code,
            "error_log_path": error_log_path,
        }
    )


def transcribe(request):
    audio_path = request["audio_path"]
    output_dir = request["output_dir"]
    os.makedirs(output_dir, exist_ok=True)

    with open(audio_path, "rb") as handle:
        marker = handle.read(4096)

    if "fail" in os.path.basename(audio_path).lower() or b"aural-stub-fail" in marker:
        fail(request, output_dir, "asr_runtime_error")
        return

    total_segments = 3
    for completed in range(1, total_segments + 1):
        time.sleep(0.05)
        emit(
            {
                "type": "progress",
                "request_id": request["request_id"],
                "task_id": request["task_id"],
                "stage": "transcribing",
                "completed_segments": completed,
                "total_segments": total_segments,
            }
        )

    segments = [
        {
            "start_sec": 0.0,
            "end_sec": 12.0,
            "text": "今天主要讨论的是本地转写工具的核心范围。",
        },
        {
            "start_sec": 12.0,
            "end_sec": 28.0,
            "text": "用户拖入音频后，系统自动在本机完成转写，不需要额外设置。",
        },
        {
            "start_sec": 28.0,
            "end_sec": 42.0,
            "text": "左侧列表负责选择任务和查看状态，右侧保留音频播放和转写内容。",
        },
    ]
    transcript = {
        "task_id": request["task_id"],
        "audio_duration_sec": 42.0,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "segments": segments,
        "text": "\n".join(segment["text"] for segment in segments),
    }
    transcript = apply_itn_to_transcript(transcript, request.get("language") or "auto")
    transcript_path = os.path.join(output_dir, "transcript.json")
    with open(transcript_path, "w", encoding="utf-8") as handle:
        json.dump(transcript, handle, ensure_ascii=False, indent=2)

    emit(
        {
            "type": "completed",
            "request_id": request["request_id"],
            "task_id": request["task_id"],
            "transcript_path": transcript_path,
            "duration_sec": 42.0,
        }
    )


def main():
    for line in sys.stdin:
        if not line.strip():
            continue
        request = json.loads(line)
        if request.get("type") != "transcribe":
            fail(request, request.get("output_dir", "."), "unsupported_request")
            continue
        transcribe(request)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"worker_stub_error: {exc}", file=sys.stderr)
        sys.exit(1)
