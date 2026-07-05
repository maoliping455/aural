# Security Policy

## Reporting a Vulnerability

Please report security issues through GitHub private vulnerability reporting if it is enabled for the repository. If it is not enabled, open a minimal public issue asking for a secure contact path without sharing exploit details.

Include:

- Affected version or commit.
- Reproduction steps.
- Expected and actual behavior.
- Whether local media, transcript files, model files, or app support data are involved.

## Scope

Security-sensitive areas include:

- Local file import and deletion behavior.
- App-owned media copies and transcripts.
- Worker process execution and JSON protocol handling.
- Release packaging, bundled runtime, and bundled model files.

Aural 0.1.0 does not use cloud transcription, telemetry, or account login.
