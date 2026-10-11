# Perry teardown → remediation plan

> **For the executor:** use `executing-plans`. Each phase below gets its own task-level sub-plan
> (`writing-plans`) before it starts. Phase 0 tasks are fully specified here; later phases list
> files, the failing check to write first, and hard acceptance gates. Never lower a gate to pass.

**Goal:** make Perry's hero loop (hold a key, point, talk, get a spoken + drawn answer) measurably
faster and more reliable than HeyClicky, then cut the duplicate stacks that make it slow and fragile.

**Architecture:** one conversation engine (TalkSession) fed by one input pipeline and one speech
output owner, routed through one brain (PerryBrain), drawing through one overlay. Everything
legacy that duplicates those (Ask, SessionPanel, VoiceConversationController, RuntimeCatalog
planners, DirectProviderClient, typed-plan Do) is migrated and deleted.

**Tech stack:** Swift 5 / SwiftUI / AppKit, XcodeGen, local SPM packages, bundled Codex
app-server, bundled cua-driver.

Evidence for every finding is in §1 with file references. Line numbers are as of 2026-10-11 with
the 97-file uncommitted WIP in the tree.

---

## 1. Findings (severity-ranked)

S0 = breaks the core promise. S1 = clearly worse than HeyClicky. S2 = quality debt that will bite.

### 1.1 The hero loop

| # | Sev | Finding | Evidence |
|---|---|---|---|
| H1 | S0 | **Point-while-you-talk is dead in production.** `TalkSession.keyDown()` shows the full-screen overlay (`guideShowOverlay` → `OverlayWindowManager.showOverlay` creates one screen-sized `OverlayWindow` per display) *before* starting the trace. `PointerTraceRecorder.perryWindowFramesInAXSpace()` returns the frame of every window in `NSApp.windows`, without filtering for visibility or `ignoresMouseEvents`. Every sample is therefore `overPerry = true`, `DeixisResolver` sees zero eligible samples, and every "this" resolves to "the whole screen". The unit test injects a 50×50 frame, so it can't catch this. | `App/Talk/TalkSession.swift:115-118`, `App/Talk/PointerTraceRecorder.swift:93-99`, `Packages/PerryOverlay/.../OverlayWindow.swift:1700-1720`, `Packages/PerryBrain/.../DeixisResolver.swift:98-102`, `AppTests/TalkControllerTests.swift:73-85` |
| H2 | S0 | **No hero latency has ever been measured.** `docs/evidence/perf/budgets.md` lists release→first text, first audio, and first ink as BLOCKED. Its "key-down ≤50 ms" row measures the ⌥⌘P panel (`invoke.keydown → panel.visible`, n=1), not ⌃⌥ Talk. Its "barge-in 1/6/1 ms" row comes from shutdown cancels, not from a user barging in. No full spoken round trip has been verified (handoff: "an audible end-to-end utterance remains user-deferred"). | `docs/evidence/perf/budgets.md`, `.devin/goal/handoff.md:497` |
| H3 | S0 | **The default brain is far too slow for voice.** The zero-key default is Codex app-server. Perry's own spike measured first agent text at 6.4–34 s, and phase-1 measured text p50 ≈3.7 s. Every turn calls `thread/start` again (`ephemeral: true`) and sends the full history as one JSON-string "envelope", so there's no server-side context reuse and the model has to parse JSON. Talk needs `[.vision, .streaming]`, which skips Apple FM, so a ChatGPT-only user always lands on Codex. | `Packages/PerryBrain/.../CodexAppServerProvider.swift:140-242`, `ProviderRouter.swift:21-22`, `.devin/goal/report.md` (spike notes), `App/Tools/AgentCoordinator.swift:217` |
| H4 | S0 | **Capture costs 4–5.5 s per call and runs on every turn.** `get_window_state` returns a full-window PNG plus 300 elements over stdio JSON, and `list_windows` plus `ensureSession` run first. The plan's "cached tree + local hit-test" decision was never built. Nothing downscales or JPEG-encodes the screenshot before it goes to the model. `screen.zoom` does a fresh full capture and then crops it. | `App/CuaDriverClient.swift:496-555`, `App/CuaGuideTreeReader.swift`, `App/Tools/ScreenTools.swift:180-197` |
| H5 | S1 | **Summarization blocks the hot path.** Once history passes its budget, `ConversationContext.prepare` makes one or more synchronous "condense" model calls *before* the user's answer starts. | `Packages/PerryBrain/.../ConversationContext.swift:63-96`, `AgentLoop.swift:81-89` |
| H6 | S1 | **The voice sounds robotic and the lookup is slow.** Talk speaks through `AVSpeechSynthesizer`. Premium voices aren't installed by default, so most users get the compact voice. `VoiceController.speakingVoice` enumerates `speechVoices()` on every sentence. The realtime path (`RealtimeVoiceSession`, 2,328 lines) isn't connected to Talk at all. HeyClicky's default is neural realtime voice. | `App/Talk/TalkSpeech.swift:108-118`, `App/VoiceController.swift:193-206` |
| H7 | S1 | **The start of every utterance gets clipped.** Each hold builds a new `DictationController`, awaits `requestPermission()`, and only then starts the audio engine. Words spoken at key-down are lost. | `App/Talk/TalkSpeech.swift:37-65` |
| H8 | S1 | **⌃⌥ hijacks every ⌃⌥ shortcut.** `ModifierHoldMonitor` taps only `flagsChanged`. It never sees key presses, so ⌃⌥←/→ (Rectangle, Magnet) or any ⌃⌥⌘ chord starts Talk: overlay, mic indicator, capture, then "I didn't catch that". There's no hold threshold. | `App/Talk/ModifierHoldMonitor.swift:8-11, 121-132` |
| H9 | S1 | **Double-tap ⌃ fires during normal typing.** The double-tap detector counts any two bare-⌃ press edges, so ⌃A ⌃E or ⌃C ⌃V in a terminal opens the composer and steals focus. It also converts `CGEvent.timestamp` by dividing by 1e9. On Apple Silicon that field is likely mach ticks, not ns, which would widen the 0.35 s window to roughly 14 s. **Verify with a log line.** | `App/Talk/ModifierHoldMonitor.swift:47, 134-143` |
| H10 | S1 | **Invoking Perry steals focus.** `showPanel()` calls `NSApp.activate(ignoringOtherApps: true)` on every wake. That breaks "draft into the focused field" and the user's flow. Wake also speaks "Perry here." on every invocation, which breaks the tone sheet's no-greeting rule. | `App/AppController.swift:1265-1284, 1912-1927` |
| H11 | S1 | **Every ⌥⌘P wake re-inventories runtimes.** `runtimes.refreshChoices()` → `inspect()` has no cache. It re-locates and re-verifies the Codex, Claude, and OpenCode executables (SHA-256 over 100+ MB binaries) and probes their auth on each invocation. | `App/AppController.swift:1283`, `App/RuntimeCatalog.swift:55-61, 115-123`, `App/RuntimeInventory.swift:258-300` |
| H12 | S2 | **Ink adds main-thread jank.** `InkAccentSampler` decodes the full-window PNG on the main actor for *every* draw command. `.point` draws a scribble whose two points are identical. | `App/Talk/TalkSession.swift:381-394` |
| H13 | S2 | **The 10-minute follow-up context store is dead code.** `TalkContextStore` is never created. Only its static `isResetPhrase` is used. | `App/Talk/TalkContext.swift`, `App/Home/HomeController.swift:581-583` |

### 1.2 Architecture and engineering quality

| # | Sev | Finding | Evidence |
|---|---|---|---|
| A1 | S0 | **Two of everything; "migrate callers, then delete" never happened.** Conversation engines: `TalkSession`, `VoiceConversationController` (notch mic, no screen), `AskSessionController`, and `VoiceController.dispatch` → legacy ask/guide/do. Brains: `PerryBrain` `ProviderRouter` plus `RuntimeCatalog`/`RuntimeProviderRegistry` (835 lines) and `DirectProviderClient` (single-shot, 768 tokens), still live. Do: `AgentLoop` plus typed-plan `DoSupervisor`/`TypedPlanning`. Speech outputs: three separate `AVSpeechSynthesizer`s (`VoiceController`, Talk's `SystemVoiceOutput`, the notch voice's `SystemVoiceOutput`) that can talk over each other, and barge-in only silences its own. | `App/AppController.swift:301-405`, `App/VoiceController.swift:45`, `App/RuntimeCatalog.swift:191-196`, `Packages/PerryRuntimes/Sources/PerryRuntimes/{DoSupervisor,TypedPlanning,DirectProviderClient}.swift` |
| A2 | S1 | **The god object grew.** `AppController` is 2,888 lines with 149 functions (plan target ≤400; the planning baseline was 2,150). It has two `#if DEBUG`/release copies of the `guideCoordinator` initializer, test seams leak into the composition root, and the app has 65 `#if DEBUG` blocks. `VoiceController` (996), `ForegroundTaskController` (1,475), `GuideSessionCoordinator` (1,216), `OverlayWindow` (1,804), and `RemoteIntegrations` (1,844) are the same pattern at smaller scale. | line counts |
| A3 | S1 | **The overlay was never split.** Phase 3 said to split `OverlayWindow` into follower, ink, caption, and ghost, and to delete the legacy buddy, scribble, and spinner code. `PerryBuddyView`, pet animation state, `BuddyNavigationMode`, the Bézier flight arc, the welcome animation, and `PerrySpinnerView` are all still there. `showOverlay` rebuilds a new window and `NSHostingView` per screen on every invocation, which defeats `warmRenderPipeline`. | `OverlayWindow.swift:207-1660, 1700-1720` |
| A4 | S1 | **The stream decoder is duplicated.** `InlineMarkupParser` re-parses the same deltas in four layers: `AgentCoordinator.consume`, `HomeController.runSpokenTurn`, `TalkSession.stream`, and `VoiceConversationController.consume`. | grep `InlineMarkupParser(` |
| A5 | S2 | **Shortcut soup with a system conflict.** There are five global gestures: ⌃⌥ hold (Talk), ⌃⌃ (composer), ⌥⌘Space hold (PTT → legacy dispatch), ⌥⌘P (wake panel), and ⌥⌘-drag (circle select), plus ⌃⌘Space for Home. ⌥⌘Space is macOS's default "Finder search window" shortcut. Onboarding copy and the notch footer have shown different "talk keys" at different times. | `App/PushToTalkController.swift`, `App/AppController.swift:1245, 1274`, `App/Home/NotchWorkspaceView.swift:16` |
| A6 | S2 | **Config and dead artifacts are scattered.** There are 35 raw `UserDefaults.standard` string keys. `App/Resources/CuaDriver/capabilities.yaml` still allowlists 6 apps even though the manifest is generated at spawn. The generated manifest scans only top-level `/Applications` (it misses `Utilities/`, Adobe-style nested folders, and apps installed after spawn) and expires after 8 h. `SessionOrchestrator` in PerryCore is unused. | `App/CuaCapabilityManifest.swift:25-60` |
| A7 | S2 | **Tests are numerous but blind.** About 38k lines of tests, yet the S0 deixis bug passes because every live provider is stubbed. No test drives the real overlay plus recorder plus resolver together. Two known timing flakes. The XCUITest scheme hangs, so nothing tests UI end to end. | `AppTests/TalkControllerTests.swift`, `.devin/goal/report.md` |
| A8 | S2 | **A clean tree doesn't build.** On Xcode 27, the new `App/Onboarding/HelloInk.metal` (a decorative greeting shader) needs the separately downloaded Metal Toolchain, and the build fails. `build/` (including `build/tools/xcodegen`) is gone, so AGENTS.md's verified commands fail as written. 97 files of WIP are uncommitted. | `/tmp/perry-build.log` (this session), `git status` |

### 1.3 UI and UX

| # | Sev | Finding | Evidence |
|---|---|---|---|
| U1 | S0 | **Home's primary button is the weaker product.** The notch's big "What's on your mind?" mic button starts `VoiceConversationController`: no screen, no deixis, no ink (`InlineMarkupParser(validElementIDs: [])`). It's a context-free voice chatbot on a 4–30 s brain, placed where users click first. | `App/Home/NotchWorkspaceView.swift:282-297`, `App/VoiceConversationController.swift:201` |
| U2 | S1 | **Onboarding asks for setup before showing any value.** The beat order is greet → **brainChoice** → firstTalk → screenAccess. The plan was to answer on-device first, then ask. First talk uses the screenless notch voice, and practice step 4 says "hold the talk key" for dictation, which uses a different key. | `App/Onboarding/OnboardingDirector.swift:8, 169-175` |
| U3 | S1 | **Guide is a form, not a teacher.** The floating card has five equal-weight buttons (Done, Let Perry do it, Find again, Skip, Stop), sits top-left away from the target, and shows no total step count. Steps without a postcondition advance only when the user clicks **Done**. Each step costs a 250 ms sleep, a full 4–5 s capture, and a planner call. `requireSameTarget` blocks the guide whenever a step opens a sheet or new window (Export dialogs, Preferences), and that happens in most real flows. | `docs/evidence/living-ink/guide-dark.png`, `Packages/PerryGuide/.../GuideEngine.swift:220-247, 322-329` |
| U4 | S1 | **The red-tier confirm field looks pre-filled.** `TextField(card.redPhrase, …)` uses the required phrase as its placeholder. The screenshot shows "Original export.pdf" in the field with Approve disabled. The card also appears near the cursor, not at the target as the PRD requires. | `App/IntentCardWindow.swift:101`, `docs/evidence/living-ink/approval-dark.png` |
| U5 | S1 | **Three identities at once.** DESIGN.md (2026-10) says to remove the faceted glass cursor and use an ink character with eyes. The megaplan says "living glass pointer". The code puts `PerryGlassCursorView` in Home, the rail, Perrys, the activity strip, guide controls, and the overlay, while onboarding shows the hand-drawn character and a mustard brush stroke that isn't in the palette. | `DESIGN.md:14,69`, grep `PerryGlassCursorView` (17 sites) |
| U6 | S2 | **Engineering copy in Settings.** "Perry copies the verified runtime's exact executable path and official authentication command. Run it in Terminal…" and "Direct providers… cannot execute actions themselves" (stale). The notch More menu's "Run in background" still opens an `NSAlert` with a runtime picker, which DESIGN.md explicitly bans. The resting view has both Minimize and Close. | `App/SettingsView.swift:530, 603`, handoff "Remaining standalone task composer" |
| U7 | S2 | **Docs contradict each other and the code.** PRD §5 puts the notch out of scope while DESIGN.md makes it home. The HeyClicky audit claims "consent-gated Sentry/PostHog clients", but no such code exists. README describes a "menu-bar companion" with 5 packages; there are 6. No `features.json` row covers the ⌃⌥ Talk loop, and `guide.annotations` is still only `wired`. | `PRD.md:95`, `docs/heyclicky-feature-audit.md:172`, `README.md` |

### 1.4 Security and privacy

| # | Sev | Finding | Evidence |
|---|---|---|---|
| P1 | S1 | **The MCP socket lets other apps borrow Perry's permissions.** The token is persistent, not per-launch as planned, and sits in a file in Application Support. Any same-user process that can read it gets the full `.agent` tool surface, running with Perry's Accessibility and Screen Recording grants. There's no peer-credential or code-signature check on the connecting client. | `App/Tools/PerryMCPSocket.swift:35-75`, `Packages/PerryBrain/.../MCPServer.swift:129-156` |
| P2 | S1 | **Screenshots touch disk.** The Codex provider writes every image to `$TMPDIR/perry-brain/*.img` and deletes it only when the turn cleans up. A crash leaves screenshots behind. PRD §8 says screenshots exist in memory only. | `CodexAppServerProvider.swift:178-181, 448-456` |
| P3 | S2 | **Learn-on-edit re-captures the user's window twice after every dictation**, at about 8 s and 17 s, through Cua (screenshot plus AX) to diff one field. | `App/VoiceController.swift:852-870` |
| P4 | S2 | **Codex stderr goes to `/dev/null`.** When the brain fails in the field there's nothing to diagnose. | `CodexAppServerProcess.swift:149-153` |

### 1.5 Process

- The 2026-10-03/04 design folders hold 7 rounds of website concepts and 4 "middle rethink" boards, made while the hero loop had never completed a spoken round trip.
- DESIGN.md has been rewritten repeatedly; the current WIP diff on it alone is 169 lines.
- The evidence culture grades wiring, not the experience. "Live-tested" rows count marker logs from synthetic or shutdown paths.

### 1.6 What's defensible (keep)

- Trust model: TrustGuard + ActionPolicyTable, typed red confirmation, protected-target check *before* capture (`CuaDriverClient.ensureTargetAllowed`), unattended runs auto-deny orange/red, fabrication guard.
- Codex confinement flags (`CodexAppServerConfiguration.defaultConfinementArguments`) and filtered env.
- ThreadStore durability (write-before-cache, pending-turn recovery, quit-mid-turn verified live).
- Idle discipline: about 0.0% CPU and 93–150 MB RSS measured over long soaks.
- Provider abstraction shape (`ModelProvider`/`ToolExecutingModelProvider`, health-reporting router).
- Workspace file runtime + undo, journals, and maintenance/erasure joins.

---

## 2. Bar: what "clearly better than HeyClicky" means, numerically

| Metric (real ⌃⌥ path, real mic, p50/p95 over ≥20 runs) | Gate |
|---|---|
| Key-down → visible listening cue | ≤50 / 80 ms |
| Release → first audible sound (ack earcon or speech) | ≤300 ms |
| Release → first spoken answer word, BYOK realtime | ≤1.2 / 2.0 s |
| Release → first spoken answer word, ChatGPT-only | ≤2.5 / 4.0 s (gate to revisit after Phase 1 spike) |
| Release → first ink on the correct element | ≤1.5 / 2.5 s |
| "What is *this*?" binds to the element under the pointer | ≥90% across Finder, Chrome, Figma, Slack, Resolve (20 runs each) |
| Barge-in (user presses during speech) → silence | ≤150 ms |
| Guide step: user click → next mark drawn | ≤1.5 s p50 |
| Accidental activations during 30 min of normal typing with Rectangle installed | 0 |
| Focus stolen from the frontmost app on any voice invocation | never |
| Idle CPU / RSS | ≤0.5% / ≤180 MB (already met; keep) |

Every number is produced by `scripts/lab/` on the real app. No row counts until it's measured on the real path.

---

## 3. Phases

| Phase | Theme | Exit gate |
|---|---|---|
| 0 | Truth and the S0 bugs | Clean build; H1, H8–H10, U4 fixed with regression tests; hero loop measured end to end once |
| 1 | Fast brain and fast eyes | §2 latency rows met for at least one brain configuration; decision recorded for ChatGPT-only |
| 2 | One loop | Duplicate engines, brains, outputs, and parsers deleted; AppController ≤500 lines |
| 3 | Guide that teaches | Click→next-mark ≤1.5 s; window/sheet transitions survive; J3/J5 step accuracy gates |
| 4 | Overlay and identity | One identity; overlay split; persistent windows; anchored cards; screen-share hiding |
| 5 | Home, onboarding, copy | Value before setup; notch CTA = spatial Talk; Settings copy rewritten; one shortcut model |
| 6 | Security and privacy | MCP peer auth; no screenshots on disk; learn-on-edit without capture |
| 7 | Proof | HeyClicky side-by-side scorecard on the same Mac; features.json truthful |

Phases 0 → 1 → 2 are sequential. 3–6 can interleave after 2. 7 runs last and again after any regression.

---

## Phase 0 — Truth and the S0 bugs

### Task 0.1: Make the tree build clean and park the WIP

**Files:** `App/Onboarding/HelloInk.metal`, `App/Onboarding/HelloGreetingView.swift`, `AGENTS.md`.

1. Decide: commit the notch-rebuild WIP in reviewed slices, or stash it on a branch. Don't leave 97 dirty files under Phase 0.
2. Remove the Metal dependency: render the greeting with SwiftUI `Canvas` + `TimelineView`, or ship the stroke as a pre-rendered image sequence. A decorative greeting doesn't justify a toolchain download for every contributor or CI.
3. Run:
   ```sh
   xcodegen generate --spec project.yml
   xcodebuild build -project Perry.xcodeproj -scheme Perry -configuration Debug \
     -derivedDataPath build/debug-p1 -destination 'platform=macOS,arch=arm64'
   ```
   Expected: `** BUILD SUCCEEDED **` with no Metal Toolchain installed.
4. Add `scripts/ci.sh` that runs the build plus `swift test` for all six packages plus `xcodebuild test -only-testing:PerryTests`, exiting non-zero on any failure. Every later task ends with `scripts/ci.sh` green.
5. Commit: `Build without the Metal toolchain; add ci.sh`.

### Task 0.2: Fix point-while-you-talk (H1)

**Files:** modify `App/Talk/PointerTraceRecorder.swift:93-99`; test `AppTests/TalkControllerTests.swift`.

**Step 1: failing test** (hosted app test, uses real windows):

```swift
func testOverlayWindowsThatIgnoreMouseDoNotCountAsPerry() {
    let screen = NSScreen.screens[0]
    let overlay = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    overlay.ignoresMouseEvents = true
    overlay.orderFrontRegardless()
    let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 200, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.orderFrontRegardless()
    defer { overlay.orderOut(nil); panel.orderOut(nil) }

    let frames = PointerTraceRecorder.perryInteractiveFrames(
        of: [overlay, panel], primaryMaxY: screen.frame.maxY
    )
    XCTAssertEqual(frames.count, 1)
    XCTAssertEqual(frames.first?.width, 200)
}
```

**Step 2:** run `xcodebuild test … -only-testing:PerryTests/TalkControllerTests`. Expected: FAIL, `perryInteractiveFrames` is undefined.

**Step 3: implementation**

```swift
static func perryWindowFramesInAXSpace() -> [CGRect] {
    perryInteractiveFrames(of: NSApp.windows, primaryMaxY: NSScreen.screens.first?.frame.maxY ?? 0)
}

static func perryInteractiveFrames(of windows: [NSWindow], primaryMaxY maxY: CGFloat) -> [CGRect] {
    windows
        .filter { $0.isVisible && !$0.ignoresMouseEvents && $0.alphaValue > 0.01 }
        .map { CGRect(x: $0.frame.minX, y: maxY - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
}
```

**Step 4:** run the test again. Expected: PASS.

**Step 5: integration test.** Drive `TalkSession.keyDown()` with the real `OverlayWindowManager` and a stub pointer inside a non-Perry rect, call `keyUp()`, and assert that `DeixisResolver` received at least one eligible sample. This is the test that should have existed.

**Step 6:** commit: `Ignore click-through overlays when flagging pointer samples over Perry`.

### Task 0.3: Make the Talk gesture safe (H8, H9)

**Files:** `App/Talk/ModifierHoldMonitor.swift`, `App/AppController.swift:383-405`, `AppTests/TalkControllerTests.swift`.

**Failing tests:**

```swift
func testKeyPressDuringHoldCancelsInsteadOfSubmitting() {
    var log: [String] = []
    let m = ModifierHoldMonitor(onHoldStart: { log.append("start") }, onHoldEnd: { log.append("end") },
                                onHoldCancel: { log.append("cancel") }, onComposer: { log.append("composer") })
    m.handle(timestamp: 0, control: true, option: true, isFlagsChanged: true, tapDisabled: false)
    m.handleKeyDown()
    m.handle(timestamp: 0.4, control: false, option: false, isFlagsChanged: true, tapDisabled: false)
    XCTAssertEqual(log, ["start", "cancel"])
}

func testControlChordsNeverOpenComposer() {
    var composer = 0
    let m = ModifierHoldMonitor(onHoldStart: {}, onHoldEnd: {}, onHoldCancel: {}, onComposer: { composer += 1 })
    m.handle(timestamp: 0.00, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
    m.handleKeyDown()                                   // ⌃A
    m.handle(timestamp: 0.05, control: false, option: false, isFlagsChanged: true, tapDisabled: false)
    m.handle(timestamp: 0.15, control: true, option: false, isFlagsChanged: true, tapDisabled: false)
    m.handleKeyDown()                                   // ⌃E
    XCTAssertEqual(composer, 0)
}
```

**Implementation rules:**
- Add `CGEventType.keyDown` to `eventTapMask`. On a keyDown during a hold, set `holding = false` and call `onHoldCancel`. On a keyDown at any time, set `lastControlTap = nil`.
- A double-tap counts only when both ⌃ presses are clean: no keyDown between press and release, and each press lasts <250 ms.
- Read time from `ProcessInfo.processInfo.systemUptime` in the callback, not `event.timestamp`.
- Show the listening cue instantly, but start the mic, capture, and trace only after the hold passes 120 ms with no keyDown. Shortcut users never light the mic indicator.
- In `AppController`, `onHoldCancel` maps to `talkSession.cancel()` plus `sessionController.requestDismissal()`, with no status text.

Commit: `Cancel Talk on chorded keys; require clean double-taps`.

### Task 0.4: Stop stealing focus and greeting (H10)

**Files:** `App/AppController.swift:1265-1284, 1912-1927`.

- `showPanel(activate:)` defaults to **false**. Only the typed composer (⌃⌃ or a click into the composer) makes the panel key, by calling `panel.makeKeyAndOrderFront(nil)` on the non-activating panel. Never call `NSApp.activate(ignoringOtherApps:)` on voice paths.
- Delete `voice.speak("Perry here.")` from `wake()`.
- Delete the `runtimes.refreshChoices()` call from `wake()` (H11). Refresh on Settings appear and after sign-in, and cache inventory results keyed by executable path + mtime + size.
- Test: after `toggleSession()`, assert `NSWorkspace.shared.frontmostApplication` is unchanged (hosted test with a launched TextEdit). Live: `scripts/lab/perry-drive.sh hotkey` while TextEdit is frontmost, then `cua-driver` checks the frontmost app.

### Task 0.5: Red-tier confirm field (U4)

**Files:** `App/IntentCardWindow.swift:95-105`.

Use `TextField("Type the name to confirm", text: $typedConfirmation)` and show `card.redPhrase` above it in monospaced type. Render test: an empty field must not visually contain `redPhrase`.

### Task 0.6: Measure the hero loop once, for real (H2)

**Files:** new `scripts/lab/talk-drill.sh`, DEBUG-only `--perry-talk-audio <wav>` launch argument in `App/Talk/TalkSpeech.swift`. It feeds a WAV file into the recognizer through `SFSpeechAudioBufferRecognitionRequest` instead of the mic.

- The drill posts a synthetic ⌃⌥ flagsChanged down event (CGEvent, needs Accessibility, which the lab already has), waits for the WAV to finish, then posts the up event.
- `latency-report.py` pairs to report: `talk.keydown:talk.listening`, `talk.keyup:answer.first_text`, `talk.keyup:talk.first_audio`, `talk.keyup:ink.first_draw`, `talk.keyup:capture.done`.
- Run 20 times against Finder with "what does this do" while the pointer sits on a toolbar button. Record the binding hit rate.
- Write the results to `docs/evidence/perf/budgets.md`, replacing the BLOCKED rows. Delete the "barge-in" row's shutdown-derived numbers.

**Phase 0 gate:** `scripts/ci.sh` green; the drill produces real numbers. Those numbers become Phase 1's baseline, and the bar is whatever they are.

---

## Phase 1 — Fast brain and fast eyes

Write the failing check first: a `talk-drill.sh --assert` mode that exits non-zero when §2 gates fail.

### 1.1 Brain latency spike (decision gate, 1 day)

Measure release→first text on the same 3 prompts plus screenshot, 10 runs each:
1. Codex app-server, current behavior (`thread/start` per turn).
2. Codex with **one persistent thread per Perry thread** (`thread/start` once, `turn/start` for follow-ups), smallest model from `model/list`, `effort: "minimal"`, native multi-message input instead of the JSON envelope.
3. Codex as in (2), plus the app-server spawned and `warm()`ed at launch + 1 s idle.
4. OpenAI Responses with a small vision model (BYOK).
5. OpenAI Realtime (BYOK) speech-to-speech.
6. Apple Foundation Models (26+), text only: acknowledgement plus intent classification.

Decision rules:
- If (2)/(3) reach ≤2.5 s p50, Codex stays the zero-key default for Talk.
- Otherwise Talk uses a split path: Apple FM speaks a ≤1-sentence acknowledgement grounded in the deixis binding label ("That's the Export button —"), and the slow model streams the substance. Onboarding offers BYOK realtime as the recommended "fast voice" upgrade.

Record the results in `docs/evidence/phase-1/talk-brain-decision.md`.

### 1.2 Codex provider rewrite

**Files:** `Packages/PerryBrain/Sources/PerryBrain/Codex/CodexAppServerProvider.swift`, tests `Packages/PerryBrain/Tests/PerryBrainTests/CodexAppServerProviderTests.swift`.

- `ModelRequest` gains `conversationKey: String?`. The provider keeps `[conversationKey: codexThreadID]`, sends only the new user message on follow-ups, and falls back to a fresh thread when the server forgets one.
- Drop the JSON envelope. Send native turns.
- Send images as data URLs if `UserInput` accepts them (verify against the generated schema). Otherwise write to a `0700` per-launch directory that's wiped at launch and at quit (fixes P2).
- Route stderr into a size-capped `Logs/codex-app-server.log` (fixes P4).
- Fake-server tests: a follow-up turn issues no second `thread/start`; thread loss triggers transparent recovery.

### 1.3 Capture budget

**Files:** `App/CuaDriverClient.swift`, `App/CuaGuideTreeReader.swift`, `App/Talk/TalkSession.swift`, new `App/Talk/ObservationCache.swift`.

- Keep the Cua session and the `list_windows` result warm per frontmost app (invalidate on `NSWorkspace.didActivateApplicationNotification` and window-move notifications).
- On key-down, request the AX tree with `include_screenshot: false` first. That's the fast part, and it's enough for deixis and drawing. Fetch the screenshot in parallel and attach it only if it arrives before the model request is built, or for "what does this look like" style questions (TierClassifier).
- Downscale screenshots to ≤1568 px on the long edge and encode JPEG q≈0.75 off the main actor, once per observation. Reuse that decoded bitmap for `InkAccentSampler` (H12).
- `screen.zoom` crops from the cached observation when it's under 2 s old instead of recapturing.
- Gate: `talk.keyup:capture.done` ≤150 ms p50, because the capture started at key-down.

### 1.4 Hot-path hygiene

- Move `ConversationContext` summarization off the hot path. Answer with the last N verbatim turns and summarize in the background after the turn finishes (H5).
- Cache `speakingVoice` and re-resolve it on preference change (H6).
- Mic pre-warm (H7): cache the permission state at launch and on change, construct the `AVAudioEngine` and recognizer once, start the engine synchronously on key-down (after the 120 ms hold threshold), and keep a 300 ms ring buffer from engine start that's fed to the request once it exists.
- Ack earcon at release (≤250 ms, from the existing cue set) so the user hears Perry immediately whatever the brain.

### 1.5 Voice quality

- In onboarding and Settings → Voice, detect whether a premium or enhanced system voice is installed. If not, play a 3-second comparison and deep-link to the download pane.
- Implement `RealtimeOutput: TalkSpeechOutput` and `RealtimeInput: TalkSpeechInput` as adapters over `RealtimeVoiceSession`, so BYOK users get neural voice *in Talk*, not just in the legacy PTT path.

**Phase 1 gate:** `talk-drill.sh --assert` passes for BYOK realtime and meets the recorded decision-gate number for ChatGPT-only.

---

## Phase 2 — One loop

Each deletion follows: inventory callers → migrate → delete → `scripts/ci.sh` green → commit.

1. **One conversation engine.** `TalkSession` gains `Source { case hold(trace), notch, composer(text) }`.
   - `VoiceConversationController` becomes `TalkSession(source: .notch)`, which still captures the frontmost window unless Home is the frontmost thing.
   - The typed composer runs the same pipeline with text input.
   - Delete `VoiceConversationController`, `AskSessionController`, `SessionPanelView`, `CompactConversationView`'s ask branch, and `AppController.dispatch(commandText:)`'s ask/guide routing.
2. **One input story.** ⌥⌘Space PTT becomes **dictation only** and is renamed so it never dispatches a request. Fix the ⌥⌘Space system-shortcut conflict by defaulting dictation to fn-hold, or ⌃⌥⌘ if fn is unavailable, and detect conflicts against `com.apple.symbolichotkeys`.
3. **One speech owner.** A single `SpeechOutputService` (one synthesizer or realtime sink) owns all speaking: Talk, Guide, Do summaries, onboarding. It has a priority queue and a global `shutUp()` wired to barge-in. Delete `VoiceController.synthesizer` and the per-feature `SystemVoiceOutput()` instances.
4. **One brain.** Move `RuntimeLadder`'s transport, `SpatialAnswer`, and `RuntimeCatalog.makeProviderClient` to PerryBrain providers. Delete `DirectProviderClient`, `DirectProviderRuntime`, `BYOKAgentRuntime`, and `RuntimeCatalog`'s planner/choice UI. Keep `RuntimeProviderRegistry` only for identity/health records if anything still reads them; otherwise delete.
5. **One Do.** Open-ended Do already goes through `AgentLoop`. Keep typed plans *only* for routine replay, move them under `PerryGuide/RoutineReplay`, and delete `DoSupervisor`'s open-ended paths and `ExecutablePlan` enqueue validation for goals.
6. **One stream decoder.** `AgentCoordinator` parses inline markup once and emits `AgentLoopEvent.draw(DrawCommand)` and clean `.textDelta`. Delete the three downstream parsers.
7. **Composition root.** `AppController` ≤500 lines. Extract `TalkCoordinator`, `PanelPresenter`, `ApprovalPresenter`, `MaintenanceCoordinator`, `DebugLaunchHarness`. Move all `#if DEBUG` initializer seams into a `AppDependencies` factory with a test variant.
8. **Preferences.** Use one typed `PerryPreferences` (property wrappers over UserDefaults) holding every key. Ban raw `UserDefaults.standard` string keys outside it (add a `scripts/ci.sh` grep check).
9. **Dead weight.** Delete `SessionOrchestrator`, `TalkContextStore` (thread context supersedes it), and the static `App/Resources/CuaDriver/capabilities.yaml` (or reduce it to a documented fallback). Make the generated manifest recurse one level into `/Applications/*` folders and regenerate on `NSWorkspace.didLaunchApplicationNotification` for unknown bundles.

**Gate:** `wc -l App/AppController.swift` ≤500; `grep -r "VoiceConversationController\|AskSessionController\|DirectProviderClient" App Packages` is empty; all suites green; the Phase 1 drill is unchanged or better.

---

## Phase 3 — Guide that teaches

Failing checks first: a drill that runs "show me how to export a PDF" in Preview and "add a transition" in Resolve, measuring click→next-mark and step accuracy.

1. **Event-driven advance.** Replace the `sleep(250ms) + full observe()` cycle with an `AXObserver` on the target pid (focused UI element changed, window created, value changed). Verify the postcondition against a targeted AX read, not a full window capture.
2. **Follow the task, not the window.** `requireSameTarget` accepts the same pid with a new focused window, sheet, or popover when the step predicted it (`GuideStep.opensWindow`), or when the new window is a child of the old one.
3. **Plan ahead, replan on deviation.** Ask the planner once for the full path (≤25 steps with targets and postconditions). Present step N from the plan, validate it against the live AX tree locally, and call the model only on validation failure or deviation. Prefetch step N+1 while the user acts.
4. **Controls at the target.** The caption anchored on the element carries Back / Skip / "Do this step" / Stop as compact affordances. "Done" disappears for steps with a postcondition, and steps without one get a postcondition or are dropped. Voice works too: "next", "back", "do it".
5. **Canvas apps.** Zoom crops come from the cached observation. A second-zoom verification uses the same frame.

**Gate:** click→next-mark ≤1.5 s p50; J3/J5 step accuracy at ≥95% (AX apps) and ≥85% (canvas apps) over 20 recorded runs each.

---

## Phase 4 — Overlay and identity

1. **Pick one identity and write it down.** DESIGN.md currently says ink character, not glass cursor. If that holds, replace all 17 `PerryGlassCursorView` sites, delete `PerryGlassCursor.swift`'s faceted and lens variants, and update the megaplan §5. If glass wins, fix DESIGN.md instead. Either way, one asset system.
2. **Split `OverlayWindow.swift`** into `OverlayHost` (persistent windows per screen, created once and toggled with `orderFront`/`orderOut`), `CompanionFollower`, `InkLayer`, `CaptionLayer`, and `GhostCursor`. Delete `PerryBuddyView`'s pet state, Bézier flight, welcome animation, `PerrySpinnerView`, and navigation bubbles after migrating callers.
3. **Real draw geometry.** `point` becomes a dot plus a short leader stroke; `ring` becomes a hand-inked ellipse around the element with padding; `arrow` keeps its approach direction clear of other marks. Fix the `.point` scribble with two identical points.
4. **Intent card at the target.** Anchor it to the element rect through `CaptionPlacer`. Fall back to near the cursor only when there's no target.
5. **Screen-share hygiene.** Hide all overlays while screen sharing is detected and during ⇧⌘3/4/5. `sharingType = .none` is already set; verify with `screencapture -w`.

**Gate:** snapshot gallery of every state on light, dark, and busy backgrounds; 120 Hz recording shows follower lag ≤1 frame; idle CPU unchanged; no Perry pixels in any `screencapture` artifact.

---

## Phase 5 — Home, onboarding, copy

1. **Onboarding order:** greet → mic (only when the user chooses voice) → first talk answered on-device (Apple FM or the system path; no account) → screen access at the moment the user asks about the screen → brain choice ("Use ChatGPT" primary, "Use this Mac" secondary, "Other models" link) → practice → finale. Practice copy names the actual keys from `PerryPreferences`.
2. **The notch's primary button runs spatial Talk** (Phase 2's `.notch` source): it answers about the window you came from. The resting state shows the one talk shortcut, and only that one.
3. **Remove the NSAlert background composer.** Run-in-background is a toggle on the composer's send action inside the notch. No runtime picker anywhere outside Settings → Brain.
4. **Settings → Brain:** signed-in account, rate-limit meter, model choice. Delete the "copy this command and run it in Terminal" flow for the bundled runtime. ChatGPT sign-in goes through `account/login/start` only.
5. **Resting view:** one dismiss control, not Minimize plus Close.
6. **Copy pass:** run `clean-copy` over every user-facing string. Remove the stale "Direct providers… cannot execute actions" text.
7. **Docs reconcile:** PRD §5 vs the notch, megaplan §5 vs DESIGN.md, the HeyClicky audit's Sentry/PostHog claim, and README's package list.

**Gate:** fresh-user drill (`tccutil reset` plus a fresh support dir) reaches the first spoken answer in ≤90 s with zero Settings visits; recorded.

---

## Phase 6 — Security and privacy

1. **MCP socket.** Generate a per-launch token held in memory and passed to `perry-mcp` children through the environment of processes Perry spawns. Check peers with `getsockopt(LOCAL_PEERPID)`, then `proc_pidpath` plus `SecCodeCopyGuestWithAttributes` to require `perry-mcp` signed by the same team (allow Debug ad-hoc only in DEBUG builds). Create the socket `0600`. Every orange/red MCP call shows an attended approval.
2. **No screenshots on disk.** Done in 1.2. Add a launch sweep of `$TMPDIR/perry-brain` for old crashes, plus a test that a crash-simulated turn leaves no file after relaunch.
3. **Learn-on-edit:** read only the focused element's `AXValue` through one targeted AX call. No screenshot, no full tree.
4. **Diagnostics:** include a redacted tail of `Logs/codex-app-server.log` in the user-initiated export.

**Gate:** `security-scan` review of the socket and capture paths with no S1 findings left.

---

## Phase 7 — Proof

1. Install HeyClicky on the same Mac (user signs in once). Run the 12 scorecard journeys on both apps with screen recordings and `talk-drill`-style timing where possible.
2. Add `features.json` rows for `talk.hold-loop`, `talk.deixis`, `talk.ink`, `guide.click-advance`, and `voice.neural-output`. Promote them only on drill evidence.
3. Freeze design exploration (website concepts, middle rethinks) until the scorecard is won. New concept boards need a ticket tied to a scorecard row.

**Gate:** Perry wins or ties every journey, and every §2 row is green on the scorecard date.
