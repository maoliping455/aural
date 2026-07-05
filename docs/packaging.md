# Local App Packaging

The SwiftPM prototype can be packaged into a local unsigned/ad-hoc-signed macOS app bundle:

```bash
scripts/build-local-app.sh
```

Output:

```text
.build/release/Aural.app
```

The default bundle includes:

```text
Aural.app/
  Contents/
    MacOS/
      Aural
    Resources/
      AuralASRWorker/
        worker_stub.py
        worker_qwen_segmented_bundle.py
        worker_qwen_direct_bundle.py
        worker_qwen_bundle.py
        worker_qwen_dev.py
        itn_postprocess.py
      itn/
        custom_wetext_fsts/
      runtime/
      asr-models/
      aligner-models/
```

By default the script does not copy the 1.49 GiB model. To create a larger bundle with the local model copied into app resources:

```bash
scripts/build-local-app.sh \
  --include-model \
  --model-source /path/to/qwen3-asr-1.7b-4bit \
  --aligner-model-source /path/to/qwen3-forcedaligner-0.6b-4bit-mlx
```

or:

```bash
AURAL_MODEL_SOURCE=/path/to/qwen3-asr-1.7b-4bit \
AURAL_ALIGNER_MODEL_SOURCE=/path/to/qwen3-forcedaligner-0.6b-4bit-mlx \
scripts/build-local-app.sh --include-model
```

To include the current local ASR runtime and bundled local models:

```bash
scripts/build-local-app.sh \
  --include-runtime \
  --include-model \
  --venv-source /path/to/asr-python-venv \
  --model-source /path/to/qwen3-asr-1.7b-4bit \
  --aligner-model-source /path/to/qwen3-forcedaligner-0.6b-4bit-mlx
```

`--include-model` copies both `qwen3-asr-1.7b-4bit` and `qwen3-forcedaligner-0.6b-4bit-mlx`. Override the aligner source with `AURAL_ALIGNER_MODEL_SOURCE` or `--aligner-model-source` if needed.

To create a local DMG from the app bundle:

```bash
scripts/package-local-dmg.sh
```

The DMG script names packages with the app version and timestamp, then prunes old local Aural packages in `.build/release`. By default it keeps only the latest 3 files matching `Aural-*.dmg`, `Aural-*.pkg`, or `Aural-*.zip`; set `AURAL_PACKAGE_KEEP_COUNT=<n>` only when a larger local package history is needed.

For VAD/chunked development smoke tests, ffmpeg/ffprobe and their native dependency closure can also be copied:

```bash
scripts/build-local-app.sh \
  --include-runtime \
  --include-model \
  --include-homebrew-ffmpeg \
  --venv-source /path/to/asr-python-venv \
  --model-source /path/to/qwen3-asr-1.7b-4bit \
  --aligner-model-source /path/to/qwen3-forcedaligner-0.6b-4bit-mlx
```

The script rewrites copied dylib references into `Contents/Resources/runtime/lib`. This is still a development packaging path until ffmpeg licensing, notarization, and architecture coverage are reviewed.

Runtime behavior:

- Swift uses `~/Library/Application Support/Aural` for task data by default.
- Swift first looks for worker scripts inside `Bundle.main.resourceURL/AuralASRWorker`.
- The segmented Qwen bundle worker uses `Contents/Resources/runtime`, `Contents/Resources/asr-models/qwen3-asr-1.7b-4bit`, `Contents/Resources/aligner-models/qwen3-forcedaligner-0.6b-4bit-mlx`, and macOS `/usr/bin/afconvert` for native audio conversion.
- Video imports are audio-extracted through AVFoundation; the app does not retain the original video copy after import.
- If bundled runtime/model are present, Swift chooses `worker_qwen_segmented_bundle.py` first.
- If bundled runtime/model are missing, the app falls back to the bundled stub worker for local UI/queue testing.

The segmented worker is the current default. It normalizes supported audio through macOS `afconvert`, uses app-local `soundfile`/`numpy` segmentation, transcribes each audio segment with the bundled Qwen model, and refines paragraph timestamps with the bundled Qwen3 forced aligner when available. Successful alignment writes `timestamp_method: qwen3_forced_aligner_paragraph` and `alignment.json`; alignment failure falls back to `vad_speech_weighted_paragraph` or `audio_segmented`.

All workers run conservative ITN after ASR when FST rules are bundled. The app displays normalized text, while `transcript.json` keeps `raw_text`, `normalized_text`, `metadata.itn`, and `metadata.alignment`. The build script copies WeText FST rules from `AURAL_ITN_FST_SOURCE` or `--itn-fst-source` when provided. If the path is missing, the bundle still builds and the worker falls back to raw ASR text.

`worker_qwen_direct_bundle.py` remains a no-segmentation fallback and smoke-test baseline. It writes `timestamp_method: text_length_proportional`.

`worker_qwen_bundle.py` remains the explicit ffmpeg-backed VAD/chunked development path. Do not make it the default until the packaged audio probing/extraction dependency is replaced or fixed: copied ffprobe builds have shown reliability issues during short-audio smoke tests.

Current runtime progress:

- `--include-runtime` copies the selected CPython base and virtual environment into `Contents/Resources/runtime`.
- `runtime/bin/python3` is a wrapper that sets `PYTHONHOME` and `PYTHONPATH` to app-local paths.
- `runtime/bin/python3` also sets `PYTHONDONTWRITEBYTECODE=1` so ASR execution does not write `__pycache__` into the signed app bundle.
- The package-local Python can import `mlx_audio`, `mlx`, `numpy`, `soundfile`, `scipy`, `silero_vad`, and `torch`.
- `--include-model` copies the real 1.5G ASR model directory into `Contents/Resources/asr-models/qwen3-asr-1.7b-4bit` and the 931M forced aligner model into `Contents/Resources/aligner-models/qwen3-forcedaligner-0.6b-4bit-mlx`.
- `worker_qwen_segmented_bundle.py` has been smoke-tested with the bundled Python runtime and bundled model, without package-manager binaries in `PATH`.
- `worker_qwen_direct_bundle.py` has also been smoke-tested with the bundled Python runtime and bundled model as a fallback path.
- `worker_qwen_bundle.py` is available for explicit VAD/chunked experiments with the bundled Python runtime, bundled model, and copied ffmpeg dependency closure, but this path is not currently accepted as the default runtime.
- The generated ASR output is written to Aural's `transcript.json` schema.
- Video files are transcribed through extracted audio; no OCR dependencies are bundled.
- Segmented worker metadata uses `timestamp_method: qwen3_forced_aligner_paragraph` when local forced alignment succeeds, with alignment details under `metadata.alignment`.
- Segmented worker metadata uses `timestamp_method: vad_speech_weighted_paragraph` when local RMS-VAD paragraph timing succeeds but forced alignment is unavailable or failed, with VAD details under `metadata.vad`.
- Segmented worker falls back to `timestamp_method: audio_segmented` if speech intervals are unavailable or invalid.
- Direct fallback metadata uses `timestamp_method: text_length_proportional`.
- The post-smoke bundle still passes `codesign --verify --deep --strict`.

Known gap:

- Segmented packaged ASR is closed-loop and produces audio-segment-derived timestamps without ffmpeg/ffprobe.
- The explicit ffmpeg-backed VAD/chunked path is still not a production default because copied ffprobe builds have shown reliability issues.

Suggested verification:

```bash
swift build
swift run aural-validate
scripts/validate-itn-postprocess.py
swift run aural-prototype
scripts/build-local-app.sh --include-runtime --include-model \
  --venv-source /path/to/asr-python-venv \
  --model-source /path/to/qwen3-asr-1.7b-4bit \
  --aligner-model-source /path/to/qwen3-forcedaligner-0.6b-4bit-mlx
codesign --verify --deep --strict --verbose=2 .build/release/Aural.app
scripts/package-local-dmg.sh
scripts/package-release-split.sh .build/release/Aural-0.1.0.dmg
scripts/validate-direct-segments.py
scripts/validate-segmented-worker.py
scripts/smoke-direct-bundle-worker.sh
scripts/smoke-app-queue-bundle.sh
scripts/audit-bundle-runtime.sh
```

The generated bundle should pass ad-hoc codesign verification.

Recent smoke test shape:

- Bundle size: about `2.5G`
- Runtime size: about `1.0G`
- Model size: about `1.5G`
- Direct worker output: `loading` progress, `transcribing` progress, then `completed`
- Direct fallback transcript path: `.build/direct-worker-smoke/task/transcript.json`
- Direct fallback timestamp method: `text_length_proportional`
- App queue smoke verifies the default segmented worker timestamp method.
- App queue smoke path: `.build/app-queue-smoke/data/tasks/<task_id>/`
- App queue smoke verifies audio is copied into app-owned task storage before transcription.
- App queue smoke also verifies a bad `.wav` reaches terminal status `转写失败` and writes `error.log` under the task directory.
- Validation also covers a worker process that writes stderr and exits non-zero; stderr and exit status are persisted to `error.log`.
- Validation covers startup recovery: interrupted `转写中` tasks return to `未开始` and can then complete through the queue.
- Validation covers supported audio extensions: `mp3`, `m4a`, `wav`, `aac`, and `flac`.
- Validation covers supported video import extensions: `mp4`, `mov`, and `m4v`; video files are extracted to app-owned `m4a` audio before transcription.
- Audit result for a release bundle should show no personal local paths or unresolved package-manager dynamic library references.
