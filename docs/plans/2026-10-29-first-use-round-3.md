# First Use, Round 3 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `executing-plans` to implement task-by-task.

**Goal:** A new user talks through a short, voice-led onboarding that grants every permission once, Perry imports their AI memory itself, and every later turn starts fast and runs without approval prompts.

**Architecture:** Onboarding drops to five beats driven by speech. Every macOS permission is requested inside the access beat, so no prompt appears later. Routines and background tasks run autonomously, with the same single exception as Talk: writes to connected services ask first. Claude Code keeps a pre-spawned process ready, uses Haiku 5.5 for quick turns, and the user picks the model per brain.

**Tech Stack:** Swift 6, SwiftUI, XcodeGen, cua-driver, Claude Code CLI (`-p --input-format stream-json`).

**Where work runs:** build, test and drive on the mini only (`~/honey/perry`, Xcode 27). Install on the laptop only when the user asks.

---

## Phase A: Speed and brain choice

### Task 1: Measure the Claude Code floor before changing it

**Files:** `scripts/lab/claude-floor.sh` (new).

- Time three intervals for 10 runs each: process spawn to first stdout byte with no input written, input written to first `assistant` event, first event to `result`.
- Run with Haiku 5.5 and Sonnet 5.5 at `--effort low`.
- Expected: most of the ~6 s sits before stdin is read. If the boot share is under 2 s, stop Task 2 and report the real split to the user.
- Write the numbers to `docs/evidence/lab/claude-floor-2026-10-29.md`.

### Task 2: Keep one Claude Code process warm

**Files:** `Packages/PerryBrain/Sources/PerryBrain/Providers/ClaudeCodeProvider.swift`, `Packages/PerryBrain/Sources/PerryBrain/MCP/MCPScope.swift`, `App/Tools/MCPSocketLifecycle.swift`, `App/Tools/PerryMCPSocket.swift`, tests in `Packages/PerryBrain/Tests/PerryBrainTests/ClaudeCodeProviderTests.swift`.

- Approach: a spare process, one turn per process. Perry keeps its own history, so a long-lived Claude session would duplicate it.
- The spare's arguments must not depend on the turn:
  - `--system-prompt` carries only the stable part per surface. The per-turn context (observation, memory, time) moves into the first user message.
  - The MCP scope opens empty. The bridge attaches when the turn starts. `MCPScopeHost.openScope()` gains a variant with no bridge, plus `attach(_ bridge:)`.
- `warm()` spawns the spare for the current model and effort. Each finished turn spawns the next one. A model or effort change discards the spare.
- A spare older than 10 minutes is discarded, so a stale login or update cannot break a turn.
- Tests: the base arguments are identical for two requests with different context. The per-turn context appears in the input line. Discarding a spare terminates its process.
- Pass: the Task 1 script, run through Perry, shows the first token at least 3 s sooner at p50.

### Task 3: Haiku 5.5 for quick turns, and a model picker

**Files:** `Packages/PerryBrain/Sources/PerryBrain/BrainModelDefaults.swift`, `App/Brain/BrainController.swift`, `App/Brain/BrainChoiceSection.swift`, `App/PerryPreferences.swift`, `App/Onboarding/SetupBeat.swift`.

- `BrainModelCatalog.claudeCode` becomes fast `claude-haiku-5-5`, deep `claude-sonnet-5-5`.
- Add a per-brain model preference, `perry.brain.model.<choice>`. Empty means the catalog default.
- Settings › Brain: under the selected brain, show a "Model" menu.
  - Claude Code and API key (Anthropic): Haiku 5.5, Sonnet 5.5, Opus 5.5.
  - ChatGPT: the Codex models in the catalog.
  - The menu sets the fast tier. Deep stays at the larger model unless the user picks a larger one.
- Changing the brain already works in Settings and in onboarding. Keep it.
- Tests: a saved choice overrides the catalog. Clearing it restores the default.
- Live check: switch to Opus 5.5 in Settings, ask a question, confirm `--model claude-opus-5-5` in the process list.

## Phase B: Autonomous routines and background tasks

### Task 4: Remove action approvals outside connected-service writes

**Files:** `App/RoutineRunner.swift:542`, `Packages/PerryGuide/Sources/PerryGuide/RoutineReplay.swift:79,127`, `Packages/PerryRuntimes/Sources/PerryRuntimes/WorkspaceFilePlanFabricator.swift:25`, `Packages/PerryGuide/Sources/PerryGuide/WorkspaceUndo.swift:191`, `Packages/PerryRuntimes/Sources/PerryRuntimes/DoSupervisor.swift:320-360`, the matching tests.

- Rule: an action gets `.none` unless it writes to a connected service. Those keep `.action`.
- Do not change the `DoSupervisor` approval machinery. Change only what each plan asks for.
- The notch pill for "needs you" then appears only for connected-service writes.
- Tests: a routine that moves files runs to completion with no approval event. A routine that sends an email parks on approval.
- Live check: on the mini, create a routine "every minute, move screenshots on the Desktop to Documents/Shots", wait two minutes, confirm the files moved and no card appeared.

## Phase C: Every permission in onboarding

### Task 5: One access beat for all permissions

**Files:** `App/Onboarding/OnboardingBeats.swift` (AccessBeat), `App/Onboarding/OnboardingDirector.swift`, `Packages/PerryCapture/Sources/PerryCapture/PerryPermissionProbe.swift`, `App/SystemNotifier.swift`, `App/SystemCalendar.swift`, `App/DictationController.swift`, `App/BackgroundTaskController.swift:259`.

- Rows, in this order:
  1. Microphone and Speech Recognition, one row.
  2. Notifications.
  3. Calendar.
  4. Accessibility.
  5. Screen Recording, last, because macOS relaunches Perry.
- Perry says each row's reason aloud before macOS shows its dialog. One "Allow" per row. Rows that use a system dialog (1-3) chain without leaving the beat.
- Before Screen Recording, Perry says "I'll restart once you allow this." After the relaunch, onboarding resumes on the next beat.
- Remove the late requests: `BackgroundTaskController:259` and the calendar and speech request paths only read status. If a permission is missing, Perry says which one and opens its Settings pane. Perry does not call the request API there.
- Input Monitoring stays unused. Accessibility covers the event taps.
- Tests: `OnboardingDirectorTests`, access advances only when every row is granted or skipped. A grep test fails if `requestAuthorization` or `requestFullAccessToEvents` is called outside the access beat.
- Live check: reset TCC on the mini, run onboarding, record it with `scripts/lab/record.sh`, then use every feature once. Pass: no macOS prompt after the access beat.

## Phase D: Voice-led onboarding

Beats become: hello and name, brain (shown only when no brain is detected), access, interview, first goal. The shortcuts and apps beats are deleted.

### Task 6: Delete the shortcuts and apps beats

**Files:** `App/Onboarding/OnboardingDirector.swift`, `App/Onboarding/OnboardingBeats.swift`, `App/Onboarding/AppsBeat.swift` (delete), tests.

- The talk shortcut is taught once, by voice, at the end of onboarding: "Hold Control and Option any time to talk to me." The key stays changeable in Settings.
- Apps come from the interview answer and the installed-app list. No screen asks for them.
- Run `xcodegen generate` after deleting the file.

### Task 7: Interview with no buttons

**Files:** `App/Onboarding/InterviewBeat.swift`, `App/Onboarding/ProfileExtraction.swift`, `AppTests/InterviewModelTests.swift`.

- Delete the `style` and `review` steps.
  - Style: infer it from the introduction length. The user changes it in Settings › You.
  - Review: Perry says one sentence of what it learned and asks "Did I get that right?" The mic opens. A correction is sent to extraction again.
- The "Done" button is removed. End of speech submits. "Type" stays as a small secondary button.
- Tests: the step list contains no `style` or `review`. A spoken correction updates the saved profile.

### Task 8: Perry imports memory itself

**Files:** `App/Onboarding/InterviewBeat.swift` (`importNotes` step), new `App/Onboarding/MemoryImport.swift`, `App/Tools/` (reuses the existing browser and UI tools).

- Perry asks by voice: "Do you use ChatGPT or Claude? I can grab what it remembers about you." The answer selects the service. "Neither" skips.
- With a yes, Perry acts in front of the user with the Talk agent and its existing tools:
  1. Open the service in the default browser.
  2. If the user is not signed in, say so and wait for them to sign in. Never type credentials.
  3. Start a new chat. Send the existing memory request. Read the reply from the accessibility tree.
- The reply goes through `ProfileExtraction`, the same path as pasted notes.
- The user's yes is the authorization. Perry asks once, before it opens the browser.
- Failure (no reply in 60 s, layout not found) leaves the user where they are. Perry says "I couldn't read it. You can paste it in Settings › You."
- Live check on the mini: a signed-in ChatGPT in Safari. Pass: profile facts from the ChatGPT reply appear in `profile.md`.
- Risk: this needs a signed-in account on the mini. If none exists, the live check waits for the user.

### Task 9: First goal by voice, with no canned prompt

**Files:** `App/Onboarding/FirstGoalBeat.swift`, `AppTests/FirstGoalTests.swift`.

- Perry says "What do you want to learn first?" and the mic opens. The text field becomes the "Type" fallback.
- Delete `askPrompt`, `promise(_:)` and the "Something else" and "Start" buttons. The user's own words go to a Talk turn, and Perry acts on them.
- Delete the "I'll start on it and ask before I change anything" line. It contradicts the no-approval rule.
- Tests: the goal text reaches the session unchanged.

## Phase E: Voice and cursor gaps

### Task 10: Speak typed answers

**Files:** `App/Talk/TalkSession+Ask.swift`, `App/Home/` composer path.

- A typed Home question gets a spoken answer unless the user muted Perry's voice in Settings.
- Test: a typed turn calls `speak` once.

### Task 11: The real pointer moves before an action

**Files:** `App/Tools/UITools.swift` (`showActuation`).

- In foreground, not unattended, animate the real pointer to the target over 250 ms with `CGWarpMouseCursorPosition` steps, then act. The ghost cursor stays for unattended work.
- If the user moves the mouse during the animation, stop and let cua act without moving the pointer.
- Live check: record a "open Calculator and compute 12 × 7" run. Pass: the pointer reaches each key before the key highlights.

### Task 12: Muted audio is said, not hidden

**Files:** `App/Talk/TalkSession.swift:388`.

- When output is muted, show the answer text in the notch. Add a one-line note "Sound is off". Delete the "full answer is in your conversation" banner.

### Task 13: Prove click-to-dismiss and the T3 Code failure

- Click-to-dismiss: test on the mini with a real HID click through cua-driver's Screen Sharing path. If no real click is possible, ask the user to click once on the laptop.
- T3 Code: after install, read `log show --predicate 'subsystem == "ai.perry.talk"'` on the laptop for the next failure.

## Out of scope

- OAuth setup for connected services (deferred by the user).
- Bundle size, updates and notarization.

## Verification for the whole round

- Mini: `xcodebuild test` for the app, then `swift test` for PerryBrain, PerryRuntimes, PerryGuide and PerryOverlay.
- One full recording of a fresh onboarding on the mini, reset with `tccutil`, reviewed frame by frame.
- `progress.md` updated after each phase with the evidence paths.
