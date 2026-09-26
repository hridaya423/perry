# Phase 8a evidence — dictation cores

- `swift test --package-path Packages/PerryCore`: **82 tests, 0 failures**
  (+13: cleanup guard 8, learner 5).
- Sub-plan: `docs/plans/2026-09-26-phase-8a-dictation-core.md`.

Covered: cleanup diff guard (word-level edit distance ≤ max(2, 20%),
filler-free budget, rejects invented words, added "—"/"…"); learn-on-edit
within 20 s preserving casing; apostrophes tokenize inside words.
Already existed: terminal newline collapsing, dictionary substitution,
insertionText prefix strip, Cua AX insertText path.

Remaining (8b): DictationPill glass UI at caret, streamed-on-26 insertion,
clipboard-paste fallback with TransientType, interruption keeps partial text,
7-day transcript backup, live latency + insertion matrix (J8).
