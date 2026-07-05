#!/usr/bin/env python3

import os
import sys
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[1]
RUNTIME_PYTHON = ROOT_DIR / ".build" / "release" / "Aural.app" / "Contents" / "Resources" / "runtime" / "bin" / "python3"
DEV_PYTHON = Path(os.environ["AURAL_DEV_PYTHON"]).expanduser() if os.environ.get("AURAL_DEV_PYTHON") else None
FST_ROOT = (
    Path(os.environ["AURAL_ITN_FST_ROOT"]).expanduser()
    if os.environ.get("AURAL_ITN_FST_ROOT")
    else ROOT_DIR
    / ".build"
    / "release"
    / "Aural.app"
    / "Contents"
    / "Resources"
    / "itn"
    / "custom_wetext_fsts"
)

if not os.environ.get("AURAL_ITN_VALIDATION_BOOTSTRAPPED"):
    for candidate in [RUNTIME_PYTHON, DEV_PYTHON]:
        if (
            candidate is not None
            and candidate.is_file()
            and os.access(candidate, os.X_OK)
            and Path(sys.executable).resolve() != candidate.resolve()
        ):
            env = dict(os.environ)
            env["AURAL_ITN_VALIDATION_BOOTSTRAPPED"] = "1"
            os.execve(str(candidate), [str(candidate), __file__], env)

sys.path.insert(0, str(ROOT_DIR / "AuralASRWorker"))

from itn_postprocess import apply_itn_to_transcript  # noqa: E402


def require(condition, message):
    if not condition:
        raise SystemExit(f"validation failed: {message}")


def main():
    require(FST_ROOT.exists(), f"ITN FST root should exist: {FST_ROOT}")
    os.environ["AURAL_ITN_FST_ROOT"] = str(FST_ROOT)

    raw_text = "今天是二零二六年七月二日，电话号码是一三八零零一三八零零零。"
    transcript = {
        "task_id": "itn-validation",
        "audio_duration_sec": 3.0,
        "created_at": "2026-07-03T00:00:00Z",
        "segments": [
            {
                "start_sec": 0.0,
                "end_sec": 3.0,
                "text": raw_text,
            }
        ],
        "text": raw_text,
    }

    normalized = apply_itn_to_transcript(transcript, "zh")
    segment = normalized["segments"][0]
    output_text = segment["text"]

    require(segment["raw_text"] == raw_text, "segment raw_text should preserve ASR output")
    require(normalized["raw_text"] == raw_text, "top-level raw_text should preserve ASR output")
    require(normalized["normalized_text"] == normalized["text"], "normalized_text should match displayed text")
    require("2026" in output_text and "07" in output_text and "02" in output_text, "Chinese date should normalize")
    require("13800138000" in output_text, "Chinese spoken phone number should normalize")
    require(normalized["itn"]["engine"] == "wetext_rules_conservative_fst", "ITN engine metadata")
    require(normalized["itn"]["status"] == "ok", "ITN should complete")
    require(normalized["metadata"]["itn"]["status"] == "ok", "ITN metadata should be mirrored")

    print("itn=ok")
    print(output_text)


if __name__ == "__main__":
    main()
