# UI verification, 2026-08-31

The `Perry` app unit suite passed 164 tests with zero failures or skips on arm64 macOS 26.5.1. The result bundle is `Test-Perry-2026.08.31_06-56-16-+0100.xcresult` in the host's Xcode test logs. This run used the dirty development worktree, not a clean release checkout.

The `PerryUI` scheme built successfully with `build-for-testing`. Earlier build commands using the `Perry` scheme did not compile the UI-test target and cannot support that claim. The corrected build includes the session-panel assertions for enabled actions, hit testing, window containment, and two-row ordering.

The isolated `SessionPanelAccessibilityUITests` execution was interrupted after approximately 53 seconds. Xcode reported `waiting for workers to materialize`; no UI assertion result was obtained. Per-test timeouts of 30 seconds, capped at 45 seconds, did not bound this pre-test worker launch. This is an unresolved test-host problem, not a UI-test pass.

The feature registry now references the recorded onboarding, Settings, session-panel, and keyboard captures, so its validator checks their artifact hashes and dirty-build restrictions. No capability status was promoted. The keyboard record only claims a visually observed focus ring for the captured Wake shortcut picker; Accessibility focus traversal alone does not prove that every control displayed a ring.

M7 remains open. The recorded runs do not prove VoiceOver completion, exact 200% text scaling, pseudo-localization, measured contrast, active-task layouts, or complete keyboard-only journeys.

The subsequent app unit run passed 166 tests with no failures or skips (`Test-Perry-2026.08.31_07-12-05-+0100.xcresult`). It includes the offline recognition request tests and precedes the session-panel layout changes.

The revised session panel passed a Debug build and manual initial-focus check. Typing after launch without a click or Tab populated the request and enabled all four actions. The captured focus ring, solid dark surface, permission error, and two-row layout are recorded in `ui/session-panel-focus-2026-08-31.json`. The panel now scrolls and permits resizing, but overflow, resize behavior, and active-task controls still need live verification.

The strengthened session UI test compiled successfully through the `PerryUI` scheme after integration. It requires initial typing without clicking the request field, accessible status, row alignment, horizontal separation, vertical ordering, and pairwise nonintersection. This build does not supply an execution result for those assertions. The independent review also identified duplicate active-task controls in the request panel; the production task flow hides that panel and uses `AgentActivityStripWindow`, so the active-task interaction review must cover that surface.

Onboarding copy now discloses that task context and screenshots can reach the selected model provider. It also distinguishes realtime voice processing from Apple Speech, whose requests now require on-device recognition and reject unsupported recognizers. Live microphone and packet-capture verification remain outstanding. The earlier screenshots preserve the old copy as historical evidence; they do not validate the revised text or its layout. The prior claims that all screen contents stay on the Mac and nothing happens outside a hotkey session have been removed.
