# Current: first-impressions rework (2026-10-25)

- Plan: `docs/plans/2026-10-25-perry-first-impressions.md`. Research: `docs/research/2026-10-25/` (r1-r10, c1-c4).
- Trigger: the user installed the 3344b57 DMG and listed 16 first-impression defects (plan section 0).
- Decisions D1-D6 answered 2026-10-25 (plan section 1). D3 updated from r8; Phase 6 needs approval for `llama-server` and the model files.

## Task log

- 0.1 Test Mac: since 2026-10-26 all testing runs on `mac-tailscale` over ssh; the user asked that nothing drive their MacBook. The mini's own Xcode is 16.3, so this MacBook's Xcode 27 (3.9 GB) was copied to `~/Applications/Xcode-27.app` on the mini; use `DEVELOPER_DIR=~/Applications/Xcode-27.app/Contents/Developer`. Sync with `rsync -a --delete --exclude .git --exclude /build --exclude .build --exclude .devin --exclude .audit --exclude docs/evidence ./ mac-tailscale:Honey/perry/`. Package tests also run with the mini's Command Line Tools (Swift 6.4).
- CI baseline at 9249f82+: green. 640 app tests (8 skipped), all package suites pass.
- 0.2 Done (`c7a5228`): 49 baseline renders in `docs/evidence/first-impressions/before/`, each opened and annotated in its README.
- 0.3 Done (`40ec19e`): stale Metal Toolchain note removed from `AGENTS.md`.
- 1.1 Done (`2d95c6a`): demo flow deleted, -477 lines. Verified by build and 638 app tests.
- 1.2 Done (`cca6af0`): prototypes and dead package types deleted, -686 lines. Verified by PerryCore/Guide/Runtimes package tests and 638 app tests.
- 1.3 Done (`06654f0`): runtime choices, the unreachable warning, the inventory working directory, the OpenCode CLI record and a stale UI test deleted, -391 lines. Verified by PerryRuntimes tests and 636 app tests (the one failure was a test expectation, fixed and rerun).
- 1.4 Done (`01d81e9`): model and shortcut choices stored as enums; `Preference` decodes `RawRepresentable` values. Deviation: an unreadable saved model choice reads as `.local`, not `.chatGPT`, to keep the existing rule that a damaged setting never selects a remote provider. Verified by `BrainControllerTests`, new `PerryPreferencesTests`, and 637 app tests.
- 1.5 Done (`4b0d4d6`): `CommandRouter.decide` split out as a pure function; `CommandRouterTests` pins 21 routes. Deviation: no `MaintenanceOrderingTests` yet. A recording fake needs about 20 controller fakes; `BackgroundTaskLifecycleOrderingTests` already pins quit and erase behaviour through the real `AppController`.
- 1.6 Done (`857e449`..`719c4fd`): the four single-conformer host protocols are deleted (coordinators hold a weak `AppController`), plus five unused forwards. Deviation: no `Hooks` structs; each coordinator uses 11-28 members, so hooks would be a bag of callbacks. The other forwards stay because about 800 call sites read them. Verified by build after each protocol and 638 app tests.
- 1.7 Done (`6c135be`): `HomeOnboardingView.swift` moved to `App/Onboarding/OnboardingBeats.swift`.
- 1.8 and 1.9 deferred: the typed-plan path in `ForegroundTaskController` (`executePreparedPlan`, rehearsal marks, `handleTypedDoEvent`) serves routines only but shares session, supervisor and control state. 1.9 fix 1 reworks the same code, so both run together before Task 7.11.

- 2.1 Done (`9625c0c`): `PromptAssembler` with a live capability block, 8 goldens and invariant tests.
- 2.2 Done (`4fc747f`): every model call uses the assembled prompt; `AgentPrompt` and the AgentLoop cannot-suffixes are deleted; `TalkPrompt` keeps only per-turn context. Deviation: the assembled prompt is about 2.2 KB against 1.4 KB before, so `testLongConversationAnswersBeforeCondensingAndRetainsSources` now uses an 8192 window (it still condenses 60 KB of history). A 4K-context local server loses about 800 bytes of history budget; Apple's provider reports no window and the R8 models have 32K or more.
- 2.3 Done (`12a8702`): `PromptAssembler.isCapabilityQuestion` plus `answerForCapabilityQuestion` answer "what can you do" in `AgentCoordinator` (Home and notch Ask) with no model call. "help me" no longer starts Guide. A signed-out ChatGPT choice now routes as no brain, with the same text as Home's missing-provider case. Deviation: a predicate instead of a new `GuideIntentParser` case, which avoids four exhaustive switches; BrainController's per-choice errors (ACP, Claude Code, API key) stay because each names its own fix.

- 2.4 Done (`862cfa0`): Ask routes to a vision model first and falls back to a text-only model when the window has accessibility text; the screenshot goes only to models with vision. The capability block and the "what can you do" answer say "read the window" for Apple's model, and only Accessibility gates it. Deviation: no per-conversation `LanguageModelSession` yet; the provider replays the transcript, which is correct, and the plan gives no latency evidence for the change.
- 2.5 Done (`dc42285`): the model's `memory/PROFILE.md` and `memory/CONTEXT.md` now reach prompts through the memory context (whenever memory is on), ahead of the 12 recent records, and the memory eraser removes both. Before, erase covered only the root `PROFILE.md` mirror of `MemoryStore`, and the claim that these files were injected into prompts was false. Deviation: no pinned slot in `MemoryStore`; the profile file already is the pinned slot.

- 3.0 Done: mockups in `docs/design/2026-10-25-notch-mockups/` (`index.html`, `mockups.png`): resting A today / B capsule eyes / C pointer mascot, B's six eye states at 3x, the 440 pt peek, listening. The user picked B (capsule eyes) on 2026-10-26.

- 3.1 Done: `App/Notch/NotchPresence.swift` owns the monitors, zones, resting panels, eyes, blink timer and peek; `HomeController` keeps input and threads. `NotchPresence.Surface { resting, peeking, open }` replaces `previewing` and `conversationVisible`; maintenance calls `suspend()` and `resume()`. `HomeHoverIntent.homeOpen`/`setHomeOpen` and the `HomeView` shell are deleted (no production caller). Deviation: no `swelling` or `hidden` case yet; swelling arrives with the hover swell in 3.x, and `hidden` is today's stopped state. Verified: app suite 640/0 on the mini (two `homeOpen` tests deleted).

- 3.2 Done: r6 §7.11 dark values in `PerryTheme.Colors` (body `#1A1B1D`, card `#232427`, new `chip` and `textTertiary`, text `#F5F2EA`, accent `#7BE3BD`, success/caution/danger hex), one `crown` token for black, and dead tokens deleted (`focus`, `Elevation`, `Spacing.cardInset`, `Sizing.settings*`, `Motion.settle`). `SemanticTypographyTests.testNotchViewsUsePaletteTokensInsteadOfBlack` fails on `Color.black`/`NSColor.black` in `App/Home`, `App/Notch` and `CompactConversationView`. Deviation: `PerryOverlayTheme.Colors.accent` (`#34D399`, same hue) stays for on-screen glow and ink, because `#7BE3BD` is about 1.6:1 on white app content; the notch status icon now uses the notch accent. Verified: 641/0 on the mini; workspace render shows the charcoal body and mint accent.
- 3.3 Done: `App/Notch/NotchShape.swift` replaces `NotchSilhouette`. It uses one quad-curve path with an ear and a bottom radius, `AnimatablePair(top, bottom)`, closed 6/14 and open 18/22. `surface` fills the crown and adds a 1 pt keyline (white 0% at the top, 10% at the bottom). The panel uses it as a background, so content is no longer clipped; the side padding became the 18 pt ear. Verified: 644/0 on the mini; `NotchShapeTests` checks that the path is closed and stays inside its rect. Renders inspected in `docs/evidence/first-impressions/3.3/`.

- 3.4 Done: the panel is created once at the largest open rect plus 48 pt of shadow padding and never resizes. `App/Notch/NotchLayout.swift` computes the visible size from the mode (focused interaction: 440 wide, content plus chrome, 160–320; workspace and onboarding: 560 × 400; caps min(600, 0.40 × screen width) and min(0.38 × screen height, 440)). SwiftUI animates the shape to that size. `SessionPanelPresenter` lost the mask morph, the animated `setFrame` and the double camera inset; its `frame` is now the visible rect, which hover, guide exclusion and the overlay already read. The surface follows r6 §7.11: black crown to `notchH + 8`, a 48 pt fade, `#1A1B1D` body, keyline, two-layer shadow. A first content measurement applies without animation, so a card does not open at the cap and then shrink. Overflow scrolls with a 16 pt fade only when the content is taller than the viewport.
  - Pulled forward from 3.9 because the 560 pt workspace overflowed: the rail is 148 pt, the workspace's 560 × 380 minimum frame is gone, the footer Settings button is icon-only, and the settings tab strip is tighter. Onboarding lost its own black fill and `.clipped()`; the greet art flexes 150–210 pt so the subtitle keeps two lines.
  - Verified: 647/0 on the mini. `NotchLayoutTests` checks every mode against the bounds table on five screen sizes. `testFocusedNotchHugsItsContent` renders a 100 pt block and measures pixels: the block is unclipped and the shape ends 16 pt below it. On a 32 pt notch a card of height c now takes c + 94 pt; before it took c + 168 pt, and the empty part showed as a black field. Renders inspected in `docs/evidence/first-impressions/3.4/`.
  - Not verified: clicks in the window's transparent area reach the app below. This relies on AppKit's default for clear windows that never set `ignoresMouseEvents`. A drill on the mini could not post events over ssh (`CGPreflightPostEventAccess` is false). Check it with a live click before Task 3.12. The shadow pixels around the shape still catch clicks.

- 3.5 Done: `App/Notch/NotchMotion.swift` holds the r6 §7.6 values. `NotchExpansion` (`open`, `contentShown`) is owned by `SessionPanelPresenter`. Open: the shape grows from the closed notch size and radii (6/14 → 18/22) with the open spring; content fades in after 80 ms from y −8. Close: content leaves first (0.10 s), then the shape closes, then the window orders out, and only then do the eyes and status return. Content is laid out once at the open size and masked by the animated shape, so text never reflows during the spring. Shadow only while open. Keyboard opens and closes stay instant (the `keyboardInitiated` flag is back). Reduce Motion: opacity only. The notch eyes fade out over 80 ms instead of vanishing.
  - Bug found and fixed on the way: the first open after launch resized the window inside the open animation's transaction, so SwiftUI animated the hosting view's own size and AppKit threw "more Update Constraints in Window passes than there are views". The presenter now lays the window out at its final frame before it starts the animation. Found by bisecting on the mini; the crash would have hit the real app on first open.
  - Verified: 649/0 on the mini. `testCloseRemovesContentThenShapeThenWindow` checks the order and that reopening during a close keeps the window. `testRenderOpenAndCloseMotionFrames` writes frames every ~29 ms; frames 0, 3, 6, 9, 12, 24 and the close frames are inspected in `docs/evidence/first-impressions/3.5/`. Open settles in about 350 ms, close in about 400 ms.
  - Not verified: a live 60 fps screen recording on a notched display. The mini has no notch and its ssh session cannot record or post events. Deviation: content out uses y −8, not −4, because one offset serves both directions.

- 3.6 Done: dwell 180 ms, tuck 350 ms (re-entry still cancels), a click in the notch still opens at once. The notch hover zone is the eyes silhouette plus 6 pt left, right and below (it was a 220 pt minimum and 8 pt below). Bugs: the peek now closes on hover-out unless a non-activity entry (approval, question, guide, routine) is revealed (c3 #3); the peek close path calls `endPeek()`, which hides surfaces without `conversationVoice.cancel()` (c3 #10); the peek becomes key without activating Perry while the pointer is over it, and a click or key inside it promotes it to open so hover-out no longer closes it (c3 #19).
  - Deviations: (1) c3 #19 uses the audit's "pointer entry" option, not "first key event": a global monitor cannot swallow that first key, so it would also land in the user's document. (2) The swell (+6 pt wide, +4 pt down at 0 ms) moves to 3.7, which rebuilds the eyes panel it animates. (3) The voice test holds a turn in `.requestingPermission`, the first in-flight state a test can reach without a microphone.
  - Verified: 652/0 on the mini. `HomeHoverIntentTests` covers the new timings; `NotchPeekTests` covers close-with-task, stay-for-approval and no-cancel. Not verified live: that key focus returns to the user's app when the peek closes (needs a GUI session).

- 3.7 Done: `App/Notch/NotchEyes.swift` replaces the CALayer bars, the 7 s repeating blink timer and the 64 × 7 tab. One 38 pt right wing with two 7 × 12 `#F4F1E8` capsules and a 0.30 mint glow. `EyeScheduler` draws one-shot blinks (3.2–7.5 s, 15% double) and glances (8–20 s; 2.5–4 s while working) from an injected random source. `NotchEyesModel` runs one-shot timers with 1 s tolerance and pauses on screen sleep, lock, Low Power Mode and Reduce Motion. Moods come from `PerryMood(voice:buddy:)`: listening (8 × 14 mint, glow 0.55, waveform left wing), working (ellipsis, faster glances), needs you (amber, held, "!"), asleep after 45 s (dim lids). Hover swells the silhouette (+6 wide, +4 down, swell springs from r6) and the eyes grow 1.12 and look toward the notch (the swell moved here from 3.6). Non-notch displays show a 150 pt pill only when there is state.
  - Verified: 655/0 on the mini. `NotchEyesTests` checks scheduler ranges, the double-blink rate and that nothing schedules while paused or in held moods, plus the mood mapping. Renders of each state inspected in `docs/evidence/first-impressions/3.7/`. Idle probe on the mini, 60 s: avg CPU 0.007%, max 0.4%, RSS 102 MB (PASS). The mini has no notch, so the resting eyes were hidden during that probe; their timers still ran.

- 3.8 Done: hover now opens a 440 pt peek (`App/Notch/NotchPeekView.swift`) instead of the workspace. `PeekRow.rows` orders a needs-you row first, then up to two tasks (background records, then working or last-24-hour threads), and falls back to two Perrys or suggestions. Rows have a 22 pt lead (amber "!", the mascot or a lightbulb), a 14 pt semibold title, a 12.5 pt one-line status and inset hairlines. Below them sit the "Ask Perry…" composer with a mic, then the Apps and History chips and an expand button. More and Close sit in the black crown beside the camera. The peek measures its own height into `NotchExpansion.peekHeight`; `NotchLayout.Mode.peek` clamps it to 120–320 pt. Tapping a row, a chip or the expand button promotes the peek to the full panel.
  - Verified: 657/0 on the mini, with 0 constraint-loop lines. `testPeekRowsPutTheApprovalFirstThenTwoTasks`: one approval and three tasks give approval, task, task. Renders of the empty, working, needs-you and long-title states, inspected next to the HeyClicky peek, are in `docs/evidence/first-impressions/3.8/`. The first renders showed three defects, now fixed: rows touched the body walls (added an 18 pt inset), "Return to active task" overflowed the peek (hidden while peeking), and the 260 pt cap clipped the three-row state (raised to 320).
  - Deviations: the cap is 320, not 260. Unverified live: hover-to-peek on a notched display.

- 3.9 Done: `App/SessionPanelView.swift` is deleted, along with `pendingPromptText`, `pendingPromptDoMode`, `pendingPromptRunInBackground`, `showsGuide` and `consumePrompt`. The workspace composer gains a mode chip (Ask, Guide, Do, Do in background) beside the window and model chips. `HomeModel.composerMode` routes a send: Guide calls `startGuiding`, Do calls `foreground.start`, background calls `backgroundTasks.queue`, and after any of these the chip returns to Ask. `presentPrompt(prefill:mode:)` writes the draft and mode straight into the model; plan-card Edit and the background menu item use it. The card fills inside the notch are gone from `NotchDialogView`, `CompactTargetChooser`, `TaskQuestionView`, the guide controls, the intent card, the routine review and the activity strip. Each now sits flat on the notch body. The panel's window identifier moved to `CompactConversationPanel.identifier`.
  - Verified: 657/0 on the mini, with 0 constraint-loop lines. New `testDoModeChipSendsTheComposerTextToTheForegroundAgent` sends composer text in Do mode and waits for the fixture agent's answer; it also checks that no chat thread was created. `testPrefilledConversationShowsDraftWithoutSubmitting` now runs through `presentPrompt`. Renders inspected in `docs/evidence/first-impressions/3.9/`. The first renders showed the activity strip's Pause, Take over and Stop labels wrapping mid-word, now fixed with `fixedSize`.
  - Deleted with the panel: the legacy SessionPanel render test, the "Guide request" box shown during an ask, and typed-text intent parsing that switched the mode automatically. The chip is now an explicit choice.
  - Open: the routine review is taller than the 320 pt focused cap, so Discard and Save scroll below the fold. Revisit in 3.12.

- 3.10 Done: `PerryTheme.Scale` holds the r6 type scale: title 15 semibold, row title 14 semibold, body 13, chip 13 medium, secondary 12.5, meta 11 medium with monospaced digits, section 11 semibold, plus display, heading, wordmark, input, keycap and code. `PerryTheme.Icon` holds three icon sizes: toolbar 13 medium, row 15 medium, inline 11 semibold. All 111 `.font(` calls in `App/Notch`, `App/Home` and `CompactConversationView` now use these. The macOS `.caption` and `.callout` styles they replace rendered at 10–12 pt. Three icon fixes: the new-conversation button is `square.and.pencil` without a filled circle; the composer mic and the peek's expand button lost their filled circles, so only Send keeps one; the status strip uses `gearshape` and 11 pt semibold glyphs. The type and palette lints moved from `SemanticTypographyTests` (deleted) to a grep in `scripts/ci.sh`.
  - Verified: 655/0 on the mini (657 minus the two lint tests), with 0 constraint-loop lines. The guard passes on the tree and fails on a planted `.font(.system(size: 9))`. Renders inspected in `docs/evidence/first-impressions/3.10/`. The first renders showed two defects, now fixed: the model chip wrapped to two lines (now shows the model name, with "Model" in its help and accessibility label), and the routine detail column wrapped its title to three lines (list column 220 → 160).
  - Open: the rail's "Recent" label clips above the Apps footer. That predates this task; take it in 3.12.

- 3.11 Done: the wordmark and greeting mascots in the workspace are now the animated `PerryCharacter`. Their mood comes from `PerryMood(voice:buddy:)`: `CompactConversationView` subscribes to a deduplicated `voiceState`/`buddyState` stream and passes the result down as `\.notchMood`. It does not observe the whole cursor state, so pointer moves do not re-render the notch. `PerryCharacter` reads a new `\.perryCharacterPaused` environment value and pauses its `TimelineView` while the notch content is hidden. Empty states and What's New use resting or sleeping mascots on the same timeline. The character draws on a canvas twice its size, so the two notch sites reserve 0.4 × size of trailing room for the mood badge.
  - Verified: 656/0 on the mini, with 0 constraint-loop lines. PerryOverlay 28/0. `testRenderMascotMoods` renders the resting, listening, working and needs-you moods; inspected in `docs/evidence/first-impressions/3.11/`. The first renders showed the badge overlapping the greeting and the wordmark, now fixed. Idle probe on the mini, 60 s with the notch closed: avg CPU 0.025%, max 0.4%, RSS 103.7 MB (PASS).
  - Not measured: CPU while the workspace is open. The probe cannot open the notch over ssh. The Perrys rail rows and the peek row leads stay static on purpose, so there is no timeline per row.

- 3.12 Done:
  - Latency: new marks `notch.hover_enter` (renamed from `home.hover_start`) and `notch.peek_visible` (`panel.visible` is unchanged for the full panel). `testPeekBecomesVisibleWithin80msOfTheDwell` times 20 `showPeek()` calls on the mini: p50 10–13 ms, p95 15–22 ms, max 34–36 ms. With the 180 ms dwell that is about 200 ms hover-to-visible at p95, under the 260 ms target. The figure comes from a test, not a live run: ssh cannot post events and the mini has no notch.
  - Three blind critic rounds (fresh Sonnet 5.5, PNGs only, HeyClicky as R). Round 3 used two critics to average out the noise. C scores, R in brackets:

    | Round | Size | Density | Colour | Icons | Life |
    |---|---|---|---|---|---|
    | 1 | 7 (8) | 6 (8) | 7 (8) | 6 (8) | 7 (7) |
    | 2 | 6 (8) | 5 (8) | 6 (8) | 5 (7) | 7 (6) |
    | 3, mean of 2 | 6.5 (8) | 6 (8) | 6.5 (8) | 5 (7.5) | 6.5 (7.5) |

  - Round 1 fixes:
    - The focused header ("‹ Workspace", collapse) moved into the crown, which saves 40 pt; `NotchLayout.headerHeight` and `headerGap` are deleted.
    - Task strip: the title has its own line, the progress bar is full width, and Pause, Take over and Stop sit in a row below.
    - The logo mascot stays resting, and the greeting hint fits on one line.
    - Rail blurb "Make a helper"; target chip "Window".
    - Composer focus outline at accent 35%; content fade delay 0.12 s.
    - The guide stop button is a plain glyph.
  - Round 2 fixes:
    - The workspace root lost its canvas fill and now shares the crown gradient.
    - "No conversations yet" is gone; Recent shows only when threads exist.
    - Activity strip fonts are on the scale; the mic is the outline glyph.
    - `NotchLayout.topInset` went from 6 to 12 pt.
    - Peek task rows lead with a spinner while working and a check when done.
  - Round 3 fixes, where both critics agreed:
    - Peek status leads are one outline-circle family: amber `exclamationmark.circle`, mint `checkmark.circle`, and a 13 pt mint arc spinner instead of the grey `ProgressView`.
    - The strip's Pause, Play and Stop use outline glyphs to match Take over.
    - The intent card's tier label is 11 pt semibold in the tier colour (was grey `.caption`); its title, body and links are on the scale.
    - Recent sits above Perrys, and thread rows are one-line titles (date in the tooltip), so the rail no longer ends on a bare "Recent" header. This closes the 3.10 open item.
  - Not taken from the critics:
    - Rebalancing the resting eyes: mockup B is the chosen layout.
    - Renaming "Perrys": a product name, so the user's call.
    - Removing the crown gradient: the critics split on it.
    - Shrinking the workspace height: it conflicts with the 3.9 single-size workspace.
  - Surprise, with evidence in `docs/evidence/first-impressions/3.12/symbol-tint-*.png`: the render harness's `cacheDisplay` capture draws SF Symbols of 14 pt or more in white, whatever their `foregroundStyle` (13 pt and below keep their colour). The same view through `ImageRenderer` shows amber and mint. A standalone probe with the same view tree does not reproduce it, so the cause is unknown. The capture, not the view, is wrong. Until live capture exists, treat the colour of large symbols in harness renders as unverified. Critics in earlier rounds saw this artifact as icon inconsistency.
  - The routine review fits under the 320 pt cap with Discard and Save visible (it only clipped when the render caught the resize mid-flight). This closes the 3.9 open item.
  - Verified: 657/0 on the mini, with 0 constraint-loop lines. Renders inspected in `docs/evidence/first-impressions/3.12/`.
  - Not done live: recordings of hover open and close, peek, approval and listening, plus the click pass-through check. They need a notched display or a GUI session that can post events and record the screen.

## Next

- Finish 3.12 (critic round 2), commit, then Phase 4.

## Evidence 2026-10-26 (mini, Xcode 27 copy)

- App suite 642 tests, 0 failures, 7 skipped. PerryBrain 338/0, PerryCore 84/0, PerryOverlay 28/0, PerryRuntimes 106/0, PerryCapture 6/0. PerryGuide 265 of 266: `testKeychainRoundTrip` fails with -25308 (errSecInteractionNotAllowed) because the login keychain is locked in an ssh session; unrelated to these changes.
- `4fc747f` and `12a8702` each compile (`build-for-testing`) on their own.
- The mini builds with `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=`; its keychain has no team identity.

# Progress: designed Perry (installer, onboarding, product)

Branch: `codex/living-ink-redesign`. Started 2026-10-21.

## Direction (decided 2026-10-21)

- Base: `codex/living-ink-redesign` with the parked `wip/notch-rebuild-2026-10-11` UI merged in (user request).
  The notch-only contract from `docs/plans/2026-10-02-notch-only-dark.md` applies: no Home window, no
  status-bar item, no floating panels. Everything opens from the notch.
- Look: "midnight sketchbook". Ivory ink on near-black carbon, a pure black camera crown, one sage accent.
- Mascot: Perry's own faceted pointer with two pill eyes (blink, glance, squint, smile). No raster art.
  References: recent.design "Bot animation states" (James McDonald) and "Buttons with feelings" (Sasha).
- Onboarding signature: the pointer writes "hello" in ivory ink, stroke by stroke, with the pen tip
  under the pointer tip. It uses the existing `PerryOverlay.InkStroke` engine.
- Verification of surfaces uses offscreen renders (`NotchSurfaceRenderTests` harness), because live
  screen captures include the user's own windows.

## Goal

Raise Perry's first-run and everyday UI to HeyClicky's bar or above. Use Arc and Raycast as the onboarding bar.
Every visual is drawn in code (SwiftUI paths, Core Graphics, Metal shaders). Nothing comes from the raster
illustrations on `wip/notch-rebuild-2026-10-11`.

## Exit condition

Each item is done only with a screenshot that was inspected, a green build, and green focused tests.

1. App icon exists, drawn by a script from vector code, and shows in Finder, the Dock, and the DMG.
2. The DMG opens to a designed window: a paper background, the icon and Applications alias placed,
   and an ink cue that tells the user to drag. A script generates it, and `package-release.sh` uses it.
3. Onboarding runs in its own window, not inside Home. Every beat (greet, first talk, brain, screen
   access, practice, finale) has a designed layout in light and dark mode, with reduced-motion fallbacks.
4. The Home welcome, the sidebar, and the compact conversation get the same design language.

## Pre-existing state (do not touch)

- Uncommitted DEBUG logging in AppController, DebugLaunchSeams, ForegroundTaskController, and
  SessionController belongs to an earlier session. Keep it out of these commits.
- `.devin/`, `.audit/`, and `build/` are never committed.

## Log

- 2026-10-21: Debug build green with Xcode 27 and `/opt/homebrew/bin/xcodegen`. Baseline screenshot
  of onboarding: one text line and a gray button above the Home composer, with the title clipped under the toolbar.
- 2026-10-21: Merged the WIP notch UI (cherry-pick without commit, 37 hunks). Kept HEAD's share-hiding
  (`PerryWindowChrome.applyChrome`), guide Back, red-tier copy, on-device speech string, and single
  composer for background runs (dropped the WIP `BackgroundTaskComposer`). Ported the WIP AppController
  changes into HEAD's split owners: `SessionPanelPresenter` (notch panel), `AppSubsystems` (voice
  conversation, steering hold, notch status), `CommandRouter` (scoped voice steering),
  `MaintenanceCoordinator` (in-notch quit and erase confirmations), `OnboardingCoordinator`.
  Ambient wake now shows in the notch status and ignores the status toggle (PRD principle 2).
  App build green. Pre-existing DEBUG logging is in `git stash` "pre-existing DEBUG logging…".
- 2026-10-21: Triaged 21 failing tests after the merge.
  - Voice now claims "listening" only once capture really starts. This is the WIP behavior; HEAD claimed it before permission.
  - Onboarding tests now follow HEAD's beat order.
  - The voice-during-approval test now enters approval directly. HEAD has no planner preview.
  - Three render tests now create `build/dependable-evidence`.
  - Re-run pending.
- 2026-10-21: User asked for a slop-test purge. Four read-only Sonnet 5.5 auditors write reports to `/tmp/test-audit/r1..r4.md`, and the rubric is in `/tmp/test-audit/brief.md`. Deletions happen only after I review each report. The default is keep.
- Next, by user request: a gauntlet-loop UI hillclimb against HeyClicky (cursor, notch, onboarding vs Raycast/Arc), with blind critic comparisons.
- 2026-10-21: Open race findings from the full-suite run.
  - (a) `testStaleStartupErrorCannotOverwriteReplacementAttempt` hung for 14 minutes. Its unbounded gate awaits have no timeout.
  - (b) `testErasureClosesAllGuideScopesAndSuppressesDismissedScopeHistory` left 1 history row after erasure in the suite. It passes 5 out of 5 runs in isolation.
  - (b) is a possible privacy race, where a dismissed guide writes history after erasure. It needs a root-cause pass.
- 2026-10-21: Slop-test purge applied. The list is in `/tmp/test-audit/accepted.txt`.
  - Deleted 37 tests, 4 dead helpers, and 7 files.
  - The 7 files are `DebugLaunchSurfaceTests`, `TypedForegroundExecutionTests`, the `PerryRuntimesTests` and `PerryCoreTests`/`PerryCaptureTests` placeholders, and 4 unused `Perry*Info.version` source enums.
  - Rejected 5 auditor picks:
    - the erasure Keychain inventory pin;
    - the OAuth redirect pin;
    - the guide probe-vs-tree read guard;
    - the legacy-bridge structure lint;
    - the custom AXSnapshot coder round-trip.
  - All 6 packages are green: Core 78, Capture 6, Overlay 18+10, Runtimes 113, Guide 266, Brain 315.
- 2026-10-21: App suite green after the merge fixes and the purge. 610 tests ran, 5 were skipped, 0 failed, in 103 s. Log: `/tmp/perry-test4.log`. Nothing is committed yet.

## Parallel ownership (since 2026-10-22)

- **Character and app icon.** Owned by an Opus 5.5 (high) subagent. Brief: `/tmp/gauntlet/character-owner-brief.md`. Files: `PerryCharacter.swift`, `PerryCharacterRigTests.swift`, `scripts/` icon generator. Log: `/tmp/gauntlet/character-log.md`.
- **Onboarding.** Owned by an Opus 5.5 (high) subagent. Brief: `/tmp/gauntlet/onboarding-owner-brief.md`. Files: `App/Onboarding/*`, `HomeOnboardingView`, `OnboardingDirectorTests`. It builds into `build/debug-onb`. Log: `/tmp/gauntlet/onboarding-log.md`.
- **Me.** I own functionality, the installer (DMG), the notch workspace, the conversation, approvals, settings, and the integration of both owners' work.
- 2026-10-22 done:
  - The new `PerryCharacter` replaces the glass cursor everywhere. `PerryGlassCursor.swift` and the `PerryBuddyAnimationState` legacy are deleted.
  - The follower is now 24 pt (`DESIGN.md` §2), and UI marks use a still pose.
  - Round 1 blind critic picked ours over the HeyClicky cat (clear).
  - Session transitions now map to done, fail and needs-you sound cues. Cues are muted under Focus (`QuietHours`). `SoundCueTests` cover this.
  - Launch at login via `LoginItem` (`SMAppService`). There is a Settings toggle, and release builds register it at onboarding finish.
  - The workspace is redesigned. It has rail links, a greeting with gesture keycaps, a shared `WorkspaceComposer`, and context chips. The conversation uses a question bubble, tight list and heading spacing, and the shared composer.
  - Installer: `scripts/make-dmg.sh` builds a designed DMG. It has an ivory paper background with Perry drawing an ink line to Applications, plus a Finder layout set by AppleScript. `package-release.sh` now calls it. It was verified in a real Finder window capture (`/tmp/dmgbg/shots/v2.png`). Labels render dark and legible.
  - Release evidence: 5 `features.json` unit-test references pointed at deleted or renamed tests. They now point at the surviving equivalents. `scripts/test-release-automation.sh` passes.
  - Task card: the progress bar is sage, the controls are labeled chips (Pause, I'll do it, Stop; icon-only when collapsed), there is no contradictory "Waiting for the first step" line, and the steer hint uses a keycap.
  - Surprise: `Capsule().strokeBorder` in an NSHostingView window draws stray vertical ticks at the capsule ends. `ImageRenderer` does not, so it is a hosted-view rendering bug. It was reproduced standalone in `/tmp/chip/main.swift`. The fix is `.clipShape(Capsule())` (in `ContextChipStyle`). `HomeOnboardingView.swift:248` has the same pattern (onboarding owner).
- 2026-10-22 later:
  - Voice settings now show a curated list of up to five natural voices in the user's language, each with play, region, quality and a selection check. The full system list sits under "All voices". `RecommendedVoicesTests` covers this.
  - The composer accepts dropped files and appends their paths. The agent has `files.read`. This is not live-verified, because a cross-app drag needs real cursor movement.
  - The guide step card is tightened: a compact Done, a "Let Perry do it" chip, and quiet Back / Find again / Skip. `InkPrimaryButtonStyle` honors `.controlSize(.small)`.
  - The GhostCursor tip now lands on the other agent's location (`PerryOverlaySpace.characterCenter`). The companion offset is one helper (`besideCursor`).
  - Race (a) root cause: the test waited only for `!supervisorActive`. The old `doStartTask` can still be in flight, so the replacement start bounced. The test now waits for both and uses bounded polls, not unbounded continuations.
  - Race (b), a privacy race: a dismissed guide's finalization task could append history after `stopForErasure`, because that scope had left `guideScopes`. The coordinator now tracks `finalizingScopes`, and erasure suppresses and awaits them. The task re-checks suppression just before append.
  - Skipped as YAGNI: quiet-gating user-initiated speech (it would read as a bug), and `perry://` (nothing links to it).
  - DMG references were captured from the real Raycast and Arc installers in `/tmp/gauntlet/dmg-refs/`. The blind DMG critic waits for the real app icon (character owner).
- 2026-10-22: Full app suite green with 613 passed, 0 failed and 6 skipped. Both race fixes held under load.
- 2026-10-22 integration:
  - Both Opus owners finished. Character: won every blind bar. Icon: `scripts/generate-app-icon.sh` generates `App/Assets.xcassets`. Onboarding: won 9 of 9 in r4, with the whole flow narrow. Logs are in `/tmp/gauntlet/{character,onboarding}-log.md`. The project was regenerated, and the suite is green at 613/0/6.
  - Fixed the voice self-cancel the onboarding owner reported. `presentConversationVoice(.listening)` collapsed the notch through `hidePanel()`, which cancelled the voice session that had just started. Listening now hides the surfaces without cancelling. Live check: the press reached the button, and Perry requested microphone permission. The TCC prompt is left for the user, so listening itself is not live-verified.
  - DMG blind rounds (keys in `/tmp/gauntlet/dmg-keys/`):
    - r1 beat Arc but lost to Raycast, both narrow;
    - r2 lost both, clear;
    - r3 used a new concept (screen bezel and notch with Perry's eyes, a bold arrow, a dotted "then it lives up here" path) and beat Raycast (narrow), Arc (clear) and a sage-card variant (clear).
    - The critic's polish is applied. Evidence: `docs/evidence/installer/dmg-finder-window.png`.
  - Finder on macOS 27 deletes `.VolumeIcon.icns` during the AppleScript layout step. `make-dmg.sh` now writes the volume icon after the layout, and the title bar shows the real icon.
- Open requests: animate the panel growing out of the notch on the first onboarding show (`SessionPanelPresenter`).
- 2026-10-22 continued:
  - The panel now grows out of the notch on every open. An animated mask runs from the notch rect to the full panel in 0.34 s, ease-out, and is skipped under Reduce Motion. Verified live from own-window frame captures. The SwiftUI host layer is flipped, so the start rect anchors at y = 0.
  - Permission beat vs HeyClicky's permission screen (blind): ours won, decisive. Applied the critic's fix: the next permission to grant is the prominent button, and a "Opens System Settings…" note sits under the rows. Stale `build/notch-rebuild-evidence/onboarding-*.png` files from before the redesign were deleted. Onboarding renders now live in `build/onboarding-evidence/`.
  - Custom MCP connectors are built end to end:
    - `PerryToolHost.setExecutors(_:group:)` adds lock-protected runtime groups. Built-ins can't be shadowed (`ToolHostTests`).
    - `App/CustomConnectors.swift` persists connectors to `connectors.json`. It connects command connectors (`zsh -lc exec …`) or URL connectors, closes the client on a 20 s watchdog, and registers `mcp.<name>.<tool>`; unknown-effect tools are orange, so they need approval.
    - It disconnects on quit and on erasure. Complete erasure removes the file with the support folder.
    - Settings → Apps has a "Custom connectors" card.
    - `CustomConnectorsTests` runs a real Python MCP server.
  - Suite: app 616/0/6, PerryBrain 316/0.
  - Skipped, with reasons: the free-form shortcut recorder (the default gestures are fixed and work with zero setup, the slots have 4 choices plus conflict warnings, and the event-tap rework isn't worth it) and connector secrets (v1 has no auth headers; plaintext keys in JSON are not acceptable, and Keychain needs the erasure inventory updated).
  - The approval card has a plain-language risk tag ("Needs your OK", etc.) in place of an unlabeled dot. Approve is the compact ink primary, and Stop and the secondary actions are chips. Suite 616/0/6.
  - Workspace inner pages (my own critique against the home bar):
    - The header is a left-aligned title with no Back and no mascot, because the rail is always visible. The wordmark and ⌘[ go home. The conversation's window chip moved into the header.
    - One `WorkspaceEmptyState` (character face, serif title, one line) replaces the four mismatched empty states. The Routines empty state uses it with its record action.
    - Empty pages hide the controls that do nothing: Tasks hides Resume all and the footnotes, History hides search and export.
    - History search now cancels stale queries, so a slow older search can't overwrite a newer one.
    - Suggestions is a card with a real switch. Routines shows real app icons, numbered step dots, an ink Run now and a quiet Delete.
  - Connector keys:
    - `CustomConnector.Secret` is `.environment(NAME)` for a command or `.bearer` for a URL.
    - The value lives only in the Keychain (`dev.perry.connectors`, account = connector id). It is deleted on remove and on a failed add, and complete erasure covers the service.
    - Tests prove the key reaches the server through its variable and never lands in `connectors.json`.
  - Robustness review: 3 read-only Sonnet 5.5 reviewers covered the uncommitted diff (22 findings). Each was verified against the code before fixing.
    - Fixed:
      - voice text surviving erasure;
      - redundant idle resets from `conversationVoice.cancel()` clobbering task overlay state;
      - ⌥⌘Space dictation hijacked into steering a running task;
      - the hold gesture and voice conversation both capturing the mic;
      - unanswerable approvals and questions after collapse (dismissing now denies or cancels);
      - guide and activity presentations stealing focus (only approval and routine presentations activate);
      - the stale do-mode view after Close;
      - a cancelled quit wiping the connector list (disconnect vs forget, reconnect on release);
      - connector slug collisions;
      - `exec` breaking `VAR=x cmd` lines;
      - the URL connect timeout not cancelling in-flight work;
      - stdio writes after server exit, plus SIGPIPE;
      - `additionalProperties` ignored by the validator;
      - non-web answer links (file:, app schemes).
    - Fixed by the implementer (Sonnet 5.5) in the onboarding and DMG files:
      - Back bouncing off screen access;
      - the replay re-enabling the login item;
      - permission polling pause and resume;
      - the finale skip guard;
      - the DMG INT/TERM trap and the detach retry.
    - Not fixed:
      - npx grandchild processes on terminate (npm forwards SIGTERM);
      - connector status staying "ready" after a server dies (calls now fail with "MCP server exited");
      - raw credentials typed into a command line (the key fields are the supported path now).
    - Declined: in-notch unmute (the volume key unmutes, the reply is already text and on the clipboard) and a Dock toggle (Perry lives in the notch).
    - One-off: `RemoteIntegrationClientTests` hit the 60 s allowance once on a Keychain call. It passed on the rerun and in the full suite.
  - Suite: app 620/0/6, PerryBrain 317/0. DMG rebuilt with the hardened script in 25 s, and nothing was left mounted.
- 2026-10-22 live pass (the user answered the mic prompt):
  - Talk drill, scripted speech, 3 runs: all answered. keyup→first text p50 1.9 s, p95 3.2 s; capture p50 219 ms; deixis bound to an element 5/5. Output is muted on this Mac, so speech playback and barge-in silence weren't exercised live. Unit tests cover barge-in.
  - Real-speech drill (`TALK_WAV`): a shell-launched Perry makes T3 Code the TCC-responsible process, so Apple Speech aborts it (`NSSpeechRecognitionUsageDescription` missing on T3 Code, not Perry). `talk-drill.sh` now launches through LaunchServices when `TALK_WAV` is set. Perry's own identity has no Screen Recording or Accessibility grant, so capture fails `noTargetWindow` there.
  - First-use speech bugs fixed in `SFSpeechInput`:
    - Releasing ⌃⌥ while the permission prompt was open left the turn "thinking" forever, and recording could start after the hold ended.
    - When permission was missing at hold time, a stale `settled` could resubmit the previous hold's transcript.
  - Idle CPU went from 7.2% (FAIL) to 0.000% (`idle-probe.sh` PASS, 155 MB):
    - The ordered-out overlay window kept `PerryCharacter`'s TimelineView ticking at 15 fps. The follower now builds the animated character only while the overlay is visible.
    - The global mouse monitors hopped through a Task and recomputed the notch zone plus a defaults read per event. They now call in with `MainActor.assumeIsolated` and cache the zone (cleared on screen change) and the preference (cleared on defaults change).
    - The 60 s scheduler tick reassigned an unchanged Perry list and re-rendered the hidden workspace. It now skips equal lists.
- 2026-10-22 design critic round 1 (Sonnet 5.5, 19 surfaces, scores 3–6.5). Fixes applied:
  - One button system, `App/InkButtonStyle.swift` (primary, secondary, destructive; `InkChoiceStyle` for choice rows). It replaced `InkPrimaryButtonStyle` and the ad hoc styles in questions, guide, approval, dialogs, What's New, the task strip, Suggestions, routines and integrations.
  - Long approvals clamp to four lines, with Show more opening a capped scroll.
  - Type scale: `title3` semibold card titles, serif `title2` for empty states and What's New.
  - Copy pass: "Take over", "Try again", "Perry didn't change anything", curly quotes, plainer empty-state lines.
  - Shared `WorkspaceEmptyState` for Tasks, History, Routines, Files and Suggestions.
  - The conversation has a higher-contrast question bubble, and the window chip sits under the composer, the same as on home.
  - Routine rows show their app icon (220 pt list, two lines).
  - Suggestions shows a dimmed example card while off.
  - Integrations rows are one line with a Set up pill. Custom connectors hide their form behind Add….
  - The History rail item, page cross-fade, and ⌘[ to go home.
- 2026-10-22 critic round 2 (Sonnet 5.5, 39 renders, average about 6.0; report in `/tmp/gauntlet/ws-r2/critique.md`). Its top item, the "hell…" hello frames, was stale 07:27 artifacts from an old fallback that no code writes any more. They are deleted. The real greeting is a drawn path. Fixes applied, compile-checked only (the user asked not to run tests on the MacBook while they use it):
  - Settings buttons default to `InkButtonStyle(.secondary)`. Destructive secondary buttons use the danger color. Button sizes follow `controlSize`: `.large` is the onboarding hero size, regular is compact, and the 92 px pills are gone.
  - Erase moved to its own section. Safety rows show the app icon and "Never" instead of the bundle ID, with a footer.
  - Copy: "conversations" everywhere, "Check again", "Looking for agent runtimes…", "Ask me for this text each time", and the self-referential "available in Settings" line is gone.
  - The Tasks and History empty states have a call to action.
  - One 20 pt inset for the header, conversation and Apps. Tab widths no longer shift.
  - Unverified: the dialog renders the critic saw look stale (left-aligned gray buttons the current code can't draw). Toggles render gray in the off-key test window. Check them live.
  - Verified once the Mac was free (2026-10-22 23:05): app suite 627/0/6, PerryBrain 317/0. Renders inspected by eye.
  - The dialog renders were confirmed stale. The current dialogs use pills, and only the first action is primary.
  - `InkSwitchStyle` replaces the native switch, which went gray in a non-key, non-activating panel, so On and Off looked alike in real use.
  - Memory uses action rows with trailing buttons. Category toggles are disabled while memory is off.
  - The Appearance tab is gone, and caption opacity is now under Voice › Captions. Values use proportional digits, and the no-op large-text renders are removed.
  - Critic round 3 runs on `/tmp/gauntlet/ws-r3/`.
- 2026-10-22 critic round 3 (Sonnet 5.5, average 6.7; `/tmp/gauntlet/ws-r3/critique.md`). It saw the Appearance tab before it was removed. Fixes:
  - Dialogs: with no actions, the cancel/OK button is primary. In stacked dialogs, Cancel is full width.
  - `InkSlider` (accent fill, adjustable accessibility action) replaces the three native sliders.
  - Notes for wake word, dictation and memory are now subtitles on their controls instead of separate divided rows. `InkSwitchStyle` stacks a subtitle. `listRowSeparator` had no effect in the macOS grouped Form, so that approach was reverted.
  - The compact-voice nudge is an action row ("Get one…"), and the redundant trailing note is gone.
  - Routine review has numbered discs, an Ink switch for "Ask me for this text each time", and curly quotes on Run.
  - The Suggestions example is at 0.7 opacity. Files has an "Open in Finder" action.
  - The task-card mascot has 4 pt more room.
  - Verified by render on this Mac before the user asked to stop local testing: dialogs, Voice, routine review, General. Not yet built or tested: the mascot padding, and the Files CTA built but not looked at.
- Testing moves to `ssh mac-tailscale` (the Mac mini). As of 2026-10-22 it can't build Perry yet: the disk is full (31 GB Tailscale cache) and it has Xcode 16.3, while Perry needs Xcode 26+. The user is fixing it. Pending there: render tests, the full app suite, PerryBrain, then critic round 4.
- 2026-10-22 design-depth audit (Sonnet 5.5, `/tmp/gauntlet/design-depth.md`): it found no matched geometry, content transitions or hover on most controls. Applied, compile-checked only (no tests on the MacBook):
  - `PerryTheme.Motion.snap/glide/settle` tokens.
  - `InkButtonStyle` gains hover, press spring and a 2 pt accent focus ring.
  - `InkSwitchStyle` and `InkSlider` are keyboard-operable (Space, arrows), fixing a regression the earlier versions introduced.
  - The rail selection pill glides via `matchedGeometryEffect`, with hover on all rail rows. The Settings tab underline glides.
  - ⌘1–5 open the rail pages, badges use numeric text transitions, and the composer autofocuses on open.
  - Deferred: the live character in the workspace (idle-CPU risk; measure with `idle-probe.sh` on the mini first), notch collapse and resize choreography, the ⌘K palette, the undo toast lane and thread context menus.
- 2026-10-22 structural code review (Sonnet 5.5, `/tmp/gauntlet/code-review.md`). Fixed, compile-checked (app and test targets plus the Core, Guide and Runtimes test builds), not yet run:
  - Restored four safety test files the 10-21 purge removed (approval state machine, guide probe-failure click gating, approved-action identity, Slack bearer). The purge rationale in /tmp was lost, and the default is keep.
  - `InkSwitchStyle`: the whole row is clickable, the whole row dims when disabled, and `accessibilityRepresentation` uses a native Toggle.
  - `InkSlider`: click focuses it; arrows, Home and End work; the value is clamped and snapped to the step (no float noise); `accessibilityRepresentation` uses a native Slider. The caption range now matches the overlay clamp (0.55–1.0).
  - Custom URL connectors reject remote plain http through `NetworkEndpointPolicy` before any token is stored (new test).
  - `VoiceConversationController` settles after `finish()` even when the input goes quiet (new test).
  - The login switch refreshes on app activation. Overlapping `connectAll` and `reconnect` calls can no longer spawn duplicate servers.
  - Deleted dead `VoiceConversationView` and `HomeComposer`. Files reads each pile once per render.
  - Open from the review:
    - five notch presenters duplicate finish and remove machinery (extract one shared lifecycle);
    - `SettingsView` is about 1100 lines (split per tab);
    - three `XCTestConfigurationFilePath` production branches;
    - dead theme constants and the light palette;
    - onboarding enables the login item by default (disclosed in the finale; a product call).
- Remaining (mine):
  - live-verify drag-drop attach (needs a real cross-app drag);

## Perfect pass (2026-10-24)

Source plan: `docs/audits/2026-10-24/` (voice-latency, providers, parity, ux). Decision log: `.audit/perry-perfect.tsv`.

### Committed and verified (2026-10-24, after the hackathon pause lifted)

Commits `c82e7f2`, `b03e882`, `69924d6`, `cd5af97`, `9be18f9`, `08b5163`, `9f52f1f`: fast-tier Talk, BYOK
profiles, Talk latency, failure notices, the Perrys editor, post-action observation, notch UX and copy.

Evidence: Debug build green. Package tests: PerryBrain 312, PerryCore 86, PerryGuide 270, PerryOverlay 27,
PerryCapture 6, PerryRuntimes 114, all 0 failures. App tests 632, 0 failures, 6 skipped.
Renders inspected (`build/notch-rebuild-evidence/`): perry-editor-new, perry-editor-existing, failure-notice,
model-profiles, task-failed.

### Agent backends

- Done (`8109a55`, `8a3b5d1`): Claude Code is a conversation model. It is a `ToolExecutingModelProvider`, the
  seam Codex already uses, so no new `AgentBackend` layer was needed. Each turn opens a scoped token on
  `PerryMCPSocket`; `perry-mcp` is embedded in `Contents/MacOS`. Evidence: 5 provider tests, a scoped-socket
  test, and a live test (`PERRY_LIVE_CLAUDE=1`) where real Claude Code called a Perry tool (3.75 s).
- Done (`6c7902f`): ACP agents, with the user's "ship with guards" choice. Read-only mode when offered, a scoped
  token for the turn's Perry tools, and every other permission request rejected. Settings states that the agent
  can still read files. Evidence: 4 provider tests (one against a fake agent), a live test (`PERRY_LIVE_ACP=1`)
  where real Cursor called a Perry tool in "ask" mode (14 s), and the `acp-agent` render.
- Done (`b820a6c`): the ACP registry. Fetched only on request; npx and uvx agents need Node or uv; binaries
  download only with a registry SHA-256. Evidence: 3 unit tests (one installs through a stubbed download and
  rejects a bad checksum and a path escape), a live test (`PERRY_LIVE_ACP_REGISTRY=1`) that fetched the real
  registry and installed Goose (11 s), and the `acp-registry` render.

- Cross-model review (GPT-6 Astra in Devin, two rounds). Round 1 fixed in `c306675`, `bd25c8e`, `f2b521b`,
  `2ef71e0`. Round 2 fixed in the next commit: ACP permission is decided from every update the agent sent for
  that tool call, and needs an exact Perry identity; text-only agents get no vision tools and no screenshots;
  scope close shuts down client sockets under the lock; Talk seeds restart element IDs; browser.read lists the
  real first and last IDs.
  Evidence: PerryBrain 327/0; app suites CuaWorkerProcessTests, AgentCoordinatorTests, BrowserToolsTests green
  apart from the Cursor live test; live Claude Code passes; live ACP passes against Devin
  (`PERRY_LIVE_ACP_COMMAND="devin acp"`), whose identity arrives as `_meta["cognition.ai/toolName"]`.
  Not re-verified: live Cursor. The local `cursor-agent` crashes at launch with `Cannot find module 'tree-sitter'`
  (its version folder changed at 22:45 on 2026-10-24, outside Perry).

### Not started

- UX items done (`7197927`): panel on the display under the pointer, hover zones and a top tab on every display,
  animated resize and collapse, a "Read the full answer" notice when an answer was not heard, and pointer
  tracking that re-renders only the bubble and character. Evidence: build, OverlayPointer test, app suite 636/0.
  Not visually verified: the external-display tab (no external display attached) and the animations (Core
  Animation does not show in offscreen renders; a live capture would include the user's windows).
- The user runs these: a live computer-use drill (needs Accessibility and Screen Recording grants for the Debug
  build), a live Talk latency measurement, and a visual check of the animations and the external-display tab.

### Smoothness pass (2026-10-24, evening)

- `96bb1a0`: Debug builds sign with a local team identity, so Accessibility and Screen Recording grants survive
  rebuilds. The user re-grants the Debug Perry once. App suite 636/0 with the signed host.
- `ba971d7`: lazy rail (299 eagerly built thread rows were the main Perry cost at panel open), a collapse that
  fades instead of popping an empty box, and no cursor hint over the open panel. Build, PerryOverlay 28/0,
  app suite 636/0. Before the fix, a 60 fps recording showed the collapse ending on a dark box under the menu bar.
  The fixed collapse is not yet confirmed in a recording.
- Measured and rejected: a display-link frame probe (identical runs gave 45 to 112 "hitches"; the profiler showed
  no matching main-thread stall). Instruments' Animation Hitches trace was 10 GB and failed to export.
- Already met, so skipped: key-down to listening 11.5 ms p50; draft-save debounce; Files listing off the body.
- Do not drive the panel while the user is at the machine: it takes keyboard focus, and their typing landed in
  Perry's composer (see memory).
- Next, code-only: em dashes in user-facing copy, the remaining stock buttons, InkButton under Reduce Motion, the
  status pill's hard cut, and the second-pass height jump for approvals.

### Overnight pass (2026-10-24 night into 2026-10-25)

Rules for this pass are in `docs/pleasant.md`. The user is away, so the lab drives the real Perry.

Done, each with build plus targeted tests, and a screenshot where it is visual:
- `73c3886`, `b53dd4b`, `cbb73b9`, `2031a2f`: plain status copy, fading status pill, optimistic new threads,
  instant keyboard open/close, plain sign-in errors, lab data isolation (`PERRY_DATA_DIRECTORY`), talk drill
  reads structured elements (deixis.element 5/5).
- `c990fa4`: Files lists Perry's workspace (it pointed at folders Perry never writes). Undo of an undo repeats
  the goal. Models tab: dead "Continue" replaced by Sign out; agent status line no longer repeated. Suite 637/0.
- `ff61967`: paused agent tasks offer Resume (they only offered Delete); one `canResume` rule for row and
  Resume all. New test.
- `46eadd9`: one close button (Minimize ran the same action); empty Perrys section has a hint.
- `b75722a`: onboarding no longer celebrates a failed first answer; Type instead focuses the field; caret at the
  left; one thinking mascot; "Connect it in Settings › Models" copy.
- `bdff454`: finale card states whether answers still need a model.
- `f9caaa8`: practice window opens below the onboarding panel instead of under it.
- `119afa0`: fenced code renders as a block with Copy (clipboard verified); inline code monospaced; titles end
  at a word with an ellipsis.

How to drive the lab tonight: `/tmp/audit/click.sh <label>` clicks an AX element at its centre with a CGEvent
(cua-driver element tokens do not survive between CLI calls). Onboarding runs with
`PERRY_DATA_DIRECTORY=/tmp/audit/fresh` and `--args -perry.onboarding.completed NO -perry.onboarding.beat <beat>`;
restore defaults afterwards from `/tmp/audit/defaults-backup.plist` (copy in the Perry-lab-backup folder).

- `4b08891`: guide stop and failure messages in plain words (History showed "Goal completion has not been
  verified").
- `18a1fcd`: approval cards ask "Open Calculator?" with Don't allow / Always allow / Allow; computer-use
  failures say when Accessibility or Screen Recording is off (live run: the model now tells the user); text
  after a tool call starts a new paragraph. Tests: headline test, AgentLoop paragraph test.
- `c7ec346`: New Perry editor focuses the job field, one background, no doubled Name. Create and delete
  verified live.
- `2971475`: menu shows the chosen wake shortcut.
- `87e7e9d`: dictation word list has real fields; plain notes.

Evidence at the end of the pass: app suite 640/0 (8 skipped), PerryBrain 329/0, PerryGuide 270/0,
PerryRuntimes 114/0, PerryCore 86/0, PerryOverlay 28/0, PerryCapture 6/0. Idle probe 0.0% CPU, 101 MB.
Talk drill 3/3 answered, first text p50 1.1 s, deixis.element 3/3.

Cleanup: tonight's 8 test threads moved to `~/Library/Application Support/Perry-lab-backup/2026-10-24/
threads-tonight/`. Defaults restored from the backup plist.

Left for the user: re-grant Accessibility and Screen Recording to the Debug Perry once (new signature);
whether to shorten the status menu (about 20 items); whether opening an app should still ask (orange tier);
`cursor-agent` is broken outside Perry; `workspace/drill-proof-2.txt` (1 October) is an old drill file.
