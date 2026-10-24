# Perry: notch and cursor implementation plan

Status: proposed architecture and visual directions, pending concept selection. This supersedes the earlier standalone Home and light-only direction. No implementation changes are part of this planning pass.

## Product contract

Perry has two application surfaces: an expanding notch and a small cursor companion. Remove the standalone Home window, sidebar navigation, Perry status-bar item, and floating task/approval/settings panels. Keep existing conversation data, routines, files, model choices, permissions and task services.

All first-party navigation begins in the notch. The cursor offers invocation and immediate contextual feedback; it never replaces or enlarges the system pointer. System-owned permission prompts, authorization windows and file pickers remain system-owned. A practice target window is demonstration content, not another Perry navigation surface.

The notch crown is pure black and reaches the physical display edge. Camera exclusion remains empty. The expanded surface uses near-black carbon, warm ivory text and a chalk-drawn mascot. Texture belongs below the camera crown and must not reduce text contrast. Do not invert existing raster artwork: create dedicated transparent warm-ink artwork after choosing the direction. No yellow highlight treatment.

## Proposed experience

Rest: occupy the camera housing with minimal extra area. Show a discreet activity mark only when relevant. Hover reveals a small invitation; click opens the last useful state. Keyboard invocation provides an equivalent route. Cursor companion stays small and quiet.

Conversation: speaking starts from an explicit invocation once permission exists. Show listening, transcript, thinking, response and interruption in the same surface. A small keyboard fallback remains available. Keep the microphone state visible and provide Stop throughout active capture or work.

Navigation: a single compact overview inside the notch offers Conversations, Tasks, Routines, Files, Suggestions, Connected Apps and Settings. It is a temporary destination, not a persistent sidebar. Selecting a row opens a focused page with Back. Return preserves scroll position and draft. Search belongs to conversation/history pages. Settings uses compact section navigation within the same shell.

Task: the notch expands to show the current step and immediate controls. Pause, Stop, Take over, steering, result and Undo remain reachable. An approval becomes the main notch content until resolved, with the exact target and consequences; collapsing must not grant or reject it. Background work continues when the surface collapses.

Onboarding: introduce the mascot inside an expanded notch, then model setup and the first conversation. Request access at the moment the relevant capability is introduced. Keep explanation, skip, Back and recovery in the same shell. Reopening resumes the current stage.

## Visual choices

A. Midnight sketchbook: subtle matte grain, expressive ivory brush lettering, miniature drawn mascot. Best continuity with the original hello concept. Requires disciplined artwork sizing so the action stays primary.

B. Quiet theatre: sparse black stage, line-based listening/progress motion, small warm mascot. Strongest hardware integration. Risk: too little character if reduced to generic waveforms.

C. Carbon folio: dark paper and precise editorial rows, restrained folds and hand-drawn progress details. Strongest information navigation. Risk: excessive card framing could recreate a dashboard.

Recommendation: A for identity, C for navigation; adopt B's restrained listening motion. Choose one coherent system before producing all state assets.

## Implementation sequence

### 1. Establish one presentation owner

Files: App/AppController.swift, App/CompactConversationView.swift, App/Home/HomeController.swift; create App/Notch/NotchNavigation.swift and AppTests/NotchNavigationTests.swift only if a focused route type is needed.

Inventory every openHome, openSettings, history, task, recovery, onboarding and status-item command. Define explicit destinations for conversation, navigation overview, history, tasks, routines, files, suggestions, settings and onboarding. Keep stores and execution services in their existing owners. Make one route transition responsible for selecting content and presenting the notch. Avoid a second independent set of guide/transcript/page booleans.

Add a route test covering all former window entry points. Verify Back, reopening, selected conversation and unsent draft persistence. During migration retain old views as content where practical; do not retain their window or sidebar shell.

### 2. Build the dark hardware shell

Files: App/CompactConversationView.swift, App/NotchStatusController.swift, App/PerryTheme.swift, App/AppController.swift, AppTests/NotchStatusControllerTests.swift.

Use the existing native top-edge positioning and constraint override. Add a notch silhouette with concave shoulders and rounded lower corners. Derive camera exclusion and crown width from actual screen geometry. The expanded surface grows downward from a fixed top anchor. Unify resting status and expanded presentation so they cannot appear as two stacked panels.

Set bounded widths and heights for voice, navigation and detail states; long content scrolls internally. Fit small screens. On external displays without a camera notch, use a top-center black tab with the same controls. Handle display changes, menu auto-hide, Spaces, fullscreen and Reduce Motion. No content or hit target may sit behind the camera.

Visually verify against the full desktop, not only a cropped view. Native frame tests remain useful but cannot prove visual attachment alone.

### 3. Move navigation and remove the Home window

Files: App/Home/HomeView.swift, App/Home/HomeController.swift, App/CompactConversationView.swift, App/Home/HomeConversationView.swift, App/SettingsView.swift, App/Home/HistoryView.swift, App/Home/BackgroundTasksView.swift, App/Home/WhatsNewView.swift.

Replace NavigationSplitView and Open in Home with the notch overview and Back navigation. Reuse existing detail content after adapting fixed minimum sizes and toolbar assumptions. Remove makeHomeWindow and standalone-window restoration only after all callers are redirected. Keep conversation and workspace data intact. Route storage recovery to the notch, including startup recovery.

Verify every destination can be reached from a collapsed notch and returns without losing draft or selection. Review long history, empty states, errors and the longest settings forms at the actual notch size.

### 4. Move task, approval and routine controls

Files: App/AgentActivityStrip.swift, App/IntentCardWindow.swift, App/GuideControlsWindow.swift, App/RoutineReviewWindow.swift, App/SessionPanelView.swift, App/AppController.swift.

Retain service/state objects and reusable content. Replace standalone panel presentation with notch destinations. Keep guidance markers as minimal cursor/context overlays, while instructions and controls live in the notch. Give foreground approvals priority over ordinary navigation without discarding the previous destination. Restore the originating task after an answer. Verify Stop, rejection, pause/resume, steering, routine save, recovery and Undo through real operations.

### 5. Move onboarding into the same shell

Files: App/Onboarding/OnboardingDirector.swift, App/Onboarding/OnboardingNotchView.swift, App/Onboarding/OnboardingPaperView.swift, App/Onboarding/OnboardingWelcomeView.swift, App/Home/HomeOnboardingView.swift, App/VoiceConversationView.swift.

Replace large standalone greeting/model/first-talk pages with notch-sized compositions. Retain the director's stage/checkpoint behavior. Use a concise animated greeting and a real first useful interaction. Permissions remain contextual. Preserve voice cancellation and stale-callback guards when changing destinations.

### 6. Remove the status item and finish cursor entry

Files: App/AppController.swift, App/PerryApp.swift, Packages/PerryOverlay/Sources/PerryOverlay/PerryGlassCursor.swift, Packages/PerryOverlay/Sources/PerryOverlay/OverlayWindow.swift.

Remove NSStatusItem creation and updates after mapping every command into the notch. Keep Settings, Quit, pause listening, setup replay and recovery accessible inside it. Standard application keyboard commands may route there; no separate Perry menu-bar icon is created. Preserve global keyboard invocation as a reliable fallback when the cursor companion is hidden.

Keep the native pointer unchanged. The companion sits beside it, avoids click targets and screen edges, and uses restrained state feedback. Respect Reduce Motion and allow hiding the companion without losing notch access.

### 7. Art, motion and acceptance

Use the selected concept to generate state artwork for greeting, listening, working, success and recoverable error. Keep illustrations separate from live text and controls. Motion should explain transitions: surface grows from the notch, mascot reacts to invocation, task completion settles. No decorative perpetual animation.

Run existing focused tests plus route regressions; regenerate the project with /opt/homebrew/bin/xcodegen generate --spec project.yml. Build with xcodebuild build -project Perry.xcodeproj -scheme Perry -configuration Debug -derivedDataPath build/debug-p1 -destination 'platform=macOS,arch=arm64'. Run relevant PerryTests with the same project, scheme, DerivedData and destination; do not use the known-hanging PerryUI runner. Inspect actual app states through native UI automation and run scripts/lab/idle-probe.sh --seconds 60.

Acceptance requires: no standalone Home/settings/task/approval window, no Perry status item, every feature reachable from notch, correct physical attachment, unobstructed camera region, readable dark hierarchy, normal system cursor, retained data/drafts, cancellation and recovery, completed voice turn, real guidance/task/approval/undo flows, keyboard access and Reduce Motion. Record evidence for each requirement; test results do not replace visual inspection.

## Dependencies and boundaries

No new packages are required. Pending microphone/speech/screen/Accessibility approval affects live capability testing, not the navigation, dark shell, removal of Home/status item, or design work. Do not mark the redesign blocked on those permissions while independent implementation remains. No external OAuth setup or provider changes are implied by this plan.
