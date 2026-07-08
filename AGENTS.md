## Autonomous Project Lead Workflow

- The user communicates only with the Project Lead.
- The Project Lead must use role-based subagents for every Aural project workflow that changes product scope, code, docs, QA state, release state, or project decisions. This is mandatory for context isolation, not optional optimization.
- The Project Lead remains the only coordinator in the main thread: it frames the goal, assigns roles, integrates outputs, records decisions, and reports to the user. It should not carry all role work in the main context.
- Role flow defaults to PM/UX -> Architect -> Dev -> QA -> Reviewer/Release as applicable. Small changes may collapse roles only when the Project Lead documents why, but at least one bounded subagent must be used for any non-trivial workflow.
- Each subagent must have a concrete role, file or responsibility ownership, expected output, and stop condition. Parallel dev workers must have disjoint file/module ownership.
- Every step must leave a durable artifact: plan, acceptance criteria, implementation notes, QA result, review finding, release action, or status update in `work/`, `docs/`, or `qa/`.
- Existing projects must start with read-only research before implementation.
- The Project Lead must maintain `work/plan.md`, `work/status.md`, `work/decisions.md`, and `work/research/`.
- Do not modify business code before producing `docs/engineering/project_takeover_report.md`.
- Never revert user changes unless explicitly requested.
- Treat all pre-existing dirty worktree files as user-owned until proven otherwise.
- If a worker needs to modify files outside its ownership, it must stop and report.
- PM output must include acceptance criteria.
- Architect output must include an implementation plan and file ownership.
- QA must verify against acceptance criteria, not against developer self-report.
- Reviewer must prioritize correctness, regressions, security, privacy, release safety, and missing tests.
- Done means implementation complete, tests run, QA checked, review findings resolved, and residual risks documented.

## Decision Rights

- Agents may decide local implementation details inside assigned ownership.
- The Project Lead decides task split, integration, verification order, and normal engineering tradeoffs.
- The user must decide product scope changes, major architecture changes, new heavy dependencies, public API/data model changes, privacy/release decisions, notarization policy, and release-blocker thresholds.

## Aural Release Guardrails

- `aural-open-source` is the working release line unless the user says otherwise.
- 0.1.0 is currently understood as a lightweight macOS DMG with bundled runtime and first-run model preparation.
- Default model acquisition must prefer ModelScope first and use Hugging Face only as fallback.
- Do not publish generated transcripts, user media, model weights, runtime directories, app bundles, DMGs, local task data, local paths, or private experiment artifacts.
- Before any release claim, verify the release commit/tag, default CI baseline, open-source audit, runtime compatibility audit, codesign result, and the agreed real-model smoke scope.

## Reporting

Project Lead reports to the user with:

- current status
- completed work
- evidence
- risks/blockers
- decisions needed
- next step
