# Aural 0.1.0

Initial open-source release.

## Highlights

- Local-first macOS transcription app.
- Audio import: `mp3`, `m4a`, `wav`, `aac`, `flac`.
- Video import: `mp4`, `mov`, `m4v`; video is converted to app-owned audio.
- Serial local transcription queue.
- Task pause/resume, delete, rename, and search.
- Playback with transcript positioning and current text highlighting.
- Export to SRT, plain text, and segmented timestamp text.
- No cloud transcription, no telemetry, no account system.

## Packaging

The source repository does not include model weights or runtime files.

The GitHub Release may include a self-contained app package split into multiple DMG parts. Download every part, merge them, and verify checksums:

```bash
cat Aural-0.1.0.dmg.part-* > Aural-0.1.0.dmg
shasum -a 256 -c SHA256SUMS.txt
```

0.1.0 is ad-hoc signed and not notarized. See `docs/release.md` for first-open instructions.

## Known Limits

- Timestamp refinement is local and best-effort; if alignment fails, Aural falls back to estimated segment timing.
- OCR context enhancement is not included in this release.
- Summarization is not included in the app.
- Release package size is large because it can include local model and runtime files.
