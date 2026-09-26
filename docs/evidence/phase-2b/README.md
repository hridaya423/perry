# Phase 2b — Talk app wiring evidence

Date: 2026-09-26. Plan: `docs/plans/2026-09-26-phase-2b-talk-app.md`.
Scope: app-side Talk loop wiring — hold gesture, pointer trace, speech I/O,
context, orchestration, session state.

## Delivered

- `App/Talk/ModifierHoldMonitor.swift` — listen-only `flagsChanged` CGEventTap:
  ⌃⌥ hold = Talk (keydown/keyup marks), bare-⌃ double-tap (350 ms) = typed
  composer (`toggleSession`), `tapDisabled` re-enables + ends the hold.
  `NSEvent` global/local monitor fallback when the tap cannot be created.
- `App/Talk/PointerTraceRecorder.swift` — 60 Hz memory-only ring buffer (360
  samples = 6 s), injected point/perry-frames/window providers; samples in AX
  space; `overPerry` flag from live Perry window frames; `windowID` via
  CGWindowList topmost layer-0 non-Perry hit.
- `App/Talk/TalkSpeech.swift` — `TalkSpeechInput`/`TalkSpeechOutput`
  protocols; `SFSpeechInput` reuses `DictationController` (route fallback,
  buffering) and maps `SFTranscriptionSegment`s → `SpokenWord`s on the trace
  epoch; `SystemVoiceOutput` (AVSpeechSynthesizer, honours speech prefs,
  immediate `stopSpeaking` on barge-in).
- `App/Talk/TalkContext.swift` — `TalkContextStore`: one SpatialConversation
  per (processID, windowID), 10-minute TTL, "new topic"/"forget that" reset.
  Memory only.
- `App/Talk/TalkSession.swift` — the loop: keyDown → listening UI + parallel
  trace/STT/capture/provider-warm; keyUp → finalize STT → deixis resolve →
  route → streamed parse (text + `⟦…⟧` draw tags + gated tool calls) →
  sentence-chunked TTS + overlays; barge-in cancels all work and speech.
  Ask-never-acts is structural: only `drawToolSpecs` are offered, every model
  tool call passes `ToolGate.check(on: .talk)`, secure AX elements are
  filtered before indexing.
- `App/SessionController.swift` — `TalkSessionState`, `.talking` case,
  `startTalk`/`updateTalk`, `.talking` handled in `fail`/`completeDismissal`,
  `isTalkingSession` helper.
- `App/DictationController.swift` — `DictationRecognitionEvent.transcript`
  now carries `[SFTranscriptionSegment]`; new `onSegments` callback.
- `App/AppController.swift` — `talkSession` + `modifierHoldMonitor` wiring:
  capture mirrors `AskSessionController.capture` via a private
  `talkTargetStore`; routing via `brain.route`; app skills via a private
  `AppSkillLibrary`; monitor started beside `voice.startInputListeners()`;
  state sink cancels Talk when the session leaves `.talking`.
- `App/AskSessionController.swift` + `App/AgentActivityStrip.swift` —
  `.talking` handled in both exhaustive switches (Ask refuses while talking;
  the strip shows Listening/Answering).
- `AppTests/TalkControllerTests.swift` — 15 tests: hold/double-tap/disable
  state machine, trace ring + overPerry, context TTL/reset/isolation, secure
  filtering, session lifecycle.

## Build & tests (2026-09-26)

- `xcodegen generate --spec project.yml` — clean (App/Talk globbed in).
- `xcodebuild build … -derivedDataPath build/debug-p1` — **BUILD SUCCEEDED**
  (Debug, arm64).
- `xcodebuild test -scheme Perry -only-testing:PerryTests/{Talk*,
  DictationControllerTests}` — **29 tests, 0 failures** (15 new Talk tests +
  14 updated dictation tests).
- `swift test --package-path Packages/PerryBrain` — **114 tests, 0 failures**
  (unchanged).
- `git diff --check` — clean.

## Perf markers wired

`talk.keydown`, `talk.keyup`, `talk.listening`, `talk.bargein`,
`bargein.silence`, `talk.first_audio`, `answer.first_text`,
`ink.first_draw`, `composer.open`, `capture.done` (via capture path).

## Known gaps / open decisions

- Live hold-loop latency (≤50 ms keydown→listening, ≤1.5 s release→ink,
  ≤150 ms barge-in→silence) is instrumented but **not yet measured** — needs a
  real ⌃⌥ hold against the running app (cua-driver sends per-window events;
  a global flagsChanged hold needs `cliclick`-style HID or manual testing).
- ⌃⌃ double-tap currently opens the existing invoke panel as the typed
  composer; a dedicated Talk composer surface is a Phase 3+ UI decision.
- Talk keeps its session in `.talking` after the answer so a re-hold continues
  the conversation; dismissal is the normal Escape/hotkey path.
- No realtime-voice output path yet — `SystemVoiceOutput` is the only
  `TalkSpeechOutput` implementation; a realtime implementation slots into
  `services.output` when Phase 1 realtime latency data supports it.
- `services.memory` returns nil — memory surfacing is Phase 9 scope; the hook
  is in place.
