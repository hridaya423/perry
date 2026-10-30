# Composition pass: findings

Wave 1 (six area agents) is merged into `cleanup/architecture`, builds, and package tests pass. This pass owns the wiring the area agents could not touch safely in parallel, plus loose ends they reported.

## Composition
1. `App/AppController.swift` has 44 one-line forwards `var x: T { subsystems.x }`. `AppSubsystems.swift`'s old header said they exist only so call sites keep their names (Middle Man). Delete the forwards; point call sites at `subsystems.x` or, better, hand each collaborator the specific dependency it needs. Remove host protocols that exist only so AppController has something to conform to (check each: a protocol a test fakes is a real seam).
2. 73 `#if DEBUG` blocks across App. `AppController` has a 17-parameter `init(debugStorageDirectory:…)` that packs seams into `DebugLaunchSeams`; subsystems in `AppSubsystems` get duplicated `#if DEBUG … #else …` constructors (the `guideCoordinator`, `probe`, `runtimes`, foreground controller and `backgroundTasks` sites). Move: one always-compiled `Overrides` value (nil defaults) that `AppSubsystems` reads, so the `#else` branches vanish. Keep genuinely debug-only UI (the debug menu, fixtures, failure drill) behind `#if DEBUG`, gathered in as few files as make sense. `AppTests/ForegroundPlanningTests.swift` `makeController` (~L1413) re-spells the seam parameters: give tests one builder.
3. `ForegroundTaskController.agentCoordinator` and `.workerLease` are `var`s injected after init and guarded with "Restart Perry"; make them init parameters if the composition graph allows it without a cycle.
4. `beginInvokingIfNeeded` / `transitionSession` now exist in three identical copies: `ForegroundTaskController`, `AppController`, and `GuideSessionCoordinator`. `SessionController` now has `isInvoking(_:)` and `beginInvokingIfNeeded(attemptID:)`. Collapse to one implementation on `SessionController`.
5. `SharedTalkOutput` forwards to `VoiceController` and is built 3 times in `AppSubsystems`: let `VoiceController` conform to `TalkSpeechOutput` directly if that is all it does.
6. `StatusMenuController` now uses closure-backed items; `AppController` still has one-line forwards for it (`isUpdateAvailable`, `checkForUpdates`, `toggleDemonstrationRecording`). Wire the closures straight to the owners.
7. `App/Runtime*.swift` (RuntimeCatalog, RuntimeInventory, RuntimeSetup, RuntimeSettingsState, RuntimeExecutableVerifier; ~616 lines): four types for one concept; `RuntimeSettingsState` is a 43-line debounced-refresh wrapper. Collapse to what the callers need.
8. Package boundaries: `KeychainStore` now lives in `Packages/PerryGuide/Sources/PerryGuide/KeychainStore.swift`, so App's OAuth and integration files import PerryGuide just for the keychain. Move it to PerryCore (it has no Guide dependency). Check other obviously misplaced types in PerryGuide (MemoryStore is used broadly) and move only where the move removes an import that makes no sense.

## Loose ends reported by wave 1
9. BUG (pre-existing): `DictationBackupStore.eraseAll()` (`Packages/PerryCore/Sources/PerryCore/DictationBackup.swift`) has no caller, so Complete Erasure does not clear the dictation backup. Wire it into the complete-erasure path (`App/CompleteErasureCoordinator.swift` / `App/PerryErasureErasers.swift`), and add a test that fails without it.
10. Unused after wave 1: `PlanDecision` and `InteractiveConfirmer.requestPlanDecision` (IntentCardPresenter and tests), `BackgroundTaskRow.runtimes`. Delete them and anything else that grep shows is now unreferenced (run a sweep: every `func`/`var`/`case`/type declared in App and Packages that has no reference outside its own declaration and its tests is a candidate; verify each).
11. `scripts/lab/cua-s1-sidecar/server.py` docstring names the deleted `ElementChooser`.

## Tests
12. Shared test support: `temporaryDirectory()` is re-implemented in ~7 test files; 34 tests mutate `UserDefaults.standard` with save/restore; 46 `AppController(` constructions. Add one small `AppTests/TestSupport.swift` (temp dir, isolated defaults, one app/controller builder) and use it. `AppTests/CopyLintTests.swift` walks 26 hard-coded source paths: make it discover files instead of hard-coding paths, or delete it if a script already covers the rule.
13. `AppTests/TalkControllerTests.swift` (~1500 lines) holds ~9 unrelated test classes: split by subject into files named after what they test.

## Comments (final sweep)
14. ~511 comment lines remain in prod Swift. Heaviest: LearnedRoutine (44), InkStroke (31), PerryTypes (26), DebugLaunchSeams (23), AppController (20), AppSubsystems (18), ActionPolicyTable (15), WorkspaceRunJournal (14), MCPConnector (14), GuidanceModels (13), WorkspaceUndo (12), ToolHost (12), RuntimeCatalog (12). Apply the brief's rule repo-wide: keep only license headers, short `///` on `public` package API that says more than the signature, issue links, and external-constraint notes.
