# Phase 9a evidence — Perrys core

- `swift test --package-path Packages/PerryBrain`: **156 tests, 0 failures**
  (+16: PerryStore 3, RoutineDecisions 7, SuggestionRules 3, MemoryFiles 3).
- Sub-plan: `docs/plans/2026-09-26-phase-9a-perrys-core.md`.

Covered: Perry CRUD + atomic writes + corrupt-file tolerance; deterministic
two-word names; daily/interval/once scheduling, catch-up-once after missed
slots, pause after 3 failures; suggestion quiet rules (call/share/Focus),
top-3 ranking, ignore-backoff; PROFILE.md/CONTEXT.md round-trip and prompt
block composition.

Remaining (9b): NSBackgroundActivityScheduler wiring, Home UI, wake word,
voice creation flow, local-model Brain page, cua-s1 sidecar experiment.
