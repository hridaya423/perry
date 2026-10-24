# Perry UX audit: smoothness, flow, failure paths, consistency

Read-only. Nothing was built, run, or launched. Working tree as of 2026-10-24, branch `codex/living-ink-redesign`.
Tags: **V** = verified in code, **R** = seen in render, **I** = inferred from code (not observed live).

## 0. Evidence quality (read this first)

- `build/` does not exist, so `build/onboarding-evidence/` and `build/dependable-evidence/` are gone.
- `/tmp/gauntlet/` belongs to a different project (web-site gauntlet: `site/`, `web-backup-start/`, `judge/*.mjs`). It has no `ws-r*` folders and no Perry `critique.md`. The round 2/3 critiques cited in `progress.md` are not on disk.
- Renders that exist and are STALE against the notch-only dark direction (all dated 2026-10-01 or older):
  - `docs/evidence/phase-5/home-dark-live.png`: a "Perry Home" window with traffic lights, a sidebar, blue SF symbols and sage-green system buttons. The plan removed this window.
  - `docs/evidence/phase-7/approval-card.png`: a titled window with a system-blue Approve and gray Stop/Always allow. Current code uses `InkButtonStyle` pills.
  - `docs/evidence/phase-4/onboarding-finale.png`: it is a desktop screenshot of the Home window over the user's other apps.
  - `docs/evidence/phase-5/notch-status-pill.png`: a gray "1 task" pill, not attached to the notch. It is not the black crown silhouette in DESIGN.md.
  - `docs/evidence/living-ink/acceptance.md` still says "light paper … dark mode deferred", which contradicts DESIGN.md (dark is the active direction).
- Current: `docs/evidence/installer/dmg-finder-window.png` (2026-10-22). It looks good: ivory paper, notch with eyes, serif headline, dotted "then it lives up here" path. No notch-state render of the current code is in the repo.
- Consequence: nothing I could look at shows the notch, workspace, approval, guide, or failure states as they are today. Every notch-surface finding below is from code. A fresh render pass is needed.
- `prose/SKILL.md` could not be found (`~/.agents/skills-library/prose`, `~/.claude/skills/prose` missing), so the house prose self-audit was not applied. I kept sentences short instead.

## 1. Top 15, ranked by user impact

Effort: S = under half a day, M = 1–2 days, L = more than 2 days.

### 1. Every failure message goes to a status string that no visible surface renders. (V, M)
- `AppController.sessionStatus` (`App/AppController.swift:127`) is read in exactly one view: `App/SessionPanelView.swift:184`. That view is shown only inside the "guide/do" sub-view, `showsGuide` (`App/CompactConversationView.swift:84-87,101`).
- About 25 call sites write to it. The hold-to-talk loop writes to it: `TalkSession.swift:107` ("Finish or dismiss…"), `:112` ("couldn't start listening"), `:225` (mic start failed), `:246` ("I didn't catch that"), `:335` (turn failed incl. provider 401/429/not configured). So do muted-output notes (`VoiceController.swift:368,393-399,762`) and route changes (`:749`).
- What the user sees when a hold fails: the character goes to `.blocked` (amber "needs you" pose, `PerryCharacter.swift:26`). There is no sentence and no action. The notch stays collapsed.
- Contrast: `VoiceConversationController` failures do open the panel (`SessionPanelPresenter.swift:185`), so the same failure is visible on one voice path and invisible on the other.
- Fix: give failures one sink. Use a `NotchPresentation` entry of priority `.activity`, or a caption bubble with a button. Add a test that fails if a status string has no renderer.

### 2. Hovering the notch for 110 ms opens the full workspace, and nothing closes it. (V; behavior I, S)
- `HomeHoverIntent.dwell = 0.110` (`HomeHoverIntent.swift:23`) → `showPeek` → `onPreviewConversation` → `showPanel(activate:false)` (`AppSubsystems.swift:522`).
- That opens the 892×520 workspace panel (`SessionPanelPresenter.swift:146`) at `.statusBar` level with `orderFrontRegardless`. The old peek view was deleted (`D App/Home/HomePeekView.swift`).
- `.hidePeek` is a no-op (`HomeController.swift:299`: `case .hidePeek: break`). The tuck timer exists but does nothing. Dismissal is Esc, the Close button, or a notch click.
- The preview is non-activating, so the composer is not key. A user who hovers and starts typing sends keystrokes to the app underneath (`SessionPanelView.swift:57-59` focuses only when the panel is key). DESIGN.md says mouse passage must not surprise; this covers a third of the screen top-center.
- Fix: hover shows a small invitation only. Click or hotkey opens the workspace. Wire tuck-to-hide if you keep hover-open.

### 3. A click anywhere in an 8 pt strip under the menu bar opens Perry. (V; behavior I, S)
- `zoneRect` (`HomeController.swift:216-221`) is the notch dead space plus 8 pt below the menu bar, at least 220+40 pt wide.
- The global `leftMouseDown` monitor (`HomeController.swift:87,270-275`) opens the conversation for any click inside it. The click also passes through to the app below.
- This is where browser tab strips and title bars sit, top-center, on notched Macs. It can open Perry while the user clicks a tab.
- Fix: limit the click zone to the notch silhouette. Keep the extra margin for hover only. Or require the notch to be the topmost window under the point.

### 4. Failure copy rarely offers a one-action recovery, and some is raw or jargon. (V, M)
- 401/403 and other HTTP errors: `HTTPStreaming.swift:140-155` builds `"HTTP 401: <provider body>"`. The body is the provider's own text, such as "Incorrect API key provided: sk-…", shown verbatim. Network down surfaces as `error.localizedDescription` (`AgentLoop.swift:177`). Neither says what to do.
- Rate limit is the only mapped case (`AgentLoop.swift:308-314`: "X is rate limited — resets 3:40 PM"). It names the provider id, not a person-readable name, and has no "switch model" action.
- No model/key configured: "Choose a conversation model in Settings." / "Add your API provider, model, and credential in Settings." (`BrainController.swift:240,248`). Plain text, no "Open Settings" button, and it lands in the invisible sink (#1).
- Mic denied: "Enable microphone and speech recognition … in System Settings › Privacy & Security" (`VoiceConversationController.swift:79`). No button that opens the pane, so it takes about 5 manual steps.
- Cua driver missing: "Cua Driver is not installed or could not be started." (`CuaDriverClient.swift:329`). "Cua Driver" is engineering vocabulary and there is no install action.
- Strong part: muted output copies the reply to the clipboard (`VoiceController.swift:393-399`). Bluetooth route flips re-route speech with a preroll (`:729-756`, `AudioRouteMonitor.swift`). Those are HeyClicky-grade. Their notices are invisible by #1.
- Fix: one `FailureNotice` type (message, one primary action: Open Settings pane / Retry / Switch model). Map `ModelProviderError.kind` and `URLError` to it.

### 5. Holding the talk key while a session is `.asking/.guiding/.executing/.reporting/.failed` silently refuses. (V; I for reachability, S)
- `TalkSession.swift:108-111` sets the status "Finish or dismiss the current session before talking." and returns. There is no cue, and the string is invisible (#1).
- `.failed` and `.reporting` need a dismissal that the user may not know about. So a user can be stuck pressing a hotkey that does nothing.
- Fix: any hold during `.failed/.reporting` dismisses and starts listening. During `.executing`, route to steering (already exists) and say so.

### 6. The notch always lives on the built-in notched display. Idle shows nothing. External-only users get a 6 pt dot. (V, M)
- Panel, status pill and hover zone all choose `NSScreen.screens.first { safeAreaInsets.top > 0 } ?? NSScreen.main` (`SessionPanelPresenter.swift:137`, `NotchStatusController.swift:97`, `HomeController.swift:240`). With the laptop open and the user working on an external monitor, Perry opens on the laptop screen, not where the user is looking. `NSScreen.main` follows the key window, not the pointer.
- `showRestingDotIfNeeded` (`HomeController.swift:322-346`) draws the fallback dot only when no screen has a notch (`:324`). So a user with an open MacBook and an external display gets no dot on the external screen. On the sole no-notch screen the dot is 6 pt, 60% `labelColor` (`:340`), on `NSScreen.main`, and is not re-placed when the display changes except via `screenLayoutChanged`.
- At rest on notched Macs the black capsule is hidden (`NotchStatusController.shouldPresent` `:76`: only recording, tasks, approvals, or wake). New users have no visual cue that the notch is interactive. The hotkeys are the only discovery path.
- DESIGN.md says "Do not hide functionality on external displays." The no-notch tab it describes is not built as a tab.
- Fix: pick the screen under the pointer. Draw a real top-center tab (same silhouette) on non-notch screens. Show a faint resting affordance for the first N sessions.

### 7. The notch panel resizes with a hard cut and collapses with no animation. (V, M)
- Frame changes use `panel.setFrame(frame, display: true)` (`SessionPanelPresenter.swift:75`). Selecting a rail item, a new approval, or a guide step can change width 592↔892 and height instantly.
- The grow-from-notch mask runs only when the panel goes from hidden to visible (`:34`, `:40-60`). It is a rounded rectangle with a 10 pt radius, not `NotchSilhouette`'s 16/30 pt shoulders, so the first 0.34 s shape differs from the final clip.
- `hide()` is `orderOut` (`:82`) with no collapse animation, so the "grows from the notch" effect has no reverse.
- Content height is two-pass: the first frame uses a default (`contentHeight … ?? (focused ? 460 : 520)`, `:143`), then `NotchPresentation.measure` (`NotchPresentation.swift:46-52`) triggers `refreshNotchLayout` (`:189`, an extra main-queue hop) and a second resize. Approvals and guide steps visibly jump.
- Fix: animate `setFrame` (`animator()` or a `CASpringAnimation` on the layer), reverse the mask on hide, and pre-measure before first show.

### 8. Main-actor work in view bodies and on every keystroke. (V, S)
- `FilesPage.body` calls `files(in:)` → `FileManager.contentsOfDirectory` plus `resourceValues` inside the sort comparator (`HomeView.swift:321-345`). The comparator reads the disk twice per comparison. This runs on every re-render of the Files page, on the main actor.
- Every key in the composer writes `HomeModel.newConversationDraft` (`HomeModel.swift:78-82`). `HomeModel` has 21 `@Published` properties and is one `ObservableObject` observed by `NotchWorkspaceView`, so each keystroke re-evaluates the whole 892×520 workspace (rail, header, page). The code base has 21 `ObservableObject`s and 0 `@Observable`.
- Each keystroke also cancels and respawns a task that writes the draft to the thread store (`HomeController.swift:414-427`), with no debounce delay.
- Idle CPU is good per `progress.md` (0.000% after the 2026-10-22 fixes), so this is typing and page-switch smoothness, not idle burn.
- Fix: load files in `.task` into `@State`. Debounce the draft save by 400 ms. Split `HomeModel` or move to `@Observable`.

### 9. Missing Screen Recording degrades silently, and revoked permissions are never re-checked. (V; I for live behavior, M)
- `LocalTalkObserver.captureJPEG` returns `nil` without a grant (`:262`). The turn proceeds with the accessibility tree only. The user is not told that Perry cannot see pixels, so answers like "what's in this chart?" quietly get worse.
- If Accessibility is missing, `TalkObservationCapture` falls to the Cua driver (`TalkObservationCapture.swift:21,42`). If that fails, the user gets "Perry couldn't answer that." with no cause (`TalkSession.swift:337`).
- Permission state is read at onboarding (`OnboardingCoordinator.swift:112`) and in Settings (`SettingsView.swift:230`). I found no runtime check or notch notice when the user later revokes access in System Settings.
- Fix: preflight at hold time (cheap: `CGPreflightScreenCaptureAccess`, `AXIsProcessTrusted`). Show one line with a button.

### 10. Failures steal focus, and closing the notch raises every window of the previous app. (V, S)
- `.failed` voice state calls `showPanel()` (`SessionPanelPresenter.swift:185`), which is `showPanel(activate: true)` (`:124`) → `NSApp.activate(ignoringOtherApps:)` (`:23`). A background error pulls key focus away from whatever the user is typing in.
- `hide()` re-activates the previous app with `.activateAllWindows` (`:86`), which brings all of that app's windows forward, not just the key one.
- Fix: for notices use non-activating presentation (`activate:false`). Use `previous.activate(options: [])` on restore.

### 11. Long answers cannot be read where they appear. (V, M)
- The answer shows as a cursor-side bubble, 11 pt, `lineLimit(3)` (`CaptionLayer.swift:158-161`). It hides while listening or processing.
- Longer replies are truncated unless the user opens the workspace. With output muted, the reply goes to the clipboard and the notice is invisible (#1).
- Fix: when the reply exceeds the bubble, show a "Read more" chip that opens the thread. Mark the bubble `…` when truncated.

### 12. Render cost in the cursor overlay while Perry is active. (V; I for frame drops, M)
- `CompanionFollower` writes SwiftUI `@State` (`cursorPosition`) for every mouse event, via `DispatchQueue.main.async` (`CompanionFollower.swift:127-134`, `updateCursorTracking` `:190`). On a 120 Hz trackpad that is up to 120 body evaluations per second per display. Moving a `CALayer` or window frame directly would not re-render.
- `PerryCharacter` runs a `TimelineView(.animation(minimumInterval: 1/60))` for listening, speaking, thinking, working and needs-you (`PerryCharacter.swift:542,556-559`), and its `Canvas` applies `.shadow` filters (`:357,447`). `InkLayer` adds blur/shadow radius 6–8 on every stroke (`InkLayer.swift:106,290,301,345,358,478,488`).
- The fallback poll is 30 Hz (`CompanionFollower.swift:179`), so if monitors fail the follower lags the system cursor visibly.
- Reduced motion is handled in the character (8 fps, no blink: `:154,202-203,555`), follower (`:264-272`), panel grow (`SessionPanelPresenter.swift:35`), onboarding and the Ink controls. Gap: `InkButton` animations (`InkButtonStyle.swift:53-54`) ignore Reduce Motion (only the scale is gated).
- Fix: drive the follower from a layer-backed view. Drop shadows from the 60 fps canvas. Measure with `idle-probe.sh` plus a frame-time probe during a talk turn.

### 13. Three overlapping voice loops with different latency and failure behavior. (V, L)
- Hold-to-talk `TalkSession` (immediate submit at key-up). Click-to-talk `VoiceConversationController`. Wake word / realtime `VoiceController` + `RealtimeVoiceSession` (2401 lines). Plus `DictationController`.
- `VoiceConversationController` waits `finalizeDelay = 1.5 s` after the last partial before submitting (`:33,276-283`). If the recognizer never finalizes after `finishListening`, it waits `silenceTimeout = 20 s` (`:34,111-118`) in "thinking".
- `.requestingPermission` shows no UI (`SessionPanelPresenter.swift:162`: `case .requestingPermission: break`), so the first mic prompt appears with no explanation from Perry.
- Failure surfaces differ per loop (see #1). Shared types for "voice failed" do not exist.
- Fix: one voice session type with one failure presenter. Show "Listening…" on the notch at key-down regardless of loop. Cut the silence stall to about 4 s.

### 14. Type scale, spacing and buttons are not one system. (V counts, I for contrast, M)
- Type: DESIGN.md calls for 13–15 body, 11–12 metadata, 20–28 headings. Code has 38 `.font(.system(size:))` in `App` (sizes 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 26) against 117 semantic styles and 88 `PerryTheme.Typography` uses. `PerryTheme.Typography` itself is all semantic styles that scale with Dynamic Type, while the hand-sized ones do not.
- Spacing: DESIGN.md says 4/8/12/16/24/32/48. `PerryTheme.Spacing` is 1, 2, 6, 8, 10, 12, 16, 18 (`PerryTheme.swift:60-69`). Literal `spacing:`/`.padding(n)` values in `App` include 3, 5, 6, 10, 14, 18, 20, 22, 28, 36.
- Buttons: `InkButtonStyle` is 38 uses, but the stock `.borderedProminent` is still on five buttons in the Tasks page (`BackgroundTasksView.swift:196,206,224,232,318`) and `.bordered` in `SessionPanelView.swift:173,227` and `HomeConversationView.swift:83`. There are also `RowButtonStyle`, `OnboardingLinkStyle`, `ContextChipStyle`, 29 `.plain` and 11 `.borderless`.
- I: `.borderedProminent` under `.tint(PerryTheme.Colors.accent)` (`CompactConversationView.swift`; accent dark is `#9CCBB6`) probably gets white text on a light sage fill, around 1.7:1. The Tasks page is where Stop/Pause/Resume live. Check in a render.
- Contrast: the token pairs are fine on paper (text `#F3F0E8`/`#AAA9A5` on `#18191B`); DESIGN.md itself says none were measured.
- Light palette is dead (panel is forced `.darkAqua`: `SessionPanelPresenter.swift:98`; `NSApp.appearance` `AppController.swift:269`) but `PerryTheme.Colors.color(light:dark:)` still builds both (already in `progress.md` open items).

### 15. Copy drifts from `docs/tone-sheet.md`. (V, S)
- The tone sheet bans "em dashes as personality" and wants failures that say what happened and what happens next. 45 user-facing string literals in `App` contain an em dash, e.g. `TalkSession.swift:246` "I didn't catch that — hold ⌃⌥ and try again.", `VoiceController.swift:363-399`, `CompactConversationView`.
- Mixed apostrophes: straight (`TalkSession.swift:225,246,337`) vs curly (`VoiceConversationController.swift:80,138`).
- Jargon in user text: "Cua Driver" (`SettingsView.swift:609`, `CuaDriverClient.swift:329-340`), "runtime" (`SessionPanelView.swift:165`, `BackgroundTasksView.swift:131`), "provider", "MCP server" (`BrainModelSettingsView.swift:22`, `CustomConnectorsSection.swift:26`).
- Fix: one `Copy` file with every status string. Lint for em dash and for the three banned nouns in user-facing literals.

## 2. Smoothness notes not in the top 15

- Motion tokens: `PerryTheme.Motion` has four entries (`PerryTheme.swift:88-93`): `panelStateChange` 0.16 s easeOut, `snap`, `glide` spring (0.32/0.86), `settle` 0.42 s. Usage is mostly `panelStateChange` (SessionPanelView, AgentActivityStrip) and `glide` (rail, tabs, switch). Onboarding uses its own `OnboardingStyle.enter`. DESIGN.md wants feedback in 100–150 ms and arrival in 180–240 ms. `snap` (160 ms) fits. The grow (340 ms) and `settle` (420 ms) exceed the arrival budget.
- `matchedGeometryEffect` is used only for the rail selection pill (`NotchWorkspaceView.swift`, `railNamespace`). The task card, approval and guide card do not share geometry with the panel.
- Notch status pill is plain AppKit (`NotchStatusController.swift`), well-reasoned for sizing stability. But it has no enter/exit animation (`orderOut`, `setFrame` at `:123-126`), so counts popping in/out hard-cut.
- Main-thread mouse path is good: the zone and enabled flag are cached (`HomeController.swift:73-79`, `currentZone` `:236-247`) and global monitors call `assumeIsolated` instead of hopping tasks.
- `AudioRouteMonitor.defaultOutputAvailable()` and `defaultOutputMuted()` are synchronous CoreAudio HAL reads on the main actor for every speak and every queued sentence (`VoiceController.swift:364-365,391-392`). HAL calls can stall during Bluetooth reconnects (I).
- `NotchPresentation` stores `AnyView` and republishes its whole `entries` array on every `measure()` (`NotchPresentation.swift:46-52`), re-rendering every observer (I).
- Window ordering: panel and status pill are both `.statusBar` level and `orderFrontRegardless`, so the notch can sit above full-screen apps' menu bar reveal and over system alerts of the same level (I).
- `warm()` only calls `displayIfNeeded()` (`SessionPanelPresenter.swift:70`). The SwiftUI tree under a non-visible window may not do its first layout, so the first open can still pay hosting cost (I).

## 3. Core loop and top-5 jobs: steps and waits

| Job | Gestures today | Waits without feedback |
|---|---|---|
| Ask by voice | 1 (hold ⌃⌥, speak, release). Follow-up: 1 more hold; per-window context lasts 600 s (`TalkContext.defaultTTL`) | keyUp → first text p50 1.9 s, p95 3.2 s (`progress.md` 2026-10-22). Capture can take up to 4 s (`LocalTalkObserver.overallTimeout`), longer through the driver fallback. Only the cursor companion shows state; no sentence |
| Ask by typing | Hover or click notch (1) → type → Return = 3. If opened by hover, typing misroutes until a click (#2) | None noted |
| Approve an action | 1 click (Approve), 1 for Always allow. Red tier: type the displayed phrase, then Approve. Panel activates (steals focus by design) | Unanswered approval has no timeout reminder. Dismissing denies |
| Be guided | Hold + "show me how…" → per step: Done / Let Perry do it / Skip. Click-advance observer can auto-advance | Step start waits on observation (up to 4 s), no step-level spinner I could verify |
| Run or stop a task | Open notch (1) → Tasks (⌘1–5) (2) → Stop/Pause (3) | Collapsing the notch hides Stop; the status pill shows count only and is not a control for stopping |

States that contradict or dead-end:
- Hold during `.asking/.guiding/.executing/.reporting/.failed` → silent refusal (#5).
- Character shows `.blocked` ("needs you") for plain provider errors, but no approval exists, so "needs you" has no target (#1).
- Hover opens, nothing closes (#2).
- Settings are reachable only through the notch (plan has no status item, `StatusMenuController.buildMenu` is embedded as the notch's ⋯ menu, `NotchCommandsMenu`). With the notch invisible at rest on a no-notch or external-only setup, first-run recovery depends on knowing the hotkeys.

## 4. Failure-path choreography scorecard

| Failure | Detected? | Plain language? | One-action recovery? | Visible in notch-only UI? |
|---|---|---|---|---|
| Mic permission denied | Yes (`VoiceConversationController.swift:77-80`, `OnboardingCoordinator.swift:112`) | Mostly | No button | Click-loop yes, hold-loop no |
| Screen Recording missing | Partly: silent degrade (`LocalTalkObserver.swift:262`) | No message | No | No |
| Accessibility missing | Falls through to driver | Generic ("couldn't answer that") | No | No |
| No model / key configured | Yes (`BrainController.swift:240,248`) | Yes | No "Open Settings" | No |
| Network down | URLError description | Passable | No retry action | No |
| Provider 401/403 | Yes (`HTTPStreaming.swift:150-151`) | No: raw "HTTP 401: <body>" | No | No |
| Provider 429 | Yes, with reset time (`AgentLoop.swift:308`) | Yes (provider id shown raw) | No switch-model action | No |
| Cua driver missing | Yes (`CuaDriverClient.swift:329`) | Jargon | No install action | Depends on path |
| Output muted | Yes, includes mid-reply (`VoiceController.swift:758-764`) | Yes ("reply is on your clipboard") | Automatic fallback | Bubble yes, status no |
| Bluetooth/route change | Yes (`AudioRouteMonitor`, `VoiceController.swift:729-756`) | Yes | Automatic | Status no |
| Wedged mic / selected mic gone | Yes (`DictationError.deviceUnavailable`) | Yes | "Choose another microphone in Settings", no button | No |

Credit where due: muted-output and route-flip handling match the HeyClicky rubric in `docs/heyclicky-feature-audit.md:67-75`. The gap is presentation, not detection.

## 5. Consistency checks that passed

- `InkButtonStyle` is the dominant system (38 uses) with hover, press and a focus ring. Switch and slider are keyboard operable with accessibility representations (per `progress.md` code review).
- Dark tokens are applied through one `PerryTheme.Colors` table. The notch crown is `Color.black` (`CompactConversationView.swift:29`) and silhouette-clipped.
- DMG installer art follows the tone: serif headline, one sentence, one cue.

## 6. What I could not check

- Any live behavior (hover, resize jumps, focus, frame time). All "I" items need a render or a recording on the Mac mini (per memory: do not test on the MacBook while in use).
- Real contrast numbers. No renders of the current UI exist to sample.
- Whether any other component reads `sessionStatus` through a path I missed. A repo-wide grep (`App`, `Packages/*/Sources`, `AppTests`) found only `SessionPanelView.swift:184` as a reader in non-test code.
