# Phase 6 evidence — Guide, perfected (partial)

- `swift test --package-path Packages/PerryGuide`: **268 tests, 0 failures**
  (+1: scorecard skill coverage; nudge-label assertion updated).
- App Debug build: BUILD SUCCEEDED.

Landed:
- Wrong-click nudge: `ClickAdvanceMatcher.elementUnder` finds the smallest
  actionable element under the misclick; `AdvanceResult.ignoredClick` carries
  `hitLabel`; the coordinator speaks "That's <label> — we want the
  highlighted one."
- Step budget 2 → 25 on the live guide loop (`runTwoStepGuide`).
- 8 new bundled app skills (Figma, Resolve, Excel, Notion, Slack, Keynote,
  Final Cut, Logic) — manifest now covers all 12 scorecard apps
  (Sheets rides the Chrome skill; it's web-only).

Already existed: "show me everything" path painting (runFullGuide +
EverythingViewBuilder), per-step replanning against the live screen,
repoint-on-stale, protected-window guard, goal kept across pauses.

Not yet (live/blocked): J3/J5 recorded runs on real apps (TCC), canvas-app
pixel pointing accuracy measurement, mid-guide handoff to Do (needs Phase 7b
AgentCoordinator), inline caption controls replacing GuideControlsWindow.
