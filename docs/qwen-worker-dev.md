# Qwen Worker Dev Adapter

`AuralASRWorker/worker_qwen_dev.py` is a development adapter for the real local Qwen ASR path.

It preserves the Aural worker protocol:

- stdin: one `transcribe` JSON request per line
- stdout: JSON event lines only
- stderr: internal technical logs only
- terminal events: `completed` or `failed`

It can call an external local Qwen ASR script during development. This is not the final packaged runtime. It exists so the Swift app boundary can be validated against real Qwen output before the model and Python/MLX runtime are embedded inside `Aural.app`.

Override paths for development:

```bash
export AURAL_DEV_ASR_PYTHON=/path/to/python
export AURAL_DEV_ASR_SCRIPT=/path/to/qwen3_asr_transcribe.py
export AURAL_DEV_ASR_MODEL=/path/to/qwen3-asr-1.7b-4bit
```

The adapter always normalizes ASR output into:

```text
tasks/<task_id>/transcript.json
```

with Aural's transcript schema:

```json
{
  "task_id": "...",
  "audio_duration_sec": 42.0,
  "created_at": "...",
  "segments": [
    {"start_sec": 0.0, "end_sec": 12.0, "text": "..."}
  ],
  "text": "..."
}
```

Packaged runtime requirements:

- Do not depend on user shell `PATH`, Homebrew Python, system Python, or a user-installed venv.
- Keep the same JSON protocol so Swift UI, persistence, and queue code stay unchanged.
- Bundle the model and runtime under app-controlled resources.

## Smoke Test Status

Verified locally with a short generated Chinese `m4a`:

```text
.build/qwen-dev-smoke/input.m4a
```

The worker emitted:

```json
{"type":"progress","stage":"transcribing","completed_segments":0,"total_segments":1}
{"type":"completed","transcript_path":".../transcript.json","duration_sec":4.95102}
```

The generated `transcript.json` used the Aural schema and included one timestamped segment. This proves the current Swift worker protocol can accept real Qwen output through the development adapter.

The first failed smoke run found and fixed a root-path bug: the worker now discovers the ASR project root by searching upward for `tools/qwen3_asr_transcribe.py` instead of assuming a fixed parent depth.
