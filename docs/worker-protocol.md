# Worker Protocol

Aural uses one JSON object per line over stdin/stdout for the first technical prototype.

For persisted transcript artifacts, see [Transcript Schema](transcript-schema.md).

The app writes a request to worker stdin:

```json
{"type":"transcribe","request_id":"...","task_id":"...","audio_path":".../source.m4a","output_dir":".../tasks/<task_id>","language":"auto","pipeline":"vad_chunked","duration_sec":42.0}
```

The worker writes progress events to stdout:

```json
{"type":"progress","request_id":"...","task_id":"...","stage":"transcribing","completed_segments":1,"total_segments":3}
```

The worker writes exactly one terminal event:

```json
{"type":"completed","request_id":"...","task_id":"...","transcript_path":".../transcript.json","duration_sec":42.0}
```

or:

```json
{"type":"failed","request_id":"...","task_id":"...","error_code":"asr_runtime_error","error_log_path":".../error.log"}
```

Rules:

- stdout is reserved for JSON event lines.
- stderr is reserved for internal technical logs.
- `duration_sec` is supplied by Swift when AVFoundation can read the copied audio duration. The segmented bundled worker first computes fallback timestamps from app-local audio segments, then uses bundled forced alignment when available to refine paragraph timestamps; the direct fallback uses the value to assign proportional text timestamps.
- The UI shows only `转写失败` for failures.
- The app runs one task at a time; queued tasks remain `未开始`.
- Workers write `transcript.json` with normalized `text` for display, plus `raw_text`, `normalized_text`, `metadata.itn`, and `metadata.alignment` so the original ASR output, ITN processing metadata, and timestamp-refinement status are retained locally.
- When forced alignment succeeds, workers also write `alignment.json` next to `transcript.json`. This file stores token-level timing for internal playback/seek improvements; the UI continues to read paragraph-level `transcript.json.segments` by default.
- For video tasks, Swift extracts app-owned audio and does not keep the original video copy. The worker receives only the extracted audio path.
