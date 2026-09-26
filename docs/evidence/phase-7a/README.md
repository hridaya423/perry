# Phase 7a evidence — tool host + agent loop core

- `swift test --package-path Packages/PerryBrain`: **140 tests, 0 failures**
  (was 122; +18: ToolHostTests 10, AgentLoopTests 8).
- App Debug build: BUILD SUCCEEDED.
- Sub-plan: `docs/plans/2026-09-26-phase-7a-tool-host.md`.

Covered by tests (megaplan §7 test list):
- schema validation rejects unknown keys / missing required / nested paths
- Talk-surface act call (`ui.click`) rejected, executor never runs
- red tier requires approver AND typed confirmation (`redConfirmed`)
- crash-between-dispatch uncertainty: app-side ActionPerformer concern (7b)
- steer/pause/interrupt/tool-call budget verified against ScriptedProvider

Remaining (7b): app executors, ActionPerformer ordering, ghost cursor, intent
cards, perry-mcp socket, coordinator collapse.
