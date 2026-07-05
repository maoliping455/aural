# Contributing

Thanks for helping improve Aural.

## Local Setup

```bash
swift build
swift run aural-validate
scripts/build-local-app.sh
```

The basic app bundle build does not require bundled models. To test local ASR, pass explicit runtime/model paths:

```bash
scripts/build-local-app.sh \
  --include-runtime \
  --include-model \
  --venv-source /path/to/asr-python-venv \
  --model-source /path/to/qwen3-asr-1.7b-4bit \
  --aligner-model-source /path/to/qwen3-forcedaligner-0.6b-4bit-mlx
```

Optional ITN rules can be passed with `--itn-fst-source /path/to/custom-wetext-fsts`.

## Before Opening a Pull Request

Run:

```bash
swift build
swift run aural-validate
scripts/audit-open-source.sh
find . -name '__pycache__' -o -name '*.pyc'
```

Do not commit models, Python runtime directories, app bundles, DMGs, user media, transcripts, or local experiment output.

## Code Style

- Keep product UI simple and local-first.
- Avoid exposing model names or technical configuration in the main app flow.
- Keep worker stdout reserved for JSON protocol events and use stderr for diagnostics.
- Preserve task deletion semantics: delete app-owned files and records, not the user's original import source.
- Prefer small, focused changes with validation coverage for persistence, import, queue, worker protocol, and export behavior.

## Release Work

Release bundles can include large model/runtime files, but they must stay out of Git. Use `scripts/package-release-split.sh` to create split assets and checksums.
