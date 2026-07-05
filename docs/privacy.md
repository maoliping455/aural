# Privacy

Aural is designed as a local-first transcription app.

## What Stays Local

- Imported audio and extracted video audio.
- Task records.
- Transcripts and sidecar files such as alignment metadata.
- Exported SRT/TXT files.

Aural 0.1.0 does not send media or transcripts to a cloud service and does not include telemetry or account login.

## Import Behavior

Audio files are copied into app-owned task storage.

Video files are converted to an app-owned audio copy. The original video file is not retained inside Aural after import.

The user's original source file is not modified.

## Deletion Behavior

Deleting a task removes:

- The app-owned task directory.
- The app-owned audio copy.
- Transcript JSON files.
- Alignment or other sidecar files.
- The task record.

Deleting a task does not delete the user's original imported file.

If a task is playing when deleted, playback is stopped before the task files are removed.

## Storage Location

The app stores task data under the macOS Application Support directory for Aural.

Release builds may include local model and runtime files inside the app bundle. Those files are used for local transcription only.

## Network

Aural's product path does not require network access for transcription after the bundled release is installed.

Source builds may require network access only when the developer chooses to download runtime dependencies or model files outside this repository.
