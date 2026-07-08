# Local App Packaging

Aural supports two packaging shapes:

- **Lightweight release package**: app + local Python runtime, no ASR / aligner model weights. This is the default 0.1.0 release shape.
- **Full offline package**: app + runtime + ASR model + aligner model. This is only for development or special offline distribution.

The source repository never stores model weights, Python runtime directories, generated app bundles, DMGs, user media, or local transcripts.

## Build A Development App

Build a minimal app bundle without runtime or models:

```bash
scripts/build-local-app.sh
```

Output:

```text
.build/release/Aural.app
```

This shape is useful for Swift UI/core development. It can use explicit development worker settings, but it is not a user-facing release package.

## Build The 0.1.0 Release Shape

Build a lightweight release app with the bundled Python runtime but without model weights.
Before packaging, pin the MLX runtime wheels to the release target platform. This is required even when building on a newer macOS, because pip may otherwise install wheels tagged for the build machine, such as `macosx_26_0_arm64`, which will not run on macOS 14/15:

```bash
scripts/pin-mlx-runtime-platform.sh /path/to/asr-python-venv macosx_14_0_arm64
```

Then build the app:

```bash
AURAL_RUNTIME_MIN_MACOS=14.0 \
AURAL_CODESIGN_REQUIRE_DEVELOPER_ID=1 \
AURAL_CODESIGN_IDENTITY="Developer ID Application: Example Name (TEAMID)" \
scripts/build-local-app.sh \
  --include-runtime \
  --venv-source /path/to/asr-python-venv \
  --python-base-source /path/to/cpython-3.12 \
  --itn-fst-source /path/to/custom-wetext-fsts
```

The generated app contains:

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
        model_resource_prepare.py
        itn_postprocess.py
        alignment_postprocess.py
      itn/
        custom_wetext_fsts/
      runtime/
      asr-models/
      aligner-models/
```

`asr-models/` and `aligner-models/` remain empty in the lightweight release. On app launch, Aural checks:

```text
~/Library/Application Support/Aural/Models/qwen3-asr-0.6b-4bit
~/Library/Application Support/Aural/Models/qwen3-asr-1.7b-4bit
~/Library/Application Support/Aural/Models/qwen3-asr-1.7b-bf16
~/Library/Application Support/Aural/Models/qwen3-forcedaligner-0.6b-4bit-mlx
```

If the selected ASR model or enabled aligner model is missing or incomplete, the app shows a blocking model preparation screen and does not allow import/transcription until preparation succeeds. Users can choose among fast, balanced, and accurate ASR modes before the first download; balanced plus timestamp alignment is the default recommendation. Accurate mode requires at least 16 GB RAM. Timestamp alignment is an independent optional resource and can be enabled or disabled in the app's local transcription settings. The downloader tries ModelScope first and Hugging Face as fallback. Downloaded models live outside the app bundle so app upgrades can reuse them.

The build script audits the packaged runtime after copying it into `Aural.app`. It fails if any Python wheel tag, Mach-O binary, or Metal library declares a minimum macOS version higher than `AURAL_RUNTIME_MIN_MACOS` (default `14.0`). Run the audit directly when investigating a bundle:

```bash
AURAL_RUNTIME_MIN_MACOS=14.0 scripts/audit-runtime-compatibility.sh .build/release/Aural.app
```

Development overrides:

```bash
AURAL_MODEL_ROOT=/path/to/Aural/Models
AURAL_MODELSCOPE_ASR_MODEL_FAST=mlx-community/Qwen3-ASR-0.6B-4bit
AURAL_HF_ASR_MODEL_FAST=mlx-community/Qwen3-ASR-0.6B-4bit
AURAL_MODELSCOPE_ASR_MODEL=mlx-community/Qwen3-ASR-1.7B-4bit
AURAL_HF_ASR_MODEL=mlx-community/Qwen3-ASR-1.7B-4bit
AURAL_MODELSCOPE_ASR_MODEL_ACCURATE=mlx-community/Qwen3-ASR-1.7B-bf16
AURAL_HF_ASR_MODEL_ACCURATE=mlx-community/Qwen3-ASR-1.7B-bf16
AURAL_MODELSCOPE_ALIGNER_MODEL=mlx-community/Qwen3-ForcedAligner-0.6B-4bit
AURAL_HF_ALIGNER_MODEL=mlx-community/Qwen3-ForcedAligner-0.6B-4bit
AURAL_ALIGNMENT_ENABLED=1
```

## Build A Full Offline Package

Only use this when a fully self-contained build is required:

```bash
scripts/build-local-app.sh \
  --include-runtime \
  --include-model \
  --venv-source /path/to/asr-python-venv \
  --python-base-source /path/to/cpython-3.12 \
  --model-source /path/to/qwen3-asr-1.7b-4bit \
  --aligner-model-source /path/to/qwen3-forcedaligner-0.6b-4bit-mlx \
  --itn-fst-source /path/to/custom-wetext-fsts
```

`--include-model` copies both models into the app bundle:

```text
Contents/Resources/asr-models/qwen3-asr-1.7b-4bit
Contents/Resources/aligner-models/qwen3-forcedaligner-0.6b-4bit-mlx
```

The full offline package is much larger and may exceed convenient GitHub Release distribution size. The default 0.1.0 public release should use the lightweight package.

## Create A DMG

```bash
scripts/package-local-dmg.sh
```

The DMG script names packages with the app version and timestamp, then prunes old local Aural packages in `.build/release`. By default it keeps only the latest 3 files matching `Aural-*.dmg`, `Aural-*.pkg`, or `Aural-*.zip`; set `AURAL_PACKAGE_KEEP_COUNT=<n>` only when a larger local package history is needed.

If a future full offline package exceeds GitHub's single-asset limit, `scripts/package-release-split.sh` can split it as a fallback. Do not use split assets for the default lightweight 0.1.0 release.

## Sign And Notarize The Public DMG

Local development bundles may use ad-hoc signing. Public 0.1.0 release bundles must use a Developer ID Application certificate and Apple notarization.

Create a notarytool keychain profile once on the release Mac:

```bash
xcrun notarytool store-credentials AuralNotaryProfile \
  --apple-id apple-id@example.com \
  --team-id TEAMID
```

For the release build, pass either `AURAL_CODESIGN_IDENTITY` or `--codesign-identity`:

```bash
AURAL_CODESIGN_REQUIRE_DEVELOPER_ID=1 \
AURAL_CODESIGN_IDENTITY="Developer ID Application: Example Name (TEAMID)" \
scripts/build-local-app.sh --include-runtime \
  --venv-source /path/to/asr-python-venv \
  --python-base-source /path/to/cpython-3.12 \
  --itn-fst-source /path/to/custom-wetext-fsts
```

After creating the DMG, submit and staple it:

```bash
AURAL_NOTARYTOOL_PROFILE=AuralNotaryProfile \
scripts/notarize-release-dmg.sh .build/release/Aural-0.1.0-<timestamp>.dmg
```

## Runtime Behavior

- Swift stores task data under `~/Library/Application Support/Aural` by default.
- Swift uses bundled worker scripts when `Contents/Resources/AuralASRWorker` is present.
- Swift probes the bundled MLX runtime before model download and before transcription resources are marked ready. If the Metal runtime cannot load on the current system, Aural fails early instead of downloading model files and then failing during transcription.
- The segmented Qwen worker is the production default.
- The worker uses bundled runtime Python and resolves models from `AURAL_MODEL_ROOT`, app support cache, or bundled model directories.
- Video imports are audio-extracted through AVFoundation; the app does not retain the original video copy after import.
- Supported video OCR context enhancement is currently not bundled.

The segmented worker normalizes supported audio through macOS `afconvert`, uses local `soundfile`/`numpy` segmentation, transcribes each audio segment with Qwen3-ASR, and refines paragraph timestamps with Qwen3-ForcedAligner when alignment is enabled and available. Successful alignment writes `timestamp_method: qwen3_forced_aligner_paragraph` and `alignment.json`; disabled or failed alignment falls back to `vad_speech_weighted_paragraph` or `audio_segmented`.

All workers run conservative ITN after ASR when FST rules are bundled. The app displays normalized text, while `transcript.json` keeps `raw_text`, `normalized_text`, `metadata.itn`, and `metadata.alignment`. If ITN rules are missing, the bundle still builds and the worker falls back to raw ASR text.

`worker_qwen_direct_bundle.py` remains a no-segmentation fallback and smoke-test baseline. It writes `timestamp_method: text_length_proportional`.

`worker_qwen_bundle.py` remains the explicit ffmpeg-backed VAD/chunked development path. Do not make it the default until packaged audio probing/extraction dependencies are reviewed.

## Verification

```bash
swift build
swift run aural-test
swift run aural-validate
scripts/audit-open-source.sh
scripts/pin-mlx-runtime-platform.sh /path/to/asr-python-venv macosx_14_0_arm64
AURAL_RUNTIME_MIN_MACOS=14.0 \
AURAL_CODESIGN_REQUIRE_DEVELOPER_ID=1 \
AURAL_CODESIGN_IDENTITY="Developer ID Application: Example Name (TEAMID)" \
scripts/build-local-app.sh --include-runtime \
  --venv-source /path/to/asr-python-venv \
  --python-base-source /path/to/cpython-3.12 \
  --itn-fst-source /path/to/custom-wetext-fsts
AURAL_RUNTIME_MIN_MACOS=14.0 scripts/audit-runtime-compatibility.sh .build/release/Aural.app
codesign --verify --deep --strict --verbose=2 .build/release/Aural.app
spctl --assess --type execute --verbose=4 .build/release/Aural.app
scripts/package-local-dmg.sh
scripts/notarize-release-dmg.sh .build/release/Aural-0.1.0-<timestamp>.dmg
```

Run `env PYTHONDONTWRITEBYTECODE=1 scripts/validate-itn-postprocess.py` when the release bundle includes custom WeText ITN FST rules. If rules are not bundled, the worker keeps raw ASR text and records ITN fallback metadata.

Optional smoke tests that run real ASR need a complete model cache or a full offline bundle:

```bash
AURAL_MODEL_ROOT="$HOME/Library/Application Support/Aural/Models" \
scripts/smoke-direct-bundle-worker.sh

AURAL_MODEL_ROOT="$HOME/Library/Application Support/Aural/Models" \
scripts/smoke-app-queue-bundle.sh
```

The generated public bundle should pass Developer ID codesign verification, notarization, stapling, Gatekeeper assessment, and should not contain personal local paths, OCR runtime payloads, or unresolved package-manager dynamic library references.
