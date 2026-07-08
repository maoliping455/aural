# Transcript Schema

Aural workers write transcript artifacts into each task output directory. The app reads these files from disk for review, playback synchronization, search, and export.

The persisted JSON format uses `snake_case` keys.

## Files

```text
transcript.json   Required when transcription succeeds
alignment.json    Optional timing sidecar written when forced alignment succeeds
error.log         Optional technical failure log
```

Do not commit generated transcripts, alignment files, task directories, or error logs to the public repository.

## transcript.json

Minimal shape:

```json
{
  "task_id": "00000000-0000-0000-0000-000000000000",
  "audio_duration_sec": 42.0,
  "created_at": "2026-07-08T00:00:00Z",
  "segments": [
    {
      "start_sec": 0.0,
      "end_sec": 12.0,
      "text": "Displayed transcript text.",
      "raw_text": "Raw ASR text before ITN.",
      "alignment_item_start": 0,
      "alignment_item_end": 12
    }
  ],
  "text": "Displayed transcript text.",
  "raw_text": "Raw ASR text before ITN.",
  "normalized_text": "Displayed transcript text.",
  "metadata": {
    "pipeline": "macos_afconvert_segmented",
    "timestamp_method": "qwen3_forced_aligner_paragraph",
    "fallback_timestamp_method": "vad_speech_weighted_paragraph",
    "segment_count": 1,
    "itn": {
      "enabled": true,
      "mode": "conservative",
      "engine": "wetext_rules_conservative_fst",
      "language": "zh",
      "rule_version": "20260702",
      "status": "ok"
    },
    "alignment": {
      "enabled": true,
      "engine": "qwen3_forced_aligner",
      "runtime": "mlx_audio",
      "status": "ok",
      "alignment_path": "alignment.json"
    }
  }
}
```

### Top-Level Fields

| Field | Required | Notes |
| --- | --- | --- |
| `task_id` | yes | UUID string matching the app task. |
| `audio_duration_sec` | yes | Audio duration used by the app and exports. |
| `created_at` | yes | ISO 8601 timestamp. |
| `segments` | yes | Paragraph-level segments for display and export. |
| `text` | yes | Display text after normalization when ITN runs. |
| `raw_text` | no | Full raw ASR text before normalization. |
| `normalized_text` | no | Full normalized text after ITN. Usually matches `text`. |
| `metadata` | no | Pipeline, timing, ITN, alignment, and diagnostic metadata. |

### Segment Fields

| Field | Required | Notes |
| --- | --- | --- |
| `start_sec` | yes | Segment start time in seconds. |
| `end_sec` | yes | Segment end time in seconds. |
| `text` | yes | Display text for the segment. |
| `raw_text` | no | Segment text before ITN. |
| `alignment_item_start` | no | Inclusive start index into `alignment.json.items`. |
| `alignment_item_end` | no | Exclusive end index into `alignment.json.items`. |

`alignment_item_start` and `alignment_item_end` are only meaningful when `alignment.json` exists and the alignment metadata is successful or partially successful.

## Timestamp Methods

Known `metadata.timestamp_method` values:

| Value | Meaning |
| --- | --- |
| `qwen3_forced_aligner_paragraph` | Paragraph timestamps were refined by Qwen3-ForcedAligner. |
| `vad_speech_weighted_paragraph` | Paragraph timestamps were estimated from local speech intervals. |
| `audio_segmented` | Paragraph timestamps fell back to coarse audio segment boundaries. |
| `text_length_proportional` | Direct fallback worker assigned timings proportionally from text length. |

When alignment fails, the worker should keep the task successful if transcript text exists and record fallback details in `metadata.alignment`.

## alignment.json

`alignment.json` is an optional sidecar for internal playback and seek improvements.

Shape:

```json
{
  "version": 1,
  "created_at": "2026-07-08T00:00:00Z",
  "model": "Qwen3-ForcedAligner-0.6B-4bit",
  "runtime": "mlx_audio",
  "status": "ok",
  "chunks": [
    {
      "index": 1,
      "start_sec": 0.0,
      "end_sec": 120.0,
      "language": "zh",
      "status": "ok",
      "alignment_item_start": 0,
      "alignment_item_end": 120
    }
  ],
  "items": [
    {
      "index": 0,
      "chunk_index": 1,
      "text": "字",
      "start_sec": 0.12,
      "end_sec": 0.24,
      "duration_sec": 0.12
    }
  ]
}
```

### Alignment Status

Known top-level and chunk status values:

| Value | Meaning |
| --- | --- |
| `ok` | Alignment succeeded. |
| `partial_fallback_estimated` | Some chunks aligned and others fell back to estimated timing. |
| `error_fallback_estimated` | Alignment failed and transcript timing fell back to estimated timing. |
| `disabled` | Alignment was disabled by user configuration or environment. |

## Compatibility Rules

- Readers should tolerate unknown `metadata` keys.
- Readers should tolerate missing `alignment.json` and fall back to `transcript.json.segments`.
- Workers should prefer preserving transcript text over failing a task because optional ITN or alignment failed.
- Generated artifacts may contain local model paths inside diagnostic metadata. Do not publish user-generated artifacts without reviewing and redacting them.
