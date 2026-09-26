# Phase 4 evidence — Onboarding as the first magic

Sub-plan: `docs/plans/2026-09-26-phase-4-onboarding.md` (surveys the wizard
it replaces and settles the beat model, file list, and open decisions).

## Delivered so far

- `App/Onboarding/OnboardingDirector.swift` — the beat state machine:
  `greet → firstTalk → screenAccess → brainChoice → practice(pointAsk →
  guide → renameUndo → dictate) → finale → done`. Injected `Effects`
  (permission probe, speak, settings-link, practice, finish) make the whole
  script unit-testable. 500 ms permission polling while `screenAccess` is
  active; grants auto-advance — no "Retry" button. Denied mic swaps the
  firstTalk beat to the keyboard variant; every beat + practice sub-step is
  skippable; stale events outside their beat are ignored.
- `AppController`: `ProcessInfo.disableAutomaticTermination` opt-out at
  launch (HeyClicky lost first-run setups to mid-setup termination).
- `project.yml` usage strings rewritten warm + specific: mic ("never
  listens in the background"), speech ("on this Mac… nothing leaves the
  Mac for speech"), AppleEvents ("only for a task you asked… undo or
  stop").

## Tests

`AppTests/OnboardingDirectorTests` — **8 tests, 0 failures**:
talk-turn drive, full skip walk (beat sequence incl. per-sub-step
practice), denied-mic variant both orderings, grant auto-advance via the
real 500 ms poll, denied-permission no-dead-end, practice step chain,
stale-event no-ops.

`xcodebuild build -derivedDataPath build/debug-p1`: **PASS**.
`git diff --check`: clean.

- `App/Onboarding/PracticeWindow.swift` — bundled surface: real NSWindow
  (real AX elements for Guide/deixis), fake controls (toggle, button,
  labels), three real files in `~/Library/Application Support/Perry/
  PracticeSandbox` with real rename+undo file ops, and a text box whose
  first keystrokes/dictation fire `.dictated`.
- `TalkSession.onTurnCompleted` hook (fired at stream end).
- `AppController` wiring: `runOnboarding`/`runDebugOnboarding` now drive
  `OnboardingDirector` — beats speak via `SystemVoiceOutput` +
  `taskBubbleText` captions (no window, per §4.1); `screenAccess` opens the
  Privacy-Accessibility deep link; `brainChoice` pops an NSMenu at the
  cursor (ChatGPT → `brain.signInWithChatGPT()`, on-device, BYOK →
  Settings, Skip); `practiceWindow.onEvent` and guide-completion (session
  state → `.idle` during the `.guide` step) advance sub-steps; denied mic
  is probed up front via `PerryPermissionProbe.checkMicrophone()`.
- **Deleted:** `App/OnboardingWindow.swift`, `OnboardingFlow.swift` +
  `OnboardingFlowTests`, `OnboardingWindowTests`; SemanticTypographyTests
  sweep list updated. `DemoDirector` kept — it backs the separate
  Watch-and-Learn recording feature (`recordDemoMenuItem`); only its
  onboarding demo-offer overlapped and that role moved to practice beats.

## Verification round 2

- `xcodebuild build -derivedDataPath build/debug-p1`: **PASS**.
- `swift test --package-path Packages/PerryGuide`: **267 tests, 0
  failures** (274 − 7 OnboardingFlowTests).
- `xcodebuild test` focused (OnboardingDirector 8, SemanticTypography 1,
  InkAccentSampler 2): **PASS**.
- `git diff --check`: clean.

## Not yet done

- Guide-on-System-Settings toggle pointing (deep link opens; Perry pointing
  at the actual toggle needs a Guide run on System Settings — live).
- Live acceptance: fresh-run timing (≤90 s first magic / ≤3 min total),
  recorded — needs a TCC-capable run (permissions granted interactively).
