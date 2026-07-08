# Release Notes and Installation

## 0.1.0 Release Shape

Aural 0.1.0 uses a lightweight DMG by default.

The Git repository does not include:

- Model weights.
- Python runtime directories.
- App bundles.
- DMGs or split package parts.
- User audio/video samples.
- Local transcripts or experiment output.

The Release DMG includes the app and the local Python runtime, but does not include ASR / aligner model weights. On first launch, Aural checks the local model cache. If resources are missing, the app asks the user to start preparation, shows the approximate download size, and blocks import/transcription until preparation succeeds.

## Model Resource Cache

Default model cache:

```text
~/Library/Application Support/Aural/Models
```

Expected model directories:

```text
qwen3-asr-0.6b-4bit
qwen3-asr-1.7b-4bit
qwen3-asr-1.7b-bf16
qwen3-forcedaligner-0.6b-4bit-mlx
```

The downloader:

- Reuses existing complete model directories.
- Writes `.aural-complete.json` after a successful check/download.
- Tries ModelScope first.
- Falls back to Hugging Face if ModelScope fails.
- Keeps partial files so a later retry can continue.
- Emits coarse overall progress based on local resource bytes so the app can show a single percentage.

The first launch downloads the selected local model resources. The default recommendation is balanced ASR plus timestamp alignment. Fast ASR without alignment is the smallest option, balanced plus alignment is about 2.6 GB, and accurate plus alignment is about 5.1 GB. Accurate mode is offered only on Apple Silicon Macs with at least 16 GB RAM. Timestamp alignment is optional and can be changed later in local transcription settings. These resources are stored outside the app bundle so later app upgrades can reuse them.

Environment overrides for development and mirrors:

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

## Install

Download the DMG from GitHub Releases, open it, and drag `Aural.app` onto the `Applications` shortcut in the DMG window.

The public 0.1.0 DMG must be Developer ID signed and Apple-notarized before upload. Local development builds may still be ad-hoc signed; those builds are not public release artifacts and may require Finder right-click Open.

## Compatibility

0.1.0 targets Apple Silicon Mac on macOS 14 or later. A separate discrete GPU is not required; the default runtime relies on Apple Silicon / Metal. Intel Mac and CPU-only backends are not part of the first public release.

The app checks macOS version, CPU architecture, and the bundled MLX runtime before downloading model resources. Unsupported systems should fail early with a clear message.

Release builds must package MLX wheels that target macOS 14 or lower. Building on a newer macOS without pinning the wheel platform can accidentally package runtime files tagged for the build machine, such as `macosx_26_0_arm64`; those bundles will fail on macOS 14/15. Use the runtime pinning and audit steps below before publishing.

## Release Checklist

Before publishing the lightweight package, create a notarytool keychain profile on the release Mac:

```bash
xcrun notarytool store-credentials AuralNotaryProfile \
  --apple-id apple-id@example.com \
  --team-id TEAMID
```

Then build, sign, package, notarize, and verify:

```bash
swift build
swift run aural-test
swift run aural-validate
scripts/audit-open-source.sh
env PYTHONDONTWRITEBYTECODE=1 scripts/validate-direct-segments.py
env PYTHONDONTWRITEBYTECODE=1 scripts/validate-segmented-worker.py
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

If the release bundle includes custom WeText ITN FST rules, also run:

```bash
env PYTHONDONTWRITEBYTECODE=1 scripts/validate-itn-postprocess.py
```

The signing/notarization flow follows Apple's Developer ID distribution model: the app is signed with a Developer ID certificate, submitted with `notarytool`, stapled with `stapler`, and verified with Gatekeeper before GitHub upload.

Before cutting the final release candidate, also close the raw ASR repetition blocker in `qa/bugs.md` by recording the bad-case regression and real-model smoke result. The root-cause summary is in `docs/research/asr-repetition-root-cause-0.1.0.md`.

Attach to the GitHub Release:

- `Aural-0.1.0-<timestamp>.dmg`
- `SHA256SUMS.txt` if generated for the release
- `THIRD_PARTY_NOTICES.md`
- `RELEASE_NOTES.md`

If a future fully offline package exceeds GitHub's single-asset limit, use `scripts/package-release-split.sh` as a fallback. The default 0.1.0 release should not require split assets.

## Acceptance

On a Mac without a local ASR development environment:

- Install and launch Aural.
- Confirm the first-run resource preparation flow appears when models are missing.
- Confirm already-downloaded model resources are reused after restarting the app.
- Import audio and video files.
- Confirm transcription, playback seek, export, pause/resume, delete, and search behavior.
