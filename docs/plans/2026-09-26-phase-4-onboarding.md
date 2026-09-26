# Phase 4 — Onboarding as the first magic

Master plan §7 Phase 4 + §4.1. Replaces the 7-card engineering wizard with a
beat script driven by the Talk pipeline and the overlay.

## Surveyed current state

- `Packages/PerryGuide/Sources/PerryGuide/OnboardingFlow.swift` — actor state
  machine, 7 steps, permission auto-skip on `probe()`, runtime detect via
  `CLIRuntime`/`CodexRuntime` locators. `App/OnboardingWindow.swift` (578 ln)
  is the titled NSPanel card UI; presented by `AppController.runOnboarding`
  (gated on `onboardingCompletedKey` default) and `runDebugOnboarding`
  (DEBUG, all-denied fixture).
- `PerryPermissionSnapshot.probe()` (PerryCapture) already polls
  `AXIsProcessTrusted` / `CGPreflightScreenCaptureAccess` / mic status —
  reuse, don't re-implement. 500 ms polling is a Timer in the director while
  a permission beat is active.
- `App/DemoDirector.swift` (166 ln) is the sandboxed demo — its beats fold
  into the PracticeWindow beats (rename files in sandbox + undo).
- `AppController` is `applicationDidFinishLaunching` host; onboarding hooks
  at `runOnboardingIfNeeded` / `runDebugOnboarding`.
- No `disableAutomaticTermination` call today.
- Info.plist usage strings live in `project.yml` — currently terse
  engineering copy ("uses the microphone only while you hold a session
  open…"). Phase 4 wants warm, specific strings.

## Beats (§4.1)

```
greet        — cursor fades in; "Hi, I'm Perry. Hold ⌃⌥ and say hi."
firstTalk    — wait for the first Talk turn to complete (or keyboard path)
screenAccess — open System Settings deep link; Guide points at toggles;
               500 ms grant polling; advances on requiredPermissionsGranted
brainChoice  — ChatGPT sign-in (account/login/start) / "Use this Mac" /
               "I have a key"; skippable
practice     — PracticeWindow beats: point+ask, 2-step guide,
               rename+undo in a bundled sandbox, dictation in a text box
finale       — "I live up here. Hover any time."; writes
               onboardingCompletedKey; tucks to notch
```

Rules: every beat skippable and keyboard-doable; denied mic → keyboard
variant of the beat (no dead-ends); permission grants detected by polling,
no "Retry" buttons; replay from Settings.

## Files

- **New** `App/Onboarding/OnboardingDirector.swift` — `@MainActor` beat
  state machine; injected `permissionProbe`, `clock`, and effect closures
  (`speak`, `openSettingsPane`, `startGuideOnSettings`, `runPracticeBeat`,
  `finish`). Pure transitions unit-tested via fake probe/events.
- **New** `App/Onboarding/PracticeWindow.swift` — bundled SwiftUI window:
  fake buttons/files/text box so Guide/Do/dictation beats have a safe,
  deterministic surface (no real app damage possible).
- **New** `App/Onboarding/OnboardingOverlay` glue — captions + ink via the
  existing `visualGuidanceOverlays`/`externalCaption` paths; no new surface.
- **Modify** `AppController` — `runOnboarding` drives the director instead
  of `OnboardingWindow.show`; `disableAutomaticTermination`; keep
  `runDebugOnboarding` DEBUG path (denied fixture → director).
- **Modify** `project.yml` usage strings (warm copy).
- **Delete (after director lands + tests green):**
  `App/OnboardingWindow.swift`, `Packages/PerryGuide/Sources/PerryGuide/
  OnboardingFlow.swift`, `App/DemoDirector.swift` (folded), and their tests
  replaced by `OnboardingDirectorTests`.
- `EnvironmentProbe.swift` — keep as the runtime-detect source for the
  brainChoice beat.

## Acceptance

- Fresh run (reset `onboardingCompletedKey`): greet → first answer ≤90 s,
  full flow ≤3 min, zero Settings visits beyond TCC toggles.
- Permission beat advances live on grant (poll), never dead-ends.
- `OnboardingDirectorTests`: beat order, skip paths, denied-mic adaptation,
  permission-grant auto-advance, replay.
- App builds; focused `xcodebuild test` green; `git diff --check` clean.
- Evidence: `docs/evidence/phase-4/README.md` + recorded fresh-run when
  TCC allows.

## Open decisions

- The §4.1 deep link `x-apple.systempreferences:com.apple.preference.
  security?Privacy_Accessibility` + Guide-on-Settings pointing is a live
  drill; unit tests cover the beat logic only.
- ChatGPT `account/login/start` reuse: CodexAppServerProvider already owns
  the login flow — director calls into BrainController, no new client.
