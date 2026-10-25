# C4 — Structural code review (2026-10-25)

Scope: `App/` (39,182 lines), `Packages/*/Sources` (23,335 lines), `AppTests` (20,559) and `Packages/*/Tests` (17,245). Read-only review. No build, test, or app run. "Unused" means a grep of type and symbol names across `App`, `Packages/*/Sources`, and tests found no other reference. Selector strings and runtime reflection were not checked.

## Verdict

1. Not "perfect". The behavior is carefully guarded, but the structure carries a large amount of ceremony and left-over code from three redesigns.
2. `AppController` is the real god object. It forwards 50 properties, implements five single-use "Host" protocols, and is extended from 12 files. Every behavior test has to construct it.
3. Voice is the worst duplication. It has three entry paths, five triggers, and four state enums for one idea, "a voice turn". A 2.4k-line opt-in realtime stack sits under it.
4. About 3–4k lines are removable with little risk. They are the demo flow, debug prototypes, dead package types, a dead UI branch, and bookkeeping for runtimes that route nothing. A further ~5k lines (the typed-plan engine) is an owner decision, because only routine replay reaches it.
5. The tests are better than the code shape. They are behavior and race oriented, and a slop purge already ran on 2026-10-21. About 20 render-to-PNG "tests" assert nothing. The riskiest router (`CommandRouter`) and quit/erase ordering have no direct tests.

## What is fine (so nobody "fixes" it)

- UserDefaults keys live in one place, `App/PerryPreferences.swift:30-77`. `scripts/ci.sh` fails the build if a raw `perry.*` key appears elsewhere. `@AppStorage` goes through `PerryPreferences.$x.key`.
- `SessionState` (`App/SessionController.swift:266-275`) is a real enum with throwing transitions. The state modelling problems below are around it, not in it.
- `MaintenanceCoordinator` makes quit and erase ordering explicit (`App/MaintenanceCoordinator.swift:40-200`). Its complexity is earned.
- `#if DEBUG` is used consistently. The debug files are fully wrapped, so they do not ship in release. They are clutter, not a release risk.
- Concurrency is mostly disciplined. The 8 `MainActor.assumeIsolated` calls all sit inside callbacks registered with `queue: .main` or `Timer` (`App/Home/HomeController.swift:79-99,358`, `App/VoiceController.swift:185`, `App/NotchStatusController.swift:70`). The 27 `@unchecked Sendable` types I spot-checked (`ForegroundWorkerLease`, `AgentObservationStore`) guard state with a lock. Timers have invalidate paths (`HomeController.swift:111-130`). I found no retain cycle.
- Package boundaries are clean. `PerryBrain` does not import `PerryRuntimes`.

---

## Top 20 structural problems (ranked)

Severity: **Critical** blocks the UX rework; **High** will slow it down; **Medium** is real debt that can wait; **Low** is cosmetic. Line estimates are rough (−removed / +added).

### 1. Critical — `AppController` is a god delegate wearing a composition root

- Evidence:
  - `App/AppController.swift:21-73` has 50 one-line `subsystems.x` forwards ("keep existing call sites working").
  - Three initializers, one with 13 injected DEBUG seams (`:139-200`).
  - Extended from 12 files: `SettingsView.swift:870`, `SessionPanelPresenter.swift:165`, `CommandRouter.swift:151`, `MaintenanceCoordinator.swift:307-334`, `StatusMenuController.swift:311,377`, `GuideSessionBridge.swift:136,203,221`, `IntentCardPresenter.swift:93,110`, `DemoFlowController.swift:106,113`, `FailureNotice.swift:17`, `DiagnosticsExporter.swift:62`, `CuaDriverClient.swift:1585`, `DebugLaunchSeams.swift:71`.
  - Five Host protocols with one conformer each and zero test fakes: `CommandRouteHost` (`CommandRouter.swift:9`), `MaintenanceHost` (`:8`), `StatusMenuHost` (`StatusMenuController.swift:8`), `GuideBridgeHost` (`GuideSessionBridge.swift:10`), `DemoFlowHost` (`DemoFlowController.swift:7`). `MaintenanceHost` lists 24 members. They add indirection and no test seam.
  - Loose state on the controller: `talkSessionStarted`, `modifierHoldIsSteering`, `lastBackgroundCount`, `lastAwaitingApprovalCount` (`:107-110`).
  - 30 `AppController(` constructions in tests (`NotchSurfaceRenderTests` 8, `BackgroundTaskLifecycleOrderingTests` 13, `ForegroundPlanningTests` 5).
- Fix: delete the forwards. Give each coordinator the 3–6 collaborators it needs (the `Hooks` closure style already used by `VoiceController` and `ForegroundTaskController`). Delete the five Host protocols. Keep `AppController` as `NSApplicationDelegate` plus launch wiring.
- Size: −350 / +120. Do this first. Every later step touches these call sites.

### 2. Critical — Voice has three front doors, five triggers, and four state machines

- Evidence:
  - Talk: `ModifierHoldMonitor` (⌃⌥ hold) → `TalkSession` (`App/AppSubsystems.swift:298-335`, `App/Talk/TalkSession.swift:21-34`).
  - Dictation and steer: `PushToTalkController` (fn hold) → `VoiceController.beginDictation` (`App/VoiceController.swift:123-127,469`). `AppSubsystems.swift:304-307` routes the steer case into it.
  - Click to talk: the notch mic → `VoiceConversationController` → `DictationController` (`AppSubsystems.swift:272-296`, `App/VoiceConversationController.swift:1-110`).
  - Also the wake word (`WakeWordListener`) and the wake shortcut (`HotkeyController`).
  - `VoiceConversationController` (312 lines) is `TalkSession` with a different front. It has its own permission flow, silence timeout, finalize delay, output, and `State` enum. Both end in `HomeController.runSpokenTurn` (`AppSubsystems.swift:250` and `:281`).
  - "Where is the user in a voice turn?" is answered by `SessionState.talking`, `TalkSession.Phase`, `VoiceConversationController.State`, and `RealtimeVoiceSessionState`. `AppController.talkSessionStarted` (`:241`) reconciles two of them.
- Fix: one voice-turn owner. Fold `VoiceConversationController` into `TalkSession` (add a "click to start, silence to stop" gesture). `VoiceController` keeps only dictation-into-app. Do not change the triggers before this merge.
- Size: −300 / +100. A prerequisite for any voice or turn-taking change.

### 3. High — `VoiceController` (1,074 lines) is five jobs in one class

- Evidence, by line range in `App/VoiceController.swift`:
  - TTS and voice selection (`:175-465`).
  - Dictation and realtime event handling (`:467-730`).
  - Audio route and mute handling (`:731-771`).
  - Dictated-text insertion into the frontmost app plus learn-on-edit (`:772-980`).
  - Wake word and PTT shortcut management (`:981-1034`).
  - Shared by all: a `Hooks` struct of 8 closures (`:17-26`), plus 6 mutable "injection" properties for tests (`:62-90`).
- Seams: `SpeechOutput` (TTS + voice prefs, about 290 lines, already used standalone via `SharedTalkOutput`, `TalkSpeech.swift:171`) and `DictationInsertion` (about 210 lines, no dependency on live audio). Both are move-only extractions.
- Size: ±0 net (file moves). Do after #2.

### 4. High (owner decision) — Two execution engines; the typed-plan one is now almost unreachable

- Evidence:
  - Open-ended Do goes through the agent loop only: `ForegroundTaskController.swift:421-440`. Background tasks queue only `agentPlan` (`BackgroundTaskController.swift:265`).
  - The typed `DoSupervisor` path (`executePreparedPlan`, `ForegroundTaskController.swift:586-780`, about 195 lines) is reached from `runRoutineOperation` (`:353-396`) for Watch & Learn replay, and nowhere else in production.
  - `startWorkspaceTask` (`BackgroundTaskController.swift:608-695`) serves persisted `.executable` records. New ones can only come from `WorkspaceRunJournal` during routine replay. `.legacy` records "survive for inspection only" (`:589-599`).
  - Code that exists to support this path:
    - `DoSupervisor.swift` 851, `ExecutionPlan.swift` 442, `ExecutableActionDecoding.swift` 321, `WorkspaceFileRuntime.swift` 1,027, `ActionPolicyTable.swift` 223, approval registry and grant 203.
    - `TypedActionRouter`, `CompositeActionVerifier`, `RehearsalMarks` (`ForegroundTaskController.swift:1330-1440`).
    - `TaskCoordinator.swift` 1,439, `WorkspaceUndo`, and the workspace journals in `PerryGuide`.
    - Tests: `TypedExecutionPlanTests`, `TypedDoSupervisorTests`, `TypedWorkspaceFileRuntimeTests` (736), `TaskCoordinatorWorkspaceJournalTests` (776).
  - Evidence the owner already half-retired it: `ForegroundTaskController.swift:48` comment "Open-ended Do goals run through the agent loop"; progress.md says the purge deleted `TypedForegroundExecutionTests`.
- Fix: decide whether routine replay keeps its own engine. If yes, isolate it behind one `RoutineRunner` and stop calling it "Do". If routines replay through the agent loop, about 4–5k lines of source and about 2k of tests go away.
- Size: −0 (isolate) or −4,500 (retire). Must be decided before the prompts rework, because it fixes how many prompt surfaces exist.

### 5. High — The notch has four owners plus a legacy panel embedded inside the new one

- Evidence:
  - Expanded panel: `SessionPanelPresenter` (294), hosting `CompactConversationView` (230).
  - Status strip: `NotchStatusController` (240), plain AppKit, 5 booleans (`:12-16`).
  - Resting dot, eyes, peek, and hover: inside `HomeController` (`:352-470`).
  - Interaction queue: `NotchPresentation`, `NotchDialog`, `NotchConfirmation`, `TaskQuestionPresenter`.
  - `CompactConversationView.swift:75-91` switches between onboarding, the new `NotchWorkspaceView`, and the old `SessionPanelView` (ask/guide/do mode picker, 344 lines) via a `showsGuide` flag. `controller.pendingPromptText` and `pendingPromptDoMode` (`AppController.swift:483-486`) feed that flag.
  - A dead branch inside it: `SessionPanelView.swift:161` shows "Perry needs an AI agent" when `runtimes.choices.count > 1 && !hasExecutionCapableChoice`. `hasExecutionCapableChoice` is `choices.contains { $0.id != automaticID }` (`RuntimeCatalog.swift:136`), so the condition can never be true. The warning is unreachable.
  - Each owner computes camera inset and screen separately (`screenUnderPointer`, `safeAreaInsets` appear 18 times).
- Fix: before the notch rework, pick one `NotchSurface` owner for window, screen, and inset. Delete `SessionPanelView` and its prompt flags if the new workspace covers ask/guide/do. Move resting/peek out of `HomeController` (see #6). Delete the dead warning.
- Size: −450 / +120.

### 6. High — `HomeController` (882 lines) is two jobs and has a stale name

- Evidence, in `App/Home/HomeController.swift`:
  - Notch presence: global and local mouse and key monitors, hover intent, zone geometry, resting tab, eyes, blink timer, peek panel (`:76-470`).
  - Conversation ingress: `acceptInput`, welcome draft save, `runSpokenTurn`, thread refresh, maintenance admission (`:470-880`).
  - There is no Home window any more (`docs/plans/2026-10-02-notch-only-dark.md:7`). `HomeView` has no production reference except tests (`App/Home/HomeView.swift:9`; the rest of that file holds pages used by `NotchWorkspaceView`).
  - 8 test files touch it; the ingress half is what they test.
- Fix: split `NotchPresence` (monitors, zones, panels, about 400 lines, goes into the notch rework) from `ConversationIngress`. Rename `Home*` to `Workspace*` when touched.
- Size: ±0 net; delete the `HomeView` shell −14.

### 7. High — The live-demo flow ships in the release target and nothing in release calls it

- Evidence:
  - `DemoDirector.swift` 166, `DemoFlowController.swift` 121, `DemoRecipe.swift` 40 are not under `#if DEBUG`.
  - The only entry is the DEBUG-only menu item (`StatusMenuController.swift:119-120`). `AppController.runFlagshipDemo` and `demoVerifiedSummary` (`DemoFlowController.swift:113-120`) have zero callers.
  - Tentacles into live code: `foreground.runForDemo` (`ForegroundTaskController.swift:839-857`), `GuideSessionCoordinator.runGuideForDemo` and `cancelPendingDemoInputs` (`:355-368`), `MaintenanceHost.demoDirector` (`MaintenanceCoordinator.swift:24,278`), `RuntimeInventory.hasReadyCLI` (used only by the demo, `RuntimeInventory.swift:17`), `AppController.swift:95-96,450`.
  - The new onboarding (greet, first talk, brain, screen access, practice, finale) does not use it.
- Fix: delete.
- Size: −330 source, −72 test (`DemoDirectorTests.swift`).

### 8. Medium — Debug scaffolding is about 1,000 lines and partly obsolete

- Evidence:
  - `DebugInvocationPrototypes.swift` (206): "Throwaway… Nothing here ships; the winning shape is reimplemented in Phase 7" (`:5-9`).
  - `DebugCursorGallery.swift` 54, `FailureDrill.swift` 19, `DebugStateFixtures.swift` 271, `DebugLaunchSeams.swift` 291.
  - 75 `#if DEBUG` blocks in 26 files, including test-only members on production classes: `GuideSessionCoordinator.swift:294-330`, `BackgroundTaskController.swift:1021-1060`, `MaintenanceCoordinator.swift:54-65`, `VoiceController.swift:1036-1045`, `RealtimeVoiceSession.swift` (`audioStartOverrideForTesting` and others).
  - progress.md notes uncommitted DEBUG logging in four files from an earlier session.
- Fix: delete the prototypes and cursor gallery now (−260). Keep fixtures and seams only for surfaces that survive the rework; revisit after it.
- Size: −260 now, about −400 later.

### 9. Medium (owner decision) — `RealtimeVoiceSession.swift` (2,401 lines) is an opt-in feature with about 5.3k lines in total

- Evidence:
  - It is active only when the user sets a realtime endpoint (`VoiceController.swift:327-333`).
  - The file holds about 25 types: the response tracker, commit barrier, output reservation ledger, transport correlation, task ledger, audio ingress, pipeline, transport, and the session (`:45-1359`, session `:1359-2401`).
  - Related: `RealtimeTalkVoice.swift` 328, `RealtimeVoiceSessionTests.swift` 2,041 (54 tests, including a 10,000-utterance dedupe and tombstone bounds, `:1428,:1596`), `RealtimeVoiceFixtures.swift` 372, `RealtimeTalkVoiceTests.swift` 199.
  - It has two integration points (`VoiceController.swift:430` and `AppSubsystems.swift:211`).
- Fix: first, move the types to `App/Realtime/` as separate files with no logic change (mechanical). Then decide: keep it as a BYOK lab feature, or cut it. If the voice rework changes turn-taking, the machinery that guards late and stale events will need rework too.
- Size: ±0 (split) or −2,700 source / −2,600 test (cut).

### 10. Medium — Foreground and Background task controllers mix lifecycle, UI, and execution

- Evidence:
  - `ForegroundTaskController` (1,441): session observation, start/preflight, agent run (`:444-585`), routine replay, typed run, rehearsal marks (`:686-780`), activity strip (`:569-585,1201`), pause/resume/take over/steer/cancel (`:860-1020`), finalization (`:1130-1200`). It has no direct test file; it is only tested through `AppController`.
  - `BackgroundTaskController` (1,063): undo (`:100-190`), records, creation, controls, launch, outcome handling, workspaces, erasure lifecycle. About 90 lines are debug seeding.
  - Both re-implement pause/resume/cancel against `AgentCoordinator` (`Foreground:860-990`, `Background:313-340,444`).
- Fix: after #4, extract the activity strip and rehearsal marks from `ForegroundTaskController` (about 300 lines). Share one "agent-run control" adapter. Do not split further before the rework.
- Size: ±0.

### 11. Medium — Three overlapping "model / runtime / brain" catalogs

- Evidence:
  - `BrainController` (635, `App/Brain/BrainController.swift`): `ModelChoice` (chatGPT, claudeCode, acp, direct, local), profiles, ACP agent, local models, Codex login.
  - `ModelProfiles`, `ModelProfilesSection`, `BrainModelSettingsView`, `AcpAgentSection`.
  - `RuntimeCatalog`, `RuntimeInventory`, `RuntimeSetup`, `RuntimeSettingsState`, `RuntimeExecutableVerifier` — about 1,000 lines. Its own header says "Nothing routes through providers… this is install/auth bookkeeping only" (`RuntimeInventory.swift:9-12`). `RuntimeCatalog.choices` is read only by the dead warning in #5.
  - The Settings tab `.runtimes` is titled "Models" and shows both the real model picker and the bookkeeping list under "Agents" (`SettingsView.swift:536-560`).
  - OpenCode is bookkeeping only: it is not a `ModelChoice`. References: `OpenCodeRuntime.swift` (68), verifier code, inventory entry, `OpenCodeRuntimeTests`.
- Fix: one model settings surface driven by `BrainController`. Delete `RuntimeCatalog.choices`, `hasExecutionCapableChoice`, and the OpenCode entry. Show Codex and Claude Code install state inside the model picker rows.
- Size: −650 / +80.

### 12. Medium — Stringly-typed model and enum preferences

- Evidence:
  - `BrainController.modelChoice` is a `String`, with a parallel enum `ModelChoice`. It is re-parsed at 7 sites: `HomeConversationView.swift:174,231`, `HomeOnboardingView.swift:378,528`, `BrainModelSettingsView.swift:12,16`, `BrainController.swift:345`. Unknown values become "Saved model unavailable".
  - Same pattern for other persisted enums: `WakeShortcut(rawValue:)`, `PushToTalkShortcut(rawValue:)`, `RealtimeVoiceProtocolMode(rawValue:)` (`VoiceController.swift:336`, `SettingsView.swift:36-37,51`). Defaults are literals like `"optionCommandP"`, `"functionHold"`, `"chatGPT"`, `"automatic"` (`PerryPreferences.swift:42-56`).
  - Runtime ids are free strings: `"cli.codex"`, `"byok.vision"`, `"local.workspace-files"`.
- Fix: make `Preference<Value: RawRepresentable>` return the enum with a fallback; delete the 7 re-parse sites.
- Size: −40 / +25.

### 13. Medium — Boolean soup and parallel dictionaries in the controllers the rework will change

- Evidence:
  - `HomeController`: `acceptsInput`, `resumeMonitoring`, `insideZone`, `previewing`, `conversationVisible`, `welcomeDraftEdited`, `welcomeDraftLoaded` (`:15-50`).
  - `NotchStatusController` (`:12-16`): recording, background count, approval count, conversation visible, wake.
  - `HomeModel`: 21 `@Published`, with six dictionaries keyed by thread id (`drafts`, `conversationTargets`, `conversationPositions`, `pendingQuestions`, `threadErrors`, `streamingAnswers`) and several sets (`HomeModel.swift:36-107`).
  - `VoiceController`: seven optional dictation fields that must move together (`:41-52`).
  - `AppController.sessionStatus` and `transcriptPreview` are free strings that every subsystem writes (`:121-122`).
  - `GuideWorkerSession`: six `Task?` fields and flags (`GuideSessionCoordinator.swift:83-110`).
- Fix: replace per-thread dictionaries with one `ThreadUIState` struct per thread; replace presence booleans with a `NotchPresence` enum while doing #6. Do not rewrite the rest before the rework.
- Size: −150 / +100.

### 14. Medium — Onboarding has one real path, but it is spread over misnamed files and entangled with unrelated code

- Evidence:
  - The beats live in `App/Home/HomeOnboardingView.swift` (590). They are not Home views. `OnboardingParts` 546, `HelloGreetingView` 213, `OnboardingNotchView` 95, `OnboardingDirector` 216, `OnboardingCoordinator` 152, `PracticeWindow` 199.
  - `HomeModel.onboarding` is an optional director (`HomeModel.swift:40`), and it is rendered from both `HomeView.swift:14` and `CompactConversationView.swift:75`.
  - `runOnboarding(force: true)` is called from 5 places (`PerryApp.swift:46`, `AppSubsystems.swift:416,599`, `DemoFlowController.swift:109`, `DebugLaunchSeams.swift:217`). One of them is the dead demo; the DEBUG "runtimeMissing" drill re-runs onboarding as a failure test (`DebugLaunchSeams.swift:217`).
  - `FirstTalkBeat` depends on `VoiceConversationController` (`HomeOnboardingView.swift:18,82`), so onboarding is coupled to voice problem #2.
  - Persistence is three prefs (`PerryPreferences.swift:33-35`), tested by `OnboardingDirectorTests` (17 tests, well-shaped).
  - `PracticeWindow` is a floating `NSWindow` (`PracticeWindow.swift:115`), against the notch-only contract in `progress.md`.
- Fix: before the onboarding rework: delete the demo (#7), do #12, and move the beat views into `App/Onboarding/`. The director and its tests can stay as the stable boundary.
- Size: ±0 net (moves), −0.

### 15. Medium — `RemoteIntegrations.swift` (1,844 lines) holds seven concepts; there are three integration systems

- Evidence:
  - In one file: write-operation enums (`:22-203`), a 585-line provider catalog (`RemoteIntegrationDefinition`, `:276-860`, 4 hardcoded providers: Notion, Slack, Linear, Google Workspace), a GraphQL tokenizer (`:296-330`), OAuth config, tokens, credential store actor (`:891-1087`), OAuth coordinator (`:1161`), REST client actor (`:1343`), and action runtime (`:1674`).
  - Parallel systems: MCP connectors in `PerryBrain/MCP/*` plus `CustomConnectors.swift` (213), and `IntegrationBackendAdapter`, `IntegrationConnections`, `IntegrationRow`, `IntegrationTools`.
  - Tests: `RemoteIntegrationClientTests` 534, `RemoteIntegrationPolicyTests`.
- Fix: split by the seams listed (mechanical). Decide whether the 4 OAuth providers survive next to generic MCP connectors. It is not blocking the UX rework.
- Size: ±0 (split).

### 16. Medium — Dead or test-only production code in the packages and app

- High confidence (zero references outside own file; tests only or none):
  - `Packages/PerryRuntimes/Sources/PerryRuntimes/RuntimePlanningPrompt.swift` (32): no references at all, no test.
  - `Packages/PerryGuide/Sources/PerryGuide/FinderTaskSuite.swift` (163), test `FinderTaskSuiteTests` (131).
  - `Packages/PerryBrain/Sources/PerryBrain/Grounding/ElementChooser.swift` (87: `ElementChooser`, `HTTPChooserTransport`, `CuaS1Chooser`), test `ElementChooserTests` (53).
  - `AsyncSupervisorStateMachine` (`PerryCore/SupervisorState.swift:117-133`, about 17 lines); only `SessionOrchestratorTests` use it.
  - `DirectProviderConfiguration` (`PerryRuntimes/DirectAIProvider.swift:41`); `TypedActionExecutor` alias of `ExecutableActionExecutor` (`AgentRuntime.swift:40`).
  - `HomeView` shell (`App/Home/HomeView.swift:9-22`).
  - The dead warning (#5).
- Medium confidence: `PerryTextTargetMatcher` (`PerryCapture/PerryVisionOCR.swift`), `IntentCardPolicy` (`IntentCard.swift:68`), `ScreenChangeDetector` (`AXModels.swift`). They are test-only today; check the planned rework first.
- Misnamed: `PerryGuide/RuntimeLadder.swift` actually defines `RuntimeGuidePlanner`.
- Size: −350 source / −200 test.

### 17. Medium — Test shape: some tests are screenshot generators or source greps

- Evidence:
  - About 20 `testRender*` functions across 8 files (`NotchSurfaceRenderTests` 8, `PaperOnboardingTests` 3, `HomeRecoveryTests` 3, `ForegroundPlanningTests` 2, others 1 each). They call `Task.sleep`, write PNGs to `build/`, and assert only that a bitmap exists (`NotchSurfaceRenderTests.swift:353-420`, helper `:416-433`; `testRenderPerfectPassSurfaces` is a bundle of seven screenshots). Their value is a human looking at the PNG, which the AGENTS.md visual rule already requires. A green result means "did not crash".
  - `SemanticTypographyTests.swift:5-50` greps source files for `.font(.system(size:`. It is a lint, and it carries a stale "Phase 5" comment.
  - `RealtimeVoiceSessionTests` (2,041 lines) tests internal ledgers and tombstone bounds. These pin implementation, not behavior a user can see.
  - Most behavior tests need a full `AppController` (see #1), so they are slow and tied to wiring. 8 files use `Task.sleep` polling (`TalkControllerTests` 13, `HomeRecoveryTests` 8, `RealtimeVoiceFixtures` 8).
  - UI tests (`AppUITests`, 467 lines) cannot run on this machine per AGENTS.md.
- Good news: behavior-oriented examples exist (`OnboardingDirectorTests`, `TalkControllerTests` hold/chord tests, `SoundCueTests`, `ToolApprovalHeadlineTests`).
- Fix: move render output into a script (`scripts/lab/`) that the visual verification step runs; turn the typography check into `scripts/ci.sh` grep next to the preferences guard; keep only the assertions that already exist in those render tests.
- Size: −600 test / +40 script.

### 18. Medium — Coverage gaps on the riskiest paths

- No direct test file references: `CommandRouter` (routes all typed and spoken commands, `CommandRouter.swift:27-86`), `HotkeyController`, `SessionPanelPresenter`, `StatusMenuController`, `MaintenanceCoordinator` (quit/erase ordering), `OnboardingCoordinator`, `SpatialSelectionController`, `GuideSessionBridge`, `IntentCardPresenter`, `ForegroundTaskController` directly.
- Partly covered: `PushToTalkController` and `WakeWordListener` in one file each; permission denial is covered only in the onboarding director and conversation voice tests; `EnvironmentProbe` in one file.
- Good: turn-taking races are covered (`TalkSessionAskTests`, `TalkControllerTests:543-886`), and the Guide, erasure, and background lifecycle paths are covered heavily.
- Fix: add table tests for `CommandRouter.route` (state × text × scope) and `MaintenanceCoordinator` ordering before touching voice or notch, because those decide whether the rework regresses silently.
- Size: +250 test.

### 19. Low — Mechanical monoliths: `CuaDriverClient` (1,601) and `SettingsView` (954)

- `CuaDriverClient` is one external-process driver, so it is one concept. Natural seams:
  - Discovery and code-identity checks (`:9-200`, static, pure).
  - JSON-RPC transport (`:1240-1415`).
  - Process lifecycle (`:839-940,1415-1465`).
  - AX snapshot mapping (`:1467-1560`).
  - An `AppController` extension that does not belong (`:1585-1601`).
- It has 1,899 lines of tests and is stable. Split only if you must change it.
- `SettingsView`: one `View` with 34 `@AppStorage` and `@State` properties and six tabs as computed properties (`:30-143`). Each tab can become its own struct. Do it while the rework touches that tab.
- Size: ±0.

### 20. Low — Narrated plan IDs and repeated stale-token plumbing

- Evidence:
  - 78 references to planning-doc IDs in code comments and test names: "Phase 9" (`SuggestionController.swift:5`, `AppSubsystems.swift:63,77`), "§3.4" (`GuideSessionCoordinator.swift:241,623`), "(H6)" (`VoiceController.swift:179`), "Plan §6.5" (`CuaCapabilityManifest.swift:5`), "§1.5" (`AppSubsystems.swift:211`, `RealtimeVoiceSession.swift:595`), `PhaseNineControllerTests.swift`, and the `SemanticTypographyTests` "Phase 5" comment. These point to documents readers do not have. Overall comment density is moderate: 1,128 comment lines in 39k.
  - A hand-rolled generation or admission token, re-implemented at least 9 times: `CuaDriverClient` (25 `generation` members), `RealtimeVoiceSession` (18), `VoiceConversationController`, `DictationController`, `WakeWordListener`, `BrainController` (admission), `GuideSessionCoordinator`, `HomeController`, `BackgroundTaskControlScope`. At least 12 tests are named "stale X cannot overwrite replacement X".
  - Long names: `RealtimeVoiceOutputReservationLedger`, `RealtimeVoiceTransportCorrelation`, `BackgroundTaskContextEnvelope`, `PerryOwnedDataSweepFailure`.
- Fix: strip the plan IDs when each file is touched (the `code-deslop` comment rule). Do not introduce a shared epoch type before the rework; consider it afterwards, once #2, #6, and #9 have removed three of the nine users.
- Size: −60 comment lines.

---

## God-object assessment (the ten largest)

| File | What it owns | One concept? | Natural seams | Split verdict |
|---|---|---|---|---|
| `RealtimeVoiceSession.swift` 2,401 | Realtime audio transport, correlation ledgers, session state | Yes (one protocol), but about 25 types in one file | Per type: tracker, barrier, ledger, ingress, pipeline, transport, session | Split into files, no logic change. Cutting the feature is the real option (#9). |
| `RemoteIntegrations.swift` 1,844 | OAuth, tokens, REST client, provider catalog, GraphQL checks | No (seven concepts) | OAuth / credential store / client / catalog / write policy | Mechanical split, reduces cognitive load, adds no code (#15). |
| `CuaDriverClient.swift` 1,601 | External driver process and its API | Yes | Discovery, transport, lifecycle, AX mapping | Split optional and low priority (#19). |
| `ForegroundTaskController.swift` 1,441 | One foreground run: start, execute, control, finalize | Mostly | Activity strip, rehearsal marks, routine replay | Extract about 300 lines after #4 (#10). |
| `GuideSessionCoordinator.swift` 1,300 | Guide sessions, scopes, speech identity, handoff, erasure | Yes, but heavy admission/scope plumbing | `GuideWorkerSession` (already separate class, `:83-215`) | Leave. Fix the callers around it, not it. |
| `VoiceController.swift` 1,074 | TTS, dictation, insertion, route, shortcuts | No (five jobs) | Speech output, dictation insertion | Split (#3). |
| `BackgroundTaskController.swift` 1,063 | Background task records and lifecycle | Yes | Undo (about 90 lines), workspace-task path | Delete the legacy path with #4; leave the rest. |
| `SettingsView.swift` 954 | All settings tabs | No | One struct per tab | Mechanical, do alongside the rework (#19). |
| `HomeController.swift` 882 | Notch hover presence and conversation ingress | No (two jobs) | Presence / ingress | Split (#6). |
| `AppController.swift` 529 + `AppSubsystems.swift` 653 | App delegate, wiring, forwards, 12 extensions | No | Wiring vs delegate | Delete forwards and Host protocols (#1). `AppSubsystems` as a composition root is fine; its 16 `unowned app` captures go away with #1. |

## Merge / delete map

### Delete (confidence)

| Target | Lines | Confidence | Evidence |
|---|---|---|---|
| `DemoDirector.swift`, `DemoFlowController.swift`, `DemoRecipe.swift`, `DemoDirectorTests.swift`, `runForDemo`, `runGuideForDemo`, `cancelPendingDemoInputs`, `MaintenanceHost.demoDirector` | −330 / −72 | High | #7 |
| `DebugInvocationPrototypes.swift`, `DebugCursorGallery.swift`, their menu items (`StatusMenuController.swift:142-143,306-307`), `DebugLaunchSeams.swift:170-176` | −260 | High | #8 |
| `RuntimePlanningPrompt.swift` | −32 | High | #16 |
| `FinderTaskSuite.swift` + test | −163 / −131 | High | #16 |
| `ElementChooser.swift` + test | −87 / −53 | High | #16 |
| `AsyncSupervisorStateMachine`, `DirectProviderConfiguration`, `TypedActionExecutor` alias | −70 | High | #16 |
| Dead warning in `SessionPanelView.swift:161-177`, `RuntimeCatalog.hasExecutionCapableChoice`, `RuntimeCatalog.choices` | −40 | High | #5, #11 |
| `HomeView` shell (`HomeView.swift:9-22`) | −14 | High | #6 |
| OpenCode bookkeeping (runtime, verifier, inventory entry, tests) | −250 | Medium | #11 |
| `SessionPanelView.swift` + prompt flags | −400 | Medium (needs the new workspace to cover ask/guide/do) | #5 |
| Legacy workspace-task path (`BackgroundTaskController.swift:608-695`, `.legacy` record handling) | −130 | Medium, tied to #4 | #4 |
| Typed-plan engine (`DoSupervisor` and friends) | −4,500 / −2,000 | Low (owner decision) | #4 |
| Realtime voice stack | −2,700 / −2,600 | Low (owner decision) | #9 |
| `SemanticTypographyTests` (becomes a ci.sh grep) | −50 | Medium | #17 |
| About 20 `testRender*` functions (keep as a lab script) | −600 | Medium | #17 |

### Merge

| From | Into | Reason |
|---|---|---|
| `VoiceConversationController` | `TalkSession` | Same turn: listen, accept input, `runSpokenTurn`, speak (#2) |
| `NotchStatusController`, resting/peek panels in `HomeController`, screen/inset logic in `SessionPanelPresenter` | One `NotchSurface` + `NotchPresence` | One owner for window, screen, inset (#5, #6) |
| `RuntimeCatalog`, `RuntimeInventory`, `RuntimeSetup`, `RuntimeSettingsState` | `BrainController` model rows | Remove the second catalog (#11) |
| `HomeOnboardingView` beats | `App/Onboarding/` | Naming and ownership (#14) |
| `SpeechOutput` half of `VoiceController` | `SharedTalkOutput` (`TalkSpeech.swift:171`) | It is already the only consumer |
| The five Host protocols | Concrete collaborators | No second implementation, no fakes (#1) |

## Refactor order

### Gate 0 — deletions only, one afternoon, no behavior change

Delete the high-confidence rows of the delete table (about 1,000 lines). Resolve the stashed DEBUG logging noted in progress.md. This shrinks the surface every later step has to read.

### Before touching onboarding

1. #7 (Demo) and #12 (typed `ModelChoice`), because the onboarding brain beat and `FirstTalkBeat` read both.
2. #14: move beat views to `App/Onboarding/`. Keep `OnboardingDirector` and its 17 tests as the boundary.
3. Voice dependency: `FirstTalkBeat` uses `VoiceConversationController`. Either do #2 first or freeze that beat.

### Before touching the notch

1. #1 (`AppController` forwards and Host protocols), because `SessionPanelPresenter`, `HomeController`, and `NotchStatusController` are all reached through it.
2. #6 (split presence from ingress) and #5 (one `NotchSurface`; delete `SessionPanelView` and its flags and dead warning).
3. #13 for the presence booleans, done as part of the split.
4. Add the `CommandRouter` and `MaintenanceCoordinator` tests (#18) first so the rework cannot silently change routing or quit order.

### Before touching voice

1. #2 (merge `VoiceConversationController` into `TalkSession`).
2. #3 (split `VoiceController` into speech output and dictation insertion).
3. #9: split `RealtimeVoiceSession.swift` into files without logic changes, and make the keep-or-cut decision. Do not change turn-taking logic across a 2.4k-line file with 54 internal-state tests.
4. Keep the existing race tests (`TalkControllerTests`, `TalkSessionAskTests`, `VoiceInputLifecycleTests`) green throughout. They are the real boundary.

### Before touching prompts

1. Decide #4 (typed-plan engine). It determines whether `GuidePlan` prompts, `RuntimeGuidePlanner`, and the planner prompts are live.
2. Prompt sites today: `PerryBrain/Tools/AgentPrompt.swift` (56), `PerryBrain/Talk/TalkPrompt.swift` (86), `PerryGuide/GuidePlan.swift`, the realtime default instructions hardcoded in `PerryPreferences.swift:75`, and the dead `RuntimePlanningPrompt`. Delete the dead one in Gate 0. Move the realtime default out of the preferences file.
3. #11 (one model catalog), so prompts target a single list of models and capabilities.

### Can wait until after the rework

#10 (Foreground/Background split beyond the activity strip), #15 (`RemoteIntegrations` split), #19 (`CuaDriverClient` and `SettingsView` splits), #20 (comment cleanup, shared epoch type), and the render-test migration in #17.

## Estimated net effect

Gate 0 plus the Before-steps remove about 2,600 lines of source and about 600 lines of tests, and add about 450. The two owner decisions (#4 and #9) are worth another 7,000+ source lines and 4,600 test lines if the answer is "cut".
