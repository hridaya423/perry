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

### Not started

- Agent backends: a `StdioAgentProcess`, an `AgentBackend` seam around `AgentLoop`, ACP (Perry tools only,
  user-started registry fetch), Codex, Claude Code (stream-json), and an Agents settings pane. Then fix
  `docs/capabilities.md:54-55` and `PRD.md:57-67`.
- UX items: the panel on the screen under the pointer, the resize animation, a "Read more" chip, and the
  follower render cost.
- A live computer-use drill, a live Talk latency measurement, and a cross-model review of the diff.
