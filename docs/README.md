# Aural Documentation

This directory contains public project documentation for Aural. Keep it safe to publish in the GitHub repository: do not include model weights, generated transcripts, local absolute paths, user media, private experiments, or credentials.

## Start Here

- [Product Current State](product-current-state.md): PM-facing product scope, 0.1.0 delivery boundary, priority, QA gates, and open decisions.
- [Aural 0.1.0 PRD](prd-0.1.0.md): product requirements, user scenarios, acceptance criteria, release gates, risks, and PM decisions.
- [Aural 0.1.0 Project Plan](project-plan-0.1.0.md): milestones, P0/P1 backlog, release gates, handoff templates, and PM decision tracking.
- [Aural 0.1.0 PM Decisions](pm-decisions-0.1.0.md): recommended defaults, alternatives, impacts, and confirmation status for release decisions.
- [Architecture](architecture.md): system boundaries, runtime flow, storage layout, and model resource handling.
- [Privacy](privacy.md): local-first behavior, import/deletion rules, storage, and network use.
- [Release Notes and Installation](release.md): release package shape, compatibility, installation, and release checklist.
- [User Install and Troubleshooting](user-install-troubleshooting.md): user-facing install steps, model preparation, common issues, cleanup, and uninstall guidance.
- [Local App Packaging](packaging.md): build shapes, bundled runtime rules, model cache behavior, and verification commands.
- [Project Workflow Principles](engineering/project_workflow_principles.md): Project Lead, role-based subagent, documentation, QA, review, and release execution rules.

## Integration References

- [Worker Protocol](worker-protocol.md): JSONL stdin/stdout contract between Swift and the Python ASR worker.
- [Transcript Schema](transcript-schema.md): persisted `transcript.json` and `alignment.json` formats.
- [Qwen Worker Dev Adapter](qwen-worker-dev.md): development adapter notes for validating the Swift/worker boundary.

## Planning and Research

- [Aural TODO](todo.md): maintainer-facing roadmap and evaluation backlog. This file may include Chinese planning notes.
- [Research Notes](research/README.md): location for future model and product evaluation reports.
- [Raw ASR Repetition Root Cause](research/asr-repetition-root-cause-0.1.0.md): 0.1.0 ASR repetition blocker root cause, mitigation, and release exit criteria.
- [Real Model Smoke Test Plan](../qa/real-model-smoke-0.1.0.md): QA plan for packaged runtime, model cache, real ASR worker, alignment, and app queue smoke testing.

## Publication Checklist

Before publishing documentation changes:

- Run `scripts/audit-open-source.sh`.
- Check that examples use placeholder paths such as `/path/to/...` rather than a developer's local path.
- Keep generated media, transcripts, task directories, model caches, runtime folders, and DMGs out of Git.
- If a document describes an experimental model or workflow, mark whether it is part of the public release path or only a research candidate.
