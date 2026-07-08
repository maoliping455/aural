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
- First-launch local model preparation with fast, balanced, and accurate modes.
- Optional local subtitle timestamp alignment, enabled by default.
- Conservative Qwen3-ASR 4bit decoding defaults to reduce long-form repetition loops.
- No cloud transcription, no telemetry, no account system.

## Packaging

The source repository does not include model weights or runtime files.

The 0.1.0 GitHub Release uses a lightweight DMG. The app includes the local Python runtime, but does not bundle ASR / aligner model weights. On first launch, Aural checks the local model cache. If resources are missing, the app asks the user to start preparation and shows overall download progress.

Default model cache:

```text
~/Library/Application Support/Aural/Models
```

Model downloads prefer ModelScope and fall back to Hugging Face. Existing complete model directories are reused across app upgrades.

The public 0.1.0 DMG must be Developer ID signed, submitted to Apple notarization, stapled, and verified before upload. See `docs/release.md` for the release checklist.

## Known Limits

- Timestamp refinement is local and best-effort; if alignment fails, Aural falls back to estimated segment timing.
- Severe ASR repetition, hallucination, or empty transcripts are treated as release-blocking bugs; minor wording, punctuation, or proper-name errors remain known local ASR limits.
- OCR context enhancement is not included in this release.
- Summarization is not included in the app.
- First launch prepares local model resources. The default recommendation is balanced mode plus timestamp alignment. Fast mode is smaller, accurate mode requires 16 GB or more RAM, and partial downloads are reused on retry.
- Intel Mac and CPU-only backends are not supported in 0.1.0.
