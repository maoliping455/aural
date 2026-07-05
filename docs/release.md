# Release Notes and Installation

## 0.1.0 Release Shape

Aural 0.1.0 publishes source code in Git and large app packages as GitHub Release assets.

The source repository does not include:

- Model weights.
- Python runtime directories.
- App bundles.
- DMGs or split package parts.
- User audio/video samples.
- Local transcripts or experiment output.

## Split DMG Assets

The self-contained app package is large because it can include local ASR model files and a Python runtime. Release assets are split into parts smaller than `1900MiB`.

Download every part and `SHA256SUMS.txt`, then merge and verify:

```bash
cat Aural-0.1.0.dmg.part-* > Aural-0.1.0.dmg
shasum -a 256 -c SHA256SUMS.txt
```

Then open `Aural-0.1.0.dmg` and move `Aural.app` to Applications.

## Signing and First Open

0.1.0 is ad-hoc signed and not Apple-notarized.

On first open, macOS Gatekeeper may block the app. Use Finder to right-click `Aural.app`, choose Open, and confirm. A future release can add Developer ID signing and notarization.

## Release Checklist

Before publishing:

```bash
swift build
swift run aural-validate
scripts/build-local-app.sh --include-runtime --include-model \
  --venv-source /path/to/asr-python-venv \
  --model-source /path/to/qwen3-asr-1.7b-4bit \
  --aligner-model-source /path/to/qwen3-forcedaligner-0.6b-4bit-mlx
codesign --verify --deep --strict --verbose=2 .build/release/Aural.app
scripts/package-local-dmg.sh
scripts/package-release-split.sh .build/release/Aural-0.1.0.dmg
scripts/publish-github-release.sh
```

Attach to the GitHub Release:

- Split DMG parts.
- `SHA256SUMS.txt`.
- `THIRD_PARTY_NOTICES.md`.
- Generated Python dependency license inventory.
- `RELEASE_NOTES.md`.

## Offline Acceptance

On a Mac without a local ASR development environment:

- Merge the split DMG.
- Install and launch Aural.
- Disconnect network.
- Import audio and video files.
- Confirm transcription, playback seek, export, pause/resume, delete, and search behavior.
