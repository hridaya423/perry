# Phase 2a — Talk core (pure) evidence

Date: 2026-09-26. Spec: `docs/plans/2026-09-26-phase-2a-talk-core.md`.
Scope: PerryBrain-only pure logic — no TCC, audio, or screen needed.

## Delivered

- `Sources/PerryBrain/Talk/DeixisResolver.swift` — demonstrative lexicon
  (en/es/fr/de/hi/ja/zh incl. CJK particle prefixes), still-pointer →
  window-level bindings, pointer-lead (250 ms) sample selection with
  latest-before/earliest fallback, `overPerry` trace filtering,
  `windowOffsets` re-resolution, smallest-frame hit test, `contextLines`.
- `Sources/PerryBrain/Talk/InlineMarkupParser.swift` — streaming
  `⟦verb target? "label"?⟧` parser; split-tag buffering, 200-char/finish
  verbatim flush, valid-element gating, `clear` without target.
- `Sources/PerryBrain/Talk/ToolSurface.swift` — `.talk`/`.guide` allow
  observe ∪ draw only; `.agent` everything; rejections logged via
  `os.Logger` (subsystem `ai.perry.brain`, category `tool-gate`).
- `Sources/PerryBrain/Talk/TalkPrompt.swift` — `ElementIndex` (compact
  `e17` ids, deterministic by observation order) + `TalkPrompt.system`
  prompt contract (elements, bindings, memory, skill, never-act rule).
- `Sources/PerryBrain/Talk/SentenceChunker.swift` — streamed text →
  speakable sentences for TTS (boundary = terminator + whitespace or
  newline; decimals safe; `finish()` flush). Phase 2b will consume both.

## Tests

`swift test --package-path Packages/PerryBrain`:
114 tests, 0 failures (71 pre-existing + 43 new).
New suites: `DeixisResolverTests` (17), `InlineMarkupParserTests` (9),
`ToolGateTests` (6), `SentenceChunkerTests` (8), `TalkPromptTests` (3) —
covering every case named in the spec, including the
malicious `ui.click`-on-`.talk` rejection (Phase 2 item 6 structural half;
the app-side dispatch check is Phase 2b).

`git diff --check`: clean.
