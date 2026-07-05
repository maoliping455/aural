# Aural

Aural is a local-first macOS app for audio and video transcription.

It is designed for personal notes: import media, let the app transcribe locally, review the transcript with playback, and export the result when needed. The product does not expose model choices or tuning controls in the main UI.

## Features

- Local transcription queue with one active task at a time.
- Audio import: `mp3`, `m4a`, `wav`, `aac`, `flac`.
- Video import: `mp4`, `mov`, `m4v`; Aural extracts app-owned audio and does not keep the original video copy.
- Task states: `未开始`, `转写中`, `已暂停`, `转写完成`, `转写失败`.
- Playback controls, seek, follow-current-position behavior, and transcript highlighting.
- Rename, delete, search, pause/resume, and export.
- Export formats: SRT subtitles, plain text, and segmented timestamp text.
- No cloud service, no telemetry, and no account system.

## Privacy

Aural stores imported media copies and transcripts under the app support directory on the local Mac. Deleting a task removes the app-owned audio copy, transcript, sidecar files, and task record, but does not delete the user's original imported file.

See [docs/privacy.md](docs/privacy.md) for the detailed privacy model.

## Install

For the 0.1.0 early release, use the GitHub Release assets:

```bash
cat Aural-0.1.0.dmg.part-* > Aural-0.1.0.dmg
shasum -a 256 -c SHA256SUMS.txt
```

Open the DMG and move `Aural.app` to Applications. The 0.1.0 build is ad-hoc signed and not notarized; see [docs/release.md](docs/release.md) for first-open notes.

## Build From Source

Requirements:

- macOS 14 or later
- Xcode Command Line Tools or Xcode
- Swift 6-compatible toolchain

Build and validate the Swift code:

```bash
swift build
swift run aural-validate
```

Create a local app bundle without bundled ASR runtime/model:

```bash
scripts/build-local-app.sh
```

Create a self-contained local bundle by passing explicit runtime and model paths:

```bash
scripts/build-local-app.sh \
  --include-runtime \
  --include-model \
  --venv-source /path/to/asr-python-venv \
  --model-source /path/to/qwen3-asr-1.7b-4bit \
  --aligner-model-source /path/to/qwen3-forcedaligner-0.6b-4bit-mlx \
  --itn-fst-source /path/to/custom-wetext-fsts
```

The ITN FST path is optional. If it is missing, the worker keeps the raw ASR text and records an ITN fallback in `transcript.json` metadata.

## Release Packaging

Models and Python runtime files are not stored in Git. Release builds may include them inside `Aural.app` and are published as split GitHub Release assets.

Useful commands:

```bash
scripts/package-local-dmg.sh
scripts/package-release-split.sh .build/release/Aural-0.1.0.dmg
```

See [docs/packaging.md](docs/packaging.md) and [docs/release.md](docs/release.md).

## Repository Layout

```text
AuralASRWorker/        Python worker scripts for local ASR processing
Resources/             App icon resources
Sources/AuralCore/     Persistence, import, queue, export, worker protocol
Sources/AuralUIPrototype/
                       SwiftUI macOS app
scripts/               Build, validation, packaging, and release helpers
docs/                  Packaging, protocol, privacy, release, and TODO docs
```

## License

Aural source code is licensed under Apache-2.0. See [LICENSE](LICENSE).

Bundled release artifacts may include third-party models and runtimes with their own licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
