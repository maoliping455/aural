#!/usr/bin/env python3

import argparse
import json
import os
import shutil
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path


ASR_MODEL_SPECS = {
    "fast": {
        "key": "asr",
        "name": "本地转写资源",
        "directory": "qwen3-asr-0.6b-4bit",
        "modelscope_env": "AURAL_MODELSCOPE_ASR_MODEL_FAST",
        "huggingface_env": "AURAL_HF_ASR_MODEL_FAST",
        "modelscope_id": "mlx-community/Qwen3-ASR-0.6B-4bit",
        "huggingface_id": "mlx-community/Qwen3-ASR-0.6B-4bit",
        "min_safetensors_bytes": 500_000_000,
        "expected_size_bytes": 760_000_000,
        "required_files": [
            "config.json",
            "generation_config.json",
            "model.safetensors",
            "model.safetensors.index.json",
            "tokenizer_config.json",
            "vocab.json",
            "merges.txt",
        ],
    },
    "balanced": {
        "key": "asr",
        "name": "本地转写资源",
        "directory": "qwen3-asr-1.7b-4bit",
        "modelscope_env": "AURAL_MODELSCOPE_ASR_MODEL",
        "huggingface_env": "AURAL_HF_ASR_MODEL",
        "modelscope_id": "mlx-community/Qwen3-ASR-1.7B-4bit",
        "huggingface_id": "mlx-community/Qwen3-ASR-1.7B-4bit",
        "min_safetensors_bytes": 1_000_000_000,
        "expected_size_bytes": 1_610_000_000,
        "required_files": [
            "config.json",
            "generation_config.json",
            "model.safetensors",
            "model.safetensors.index.json",
            "tokenizer_config.json",
            "vocab.json",
            "merges.txt",
        ],
    },
    "accurate": {
        "key": "asr",
        "name": "本地转写资源",
        "directory": "qwen3-asr-1.7b-bf16",
        "modelscope_env": "AURAL_MODELSCOPE_ASR_MODEL_ACCURATE",
        "huggingface_env": "AURAL_HF_ASR_MODEL_ACCURATE",
        "modelscope_id": "mlx-community/Qwen3-ASR-1.7B-bf16",
        "huggingface_id": "mlx-community/Qwen3-ASR-1.7B-bf16",
        "min_safetensors_bytes": 3_000_000_000,
        "expected_size_bytes": 4_080_000_000,
        "required_files": [
            "config.json",
            "generation_config.json",
            "model.safetensors",
            "model.safetensors.index.json",
            "tokenizer_config.json",
            "vocab.json",
            "merges.txt",
        ],
    },
}

ALIGNER_MODEL_SPEC = {
        "key": "aligner",
        "name": "时间戳对齐资源",
        "directory": "qwen3-forcedaligner-0.6b-4bit-mlx",
        "modelscope_env": "AURAL_MODELSCOPE_ALIGNER_MODEL",
        "huggingface_env": "AURAL_HF_ALIGNER_MODEL",
        "modelscope_id": "mlx-community/Qwen3-ForcedAligner-0.6B-4bit",
        "huggingface_id": "mlx-community/Qwen3-ForcedAligner-0.6B-4bit",
        "min_safetensors_bytes": 500_000_000,
        "expected_size_bytes": 1_000_000_000,
        "required_files": [
            "config.json",
            "generation_config.json",
            "model.safetensors",
            "model.safetensors.index.json",
            "tokenizer_config.json",
            "vocab.json",
            "merges.txt",
        ],
}


def model_specs(profile, include_aligner=True):
    try:
        asr_spec = ASR_MODEL_SPECS[profile]
    except KeyError as exc:
        raise ValueError(f"unsupported profile: {profile}") from exc
    specs = [asr_spec]
    if include_aligner:
        specs.append(ALIGNER_MODEL_SPEC)
    return specs


def expected_total_bytes(profile, include_aligner=True):
    return sum(spec["expected_size_bytes"] for spec in model_specs(profile, include_aligner=include_aligner))


def emit(event):
    event.setdefault("created_at", datetime.now(timezone.utc).isoformat())
    print(json.dumps(event, ensure_ascii=False), flush=True)


def directory_bytes(path):
    if not path.exists():
        return 0
    total = 0
    for item in path.rglob("*"):
        try:
            if item.is_file() or item.is_symlink():
                total += item.stat().st_size
        except OSError:
            pass
    return total


def downloaded_bytes(model_root, profile, include_aligner=True):
    total = 0
    for spec in model_specs(profile, include_aligner=include_aligner):
        path = model_dir(model_root, spec)
        if is_complete(path, spec):
            total += spec["expected_size_bytes"]
        else:
            total += min(directory_bytes(path), spec["expected_size_bytes"])
    return min(total, expected_total_bytes(profile, include_aligner=include_aligner))


def emit_progress(model_root, profile, include_aligner=True, active_model=None):
    expected_bytes = expected_total_bytes(profile, include_aligner=include_aligner)
    downloaded = downloaded_bytes(model_root, profile, include_aligner=include_aligner)
    emit(
        {
            "type": "download_progress",
            "model": active_model,
            "profile": profile,
            "downloaded_bytes": downloaded,
            "total_bytes": expected_bytes,
            "progress": round(downloaded / expected_bytes, 4) if expected_bytes else 0,
        }
    )


def model_dir(model_root, spec):
    return model_root / spec["directory"]


def marker_path(path):
    return path / ".aural-complete.json"


def is_complete(path, spec):
    if not path.is_dir():
        return False
    for filename in spec["required_files"]:
        if not (path / filename).is_file():
            return False
    weights = path / "model.safetensors"
    try:
        if weights.stat().st_size < spec["min_safetensors_bytes"]:
            return False
    except OSError:
        return False
    return True


def write_marker(path, spec, source):
    marker = {
        "model": spec["key"],
        "directory": spec["directory"],
        "source": source,
        "completed_at": datetime.now(timezone.utc).isoformat(),
        "required_files": spec["required_files"],
    }
    marker_path(path).write_text(
        json.dumps(marker, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def source_model_id(spec, source):
    if source == "modelscope":
        return os.environ.get(spec["modelscope_env"]) or spec["modelscope_id"]
    if source == "huggingface":
        return os.environ.get(spec["huggingface_env"]) or spec["huggingface_id"]
    raise ValueError(source)


def download_from_modelscope(spec, target_dir, max_workers):
    from modelscope.hub.snapshot_download import snapshot_download

    snapshot_download(
        model_id=source_model_id(spec, "modelscope"),
        local_dir=str(target_dir),
        max_workers=max_workers,
    )


def download_from_huggingface(spec, target_dir, max_workers):
    from huggingface_hub import snapshot_download

    snapshot_download(
        repo_id=source_model_id(spec, "huggingface"),
        local_dir=str(target_dir),
        max_workers=max_workers,
    )


def prepare_one(model_root, profile, include_aligner, spec, retries, max_workers):
    target_dir = model_dir(model_root, spec)
    if is_complete(target_dir, spec):
        write_marker(target_dir, spec, "existing")
        emit_progress(model_root, profile, include_aligner=include_aligner, active_model=spec["key"])
        emit(
            {
                "type": "model_ready",
                "model": spec["key"],
                "name": spec["name"],
                "profile": profile,
                "path": str(target_dir),
            }
        )
        return

    if target_dir.exists() or target_dir.is_symlink():
        if not target_dir.is_dir():
            raise RuntimeError(f"model path exists but is not a directory: {target_dir}")
    else:
        target_dir.mkdir(parents=True, exist_ok=True)
    sources = [
        ("modelscope", download_from_modelscope),
        ("huggingface", download_from_huggingface),
    ]
    errors = []

    for source, downloader in sources:
        for attempt in range(1, retries + 1):
            emit_progress(model_root, profile, include_aligner=include_aligner, active_model=spec["key"])
            emit(
                {
                    "type": "download_started",
                    "model": spec["key"],
                    "name": spec["name"],
                    "profile": profile,
                    "source": source,
                    "attempt": attempt,
                    "model_id": source_model_id(spec, source),
                }
            )
            try:
                stop_progress = threading.Event()

                def progress_monitor():
                    while not stop_progress.wait(1.0):
                        emit_progress(model_root, profile, include_aligner=include_aligner, active_model=spec["key"])

                monitor_thread = threading.Thread(target=progress_monitor, daemon=True)
                monitor_thread.start()
                try:
                    downloader(spec, target_dir, max_workers)
                finally:
                    stop_progress.set()
                    monitor_thread.join(timeout=2)
                    emit_progress(model_root, profile, include_aligner=include_aligner, active_model=spec["key"])
                if not is_complete(target_dir, spec):
                    raise RuntimeError("download finished but required model files are incomplete")
                write_marker(target_dir, spec, source)
                emit_progress(model_root, profile, include_aligner=include_aligner, active_model=spec["key"])
                emit(
                    {
                        "type": "model_ready",
                        "model": spec["key"],
                        "name": spec["name"],
                        "profile": profile,
                        "source": source,
                        "path": str(target_dir),
                    }
                )
                return
            except Exception as exc:
                message = repr(exc)
                errors.append(f"{source} attempt {attempt}: {message}")
                emit(
                    {
                        "type": "download_retry",
                        "model": spec["key"],
                        "name": spec["name"],
                        "profile": profile,
                        "source": source,
                        "attempt": attempt,
                        "message": message[:500],
                    }
                )
                if attempt < retries:
                    time.sleep(min(3 * attempt, 10))

    raise RuntimeError("; ".join(errors[-4:]) or f"failed to download {spec['key']}")


def release_unused_download_cache(model_root):
    cache_dir = model_root / ".cache"
    if cache_dir.exists():
        shutil.rmtree(cache_dir, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-root", required=True)
    parser.add_argument(
        "--profile",
        choices=sorted(ASR_MODEL_SPECS.keys()),
        default=os.environ.get("AURAL_MODEL_PROFILE", "balanced"),
    )
    parser.add_argument(
        "--include-aligner",
        dest="include_aligner",
        action="store_true",
        default=os.environ.get("AURAL_ALIGNMENT_ENABLED", "1").lower() not in {"0", "false", "no", "off"},
    )
    parser.add_argument(
        "--skip-aligner",
        dest="include_aligner",
        action="store_false",
    )
    parser.add_argument("--retries", type=int, default=int(os.environ.get("AURAL_MODEL_DOWNLOAD_RETRIES", "3")))
    parser.add_argument("--max-workers", type=int, default=int(os.environ.get("AURAL_MODEL_DOWNLOAD_WORKERS", "4")))
    args = parser.parse_args()

    model_root = Path(args.model_root).expanduser()
    model_root.mkdir(parents=True, exist_ok=True)

    emit({
        "type": "checking",
        "model_root": str(model_root),
        "profile": args.profile,
        "alignment_enabled": args.include_aligner,
    })
    try:
        for spec in model_specs(args.profile, include_aligner=args.include_aligner):
            prepare_one(
                model_root,
                args.profile,
                args.include_aligner,
                spec,
                retries=max(1, args.retries),
                max_workers=max(1, args.max_workers),
            )
        release_unused_download_cache(model_root)
        expected_bytes = expected_total_bytes(args.profile, include_aligner=args.include_aligner)
        emit(
            {
                "type": "download_progress",
                "profile": args.profile,
                "alignment_enabled": args.include_aligner,
                "downloaded_bytes": expected_bytes,
                "total_bytes": expected_bytes,
                "progress": 1.0,
            }
        )
        emit({
            "type": "completed",
            "model_root": str(model_root),
            "profile": args.profile,
            "alignment_enabled": args.include_aligner,
        })
    except Exception as exc:
        emit({
            "type": "failed",
            "message": repr(exc)[:1000],
            "model_root": str(model_root),
            "profile": args.profile,
            "alignment_enabled": args.include_aligner,
        })
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
