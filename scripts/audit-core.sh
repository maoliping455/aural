#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="$ROOT_DIR/.build/core-audit"
REPORT="$REPORT_DIR/report.md"
APP_DIR="$ROOT_DIR/.build/release/Aural.app"

mkdir -p "$REPORT_DIR"

log_step() {
  local text="$1"
  echo "==> $text"
  printf -- "- %s\n" "$text" >> "$REPORT"
}

cd "$ROOT_DIR"

cat > "$REPORT" <<REPORT_HEADER
# Aural Core Audit

- Generated at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
- Workspace: $ROOT_DIR

## Checks
REPORT_HEADER

log_step "Build Swift package products"
swift build

log_step "Validate core store, queue, worker, failure, timeout, deletion, and format behavior"
swift run aural-validate

log_step "Run stub prototype for serial queue success and failure"
swift run aural-prototype

log_step "Build local Aural.app with bundled runtime and bundled Qwen model"
scripts/build-local-app.sh --include-runtime --include-model > "$REPORT_DIR/build-app.log"

log_step "Validate direct worker text segmentation helpers"
scripts/validate-direct-segments.py

log_step "Validate macOS afconvert audio segmentation helpers"
scripts/validate-segmented-worker.py

log_step "Smoke test bundled direct Qwen worker"
scripts/smoke-direct-bundle-worker.sh > "$REPORT_DIR/direct-worker-smoke.log"

log_step "Smoke test Swift queue against bundled segmented Qwen worker"
scripts/smoke-app-queue-bundle.sh > "$REPORT_DIR/app-queue-smoke.log"

log_step "Audit bundle codesign, runtime imports, and external dylib references"
scripts/audit-bundle-runtime.sh > "$REPORT_DIR/bundle-runtime-audit.log"

cat >> "$REPORT" <<REPORT_FOOTER

## Artifacts

- App bundle: $APP_DIR
- Direct worker smoke log: $REPORT_DIR/direct-worker-smoke.log
- App queue smoke log: $REPORT_DIR/app-queue-smoke.log
- Bundle runtime audit log: $REPORT_DIR/bundle-runtime-audit.log

## Result

Core audit passed.
REPORT_FOOTER

echo "$REPORT"
