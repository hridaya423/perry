# Perry First-Impressions Rework: Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `executing-plans` to implement task-by-task. Load `ponytail`, `architect` and `code-deslop` before each phase. Load `design-engineering` and `emil-design-eng` before Phases 3, 4 and 7.

**Goal:** Make Perry's first ten minutes match or beat HeyClicky: an honest first answer, a small and alive notch, voice that ends by itself, an onboarding that asks about the user, and code that is smaller than today.

**Architecture:** Clean up first (delete dead code, then remove the `AppController` forwarding layer), so the rework touches fewer files. Then fix the work in the order the user meets it: the first answer (prompts), the notch, voice, the shared permission and shortcut components, the brain choice, onboarding, and Settings. Every visual task ends with a render that a person inspects. Every behaviour task ends with a test at a stable boundary.

**Tech stack:** Swift 6, SwiftUI inside borderless AppKit `NSPanel`s, XcodeGen, Swift packages (`PerryBrain`, `PerryGuide`, `PerryOverlay`, `PerryCapture`, `PerryRuntimes`, `PerryCore`), `SFSpeechRecognizer`, Apple Foundation Models, cua-driver. No new third-party dependency unless a decision below approves it.

---

## 0. Why this plan exists

The user installed the DMG and found these problems before trying any real task:

| # | Complaint (user's words, shortened) | Root cause found | Fixed in |
|---|---|---|---|
| 1 | "what can you help me with" got "I cannot read apps or files…" | Onboarding defaults to Apple's on-device model, which has no `.tools`. `AgentLoop.swift:75-76` then appends a fixed "cannot" sentence. The base prompt also tells the model to use `screen.observe`. No prompt says what Perry is for. | Phase 2 |
| 2 | Wants the "drag me into the list" permission helper | No helper exists. Perry also calls `requestAccessibility()` before opening the pane, which adds Perry to the list switched off. | Phase 5, 7 |
| 3 | "On this Mac" should lead to local models, sized to the machine, with a RAM budget | The "On this Mac" card is disabled because onboarding never runs `checkLocalModel`. No machine tiering, budget or unload exists. | Phase 6 |
| 4 | "ChatGPT" should be "Cloud" with every provider | Onboarding shows only ChatGPT. Claude Code, ACP agents and API keys are only in Settings. | Phase 6 |
| 5 | Replace the practice window with "what do you want to learn", plus a "tell me about yourself" step | The practice window checks nothing it claims. No profile step exists. The profile file is never put in a prompt. | Phase 2, 7 |
| 6 | The shortcut screen is ugly and the shortcuts cannot be edited | The finale shows hard-coded keycaps. Perry has no shortcut recorder. The talk gesture has no setting. Onboarding never asks for Input Monitoring, so the taught gesture can be dead. | Phase 5, 7 |
| 7 | The eyes are hard to see. Hover-to-open needs tuning. The colours are "meh". | The eyes are 3.5 × 9 pt sage bars in one ear with a fixed 7 s blink. Open is a mask wipe over a full-size view. The palette mixes three blacks and two accents. | Phase 3 |
| 8 | The open notch is too big, with a black bar that clips content | Hover opens the full 892 × 552 pt workspace. HeyClicky opens at about 441 × 250 pt (measured at 1.157 px/pt on this 1728 pt wide screen). Interaction panels count the 32 pt camera strip twice. Heights are fixed. The window resizes while SwiftUI clips. | Phase 3 |
| 9 | Settings UX is weak | Six tabs, two surface styles, developer controls next to basics. | Phase 8 |
| 10 | Show what the user wants to see, like HeyClicky | The peek shows a sidebar, a greeting, hints and a composer. HeyClicky shows who is working and what needs you. | Phase 3 |
| 11 | Voice should end when the user stops talking | The auto-end timer starts only after the first transcript text. Listening hides the notch. The only visible control, "Stop", throws the turn away. | Phase 4 |
| 12 | Apps should be set up in onboarding | Connecting an app needs the user's own OAuth client ID and secret. | Phase 7 (decision D4) |
| 13 | The notch feels lifeless | The notch uses static mascot poses. The animated `PerryCharacter` rig exists but is not used there. | Phase 3 |
| 14 | The menu is "slop" | It is the notch's More menu: 20 flat items, a literal "Memory:…", and a "Check for Updates…" that is always grey. | Phase 8 |
| 15 | The notch icons are ugly | Default SF Symbols at mixed sizes and weights, in mixed containers. | Phase 3 |
| 16 | Stop claiming the code is perfect | C4 review: about 3–4k lines are safe to delete. `AppController` is a god object. Voice has three entry paths and four state machines for one idea. | Phase 1 |

Research behind every decision is in `docs/research/2026-10-25/` (r1–r7 external, c1–c4 code audits). Cite those reports when a task needs detail. Do not repeat the research.

## 1. Decisions

The defaults below apply unless the user chooses otherwise. Tasks that depend on a decision say so.

| ID | Question | Default | Evidence |
|---|---|---|---|
| D1 | Keep the typed-plan engine (`DoSupervisor`, `WorkspaceFileRuntime`, `TaskCoordinator`, about 4.5k lines)? Only routine replay reaches it. | Keep, but isolate it behind one `RoutineRunner` and stop calling it "Do". Decide retirement after the rework. | c4 #4 |
| D2 | Keep realtime voice (about 5.3k lines with tests, BYOK only)? | Keep as a BYOK lab feature. Split the file mechanically. The new local end-of-turn detector is the default for every path. | c4 #9, r4 §3.2 |
| D3 | Local model runtime. | No new dependency: Apple Foundation Models plus detected Ollama and LM Studio models. A bundled MLX helper (lowest idle RAM, in-app model download) needs approval for `mlx-swift-lm`, `swift-transformers` and `swift-huggingface`. It gets its own plan if approved. | r3 §4, §7 |
| D4 | App connections in onboarding. | Show the apps the user named, with a "Set up in Settings" action. Perry-owned OAuth clients (PKCE) are a separate product decision. Gmail scopes are Google "restricted" and need a security assessment. | c2 §5 #4, r7 §7 step 6 |
| D5 | Notch look. | r6 §7.11: black crown that fades to warm charcoal `#1A1B1D`, ivory text `#F5F2EA`, one mint accent `#7BE3BD`, state colours only on the eyes. Render mockups before code (Task 3.0). | r6 §7, r1 §B |
| D6 | Optional voice detectors (FluidAudio Silero VAD, Smart Turn). | Not added. Use only if the built-in detector misses the fixture targets in Task 4.2. | r4 §3.3 |

## 2. Rules for every task

1. **Where to test.**
   - Builds, `swift test` and the hosted `PerryTests` bundle may run locally.
   - Never drive Perry's panel (hotkeys, lab drills, clicks) while the user is at the Mac. A panel opened by automation takes keyboard focus.
   - Live drills, recordings and permission tests run on `ssh mac-tailscale` once Task 0.1 shows it is ready. Otherwise they wait until the user is away and says so.
2. **Visual evidence.**
   - Every UI task produces a PNG in `docs/evidence/first-impressions/<task-id>/`, made with the offscreen render harness (`AppTests/NotchSurfaceRenderTests.swift`). Then open each image and inspect it.
   - Compare the image side by side with the HeyClicky screenshots in `/Users/hridyaagrawal/.t3/userdata/attachments/58557fdf-a5e5-49e3-a1d1-4bcef3a8136e-*.png`.
   - A task is not done if it has no image that someone looked at.
3. **Size.** The task's diff must be smaller than the code it replaces, or the task must state why not. Follow `ponytail`.
4. **Commits.** One commit per task. Never commit `.devin/`, `.audit/` or `build/`. No `git push`. End each message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
5. **Progress.** Update `progress.md` after each task: what is done, the evidence path, and what is next.
6. **Gate per phase.** `scripts/ci.sh` is green before a phase is marked done.
7. **Honesty.** Report what was verified and how. "Verified by render", "verified by unit test" and "verified live on the test Mac" are different claims. Do not merge them.

Standard commands:

```sh
/opt/homebrew/bin/xcodegen generate --spec project.yml
xcodebuild build -project Perry.xcodeproj -scheme Perry -configuration Debug \
  -derivedDataPath build/debug-p1 -destination 'platform=macOS,arch=arm64'
xcodebuild test -project Perry.xcodeproj -scheme Perry -configuration Debug \
  -derivedDataPath build/debug-p1 -destination 'platform=macOS,arch=arm64' \
  -only-testing:PerryTests/<TestClass>
swift test --package-path Packages/<Package> --filter <TestName>
scripts/ci.sh
```

---

## Phase 0: Ground truth

### Task 0.1: Test Mac readiness

**Files:** `progress.md` only.

1. Run `ssh mac-tailscale 'xcodebuild -version; df -h ~; sw_vers'`.
2. Expected: Xcode 26 or later, at least 40 GB free, macOS 26 or later. On 2026-10-24 it had Xcode 16.3 and a full disk.
3. If it is not ready, write "live drills blocked: <reason>" in `progress.md`. Ask the user to update Xcode and free disk on the mini. Continue with local builds and tests.
4. If it is ready, clone the branch there, run `scripts/ci.sh`, and record the result.

### Task 0.2: Baseline renders ("before")

**Files:** Output only, `docs/evidence/first-impressions/before/`.

1. Run `-only-testing:PerryTests/NotchSurfaceRenderTests` and `-only-testing:PerryTests/PaperOnboardingTests`.
2. Copy the PNGs from `build/dependable-evidence/` to the folder above.
3. Open every PNG. Write one line per image in `docs/evidence/first-impressions/before/README.md`: surface, size in points, and the defect it shows (use the complaint numbers from section 0).
4. Commit the README and the images.

### Task 0.3: Fix the stale build note

**Files:** Modify `AGENTS.md` (the "As of 2026-10-11" paragraph).

- `App/Onboarding/HelloInk.metal` does not exist (c2 §0 #1). Delete the Metal Toolchain sentence. Keep the xcodegen sentence.
- Commit: `AGENTS.md: drop the stale Metal Toolchain note`.

---

## Phase 1: Delete and untangle first

The rework touches `AppController`, the voice entry paths, the notch owners and onboarding. Each of these is smaller after this phase. No behaviour changes here. `scripts/ci.sh` is the gate for every task.

### Task 1.1: Delete the demo flow

**Files:**
- Delete `App/DemoDirector.swift`, `App/DemoFlowController.swift`, `App/DemoRecipe.swift`, `AppTests/DemoDirectorTests.swift`.
- Modify the call sites listed in c4 #7: `ForegroundTaskController.runForDemo` (`:839-857`), `GuideSessionCoordinator.runGuideForDemo` and `cancelPendingDemoInputs` (`:355-368`), `MaintenanceHost.demoDirector` (`MaintenanceCoordinator.swift:24,278`), `RuntimeInventory.hasReadyCLI` (`:17`), `AppController.swift:95-96,450`, and the DEBUG menu item (`StatusMenuController.swift:119-120`).

**Steps:**
1. `rg -n "Demo(Director|Flow|Recipe)|runForDemo|runGuideForDemo|cancelPendingDemoInputs|hasReadyCLI|runFlagshipDemo|demoVerifiedSummary" App Packages AppTests`. Record the list.
2. Delete the files and the members. Regenerate with xcodegen.
3. Build and run `scripts/ci.sh`. Expected: green, about 400 lines fewer.
4. Commit: `Delete the live-demo flow; nothing in release reached it`.

### Task 1.2: Delete the debug prototypes and dead package types

**Files:**
- Delete `App/DebugInvocationPrototypes.swift`, `App/DebugCursorGallery.swift`, `Packages/PerryRuntimes/Sources/PerryRuntimes/RuntimePlanningPrompt.swift`, `Packages/PerryGuide/Sources/PerryGuide/FinderTaskSuite.swift` and its test.
- Remove `AsyncSupervisorStateMachine` (`PerryCore/SupervisorState.swift:117-133`) and its test use. Remove `DirectProviderConfiguration` and the `TypedActionExecutor` alias.
- Modify `StatusMenuController.swift` to drop the menu items for those prototypes.
- Keep `ElementChooser` / `CuaS1Chooser`. Phase 6 may use them.

**Steps:** Grep each symbol, delete it, build, run `scripts/ci.sh`, and commit with the message `Delete throwaway prototypes and unreferenced package types`.

### Task 1.3: Delete the dead runtime bookkeeping and the unreachable warning

**Files:**
- `App/SessionPanelView.swift:161`. The warning can never show (c4 #5).
- `App/RuntimeCatalog.swift`: remove `choices` and `hasExecutionCapableChoice`.
- OpenCode bookkeeping: `OpenCodeRuntime.swift`, its verifier branch, its inventory entry and `OpenCodeRuntimeTests`.

**Steps:**
1. Confirm that `OpenCodeRuntime` is not a `ModelChoice` and is not routed: `rg -n "OpenCode" App Packages`. If anything routes through it, stop and record the finding.
2. Delete the code. Build and test.
3. Commit with the message `Delete runtime bookkeeping that routes nothing`.

### Task 1.4: Typed enum preferences

**Files:**
- Modify `App/PerryPreferences.swift`. Add a `Preference` initializer for `RawRepresentable` values with a fallback.
- Modify the 7 `ModelChoice(rawValue:)` re-parse sites: `HomeConversationView.swift:174,231`, `HomeOnboardingView.swift:378,528`, `BrainModelSettingsView.swift:12,16`, `BrainController.swift:345`.
- Apply the same change to `WakeShortcut` and `PushToTalkShortcut` (`SettingsView.swift:36-37`).
- Test: `AppTests/BrainControllerTests.swift`.

**Steps:**
1. Write a failing test: an unknown stored raw value (`"gone"`) reads back as the fallback choice, and `modelChoice` is typed as `ModelChoice`.
2. Run it. Expected: it fails to compile, because `modelChoice` is a `String`.
3. Implement: `BrainController.modelChoice: ModelChoice`. The persisted raw values stay unchanged, so no migration is needed.
4. Run `BrainControllerTests`, then `scripts/ci.sh`.
5. Commit with the message `Store model and shortcut choices as enums`.

### Task 1.5: Tests for the routers before they move

**Files:** Create `AppTests/CommandRouterTests.swift` and `AppTests/MaintenanceOrderingTests.swift`.

1. `CommandRouterTests`: a table of `(SessionState, text, scope) → expected route`. It covers typed ask, "do this", "stop", steering during a task, and empty text. It asserts the routes that exist today.
2. `MaintenanceOrderingTests`: quit and erase call their steps in the order `MaintenanceCoordinator.swift:40-200` defines. Use a recording fake for the collaborators.
3. Both must pass on the current code. They lock current behaviour before Task 1.6.
4. Commit with the message `Pin command routing and quit/erase ordering with table tests`.

### Task 1.6: Remove the `AppController` forwarding layer

**Files:**
- Modify `App/AppController.swift:21-73`, which holds 50 forwards.
- Delete the five single-conformer Host protocols: `CommandRouteHost`, `MaintenanceHost`, `StatusMenuHost`, `GuideBridgeHost`, and `DemoFlowHost`, which is already gone after Task 1.1.
- Update the coordinators. Each one receives the 3 to 6 collaborators it uses, as a `Hooks` struct like the one in `VoiceController` (`:17-26`).
- Move the 12 `extension AppController` blocks listed in c4 #1 into the owner they serve.

**Steps:**
1. Do one protocol per commit. For each one: replace `host.x` with an explicit collaborator, delete the protocol, build, and run `CommandRouterTests`, `MaintenanceOrderingTests` and the affected test classes.
2. Delete the forwards once no call site uses them (`rg -n "controller\.(<name>)"`).
3. Update the 30 `AppController(` constructions in tests only where a constructor changed.
4. Gate: `scripts/ci.sh`. Expected: about 350 lines removed and 120 added.
5. Commit messages follow the pattern `Give <Coordinator> its collaborators directly; delete <Host>`.

### Task 1.7: Move the onboarding views to `App/Onboarding/`

**Files:** Move `App/Home/HomeOnboardingView.swift` to `App/Onboarding/OnboardingBeats.swift`. No code change. Regenerate the project, build, and commit with the message `Move onboarding beat views next to their director`.

### Task 1.8: Isolate the routine engine (D1 default)

**Files:**
- Create `App/RoutineRunner.swift`.
- Modify `ForegroundTaskController.swift` (`runRoutineOperation` at `:353-396`, `executePreparedPlan` at `:586-780`, and the rehearsal marks at `:1330-1440`).

1. Move the routine-replay path behind `RoutineRunner.run(_ routine: Routine) async -> RoutineOutcome`. `ForegroundTaskController` then only calls it.
2. Existing routine tests must pass unchanged.
3. Commit with the message `Put routine replay behind RoutineRunner; Do is the agent loop only`.

---

## Phase 2: An honest first answer

### Task 2.1: Prompt assembly with golden tests

**Files:**
- Create `Packages/PerryBrain/Sources/PerryBrain/Prompt/CapabilitySnapshot.swift`, `.../Prompt/PromptAssembler.swift`.
- Test: `Packages/PerryBrain/Tests/PerryBrainTests/PromptAssemblerTests.swift` plus `Goldens/*.txt`.

**Interface:** Use the shapes in c1 §4.2: `CapabilitySnapshot`, `BrainState`, `PermissionState`, `ToolSummary`, `IntegrationSummary`, `MemoryState`, `VoiceState`, `PromptMode`, `Capability` (with `.available` or `.blocked(reason:fix:)`), `CapabilityResolver.resolve(_:)`, and `PromptAssembler.assemble(snapshot:user:perry:skills:workspacePath:) -> AssembledPrompt`. Every function is pure. The output contains no dates, no UUIDs and no unordered iteration.

**Steps:**
1. Write the failing contradiction test: a snapshot whose brain lacks `.tools` produces a prompt with no `screen.observe` and no "Observe before you act".
2. Write the invariant tests from c1 §4.6:
   - The identity is 250 words or fewer.
   - Every blocked capability has a fix.
   - Any sentence with "cannot" also contains a fix.
   - The prompt contains no tool names.
   - Two runs give the same bytes.
   - The prompt stays within a token budget per brain.
3. Write golden fixtures for cases (a) to (h) in c1 §4.6. `UPDATE_GOLDENS=1` rewrites them. Without the flag, a mismatch fails.
4. Implement. Use the identity text in c1 §4.3 as the starting draft. The mode deltas come from c1 §4.4. Add a voice rule: spoken answers are at most three sentences (HeyClicky keeps spoken lines to 6–12 words, r1 §I #13).
5. Run `swift test --package-path Packages/PerryBrain --filter PromptAssembler`. Expected: PASS.
6. Commit with the message `One assembled system prompt with a live capability block`.

### Task 2.2: Wire the assembler and delete the old prompt pieces

**Files:**
- Modify `Packages/PerryBrain/Sources/PerryBrain/Tools/AgentLoop.swift:75-78` (delete P8 and P9).
- Modify `Packages/PerryBrain/Sources/PerryBrain/Tools/AgentPrompt.swift:17-53`, `Packages/PerryBrain/Sources/PerryBrain/Talk/TalkPrompt.swift:38-75`, `App/Tools/AgentCoordinator.swift` (`systemPrompt`), and `App/PerryPreferences.swift:75`.
- Create `App/CapabilitySource.swift`. It builds the snapshot from `provider.capabilities`, `PerryToolHost.specs(for:)`, `PerryPermissionProbe`, `IntegrationService` and the memory configuration.
- Test: `AppTests/AgentCoordinatorTests.swift`.

**Steps:**
1. Write a failing wiring test. Build `AgentLoop.request` with a fake provider that has no tools. Assert that `system` equals `PromptAssembler.assemble(...).system`.
2. Implement. `AgentLoop` stops editing prompt text. Keep exactly one identity.
3. Replace the substring tests in `AgentPromptConsentTests.swift:5-10` and `TalkPromptTests.swift:22,37` with the golden suite.
4. Run the PerryBrain package tests and `AgentCoordinatorTests`, then commit with the message `Every model call uses the assembled prompt; delete the cannot-suffixes`.

### Task 2.3: A deterministic answer to "what can you do"

**Files:**
- Modify `Packages/PerryGuide/Sources/PerryGuide/GuideSupport.swift:82-104` (intent parsing) and `App/CommandRouter.swift`.
- Use `PromptAssembler.answerForCapabilityQuestion`.
- Test: a routing table in `Packages/PerryGuide/Tests/PerryGuideTests/GuideSupportTests.swift`.

**Steps:**
1. Write a failing table test of 40 utterances mapped to an intent. It includes:
   - "what can you help me with" and "what can you do" map to `.capabilities`.
   - "help me write a poem" maps to Ask, not Guide. Today the `help me` prefix sends it to Guide.
2. Implement:
   - The `.capabilities` intent renders the answer from the snapshot without a model call. The model still has the same block for follow-up questions.
   - With no brain (state c), app code renders the text from c1 §4.5(c).
3. Delete the scattered no-brain strings (`HomeController.swift:675-676`, `BrainController.swift:345-346,363-364`). Route them through the same renderer.
4. Commit with the message `Answer "what can you do" from live state, without a model`.

### Task 2.4: Let on-device Ask read the screen as text

**Files:**
- Modify `App/Tools/AgentCoordinator.swift:218-225` (the vision gate) and `Packages/PerryBrain/Sources/PerryBrain/Talk/TalkPrompt.swift:58-63`.
- Modify `Packages/PerryBrain/Sources/PerryBrain/Providers/AppleFoundationModelProvider.swift`. Keep one `LanguageModelSession` per conversation.

**Why:** with Apple's model only, screen questions fail today, because `.vision` is required and the router throws (c1 §1.6, r5 §1.4). The accessibility-tree `ElementIndex` already exists as text.

**Steps:**
1. Write a failing test. With a provider that has no vision but an accessibility snapshot exists, Ask builds a request that has the element text in the user message and does not throw.
2. Implement. The vision requirement applies only when no accessibility text exists. The capability block then lists "explain what is on screen (as text)" for state (b).
3. Re-render the goldens for state (b) and review the diff.
4. Commit with the message `On-device Ask reads the window as text instead of failing`.

### Task 2.5: Put the profile into prompts and erase it everywhere

**Files:**
- Modify `Packages/PerryGuide/Sources/PerryGuide/MemoryStore.swift:94-131`. Add a pinned `profile` slot that `promptContext` always includes, ahead of the 12 recent records.
- Modify `Packages/PerryBrain/Sources/PerryBrain/Perrys/MemoryFiles.swift:3-4`. Delete the false comment, or route `PROFILE.md` through the pinned slot. Choose one profile store: `MemoryStore` `.preference` plus the pinned slot.
- Modify `App/PerryErasureErasers.swift:441` so that erase covers `<support>/memory/PROFILE.md` too.
- Tests: `Packages/PerryGuide/Tests/PerryGuideTests/MemoryAndRunnerTests.swift` and `AppTests/CompleteErasureCoordinatorTests.swift`.

**Steps:**
1. Write the failing tests:
   - The pinned profile survives 20 newer records in `promptContext`.
   - Erase-all leaves no `PROFILE.md` under either path.
2. Implement, run both tests, and commit with the message `Pinned profile reaches prompts; erase removes every copy`.

---

## Phase 3: The notch

Spec source: r6 §7 (numbers), c3 §7 (defects with file and line), and r1 §B (HeyClicky peek layout).

### Task 3.0: Mockups before code (D5)

**Files:** `docs/design/2026-10-25-notch-mockups.html`, a self-contained page.

1. Draw three variants at 1:1 points against a menu-bar strip and a 32 pt notch:
   - Resting eyes: the r6 §7.2 capsules, a variant of Perry's pointer mascot in the wing, and the current eyes.
   - The peek at 440 pt with the D5 palette.
   - The listening state.
2. Check the page with `html_preview`, then publish it with `html_render`. The user picks one variant.
3. Record the choice in `progress.md`. Use the D5 default only if the user does not answer.

### Task 3.1: Split notch presence out of `HomeController`

**Files:**
- Create `App/Notch/NotchPresence.swift`. It holds the mouse and key monitors, zones, the resting panel, the eyes, the blink timer and the peek.
- Modify `App/Home/HomeController.swift`. Keep the conversation-ingress half.
- Replace the presence booleans (`insideZone`, `previewing`, `conversationVisible`, `resumeMonitoring`) with one enum: `NotchPresenceState { resting, swelling, peeking, open, hidden }`.
- Delete `homeOpen` and `setHomeOpen` (`HomeHoverIntent.swift:25-26,37,91-102`) and the `HomeView` shell (`HomeView.swift:9-19`). Point their tests at the real types.

**Steps:** Move the code without behaviour change. Run `HomeHoverIntentTests`, `HomeRecoveryTests` and `NotchSurfaceRenderTests`, then commit with the message `NotchPresence owns hover, eyes and peek; HomeController keeps input`.

### Task 3.2: One palette

**Files:**
- Modify `App/PerryTheme.swift:6-33`.
- Modify `Packages/PerryOverlay/.../PerryTypes.swift:4`: delete the second accent and update `NotchStatusController.swift:192`.
- Replace `Color.black` and `NSColor.black` at `CompactConversationView.swift:29,52` and `HomeController.swift:380,429` with tokens.

**Tokens (D5 default, r6 §7.11):**

| Token | Value |
|---|---|
| `crown` | `#000000` |
| `body` | `#1A1B1D` |
| `card` | `#232427` |
| `chip` | `#2C2D31` |
| `separator` | white 8% |
| `text` | `#F5F2EA` |
| `text2` | `#A6A59F` |
| `text3` | `#8B8A85` |
| `accent` | `#7BE3BD` |
| `success` | `#5FD38D` |
| `caution` | `#FFB020` |
| `danger` | `#FF6B63` |

Delete the dead tokens: `Sizing.settings*`, `Spacing.cardInset`, `Elevation.shadow`, `Motion.settle` and `Colors.focus`, after confirming zero uses with a grep.

**Steps:**
1. Extend `SemanticTypographyTests` (or a `scripts/ci.sh` grep) to fail on `Color.black` or `NSColor.black` in `App/Home` and `App/Notch`. Run it and confirm it fails.
2. Implement and run the test again.
3. Render. Commit with the message `One notch palette: black crown, warm charcoal body, one accent`.

### Task 3.3: Notch shape with animatable radii

**Files:** Create `App/Notch/NotchShape.swift`. It replaces `NotchSilhouette` in `App/NotchPresentation.swift:90-107`.

- Use the path in r6 §4.1, which is the quad-curve ear and bottom shared by boring.notch, DynamicNotchKit and AgentNotch.
- `animatableData` is `AnimatablePair(top, bottom)`. Closed radii are 6 and 14. Open radii are 18 and 22.
- Use the shape as `.background(shape.fill(...))`. Do not use `.clipShape` on content.
- Add a 1 pt keyline, white 0% at the crown to 10% at the bottom.
- Test: one unit test checks that the path is closed and stays inside its rect for closed and open radii. Render both states.
- Commit with the message `NotchShape: one path for closed and open, radii animate`.

### Task 3.4: Fixed window, size driven by content, no black bar

**Files:**
- Modify `App/SessionPanelPresenter.swift`:
  - Delete the mask morph at `:52-97`.
  - Delete the animated `setFrame` at `:98-110`.
  - Delete the double camera inset at `:195-198`.
- Modify `App/CompactConversationView.swift:27-68`: remove the `Color.clear.frame(height: 16)` and the 892-wide top strip.
- Modify `App/Onboarding/OnboardingNotchView.swift:58-64`: remove `.clipped()`.

**Design:**
- Create the panel once at the maximum open rect plus 48 pt of shadow padding. Set `hasShadow = false` and `NSHostingView.sizingOptions = []`.
- A `@State` size inside SwiftUI animates the shape. `NotchPresentation.measure` feeds that size.
- Hit testing returns `nil` outside the visible shape, so clicks pass through to the app below.
- Paint the black background 40 pt larger than the shape, so spring overshoot never shows a gap (DynamicNotchKit pattern).
- Size bounds (r6 §7.4):

| Mode | Width (pt) | Height (pt) |
|---|---|---|
| Peek | 440 | content, 120–260 |
| Focused | 440 | content, 160–320 |
| Workspace and onboarding | 560 | content, 220–400 |
| Hard cap | min(600, 0.40 × screen width) | min(0.38 × screen height, 440) |

Overflow scrolls between a fixed header and footer, with a 16 pt fade.

**Steps:**
1. Write a failing test: for an interaction with measured content height `c`, the panel height equals the computed host height. Today it is `c + 168`, against about `c + 132` needed.
2. Write a failing test: every mode's frame stays within the bounds table.
3. Implement and run `InteractivePanelTests`, `NotchPresentationTests` and the new tests.
4. Render the peek, an approval, a long answer and onboarding. Inspect each one for black bands and clipping.
5. Commit with the message `Notch sizes to content inside a fixed window; no black bar`.

### Task 3.5: Motion

**Files:** `App/Notch/NotchMotion.swift` holds the values. The views use them.

| Use | Value (r6 §7.6) |
|---|---|
| Open | `.spring(response: 0.38, dampingFraction: 0.82)` |
| Close | `.spring(response: 0.30, dampingFraction: 0.95)` |
| Resize | `.spring(response: 0.32, dampingFraction: 0.90)` |
| Swell in | `.spring(response: 0.30, dampingFraction: 0.72)` |
| Swell out | `.spring(response: 0.26, dampingFraction: 0.95)` |
| Content in | `.easeOut(0.20)`, delay 0.08, y −8 to 0 |
| Content out | `.easeIn(0.10)`, before the shape moves |
| Reduce Motion | opacity only, 0.15 s |

- The eyes cross-fade out over the first 80 ms of open. They return only after close completes. This fixes c3 defect 17.
- Verification: record a 60 fps clip on the test Mac (`scripts/lab/record.sh notch-open 6`). Extract frames with ffmpeg and look at frames 0, 3, 6, 9, 12 and 24. Keep every animation under 2 s (HIG).
- Commit with the message `Notch grows from the hardware notch with springs and staged content`.

### Task 3.6: Hover and the presence bugs

**Files:** `App/Home/HomeHoverIntent.swift:23-24`, `App/Notch/NotchPresence.swift`, `App/AppSubsystems.swift:526-538`, `App/SessionPanelPresenter.swift:176-184,278-288`.

**Changes:**

| What | Today | New |
|---|---|---|
| Hover zone | notch + 64 pt wide, 8 pt below the menu bar | visible silhouette + 6 pt left, right and bottom |
| Swell | none | starts at 0 ms (+6 pt wide, +4 pt down) |
| Peek open | 110 ms dwell | 180 ms dwell; a click opens at once |
| Close | 250 ms | 350 ms; re-entry cancels |

Bugs to fix:
- The peek never closes while a task is running (c3 defect 3).
- Hover-out cancels a voice turn (`SessionPanelPresenter.swift:279`, c3 defect 10). The preview close path calls `sessionPanel.hide()` only.
- The peek is not key (c3 defect 19). It becomes key on the first key event while the pointer is inside it.

**Steps:**
1. Write failing tests in `HomeHoverIntentTests`:
   - The new dwell and tuck timings.
   - The peek closes with a running task.
   - A hover-out during `.listening` does not call `cancel()`.
2. Implement, run the tests, and commit with the message `Hover: instant swell, 180 ms peek, no cancelled voice on hover-out`.

### Task 3.7: Eyes that can be seen and feel alive

**Files:** `App/Notch/NotchEyes.swift`. It replaces `makeNotchEyes` (`HomeController.swift:363-412`).

**Spec (r6 §7.1-7.2):**
- Idle wing: one right wing, 38 pt wide.
- Eyes: two capsules, 7 × 12 pt each, 8 pt gap, colour `#F4F1E8`, with an accent glow at opacity 0.30 and radius 6.
- Blink: a one-shot event at a random interval of 3.2–7.5 s, scale y to 0.08 over 150 ms, with a 15% chance of a double blink. The timer is a one-shot `Timer` with 1 s tolerance. No repeating timer and no idle loop.
- Glance: ±2 pt, every 8–20 s, and once after hover enter.
- States, mapped from `PerryMood(voice:buddy:)` (`PerryCharacter.swift:11-26`):

| State | Eyes |
|---|---|
| Listening | 8 × 14 pt, accent fill, glow 0.55 |
| Working | slow glance |
| Needs you | amber, held, no blink |
| Asleep (after 45 s idle) | closed arcs |

- In active states, a left wing shows a count or a glyph.
- Pause all motion on screen sleep, on lock, in Low Power Mode and under Reduce Motion.
- Non-notch displays: no idle pill. Show a 150 pt pill only when there is state to show.

**Steps:**
1. Write a failing test. With a seeded random source, the scheduler produces the intervals in range and never schedules while paused.
2. Implement, render each state, and inspect the renders.
3. Run `scripts/lab/idle-probe.sh --seconds 60` on the test Mac. Budget: average CPU at most 0.5% and RSS at most 180 MB.
4. Commit with the message `Readable eyes in a notch wing, with event-driven blinks and moods`.

### Task 3.8: The peek shows what the user wants to see

**Files:** Create `App/Notch/NotchPeekView.swift`. Modify `App/Home/NotchWorkspaceView.swift`. The hover peek no longer shows the workspace.

**Content priority, top to bottom, at 440 pt:**
1. Anything that needs the user: an approval or a question. It shows as one row with its action.
2. Running and recent tasks, at most 2 rows. Each row has the animated mascot or the app icon (22 pt), a 14 pt semibold title, a 12.5 pt one-line status with tail truncation, and a hairline between rows (HeyClicky pattern, r1 §B).
3. If the first two are empty: up to 2 Perrys or suggestions.
4. A one-line composer, "Ask Perry…", with a mic.
5. A footer with chips: `Apps`, `History`, and the expand button.

The header controls (close and More) sit in the black crown beside the camera, not in a row of their own (r6 §7.7). An empty state shows only the composer and one line about the gesture.

**Steps:**
1. Write a failing test. Given a model with one approval and three tasks, the peek row list is approval, task, task, and the third task is hidden.
2. Implement and render four states: empty, working, needs-you, and long titles.
3. Put each render beside the HeyClicky peek screenshot. Compare density and size, and note any difference in `progress.md`.
4. Commit with the message `A 440 pt peek that shows what needs you and what is running`.

### Task 3.9: The expanded workspace at 560 pt, without the legacy panel

**Files:**
- Modify `App/Home/NotchWorkspaceView.swift:19-38`. The rail shrinks from 210 pt to 148 pt or to an icon rail.
- Delete `App/SessionPanelView.swift` and the `showsGuide`, `pendingPromptText` and `pendingPromptDoMode` plumbing (`CompactConversationView.swift:75-91`, `AppController.swift:483-486`).
- The composer covers ask, guide and do with one mode chip, so the old picker has no job.
- Delete the card-in-notch fills (`NotchDialog.swift:123-125`, `CompactConversationView.swift:226`).

**Steps:**
1. Grep for `SessionPanelView`, `showsGuide` and `pendingPrompt`, and move each caller to the composer.
2. Write a test: sending text with the Do mode chip starts the foreground agent path.
3. Render and inspect.
4. Commit with the message `One workspace at 560 pt; delete the legacy ask/guide/do panel`.

### Task 3.10: Icons and type

**Files:** All files under `App/Notch/*` and `App/Home/*`.

**Rules (r6 §7.8, §7.10):**

| Size | Weight |
|---|---|
| 11 pt and below | `.semibold` |
| 12–15 pt | `.medium` |

- Icon sizes: toolbar 13, row lead 15, inline 11. Hit target 28 × 28. The hover wash is white 8%.
- Use monochrome icons, except status glyphs, which are hierarchical.
- No icons in filled circles, except the single primary action.
- Replace `gearshape.2` with `gearshape`. Use the names in r6 §7.10.

**Type scale:**

| Role | Size and weight |
|---|---|
| Panel title | 15 semibold |
| Row title | 14 semibold |
| Body | 13 |
| Secondary | 12.5 |
| Meta | 11 medium, monospaced digits |

**Steps:**
1. Add a `scripts/ci.sh` grep that rejects `.font(.system(size:` in `App/Notch` and `App/Home`. Move the typography lint here from `SemanticTypographyTests`, as c4 #17 suggests, and delete the lint test.
2. Render and inspect.
3. Commit with the message `One icon and type scale for the notch`.

### Task 3.11: An animated mascot in the notch

**Files:** `NotchWorkspaceView.swift:84,177,304`, `WorkspaceComponents.swift:151`, `WhatsNewView.swift:17`.

- Replace `PerryCharacterView(pose:)` with `PerryCharacter(mood:)`, driven by the voice and task state.
- Pause its `TimelineView` when the notch is closed or hidden.
- Render and inspect.
- Run the idle probe and check the budget.
- Commit with the message `The notch mascot blinks and reacts`.

### Task 3.12: Phase verification

1. On the test Mac, record:
   - Hover open and close.
   - Peek with a running task.
   - An approval.
   - Listening, after Phase 4.
2. Get the hover-to-visible latency with `latency-report.py` from new `PerfMark` pairs: `notch.hover_enter:notch.peek_visible`. Target p95 under 260 ms, which is the 180 ms dwell plus 80 ms.
3. A blind critic, a fresh Sonnet 5.5 task, gets only the PNG frames and the four HeyClicky screenshots. It scores size, density, colour, icons and life from 1 to 10 against HeyClicky. Any score below HeyClicky goes back to its task.

---

## Phase 4: Voice that ends by itself

Source: r4 §3. The prerequisite is c4 #2.

### Task 4.1: One owner for a voice turn

**Files:**
- Fold `App/VoiceConversationController.swift` (312 lines) into `App/Talk/TalkSession.swift` as a "click to start, silence to stop" gesture.
- Update `AppSubsystems.swift:272-296`.
- `AppController.talkSessionStarted` (`:241`) is removed.
- Tests: move `VoiceConversationControllerTests` into `TalkControllerTests`.

**Steps:**
1. Port the controller's tests first. Run them against `TalkSession`. They fail.
2. Implement until they pass. Behaviour stays the same, including the 1.5 s heuristic, which is replaced in Task 4.3.
3. Commit with the message `One voice-turn owner: TalkSession handles click-to-talk`.

### Task 4.2: `EndOfTurnDetector` with recorded fixtures

**Files:**
- Create `Packages/PerryCore/Sources/PerryCore/EndOfTurnDetector.swift`. It is pure and has no clock of its own.
- Fixtures: `Packages/PerryCore/Tests/PerryCoreTests/Fixtures/turns/*.json`, which are RMS frames plus word timings, generated once by `scripts/voice/make-turn-fixtures.sh` from `say` output mixed with noise.

**Interface (r4 §3.1):**
- Inputs: `frame(t, rms)`, `transcript(t, text, lastWordEnd)` and `userAction(.sendNow | .cancel)`.
- Outputs: `.speechStarted`, `.silence(since:progress:)`, `.commit(reason)` and `.abort(reason)`.

**Parameters:**

| Parameter | Value |
|---|---|
| Onset | floor + 9 dB for 120 ms or more |
| Base silence | 700 ms |
| After a continuation cue (and, but, so, um, uh, a trailing comma) | 1200 ms |
| After a clear end (". " or "?" with 4 or more words) | 500 ms |
| Hard cap on silence | 2500 ms |
| No speech at all | abort at 8 s |
| Turn length cap | 60 s |
| Adaptive widening | +300 ms, at most 3 times |

**Steps:**
1. Write failing tests over the fixtures:
   - A short question commits within 900 ms of the last word.
   - "I want to… um… book" does not commit during the "um" pause.
   - Silence aborts at 8 s.
   - A noise bed does not count as speech.
   - The targets are a cut-off rate under 5% and a median commit latency under 900 ms across the set.
2. Implement until the tests pass. If the targets fail, record the numbers. D6 then comes back to the user.
3. Commit with the message `EndOfTurnDetector: audio and transcript endpointing, fixture-tested`.

### Task 4.3: Wire the detector into capture

**Files:**
- `App/DictationController.swift:333-336`: add an RMS callback on the existing tap using `vDSP_measqv`.
- `TalkSession`: replace `armFinalize` with the detector, and commit through the existing finish path.
- Test: drive `TalkSession` with fixture frames and a virtual clock.

Hold-to-talk stays "release = send", with a 250 ms tail after release. A press shorter than 250 ms latches hands-free mode.

**Steps:** Write the failing tests, implement, then commit with the message `Spoken turns end on silence; hold-to-talk sends on release`.

### Task 4.4: Listening in the notch, with no button needed

**Files:**
- `App/SessionPanelPresenter.swift:209-240`: stop hiding the panel on `.listening`.
- `App/Home/NotchWorkspaceView.swift:558-599`.
- `App/Home/WorkspaceComponents.swift:68-80`.
- `App/Onboarding/OnboardingBeats.swift`: delete "I'm done".

**UI (r4 §3.4):**
- A ring around the animated mascot scales with real RMS at 20 Hz.
- The live transcript shows under the ring.
- A thin arc drains during the final silence. The `send` earcon plays at commit.
- Show "Pause when you're done" for the first three uses only.
- Overrides: click the notch, the up-arrow, the hotkey or Return to send now. Esc or the small × cancels.
- VoiceOver announces "Listening", "Sending" and "Thinking".
- Under Reduce Motion, the arc becomes an opacity step.

**Steps:**
1. Write failing tests:
   - The `.listening` state keeps the panel visible.
   - Return sends.
   - Esc cancels.
   - "Stop" no longer discards a turn that has speech.
2. Implement, render the listening and ending states, and inspect them.
3. Commit with the message `Listening stays in the notch with a live ring; no "I'm done" button`.

### Task 4.5: Wake word endpointing

**Files:** `App/WakeWordListener.swift:97-119`, `App/VoiceController.swift:1024-1033`.

- On a match, start a hands-free turn seeded with the text after the wake phrase. Do not dispatch the partial.
- "Hey Perry" alone opens a turn and plays the `wake` earcon.
- Keep a 1.5 s ring buffer across the handoff.
- Test: with a recorded partial stream ("hey perry what's the weather in paris"), the dispatched text is the full sentence.
- Commit with the message `Wake word waits for the end of the sentence`.

### Task 4.6: Split `VoiceController`

**Files:**
- Extract `App/Voice/SpeechOutput.swift` (`VoiceController.swift:175-465`).
- Extract `App/Voice/DictationInsertion.swift` (`:772-980`).
- Only move code. Run the tests and commit.

### Task 4.7: Realtime file split (D2 default)

Move the about 25 types in `RealtimeVoiceSession.swift` into `App/Realtime/` files, with no logic change. Set realtime to use the local detector plus a manual commit (`turn_detection` stays null). Commit.

---

## Phase 5: Shared components: permission helper and shortcut recorder

### Task 5.1: Privacy panes and deep links

**Files:**
- Create `App/Permissions/PrivacyPane.swift`.
- Test: `AppTests/PrivacyPaneTests.swift`.

**Interface:** As in r2 §6.1:
- `enum PrivacyPane { accessibility, screenRecording, inputMonitoring }` with `anchor` and `url`. The URL uses `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?<anchor>`.
- `legacyURL`, `supportsDrag` and `displayName(osMajor:)`. On macOS 27 and later, the Accessibility name is "Device Control and Data Access".
- `relaunchLikelyAfterGrant`.

**Steps:**
1. Write failing tests for the URLs and the display names.
2. Implement, delete the two copies of the old URL logic (`OnboardingCoordinator.swift:70-83`, `SettingsView.swift:294-297`), and commit.

### Task 5.2: Find and follow the System Settings window

**Files:** Create `App/Permissions/SettingsWindowTracker.swift`.

- Find the window with `CGWindowListCopyWindowInfo`, which needs no permission. Never read `kCGWindowName`.
- The tracker updates at 60 Hz while the helper is visible and stops when it is hidden.
- `dockFrame(settings:visible:cardSize:) -> (NSRect, Dock)` is a pure function that places the panel, as specified in r2 §6.3.
- Test: a table test for `dockFrame` covering the cases below, inside and clamped, and multiple displays.
- Commit.

### Task 5.3: The drag helper panel

**Files:** Create `App/Permissions/PermissionHelperPanel.swift` and `App/Permissions/AppBundleDragView.swift`.

**Panel:**
- Borderless and non-activating, level `.floating`, with `[.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]`.
- `canBecomeKey` is false.

**Drag source:**
- `AppBundleDragView: NSView, NSDraggingSource`. It writes `Bundle.main.bundleURL as NSURL`.
- The drag operation outside the app is `.copy`. Never use SwiftUI `.onDrag`, which sends a file promise that the list refuses (r2 §1, §6.5).

**Copy (r2 §7, r1 §C2):**
- Header: "Drag Perry into the list above."
- Then the pane name: "Then switch it on in {Device Control and Data Access}".
- Then "macOS will ask for your password."

**Motion:** A fly-in from the notch. Reduce Motion fades it in instead.

**Verification:** Render the panel offscreen and inspect it. The live drag test is Task 5.6.

**Commit** the panel and the drag view.

### Task 5.4: Detect the grant, and handle relaunch

**Files:** Create `App/Permissions/GrantMonitor.swift`. Modify `App/PerryApp.swift` to handle a `--check-permission <pane>` flag before `NSApplication` starts.

- Accessibility uses `AXIsProcessTrusted()`, which changes live.
- Screen Recording and Input Monitoring use a fresh-process probe, `Process(Bundle.main.executableURL, ["--check-permission", pane])`, which prints `{"granted":true|false}` and exits.
- When the fresh probe says yes and the in-process check says no, show "Restart Perry". `relaunchSelf()` saves the onboarding beat first.
- Polling: every 0.75 s, and every 0.25 s for 5 s after a drop or a `com.apple.TCC.updated` notification.
- Test:
  - A table test of `relaunchNeed(for:grantedInFreshProbe:grantedInProcess:)`.
  - The flag handler returns JSON and exits without starting the UI.
- Commit.

### Task 5.5: `PermissionGuideCoordinator`

**Files:** Create `App/Permissions/PermissionGuideCoordinator.swift`. Modify `App/Onboarding/OnboardingCoordinator.swift:70-83`.

`present(_ pane:) async -> GrantState` does these steps in order:
1. Refuse to run from a translocated or `/Volumes` copy. Show "Move Perry to Applications first."
2. Open the pane. Do not call `requestAccessibility()` first, because that pre-registers Perry switched off (r7 §2.4).
3. Wait for a stable window frame.
4. Show the panel.
5. Monitor for the grant.
6. On success, show "Got it." and fade out.

It handles three failure states: the user left the pane ("Go back"), Settings closed ("Open Settings"), and the password was cancelled ("Drag me again").

**Steps:**
1. Write a failing test with fake tracker, probe and opener collaborators. The flow emits the expected phases for success, Settings closed, and a cancelled drop.
2. Implement and commit.

### Task 5.6: Live permission check on macOS 27

This is a manual drill on the test Mac, or on this Mac only when the user is away and says so.

1. Run `tccutil reset Accessibility dev.perry.Perry` and `tccutil reset ScreenCapture dev.perry.Perry`.
2. Run the Accessibility, Screen Recording and Input Monitoring guides.
3. Confirm:
   - The deep link lands on the right list.
   - The list accepts the drag.
   - The grant flips.
   - The relaunch prompt works for Screen Recording.
4. Record the run with `scripts/lab/record.sh`.
5. Write the results into r2's "could not verify" list.
6. If the drop fails, widen the pasteboard writer to PermissionFlow's multi-type writer (r2 §6.5) and repeat.

### Task 5.7: Shortcut model

**Files:**
- Create `App/Shortcuts/Gesture.swift`. It defines `enum Gesture { hold(ModifierSet), chord(ModifierSet, KeyCode), doubleTap(Modifier) }` plus a `Preference`.
- Modify `App/Talk/ModifierHoldMonitor.swift:11-16,166`. It reads the saved talk gesture instead of the hard-coded `control && option`.
- Fix the ⌃⌥ against ⌃⌥⌘ overlap: an exact modifier-set match.
- Modify `PushToTalkController` and `HotkeyController` to use `Gesture`.
- `TalkGesture` strings read the saved value.

**Steps:**
1. Write failing tests:
   - A held ⌃⌥⌘ does not fire the ⌃⌥ talk gesture.
   - A saved custom hold fires.
2. Implement and commit.

### Task 5.8: The recorder pill

**Files:** Create `App/Shortcuts/ShortcutRecorder.swift`.

**Pill states (r7 §4.2):**

| State | Shows |
|---|---|
| Idle | the saved gesture |
| Recording | accent border, "Press the keys…". Esc cancels. ⌫ resets to the default. |
| Captured | the gesture, saved when the keys are released |
| Conflict | an amber line, plus "Pick another" and "Use anyway" |

**Rules:**
- A hold needs one to three modifiers.
- A chord needs a modifier and a key.
- Reject ⌘Space and ⌘⌃F, and name the owner.
- Check for conflicts in this order: Perry's own gestures, then `SymbolicHotkeys` (`SettingsView.swift:287`), then a short list of known app shortcuts.
- Preset chips below each pill: "Hold fn", "Hold right ⌥", "Hold ⌃⌥", "Custom…".

**Steps:**
1. Write failing tests on the capture state machine. Feed `NSEvent`-shaped values and assert the state that results, including conflicts.
2. Implement, render all four states, and commit.

### Task 5.9: A live "press it now" check

**Files:** The shortcut view, plus `PushToTalkController.CaptureMode`.

- The check reads the real capture path. If only the in-app fallback is live, show "I can only hear that key inside Perry. Turn on Input Monitoring." and open the Input Monitoring guide. Never mark success from a local monitor.
- Test: when the capture mode is the fallback, the check reports `needsInputMonitoring`.
- Commit.

---

## Phase 6: Brain choice: cloud and on this Mac

### Task 6.1: Status for each provider

**Files:** `App/Brain/BrainController.swift:121-123,586-593`, `App/RuntimeCatalog.swift`.

- Add `[ModelChoice: SetupState]` with the states `ready(detail)`, `needsSignIn`, `notInstalled` and `unchecked`. It is fed by `RuntimeCatalog.currentSetup()`, which already has a 3 s timeout for each probe.
- Claude Code is ready only when the binary is verified and signed in. Fix the skipped signature check at `BrainController.swift:586`.
- ACP agents show "Installed". Never show "Signed in" for them, because Perry cannot know (r5 §3.4).
- Test: a table of probe results mapped to `SetupState`.
- Commit.

### Task 6.2: The cloud card

**Files:** Create `App/Brain/CloudBrainList.swift`. It reuses `HomeConnectionView`, `ModelProfilesSection` and the Claude Code status from `BrainModelSettingsView.swift:17-33`.

- Rows: ChatGPT, then Claude Code if installed, then installed ACP agents (Cursor is installed on this Mac), then "API key…".
- Each row shows one capability line from r5 §3.5, for example "Sees your screen and acts". Never claim voice as a cloud benefit.
- Pre-select the saved choice if one exists. Otherwise pre-select the first row that is ready.
- Render and commit.

### Task 6.3: Machine profile and model fit

**Files:**
- Create `App/Brain/MachineProfile.swift`.
- Create `Packages/PerryBrain/Sources/PerryBrain/Local/ModelFit.swift`. It is pure.

**MachineProfile reads:**
- Total memory from `ProcessInfo.physicalMemory`.
- The chip from `machdep.cpu.brand_string` and `hw.model`.
- Available memory from `host_statistics64`.
- The GPU budget from `MTLDevice.recommendedMaxWorkingSetSize`.
- Memory-pressure events from a `DispatchSource` memory-pressure source.
- Do not use `os_proc_available_memory`. It is unavailable on macOS (r3 §5.1).

**ModelFit:** `recommend(memoryGB:chip:budget:available:) -> Recommendation`. It encodes the tier table in r3 §5 and the presets in r3 §7. The candidate models are those the D3 runtime can run.

**Steps:**
1. Write failing table tests: 8, 16, 24, 32, 48 and 64 GB, crossed with the budget presets.
2. Implement and commit.

### Task 6.4: The On this Mac screen

**Files:**
- Create `App/Brain/LocalBrainView.swift`, extracted from `BrainModelSettingsView.swift:34-79`.
- Modify `BrainController.refresh()`, which now runs `checkLocalModel` for every discovered model automatically.

**Content (r3 §7):**
- The machine line, for example "This Mac: M4 Pro, 48 GB".
- An Apple Intelligence row that states its limits: "Text answers. Reads windows as text after Task 2.4. Cannot act."
- Detected Ollama and LM Studio models, each with its checked capabilities.
- The recommended model for this machine.
- "How much memory can Perry keep ready?" A snapping slider: None, 2, 4, 8 or 24 GB, limited by the tier.
- "Let go after": 2 min, 10 min, 1 h or Never.
- "When this Mac's model cannot do a task": "Ask me before using the cloud" (the default) or "Never use the cloud".

**Unloading:**
- With D3 at its default, the budget and timer map to Ollama `keep_alive`.
- On a `.warning` memory-pressure event, unload the model.
- If neither runtime is installed, show one line with a link to install Ollama. Do not download in the background.

**8 GB Macs:** the default is None and the Apple model, and no screenshot model is offered.

**Steps:**
1. Write failing tests:
   - The budget and the "let go after" value map to the `keep_alive` value sent to Ollama.
   - A pressure warning triggers an unload request.
2. Implement, render the 8 GB and 48 GB variants, and commit.

### Task 6.5: MLX helper (only if D3 is approved)

Write a separate plan: `docs/plans/<date>-mlx-local-brain.md`. It covers:
- A helper process that exits when idle.
- A pinned Hugging Face revision, a disk check and resumable download.
- Qwen3.5 4B or 9B as both the brain and the screen-reading model.
- An evaluation against the 200-case gate in `docs/plans/megaplan-iii-painkiller.md`.

Do not start that plan without the approval.

---

## Phase 7: Onboarding rebuild

**New beats:** `hello, brain, access, shortcuts, interview, apps, firstGoal`. The target is about 125 s of setup plus about 40 s for the first task (r7 §7). Onboarding uses the workspace bounds (560 × up to 400 pt) and `PerryTheme` tokens only.

### Task 7.1: Director and persistence

**Files:** `App/Onboarding/OnboardingDirector.swift:7-13,58-67,191`, `AppTests/OnboardingDirectorTests.swift`.

1. Update the tests first:
   - The new beat order.
   - An unknown saved beat (an old name) restarts at `hello`.
   - Back works from every beat except `hello`.
   - X saves the current beat. It does not re-open onboarding on the next launch. Instead, the peek shows a "Finish setting up" row.
   - Per-beat `PerfMark`s exist.
2. Implement and commit.

### Task 7.2: Delete the old beats

Delete:
- `App/Onboarding/PracticeWindow.swift`, `PracticeStep` and the practice members in the director (c2 §6).
- The practice wiring in the coordinator (`OnboardingCoordinator.swift:17,52-60,84-88,105-117`).
- `PracticeWindowSketch`, `StepGrid`, `FinaleCard`, `LargeKeycap` and `LargeShortcut` (`OnboardingParts.swift`).
- The `firstTalk` and `finale` beats, the `preferOnDeviceBrain` chain, and two of the three first-answer triggers.
- The preference key `perry.onboarding.practice`.
- `OnboardingStyle`. Use `PerryTheme`.

Then build, run the tests, and commit.

### Task 7.3: Hello

- Keep `HelloGreetingView` (the ink "hello.").
- Copy: "Hi, I'm Perry. I live in your notch. What should I call you?"
- The name field is prefilled from `NSFullUserName()`. Return accepts.
- The name is stored in the pinned profile from Task 2.5.
- Render and commit.

### Task 7.4: Brain

The cloud card (Task 6.2) and the On this Mac card (Task 6.4) sit side by side. One selection covers both cards.

**Readiness:**
- `.direct` needs a saved profile. Today it is always "ready" (`HomeOnboardingView.swift:386`).
- "Later" leaves no brain. The later beats then use typed chips, and Task 2.3 answers in state (c).

Render and commit.

### Task 7.5: Access

- Copy: "I need to see what you see."
- Two rows: Accessibility, through the drag helper (Task 5.5), and Microphone, through the system prompt. Each row has a one-line reason, for example "Only while you hold the shortcut."
- Screen Recording is not requested here.
- Delete the old rows and the 1 s poll duplication. `GrantMonitor` owns polling.

Render and commit.

### Task 7.6: Shortcuts

- Title: "Hold ⌃⌥ and say hi." The title shows the gesture the user saved.
- One card with two rows, Talk and Dictate, using recorder pills and preset chips.
- The live check comes from Task 5.9. A dead event tap leads to the Input Monitoring guide.
- A visible checkbox, "Open Perry when I log in", which is on by default. It replaces the silent `LoginItem.setEnabled(true)` at `OnboardingCoordinator.swift:127-129`.

Render and commit.

### Task 7.7: Interview

**Files:** Create `App/Onboarding/InterviewBeat.swift` and `Packages/PerryBrain/Sources/PerryBrain/Prompt/ProfileExtraction.swift`. Extraction uses guided generation and a fixed schema.

**Consent line:** "Tell me about you. I keep short notes on this Mac so I can help your way. You can read and delete them any time." If the brain is in the cloud, add: "I send these notes with your questions to {provider}."

**Questions, one at a time** (voice turns end on silence through Task 4.3; typing works too):
1. "What do you do?"
2. "Which apps do you spend your day in?" Chips come from installed apps.
3. "What's something you've been wanting to learn lately?"

**Reactions:** Perry reacts to each answer in at most 12 words, naming something specific the user said (HeyClicky's rule, r1 §C5). It then asks the next question.

**End:** "Here's what I got." The facts show as editable chips (name, work, apps, learning goal), with "Looks right" and "Edit". Nothing is saved before confirmation. No transcript is stored. Memory is turned on only by this consent.

**Without a brain:** the beat shows typed chips only, with no extraction.

**Steps:**
1. Write failing tests:
   - Extraction output decodes into the chip model.
   - Cancelling saves nothing.
   - Confirming writes the pinned profile and enables memory.
   - Skipping every question leaves memory off.
2. Implement, render and commit.

### Task 7.8: Apps (D4 default)

- Show only the apps the user named, plus Google if mail or calendar came up.
- Each tile has a one-line description and "Set up in Settings". The action opens Settings, then Apps. Footer: "Skip".
- If D4 approves Perry OAuth clients, the tile instead uses `IntegrationConnections.connect`, and a separate plan covers the client registration.

Render and commit.

### Task 7.9: First goal

**Routing:** The learning goal is routed by type (r7 §3.3):

| Goal type | First task |
|---|---|
| A skill in an app on this Mac | Guide mode |
| A topic | A spoken three-line starter plan |
| A thing to make | Do mode with the normal approvals |

**Screen Recording:** asked just in time through the helper, only if the task needs to see the screen. If macOS needs a relaunch, the saved beat and goal resume after it.

**End:** onboarding ends when the task starts. The notch says "I'm up here whenever you need me."

**Test:** a goal that names an installed app routes to Guide. A topic routes to Ask. A relaunch resumes at `firstGoal` with the goal intact.

Render and commit.

### Task 7.10: Phase verification

1. On the test Mac, create a fresh macOS user account and install the DMG.
2. Record the whole first run with `scripts/lab/record.sh`.
3. Extract a frame every 2 s and inspect all of them.
4. Time it from `onboarding.start` to `onboarding.finish` with `latency-report.py`. The target is 3 minutes or less.
5. A blind critic agent compares the frames with the HeyClicky onboarding screenshots.

---

## Phase 8: Settings and the More menu

### Task 8.1: Sidebar Settings

**Files:**
- Split `App/SettingsView.swift` (954 lines) into one struct per page under `App/Settings/`.
- When Settings opens, a sidebar replaces the rail, with "‹ Back" at the top (r7 §5.4). Do not nest a second sidebar.

**Pages (r7 §5.2):**
- General
- You
- PERRY: Voice, Dictation, Shortcuts
- WORK: Brain, Apps
- TRUST: Privacy & Safety

**Surface language:** cards on `card` (`#232427`) with 12 pt radius, ink controls, and no grouped `Form`.

**Advanced disclosures:** realtime BYOK, the Cua driver path, the sign-in command buttons and the agent runtime list.

**Steps:**
1. Write a failing test. `openSettings(tab:)` maps every old `SettingsTab` case to the new page. Run the test, implement, then run it again.
2. Render every page.
3. Commit.

### Task 8.2: Page contents

Move each control as the table in r7 §5.2 says.

| Page | New controls |
|---|---|
| General | Notch eyes on or off, quick peek on hover, Check for Updates (always enabled), What's New, Replay setup |
| You | The profile chips, a list of what Perry remembers with delete, Redo the interview, Erase what Perry knows |
| Shortcuts | Recorder pills for Talk, Type, Dictate and the wake chord, plus the wake word toggle |
| Privacy & Safety | Permission rows whose fix action opens the drag helper, the workspace folder, the always-blocked apps, the activity log, diagnostics and Erase all |
| Dictation | A live level meter. It replaces the "Test microphone" text. |

Delete:
- The contradictory Caps Lock sentence (`SettingsView.swift:189`).
- The duplicate voice picker. Keep the recommended rows plus "More voices".

Render each page and commit.

### Task 8.3: The More menu

**Files:** `App/StatusMenuController.swift:82-232`.

**New menu (r7 §6.1):**
- Talk to Perry
- Ask or do something…
- Background tasks (shown only when more than 0)
- Record a routine… (shows "Stop recording" while recording)
- ─
- Settings… ⌘,
- ─
- Update available (shown only when true)
- Quit Perry ⌘Q

In DEBUG, every debug item goes into one "Developer ▸" submenu.

**Steps:**
1. Write a failing test. The release menu has 7 titles in the order above, with no conditional state. No title contains "…:" state text.
2. Implement, then delete the actions that are no longer used.
3. Commit.

---

## Phase 9: Release gate

The user must not be the first person to see a defect. All of these steps must pass before anyone says "ready".

1. `scripts/ci.sh` is green, and `scripts/performance/self-test.sh` passes.
2. On the test Mac, `idle-probe.sh --seconds 60` stays within budget with the eyes on.
3. The first-run recording on a fresh account (Task 7.10) is inspected frame by frame. Every complaint in section 0 has a frame that shows it fixed. List the frame paths in `docs/evidence/first-impressions/after/README.md`.
4. A blind critic agent scores each surface against HeyClicky. It sees only images, not code or this plan. A score below HeyClicky on any surface blocks the release.
5. Manual prompt evaluation. Ask "what can you help me with" in each of the three capability states, (a), (b) and (c), against the real models. Paste the answers into the evidence README.
6. Build the Release app and the DMG. Notarization needs the user's approval, because it uploads to Apple.
7. Report to the user: what was verified, how, and what was not verified.

## 3. Order and size

| Phase | Depends on | Rough size |
|---|---|---|
| 0 Ground truth | none | small |
| 1 Delete and untangle | 0 | −2.5k to −3k lines |
| 2 Honest first answer | 1.4, 1.6 | +600 (mostly tests and goldens) |
| 3 Notch | 1.6 | net negative (mask morph, legacy panel and `HomeView` go) |
| 4 Voice | 1.6, 3.4 | −300 / +400 |
| 5 Permission helper and recorder | 1.6 | +900 |
| 6 Brain choice | 1.4, 5 | +500 |
| 7 Onboarding | 2, 3, 4, 5, 6 | −700 (practice and finale go) / +900 |
| 8 Settings and menu | 5, 6 | about neutral (a split, plus deletions) |
| 9 Release gate | all | none |

Phases 2, 3 and 5 can run in parallel worktrees after Phase 1. Each one touches different files.
