# Phase 2b: Talk app wiring (DRAFT — lead review before implementing)

Scope: the app-side Talk loop that consumes the Phase 2a pure core
(`Talk/DeixisResolver.swift`, `Talk/InlineMarkupParser.swift`,
`Talk/ToolSurface.swift` in PerryBrain). Covers master plan §6.4 pipeline and
§7 Phase 2 items 1, 3, 4, 5, 7 — the parts that need AppKit, TCC, audio, and a
live window. Nothing here changes the settled 2a interfaces.

## New files (`App/Talk/`)

- `ModifierHoldMonitor.swift` — replaces `PushToTalkController`. Listen-only
  `CGEventTap` on `flagsChanged`: hold ⌃⌥ to talk, double-tap ⌃ opens the typed
  composer. Reuses PushToTalkController's tap create/fallback-monitor/tap-
  disabled-rearm pattern. Emits `PerfMark` `talk.keydown`/`talk.keyup` and
  `composer.open`.
- `PointerTraceRecorder.swift` — 60 Hz ring buffer of `TraceSample` during the
  hold only (start on key-down, freeze on key-up; ~5 s cap ≈ 300 samples,
  memory-only). Point = `NSEvent.mouseLocation` in AppKit coords converted to
  the AX space the observation uses; `windowID` from the observation's
  `windowID`; `overPerry` when the point is inside any Perry overlay window
  frame (via `OverlayWindowManager`).
- `SpeechInput.swift` — protocol producing `[SpokenWord]`-compatible word
  timestamps:
  ```swift
  protocol TalkSpeechInput: Sendable {
      func start() async throws
      var words: AsyncStream<SpokenWord> { get }   // partial + final, timestamped
      func stopAndFinalize() async throws -> [SpokenWord]
      func cancel()
  }
  ```
  Implementations: `SFSpeechInput` (14+, reuse VoiceController's recognizer
  plumbing; on-device when `supportsOnDeviceRecognition`), `SpeechAnalyzerInput`
  (macOS 26+, `SpeechTranscriber`), `RealtimeInput` (adapt the existing
  `RealtimeVoiceSession` transcript events). Selection order: realtime endpoint
  configured → `RealtimeInput`; macOS 26+ → `SpeechAnalyzerInput`; else
  `SFSpeechInput`.
- `SpeechOutput.swift` — protocol:
  ```swift
  protocol TalkSpeechOutput: Sendable {
      func speak(sentences: AsyncStream<String>) async
      func shutUp()   // must be silent ≤150 ms (barge-in budget)
  }
  ```
  `SystemVoiceOutput` (AVSpeechSynthesizer, sentence-chunked, speed 0.5–1.5× via
  existing VoiceController prefs), `RealtimeOutput` (realtime session audio),
  `OpenAITTSOutput` (BYOK key). Sentence chunker is a pure helper in PerryBrain
  (`Talk/SentenceChunker.swift`, unit-tested): splits streamed text on
  `.?!…` + newline boundaries, flush remainder at stream end.
- `TalkSession.swift` — key-down→done orchestration replacing the Ask path of
  `AskSessionController`:
  1. key-down: `sessionController` → `.talking`, listening UI ≤50 ms,
     `provider.warm()`, start trace + capture + STT in parallel.
  2. key-up: stop STT → words; `DeixisResolver.resolve` against trace +
     `ObservedElement`s mapped from `GuideObservation.snapshot.elements`
     (windowID from `observation.windowID`).
  3. Build `ModelRequest`: system = prompt contract (below), user = transcript +
     `DeixisResolver.contextLines(bindings)` + compact element index; tools =
     `ToolGate.filter(specs, for: .talk)`; every model-emitted `ToolCall` passes
     `ToolGate.check` before dispatch.
  4. Stream: `.textDelta` → `InlineMarkupParser.feed` → caption text + draw
     commands → ink layer; sentences → `SpeechOutput.speak`; `.done` →
     `finish()` flush.
  5. Barge-in: any `ModifierHoldMonitor` key-down during speak → cancel turn
     task + `shutUp()`, `PerfMark` `talk.bargein` → silence checked ≤150 ms.
- `TalkComposer.swift` — typed composer (double-tap ⌃): glass field at cursor,
  same pipeline minus STT, answer as caption, ⌘C copies.
- `TalkContext.swift` — 10-min follow-up context keyed by app window
  (processID+windowID): keeps `SpatialConversation` turns + last observation
  ID; "new topic" or >10 min idle clears. Pure-ish store, unit-tested with
  injected clock.

## New PerryBrain file (pure, headless-tested) — DONE

- `Sources/PerryBrain/Talk/TalkPrompt.swift` — IMPLEMENTED as
  `ElementIndex` (stableID ↔ compact "e17" ids, deterministic by
  observation order; `validIDs` feeds `InlineMarkupParser`) and
  `TalkPrompt.system(index:bindings:memory:skill:)` per the prompt
  contract. Sensitive elements must be filtered in the app-side
  `AXElement`→`ObservedElement` mapping — `ObservedElement` carries no
  sensitivity flag.
- `Sources/PerryBrain/Talk/SentenceChunker.swift` — IMPLEMENTED:
  boundary = terminator + whitespace or newline, decimals safe,
  `finish()` flush. Tests: `SentenceChunkerTests` (8), `TalkPromptTests` (3).

## Modified

- `SessionController.swift`: add `.talking(TalkSessionState)`; Talk never
  preempts `.guiding`/`.executing` (same rule Ask uses).
- `AppController.swift`: `ModifierHoldMonitor` wiring → TalkSession; keep
  `PushToTalkController` compiled until Talk is proven live, then delete.
- `AskSessionController.swift`: voice path retired to TalkSession; typed Ask
  path migrated to TalkComposer (delete only after callers migrate).
- `VoiceController.swift`: shrinks to device/route + voice prefs; Talk borrows
  `speakingVoice` selection and the synthesizer.
- `project.yml`: add `App/Talk/` sources (xcodegen glob should pick it up).

## Perf marks

`talk.keydown` → `talk.listening` (≤50 ms), `talk.keyup` → `answer.first_text`
(≤700/1500 ms), `talk.first_audio` (≤1.0 s realtime / 1.4 s system), `ink.first_draw`
(≤1.5 s), `talk.bargein` → `bargein.silence` (≤150 ms). All already pairable via
`scripts/lab/latency-report.py --pair`.

## Open decisions for lead

1. Hold key: plan §6.7 says ⌃⌥ hold; today PTT is ⌥⌘Space. Default both in
   ModifierHoldMonitor or migrate the setting?
2. Does TalkSession keep the Ask panel UI (`SessionPanelView`) as its bubble,
   or new glass surface? Plan says "replaces SessionPanelView" — new surface?
3. Screenshot for the model: reuse `observation.screenshotData` (JPEG) as the
   `ModelContentPart.image`, temp-file rules from Phase 1 still apply?
4. Typed composer: before or after voice path lands?
5. `SpeechAnalyzerInput` on macOS 26 needs entitlements check — confirm the
   app's entitlements/Info.plist cover `Speech` + microphone for Talk.

## Verification

- `swift test --package-path Packages/PerryBrain` green (new pure tests:
  ElementIndex determinism, prompt contents, SentenceChunker boundaries).
- Focused `xcodebuild test … -only-testing:PerryTests` for TalkSession state
  transitions with a scripted `ModelProvider` stub (stream deltas → draw/tts
  fan-out; `ui.click` rejected via ToolGate).
- Live drill (recorded via `scripts/lab/record.sh`): hold ⌃⌥, point at a
  Finder control, "what does this do?" → ring on right element + spoken
  answer; barge-in mid-answer; double-tap ⌃ typed path. Latency report +
  60 s idle probe into `docs/evidence/phase-2/`.
