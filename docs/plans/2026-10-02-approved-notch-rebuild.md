# Approved notch and cursor rebuild

Status: implemented and reviewed; see 2026-10-03-notch-acceptance.md for evidence and user-deferred device checks. The approved refined concepts supersede the earlier Home window, light-only design and tall Your Perry menu. Root owns taste, integration and visual acceptance. Devin performs scoped implementation using `swe-2-max` only.

## Outcome

Perry lives in one expandable, black, physically attached notch plus a miniature cursor companion. Its full workspace expands horizontally with a compact saved-assistant and conversation rail. Everyday listening and progress stay beside the normal cursor. Reading, browsing and approvals use the notch. Existing conversations, drafts, routines, permissions and execution safeguards survive the transition.

## Locked references and dimensions

References: `docs/design/notch-only/refined/workspace-v3.png`, `cursor-feedback.png`, `results-approval.png`, `routines-settings.png`. Greeting: the approved handwritten hello with Perry sitting in the final letter. The generated greeting asset will be saved in App/Resources/Illustrations. Concepts are composition references; invented names, dates, progress and Undo promises must not become hardcoded live product claims.

- Crown and perimeter: opaque #000000, top anchored to `NSScreen.frame.maxY`, no visible gap, no shadow seam, no content behind camera. Derive camera exclusion from screen safe area. Concave top shoulders, continuous rounded lower corners.
- Workspace: target 860 × 500 points plus camera inset; compact rail about 220 points. Clamp to screen bounds. Focused onboarding and result surfaces may be smaller. Long content scrolls within the surface.
- Content: #0C0D0E canvas, #18191B subordinate surface, #F3F0E8 foreground, #AAA9A5 secondary text. Keep texture below the camera and sufficiently faint to preserve legibility. No yellow highlights.
- Typography: native system text 13–16 points for controls/body; 22–28 for page titles. Expressive handwriting belongs to greeting and occasional illustration, not every heading.
- Cursor: normal OS pointer stays unchanged; separate approximately 18–24 point mascot. Listening is three bars; progress is a short capsule with a working label and Stop. Clamp beside the pointer without covering its target.
- Motion: first-run hello gets one 2–3 second ink/light reveal, then stops rendering frames. Routine interactions settle within 150–250 ms; Reduce Motion gets a static greeting and immediate state changes. No perpetual decorative shimmer.

## Ownership and interfaces

Keep HomeModel and HomeController's persistence/execution responsibilities. Replace presentation rather than rebuilding their stores. AppController remains the one owner of the notch panel. HomeController.openHome becomes a route into that panel, never a second window. The root view selects onboarding, workspace or a priority interaction. Existing HomeModel.Selection remains the source for workspace destinations.

Priority interactions (approval, guide controls, routine review, task controls) embed their existing SwiftUI content inside the notch. Their cancellation/completion owners remain intact; no callback may be lost or resumed twice. Collapsing the surface never approves anything. System permission dialogs, browser authorization and file pickers remain system-owned. A practice target may remain a separate sample document window.

## Work packages

### A. Dark identity and onboarding — Devin

Own App/PerryTheme.swift, App/Onboarding/*.swift except PracticeWindow.swift, App/Home/HomeOnboardingView.swift, App/VoiceConversationView.swift, new greeting Metal shader and asset, focused onboarding tests. Do not edit AppController, CompactConversationView, HomeController or HomeView.

1. Replace fixed light overrides in owned files with dark styling and semantic button colors.
2. Make all six director stages use the notch; preserve checkpoints, Back, skip and permission recovery.
3. Implement the hello asset reveal using native SwiftUI/Metal with a finite lifetime and Reduce Motion. No dependency.
4. Make OnboardingNotchView render greeting, model connection, microphone setup/first talk, contextual access, practice and completion at bounded width. First talk remains voice-led. Do not automatically grant OS permission or falsely claim capture is active.
5. Keep controls live and keyboard-accessible during animation. Remove old references to Home as the product destination.
6. Report exact APIs and tests changed; root compiles and visually reviews after integration.

### B. Cursor feedback — Devin

Own Packages/PerryOverlay/Sources/PerryOverlay and corresponding overlay tests only. Read the existing state and callers; preserve external API unless an integration requirement is documented. Do not edit AppController or voice controllers.

1. Render the existing mascot at miniature companion scale beside the unchanged native cursor.
2. Replace verbose listening bubble with three restrained bars from existing listening/audio state. Never imply active listening when capture is inactive.
3. Use compact progress/completion capsule for working and finished states. Keep existing cancel/interaction callbacks and real state data.
4. Clamp to display edges, avoid pointer hotspot, preserve hit testing and click-through behavior. Static reduced-motion state.
5. Run PerryOverlay tests and report integration requirements. No UI taste decisions beyond the approved reference.

### C. Wide workspace and detail surfaces — Devin

Own App/Home/HomeView.swift, App/Home/HomeConversationView.swift, App/Home/BackgroundTasksView.swift, App/Home/HistoryView.swift, App/Home/WhatsNewView.swift, App/SettingsView.swift and new workspace view files. Do not edit HomeModel, HomeController, AppController or CompactConversationView.

1. Expose a reusable `NotchWorkspaceView(model:)`. It owns no window. Reuse HomeModel.Selection and existing callbacks.
2. Build the approved narrow rail: search, saved Perrys, recent conversations, Apps and Settings. Main resting view is mascot + primary voice action; secondary Tasks/Routines/Files/Suggestions stay compact and horizontal.
3. Focused selected pages keep Back and Close reachable. Reuse existing data and storage recovery; no placeholder pages, mock content or removal of functions.
4. Adapt settings, routines, files, tasks, history and conversations to the wide bounded notch. Settings sections use horizontal navigation or a compact picker when width is constrained. Preserve safe file access, Undo semantics and destructive confirmation.
5. Accessible keyboard focus, empty, loading and recovery states. No hard minimum width larger than 820 content points; long content scrolls.
6. Root owns final styling and checks images against the reference.

### D. One native presentation surface — root

Own App/AppController.swift, App/CompactConversationView.swift, App/Home/HomeController.swift, App/NotchStatusController.swift, App/PerryApp.swift and routing tests.

1. Inventory every openHome/openSettings/showNearCursor/show-panel caller before rewiring.
2. Route all Home requests into the notch and embed NotchWorkspaceView. Keep stores and draft restoration; remove full-window creation after callers migrate.
3. Replace detached hover peek with a top-edge attached presentation. Keep hidden/expanded status coordinated so two surfaces cannot overlap.
4. Build one silhouette and camera inset with screen-change repositioning and small-display clamping. Keep full-screen/Spaces behavior and Escape cancellation.
5. Move every status-item command to workspace/settings or app commands before removing NSStatusItem creation. Quit, replay setup, recovery and pause listening remain reachable.
6. Preserve keyboard invocation and existing hotkeys. No onboarding reset or deletion of app data.

### E. Task, approval, guide and routine presentation — root, then scoped Devin if useful

Files: App/IntentCardWindow.swift, App/Tools/ToolApprovalPresenter.swift, App/GuideControlsWindow.swift, App/RoutineReviewWindow.swift, App/AgentActivityStrip.swift and their owners.

1. Extract/reuse their content without flattening the existing decision and cancellation contracts.
2. Present in the single notch with priority over ordinary browsing; restore prior navigation after resolution.
3. Summary/results use content appropriate to actual output. Do not invent dates, sources, progress percentages or reversibility.
4. Keep Stop/Pause/Take over/retry/steering/typed high-risk confirmation reachable. Resolve cancellation exactly once.

## Integration and verification gates

Devin jobs edit disjoint owned files in the existing checkout. They must preserve dirty work, add no comments or dependencies, avoid git reset/clean/commit/push, avoid changing permissions or credentials, and leave build/project regeneration to root. Root snapshots source before dispatch and reviews each changed file against that baseline.

Commands (repo's bundled xcodegen path is currently absent; installed `/opt/homebrew/bin/xcodegen` is available):

```
/opt/homebrew/bin/xcodegen generate --spec project.yml
xcodebuild build -project Perry.xcodeproj -scheme Perry -configuration Debug -derivedDataPath build/debug-p1 -destination 'platform=macOS,arch=arm64'
xcodebuild test -project Perry.xcodeproj -scheme Perry -configuration Debug -derivedDataPath build/debug-p1 -destination 'platform=macOS,arch=arm64' -only-testing:PerryTests
swift test --package-path Packages/PerryOverlay
scripts/performance/self-test.sh
scripts/lab/idle-probe.sh --seconds 60
```

No clean build and no PerryUI runner. Focus unit tests first on onboarding checkpoint/back/skip, routing, draft persistence, screen geometry and approval cancellation. Existing tests that assume a standalone Home must be rewritten to assert the intended new product behavior, not deleted to hide regressions.

Visual review uses the real app through CUA and native render fixtures. Inspect full desktop attachment, not just cropped content. Inspect hello at start/middle/end and Reduce Motion; all onboarding steps; default workspace; search, long conversation and unsent draft; settings sections; empty and populated routines/files/tasks; approval and cancellation; working, stopped, success and error; cursor near each screen edge. Compare layout, typography, spacing, contrast, mascot scale and control behavior to approved images. Return scoped defects to Devin or fix them locally; repeat the affected checks until accepted.

Completion requires evidence for every product surface, no standalone Home/settings/approval/control windows, no Perry menu-bar item, all functionality reachable through notch/cursor, retained data, real keyboard and voice lifecycle, and no idle animation/performance regression. If live capability testing needs user-owned OS permissions, continue independent implementation and explicitly distinguish untested capability from verified UI. Never call the whole redesign complete from build success alone.

## Checkpoint

2026-10-02: inspected current dirty tree; pre-change source snapshot in `.devin/notch-rebuild/pre-change-source.tar.gz`. Model identifier verified as `swe-2-max`. Jobs pending dispatch. No implementation acceptance yet.

2026-10-02 implementation checkpoint: Devin SWE-2 Max jobs are running in sessions 35757 (onboarding), 28800 (cursor), and 52542 (workspace); prompts and logs are under `.devin/notch-rebuild/`. Root has routed Home into the notch, removed status-item creation, and moved approval, guide, routine and task presenters into shared notch content. These edits are not yet built or visually accepted. Root is migrating presentation tests while the jobs complete.

2026-10-02 review checkpoint: first integrated focused suite passed 51 tests; lifecycle/render suite passed 18 tests; performance tooling passed 8 tests. Rendered and inspected all onboarding beats and workspace destinations under `build/notch-rebuild-evidence`. Findings being corrected: sparse upper-left onboarding, off-center empty history/tasks, white-filled mascot, stale Home copy, and hover taking keyboard focus. Root replaced the greeting wipe with a finite Metal ink reveal. Cursor follow-up passed 30 package tests and exposes onCompanionStop/onCompanionOpen; root wired these to cancellation and notch reopening. Live action-strip hit testing remains to verify. Two first-pass Devin jobs exited after their CLI rejected syntax-check calls; root compiled/tested their edits directly. No claim of visual completion yet.

### Verification checkpoint, 2 October, late evening

The full app suite executed 555 tests with four skips and three assertion failures: two in the foreground retry test, one typography gate. Fixed the new fixed-size empty-state typography using semantic styles. The retry test passed on an isolated rerun without changes to its implementation. The focused rerun (retry, typography, all surface renders) passed all three tests. Full-suite timing remains unproven.

Inspected refreshed hello, model choice, screen access, first talk, workspace, tasks, populated routines, conversation, and voice settings renders. Removed stale shared presentation entries from the render fixture; the new hello screenshot now has no unrelated active-task footer. Devin cursor follow-up is terminal and its handoff is saved. Live pointer hit testing remains outstanding.

Visual review found the conversation detail still defaulted to a large typed composer. Changed it to a voice action with an explicit Type instead control, while showing existing drafts and retaining test/standalone composer behavior. The existing accepted-input path selects the current thread for spoken follow-ups. Recovery and render verification is running in exec session 57532, output `.devin/notch-rebuild/voice-surface-tests.log`. Inspect its new conversation screenshot before accepting. Other pending gates remain cursor live verification, motion frames, idle performance, structural review, and complete surface/functional acceptance.

### Live verification checkpoint

Restarted the old running Perry instance through CUA, then inspected the current build. Search truncation and white-filled mascot are fixed in the live workspace; the existing unsent draft remains intact. The 60-second idle probe passed with average CPU 0.033%, peak CPU 2.0%, peak RSS 96.4 MB: `docs/evidence/perf/idle-20261002T224554Z.csv`.

Opened the inert orange approval fixture through More. Verified approval is hosted in the same notch panel, and Stop returns to the workspace without file operations. Visual rejection: the short approval content is at the top of a 492-point panel with excessive blank lower space. Tighten interaction panel height or measure content before acceptance. Live cursor hit testing is still pending; the current fixtures do not directly exercise companion states. CUA `perry` is bound to the rebuilt app, currently showing workspace after cancelling fixture. Native input/snapshot APIs have no move-pointer method, so exact physical approach behavior needs an appropriate supported verification path; do not substitute guessed UI events.

The prior voice-first conversation render/recovery suite completed with 19 tests passing and its screenshot was inspected. Markdown headings currently display literally in conversation answers; improve the existing answer renderer before final polish acceptance.

### Approval sizing implementation

Added measured content height to each notch presentation entry. The interaction view reports intrinsic height; the existing panel positioning path adds crown/header/footer space and clamps to the display. Short approvals now shrink instead of inheriting onboarding height, while longer content remains scrollable. Presentation and interactive-panel tests passed. Live orange fixture confirmed the shorter panel but exposed roughly one line of missing chrome allowance; increased allowance from 112 to 136 points. This last adjustment still needs rebuild and short/long live comparison. CUA currently shows the inert orange approval fixture; cancel it using Stop before leaving the app.

### Approval acceptance follow-up

Added a real-window render test for short and long approval content. It verifies top-edge anchoring, compact short height, growth for long text, and display-height bounds. The test initially caught first-presentation measurements arriving while the panel was not yet visible. The resize path now accepts hidden-panel layout, and showPanel reapplies the measured size after showing. The focused render test passed after this fix. Inspected `build/notch-rebuild-evidence/approval-short.png`: content, buttons, rounded card bottom, and footer are fully visible without the former large blank region. Long content remains clamped and scrollable; further final review should include scrolling to its action controls. No approval fixture performed file operations.

### Answer formatting and motion evidence

Delegated answer formatting to Devin CLI with explicit `--model swe-2-max`, exec session 41155, prompt `.devin/notch-rebuild/answer-formatting.md`, log `.devin/notch-rebuild/answer-formatting.log`. Scope restricted to answer rendering and tests; root owns taste and will build/render. Do not restart unless terminal/missing.

Added Hello reveal frame capture test and ran it successfully. Inspected start/middle/finished/static PNGs: all show full artwork. NSView bitmap snapshot evidence does not demonstrate the Metal shader reveal; do not call motion verified from these images or the passing test. Need live GPU-rendered observation (or inspect whether Reduce Motion on the host explains the static result). Test images are in build/notch-rebuild-evidence/hello-*.png. Static final artwork is legible and preserves the approved hello/mascot.

### Presentation cleanup and delegation retry

Removed unreachable hover-peek panel state, its status/answer update work, and the obsolete hit-region extension from HomeController/AppController. The remaining hover intent routes into the notch; leaving the former peek region does not collapse an explicitly open workspace. Recovery and notch-presentation tests passed after the cleanup.

Answer renderer first Devin job (41155) exited without edits after a rendering command was rejected in non-interactive mode. Relaunched only after terminal exit, with explicit source-only instructions and the same SWE 2 MAX model. Current session: 71797; log `.devin/notch-rebuild/answer-formatting-retry.log`. Root retains build and visual review. No need to retry again while this handle is live.

### Native answer rendering

Both Devin formatting attempts are terminal without source changes after read/render tool-confirmation failures. Root implemented ConversationAnswer in the existing conversation file using Foundation Markdown presentation intents. It reconstructs block boundaries, native heading/code fonts and list markers while retaining inline attributes/links. Source updates trigger formatting; unrelated parent renders do not. Tables deliberately retain original text rather than losing cells. Existing answer text selection remains enabled. The conversation render suite passed and root inspected the updated screenshot: literal heading/list syntax is gone, voice follow-up retained. A focused assertion test covers block separation, code content, and link preservation; log `.devin/notch-rebuild/answer-format-tests.log`.

### Cursor visual acceptance and contract update

Updated DESIGN.md to describe the approved dark notch workspace and cursor interaction instead of a separate Home window/light-first contract. Added a package-internal render fixture for the actual companion views, without widening their public API. Package render test passed; inspected cursor-listening/working/finished/blocked/approval PNGs at 3×. Listening is exactly three bars; actual mascot size is 24 points; capsules have readable labels and appropriate Stop/Open glyphs. This establishes static visual evidence only. Physical approach/freeze/click behavior remains unverified.

Full app suite rerun is exec session 66542, log `.devin/notch-rebuild/final-app-tests.log`; poll current handle rather than restarting. It compiled before the package render visibility-only edit. That edit changes private to internal for the view and adds a test, with no rendering behavior changes.

Full-suite rerun is terminal (exit 65): failing test `ForegroundPlanningTests.testDismissedGuidePlannerFailurePersistsStoppedHistoryOnceWhileReplacementRuns`. Inspect exact failure in final-app-tests.log and its synchronization before acceptance. Previous retry failure did not recur in this run. Do not call full suite green.

### 3 October: lifecycle and unnecessary preview reads

Verified the pending guide lifecycle test run: 39 foreground-planning tests passed. Dismissal now requests finalization even before a guide worker acquires its body; closing a scope schedules pending finalization without requiring that body to have started. Existing erasure suppression remains intact. Overlay package log confirms 26 XCTest tests plus six Swift Testing tests passed.

The next full app run executed 558 tests with four skips and two assertion failures in the same retry test. Guide-history regression passed. Traced the retry delay to paintRehearsalMarks reading the real accessibility tree even for plans with no computer actions. Added an early return for those plans; computer plans retain their observation and sensitive-target masking. Focused ForegroundPlanningTests then passed all 39 tests in 42.7 seconds. The retry test passed in 10.2 seconds including both existing five-second cancellation windows. No timeout inflation.

Inspected General, Memory, Safety, Appearance, Models, Apps and long approval screenshots. Controls remain readable; Appearance has excessive blank space and needs sizing refinement. Apps is noticeably less composed than the approved concept. Long approval content includes its actions, but live scroll behavior remains to check. Full-run log also reports geometry cycling; investigate content measurement/window resizing before visual acceptance.

New full app run is `.devin/notch-rebuild/noncomputer-final-app-tests.log`; inspect its current exec handle before restarting. Remaining gates: full-suite result, geometry cycle, settings polish, live cursor approach/click, GPU hello motion, final structural review and requirements audit. Goal remains active.

### 3 October: full-suite success and layout stability

The noncomputer-final-app-tests run completed successfully: 558 tests, four skips, zero failures in 104.5 seconds. This verifies the non-computer preview-read guard and guide-finalization fix together. The prior goal turn made implementation progress; this continuation verified its full-suite result.

Changed measured interaction resizing so the geometry callback only records content height. A view task keyed by that height performs the AppKit resize after layout; identical window frames are no longer reapplied. Added a settled-frame assertion to the real-window approval test. Focused run `.devin/notch-rebuild/layout-stability-tests.log` passed five tests, including short/long approval geometry, presentation rules and the retry regression. No geometry-cycle warning appeared in that run. Inspected the refreshed approval-short render: complete card and action row, compact panel, no clipping. The full suite predates this small layout adjustment; focused coverage applies to the final layout change.

Still outstanding: settings density (especially Apps and Appearance), actual cursor approach/action hit testing, GPU hello reveal observation, final structural review and completion audit. No current test process remains live. The app binary was rebuilt by the focused test command; any older running Perry instance needs a CUA restart before live review.

### Apps settings refinement and live check

Reduced connection-description typography to the shared note style and moved disconnected write-permission detail inside each setup disclosure. Connected accounts still show that detail. Grouped the list at the existing settings content width with a shared surface background; connection logic and confirmation flow are unchanged. The workspace-destination render test passed (`apps-density-render.log`). Inspected the refreshed Apps screenshot, then restarted the built app through CUA, opened Apps and expanded Notion setup. Verified callback text, both credential fields, disabled empty Connect button, and read-only detail are visible together. Entered no credentials and initiated no connection. Closed the disclosure afterward. Current live app is the rebuilt version on Apps settings; original unsent draft was preserved.

This turn made code and visual-verification progress. Remaining gates from the prior checkpoint still apply, particularly live cursor interaction, GPU hello motion, structural review and the complete requirement audit. Appearance sizing remains a separate polish item; do not treat this Apps refinement as all-settings acceptance.

### Native cursor action-panel boundary

Added a package integration test that instantiates the actual CompanionActionPanelController and verifies its native window: exact 30×32 control bounds (origin allows AppKit's observed half-point rounding), nonactivating style, no key focus, mouse-event reception, foreign-display clear ignored, owning-display clear hides it, reuse shows it again, teardown hides and releases content. Focused CompanionRenderTests passed both tests (`companion-panel-tests.log`). This is stronger native lifecycle evidence, but does not verify a physical pointer approach or Stop/Open invocation. No synthetic input was used.

Began the structural/window inventory: production main settings command routes to the notch; remaining explicit windows include permitted practice, non-notch fallback dot, collapsed notch status, OAuth presentation anchor, and DEBUG-only galleries. These are inspected locations, not a completed whole-diff structural verdict. AppController and OverlayWindow were already large; compare against the saved baseline before assigning scope-related findings. Root retains taste/review ownership. No live process remains from this verification.

### Live hello shader evidence

Replayed onboarding through the running app's Set up Perry command using CUA. The immediate native screenshot showed only the opening ivory stroke of hello; the subsequent native screenshot showed the complete lettering and mascot. The surrounding copy, button and panel geometry stayed unchanged. This verifies the shader is active in the real GPU-rendered app, unlike the NSView bitmap fixtures that only captured finished artwork. CUA screenshots are in this turn's tool outputs. Closed the replay afterward through its Close button; app returned to the collapsed notch with its existing task count. No permissions were granted, no data erased and no credentials changed.

The remaining motion-specific limitation is continuous-frame smoothness/performance observation; these two captures establish the reveal transition but not frame pacing. Static reduced-motion behavior is covered by source branching and the static render, not by changing the user's OS setting. Previous turn classified as progress (native action-panel verification); this turn adds live visual evidence that resolves the prior shader-output uncertainty.

### Presentation sizing regression and companion boundary

Added a regression for presenting the same entry ID twice after it has been measured. It failed before the fix because present discarded contentHeight. NotchPresentation now retains that measurement until the content reports a replacement. The focused presentation and real-window approval tests passed five tests after the fix (`reopen-height-red.log`, `reopen-height-green.log`). Repeated presentation retains one entry and still reveals it.

Structural baseline comparison: AppController 2801→2809 lines before this turn; HomeController 889→760; OverlayWindow 1792→2259. Extracted the contiguous, cohesive waveform/companion mapping/rendering/action-panel block into CursorCompanion.swift without changing declarations or behavior. OverlayWindow is now 1882 lines, CursorCompanion 380. This avoids adding the companion subsystem to the overlay's existing mixed responsibilities without introducing forwarding layers. Full PerryOverlay suite passed 27 XCTest tests plus six Swift Testing tests; inspected its refreshed working-companion render. App integration build is `.devin/notch-rebuild/companion-extraction-build.log`, current exec handle returned by launch; inspect before starting another build.

Structural review remains partial: inspected presentation owners and companion boundary, not all changed files. Remaining live cursor and final acceptance gates are unchanged. This turn made a tested sizing fix and behavior-preserving structural progress.

### Active interaction visual pass

App integration build after companion extraction succeeded. Added deterministic rendered fixtures for guide step, guide question, routine review, working task and failed task, all embedded through CompactConversationView. Inspected all five images. Fixed the failed/reporting empty-step message: it now says no steps were recorded instead of implying it is still waiting. Routine Stop & review, Save routine and Run now use the shared ivory primary style. Re-rendered and inspected failed task and routine review; all content/actions fit. Focused render plus InteractivePanelTests passed nine tests (`active-surfaces-review.log`).

These fixtures use fixed outer heights to compare content; their blank lower regions do not establish production measured panel height. Real-window sizing is covered separately. New evidence files: build/notch-rebuild-evidence/guide-step.png, guide-question.png, routine-review.png, task-working.png and task-failed.png. No actual guide was run or routine saved. Voice steering remains an outstanding requirement audit item: the task details still expose a typed steering field, so verify whether the existing voice invocation path can steer before declaring the entire product voice-first.

### Persistent workspace navigation

The concept-generation turn produced revised workspace, cursor and surface sheets under docs/design/notch-only/revised-concepts, with prompts and limitations recorded there. Implementation review found NotchWorkspaceView removed the rail whenever a destination was selected, contrary to the approved wide workspace. Removed that conditional so the existing rail remains visible across destinations. The workspace render test passed (persistent-rail-render.log); inspected conversation, Appearance, Apps, Voice, populated Routines, Tasks and Files renders. Controls fit at the standard 892-point width. Smaller displays and long titles still need verification. Appearance retains unused vertical space; do not treat the navigation correction as resolving its sizing finding.

Devin SWE 2 MAX voice-steering job is still live, verified through exec session 32916. It is tracing input and execution lifecycle; no handoff exists yet. Do not restart it while live. Root retains review and visual acceptance. This turn made implementation and visual-verification progress; the full completion audit remains open.

### Narrow workspace and long titles

Added a 720×500 render fixture for a long conversation title and settings. Initial capture was invalid because the asynchronous thread-store refresh replaced in-memory fixture data. Seeded the temporary ThreadStore before rendering instead; the resulting image exposed the title overlapping Back and Close. Replaced the header overlay with a normal HStack title allocation, fixed-size navigation controls, single-line truncation and a full-title help tooltip. The focused render test passed (narrow-workspace-fixed.log); inspected the final conversation image and confirmed no overlap, with voice and typing actions visible. This is static 720-point evidence, not all-display or live keyboard acceptance.

Devin session 32916 remains live and has advanced to VoiceTextPolicy and VoiceInvocationGate tracing. No restart or duplicate task launched. This turn made a visually verified header fix; remaining goal gates are unchanged.

### Live persistent-rail verification

Restarted the built app through CUA, opened its collapsed notch and verified the existing unsent draft `t a`, saved conversations/Perrys and one background task remained. Opened Settings, scrolled Apps to its bottom and inspected the live screenshot: Google Workspace setup is reachable, the rail remains fixed and the content scrolls independently. Command-F focuses rail search from Settings; Escape collapses to the existing one-task notch. No credentials, permissions, task state or draft text changed. This adds real keyboard and scrolling evidence for these paths only; it does not verify all keyboard paths or cursor hit testing. Devin voice-steering session remains live; no handoff was available at this checkpoint.

### Companion reduced-motion correction

Source review found the companion waveform honored Reduce Motion while the parent position, frozen-anchor and kind animations did not. Those three animation modifiers now use nil under the existing accessibilityReduceMotion environment value. Overlay package tests passed; inspected the refreshed working-companion render for unchanged static composition. Static rendering and source branching do not establish real pointer movement or OS-setting behavior. Edge positioning and physical approach/click still require stronger evidence. Devin voice-steering session 32916 was verified live during this turn; do not restart it.

### Companion resize target lifecycle

Source review found that a frozen companion could change its measured width while keeping the old native action strip until another pointer event. Size changes now release the frozen interaction and clear that strip before adopting the new size, so the next layout uses the normal screen-clamped placement. PerryOverlay tests passed (companion-resize-tests.log). This does not replace the pending physical pointer check.

Started a full app test run for the accumulated navigation and cursor changes: navigation-cursor-app-tests.log, exec handle returned by this launch. Poll the existing run before starting another. Devin session 32916 remains live without a handoff; root has not accepted voice steering yet.

### Navigation and cursor integration suite

The navigation-cursor-app-tests run completed successfully: 561 tests, four skipped, zero failures in 108.4 seconds. This covers the persistent rail, long-title layout and cursor changes together at the app build boundary. It does not cover unfinished Devin voice steering. Read the primary presentation owners and searched App sources: no NSStatusItem/statusItem creation remains; HomeController's remaining native panel is the non-notch fallback dot. This source inventory supports routing verification, not full live surface acceptance. Devin session 32916 remains live and is inspecting existing test helpers and AgentCoordinator steering. The previous turn made a cursor lifecycle fix; this turn verified its full integration suite. Remaining live pointer/voice checks, Appearance sizing and final structural/requirement audit remain open.

### Live approval collapse and cancellation

Opened the DEBUG red approval fixture through the notch More menu after confirming its callback performs no action. Inspected the native screenshot: target, irreversibility, exact typed-phrase requirement, Stop and disabled destructive action all fit. Collapsed using its Collapse control, reopened from the notch and verified the same pending card and disabled action remained. Stop removed the fixture and restored Settings/Apps navigation. Entered no confirmation phrase and performed no destructive operation. This verifies real presentation persistence and cancellation routing for the fixture, alongside the existing unit tests; it is not evidence of real destructive execution. Devin session 32916 remains live without a handoff.

### Opt-in synthetic runtime verification

Audited the four full-suite skips: two signed-in ChatGPT runtime tests with synthetic data, and two CUA capture tests requiring a permitted TextEdit fixture. Ran the two runtime tests with TEST_RUNNER_PERRY_LIVE_CHATGPT_TESTS=1; both passed in 16 seconds (live-synthetic-runtime-tests.log). The agent test verified exactly one grounded ring tool call, preserved a separate draft, persisted two turns and recalled the synthetic project name. The guide test selected the synthetic Save control without BYOK credentials. These verify actual runtime responses through existing account authentication; they do not verify microphone capture or live desktop observation. No OS permission changed. Devin session 32916 was verified live at turn start and remains the sole voice-steering job.

### Live capture prerequisite result

Opened the existing docs/release-readiness/fixtures/Perry-Cua-Fixture.txt in TextEdit through CUA and verified its seeded marker. Ran CuaLiveTests with TEST_RUNNER_PERRY_LIVE_CUA=1. Both tests failed at readyLiveClient before capture: CUA Driver needs Accessibility and Screen Recording permission in System Settings (live-cua-capture-tests.log, lines 1338 and 1341). This is a verified permission prerequisite failure, not a successful capture or a capture regression. No permissions were granted. Closed the unchanged fixture through Command-W; CUA reported no remaining TextEdit windows. Independent implementation/review remains available, so the goal is not blocked. Devin session 32916 remains live without a handoff.

### Voice steering implementation in progress

Verified session 32916 remains live; VoiceController now has partial Devin edits that capture an execution ID at dictation start and bypass direct insertion for scoped task speech. No handoff yet, and the partially edited source has not been compiled or accepted. Do not run another full suite until the scoped job finishes editing. Root tightened the narrow render fixture to require its temporary store and assert its long title survives capture; rerun that focused test after integration. This prevents the earlier empty-thread screenshot from silently counting as long-title evidence. Capture permissions remain an external prerequisite, but independent review work is available.

### Voice dispatch review in progress

Devin has added modifier-hold dictation routing, execution-ID validation in dispatch and the typed-steering disclosure; it is now writing tests. Root inspected these partial edits without modifying the owned files. Review follow-up: explicitly test speech that began with no execution and completes after a task starts, since nil scope currently routes to whichever execution is current. Also verify scope identity across retries. Do not accept from source inspection alone. Root added native help text to truncated saved-assistant descriptions and recent conversation titles; the pending focused render/build should cover compilation after Devin finishes. Session 32916 remains live; no duplicate job or build was started during edits.

### Onboarding transition accessibility review

Reviewed workspace width constraints and onboarding motion owners. OnboardingNotchView still applied its page-change animation unconditionally, despite the greeting itself honoring Reduce Motion. Added the existing SwiftUI environment check and nil animation under Reduce Motion. No visual composition changed. Build and visual verification remain pending with the sidebar tooltip/render-fixture edits until Devin finishes the voice task; do not report these latest edits as tested. Session 32916 remains live and is writing behavioral fixtures.

### Draft visibility on return

Workspace review found sidebar selection changes reset typing to false on departure but did not restore it on returning to the welcome page. An existing draft could remain stored yet disappear from view until Type instead was chosen. The selection handler now shows typing when returning with a nonempty newConversationDraft. Verify live with the existing unsent draft after the next build; do not send or overwrite it. Devin session 32916 remains live while preparing approval-hold tests. Latest root edits remain uncompiled pending completion of concurrent source edits.

### Revised surface concepts, continuous notch silhouette

Reviewed the previously generated workspace, cursor and four-surface sheets. Regenerated the four-surface sheet with built-in imagegen to remove the visible hardware-notch seam and use the workspace silhouette consistently. Saved docs/design/notch-only/revised-concepts/surfaces-v2.png; prompt and visual review are in prompts.md beside it. All four views now attach directly to their desktop top boundary. Settings will need scrolling at constrained heights. Cursor listening remains exactly three bars by default; the previous cursor concept's duplicate notch listening indicator is not an implementation requirement. These are concepts, not evidence of running-app behavior. Devin exec session 32916 remains live; no duplicate job started and pending source edits remain uncompiled.

### Voice steering integration and fixture repair

Devin SWE 2 MAX session 32916 is terminal with exit 0, but its log ends with a noninteractive tool-approval rejection and no handoff. Source edits were retained and root took over. Repaired its optional-return test helper and removed newly added comments. Initial focused run compiled and executed 50 tests: six surface renders passed; two new voice tests produced three assertions. The approval fixture used a file goal that never reached its injected confirmer; changed it to the existing generic fixture planner path. The other test incorrectly expected no start task while a held agent run was active. Both repaired tests passed in voice-steering-fixture-repair.log.

Root rejected unscoped speech dispatch into a newly active execution and added a nil-scope regression assertion. VoiceController now also checks captured versus current execution before direct text insertion, cancelling stale input before either insertion or dispatch. Scoped stop, steering and stale replacement tests passed in the initial run. Inspected the refreshed task-working render: the voice shortcut leads, Type instead is collapsed, and controls fit. Actual microphone capture and live disclosure keyboard behavior remain unverified.

Combined final rerun is LIVE in exec session 38100, output .devin/notch-rebuild/voice-steering-integration-final.log. Poll this run; do not duplicate. It covers the final guard plus pending workspace draft visibility, tooltip, reduced-motion and render-fixture edits. Pending checks still include real-app draft return/disclosure, physical pointer interaction, capture permissions and final requirement audit. Previous goal turn made progress by correcting the generated surface silhouette; this turn made implementation and verification progress.

### Final focused suite and live steering disclosure

Session 38100 completed successfully: 50 tests, zero failures, 68.6 seconds (voice-steering-integration-final.log). Restarted the rebuilt app through CUA. The existing new-conversation draft `t a` remained visible after Settings → Back, without sending or changing it. Inspected the live workspace screenshot and native AX state.

The DEBUG Running menu fixture still set legacy session state and showed the workspace rather than activity controls. Routed that fixture to the existing debugShowActivityFixture and made its details expanded. Build passed (live-steering-fixture-build.log). After restart, the fixture displayed the actual task panel in the notch. Live inspection confirmed Type instead starts closed, opening focuses its field, the typed fixture instruction survives collapse/reopen, and Return invokes the inert fixture steering callback and clears the field. The panel grows so field/button remain visible. No real task or external app action occurred. Restarted afterward to clear the fixture; normal collapsed notch again shows the existing one background task.

This turn closes live workspace draft-return and steering-disclosure gates. Real microphone capture, physical cursor approach/actions, capture permission prerequisites and the final structural/requirement audit remain open. No running build or Devin job remains. Previous turn and this turn both made concrete progress.

### Requirement acceptance audit started

Created docs/plans/2026-10-03-notch-acceptance.md with requirement-level evidence and remaining limits. Rechecked current panel creation, silhouette, presentation priority, finite greeting reveal and Reduce Motion branches. No status-item creation exists; remaining explicit windows serve practice, authentication and non-notch fallback. Requested explicit user approval for CUA Driver Accessibility and Screen Recording through asynchronous input; pending, no permission changes. Full post-voice app suite is live in exec session 19218, final-integration-app-tests.log. Prior turn made implementation/live-verification progress; this turn adds the acceptance audit and starts final integration verification. Goal remains active with independent review work available.

### Post-voice full suite and accessibility render limits

Exec session 19218 completed: 566 tests, four skipped, zero failures in 113.4 seconds. Added two accessibility3 renders to the existing narrow-workspace fixture; focused test passed (accessibility-layout-review.log). Inspected conversation-large-text.png and settings-large-text.png. No clipping, but macOS did not visibly enlarge fonts under dynamicTypeSize, so these are not accepted as enlarged-text evidence. Updated the acceptance audit with that limitation and source-size comparisons against the pre-change snapshot. No running process remains. User permission response is still pending; no access was granted. This turn made verification progress, not an overall completion claim.

### Dead onboarding surfaces and final idle measurement

Structural review found OnboardingPaperView/OnboardingArtwork unused and OnboardingWelcomeView referenced only by an obsolete render test. Removed both source files and regenerated with installed xcodegen. Migrated the render test to the actual OnboardingNotchView using an isolated controller/director. The old test labelled a case reduced motion but never used its value. Attempting explicit environment injection proved accessibilityReduceMotion is read-only in this SDK; removed that misleading case rather than treating it as coverage. Eleven OnboardingDirectorTests passed and the current dark greeting render was inspected. It shows the approved ivory hello/mascot and visible primary/close controls. No remaining source/test references to deleted types.

Final voice-build idle probe passed over 60 samples: average CPU 0.023%, peak CPU 1.4%, peak RSS 93.5 MB. Evidence: docs/evidence/perf/idle-20261003T004158Z.csv. The later cleanup removes unreachable views and does not change idle behavior. Permission response remains pending. No live command remains. This turn made structural simplification and verification progress; whole-change structural review and external live checks remain open.

### Retired peek and restored target selection

Removed unused HomePeekView/HomePeekContent after repository-wide caller inventory; retained the actively used HomeHoverIntent state machine. Regenerated Xcode project. Sixteen typography, hover and notch-status tests passed (retired-peek-cleanup.log).

Review of CompactConversationView's migration diff exposed a real lost function: choosesTarget/selectTarget were removed while CompactTargetChooser was orphaned. Restored a Choose a window control in the new-conversation area and conversation detail. The chooser is an inline overlay inside NotchWorkspaceView with Back, not another window/popover. It writes the same HomeModel newConversationTarget/conversationTargets values and disables changes during active/pending thread work, matching the old contract.

Focused surface-render and recovery suite is LIVE in session 11633, target-chooser-restoration.log. Poll before any duplicate run. Build/render and live chooser acceptance are pending; no completion claim. Permission approval is still unanswered. Previous and current turns made concrete progress.

### Window chooser live acceptance and accessibility correction

Target restoration suite passed 24 tests (target-chooser-restoration.log). Restarted app through CUA, opened the target chooser and selected the already-selected Helium application. Chooser stayed inside the notch and returned to the preserved `t a` draft without executing a task.

Live AX inspection exposed covered workspace controls remaining accessible/focused beneath the overlay. Disabled and accessibility-hid the underlying workspace while choosing; added Back focus state and rounded the chooser surface with the existing continuous-corner language. Build passed (target-chooser-accessibility.log). Repeated live inspection confirms covered workspace controls disappear from AX and the search field loses focus. Back did not become focused in the observed AX state, so explicit initial button focus remains unproven. Escape collapses the whole notch via the existing global handler. Current app is collapsed with its prior one background task. No permission change, external capture, or draft modification. No command remains live. This turn made a tested accessibility correction and live verification progress.

### Window chooser keyboard acceptance

Made Back explicitly focusable and focused it on appearance. Live AX confirmed Back receives initial focus. Tab initially stayed there because the app choices inherited macOS button-navigation restrictions; made chooser buttons explicitly focusable. Live AX then confirmed Tab traverses Back → Devin → Helium. Return/Space still did not activate the focused choices, so added explicit key handlers to choices, Refresh, No window and Back. Build passed (target-chooser-key-activation.log). Restarted and repeated the complete path: chooser opens focused on Back; two Tabs focus Helium; Return closes chooser and shows the same selected target with the untouched `t a` draft. Covered workspace remains absent from AX while choosing. No external app operation or permission change occurred. No build is running. This turn made verified keyboard interaction progress.
