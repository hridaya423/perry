# Phase 7c evidence: package-level tool executors + MCP connectors

Sub-plan: `docs/plans/2026-09-26-phase-7c-executor-cores.md`
Machine: mac mini (Xcode 16.3 — package work only; app wiring is a main-machine handoff)

## Landed (PerryBrain)

- `Tools/FileTools.swift` — `WorkspaceFileBackend` protocol +
  `LocalWorkspaceFiles` (root-confined: `..`/symlink/absolute escapes
  refused; 8 MiB write cap matching `WorkspaceFileRuntime`, capped reads)
  + executors `files.list` (green, readOnly), `files.read` (green,
  readOnly), `files.write` (yellow, create-only), `files.overwrite`
  (orange, snapshots prior text into the undo payload), `files.mkdir`
  (yellow), `files.move` (yellow), `files.trash` (orange, real Trash).
  Results carry a machine-readable `undo` `{tool, arguments}` when a
  verified inverse exists.
- `Tools/MemoryTools.swift` — `memory.read` (green) / `memory.write`
  (yellow, replace|append) over `MemoryFiles`.
- `Tools/IntegrationTools.swift` — `IntegrationBackend` protocol for the
  app to wrap `RemoteIntegrations`; `integrations.list`/`integrations.read`
  (green, readOnly) / `integrations.write` (orange — also requires the op
  to be a write op and the service's `writeEnabled` flag). Inner `arguments`
  validated against the per-operation schema (outer schema passes the
  envelope through — strict validator rejects undeclared nested keys
  otherwise).
- `Tools/PerryTools.swift` — `perry.list` (green), `perry.createPerry`
  (yellow, two-word auto-name), `perry.schedule` (yellow;
  daily/interval/once/off), `perry.settings.open` (green, injected handler —
  errors cleanly when unwired).
- `Tools/ToolCatalog.swift` — `agentExecutors(...)` one-call assembly for
  the app composition root.
- `MCP/MCPConnector.swift` (Phase 9 custom connectors) — `MCPTransport`
  protocol, `StdioMCPTransport` (child process, NDJSON, id-matched
  responses, pending calls fail on exit), `MCPConnector` actor
  (initialize + notifications/initialized, paginated tools/list, tools/call
  mapping incl. base64 image parts), `makeExecutors` bridging remote tools
  as `mcp.<server>.<tool>` on `.agent` with default `.orange` tier
  (unknown-effect review) lowered to green when the server advertises
  `readOnlyHint`; `tierOverrides` for explicit policy.
- `MCPServer` additions — `resources/list`, `resources/templates/list`,
  `prompts/list` return empty lists (clients probe these; they used to get
  method-not-found), `logging/setLevel` acks, `tools/list` emits
  `annotations` (`readOnlyHint` from new `ToolSpec.readOnly`,
  `destructiveHint` = tier ≥ orange).

## Test run

`swift test --package-path Packages/PerryBrain`: **199 tests, 0 failures**
(was 166). New suites: `ToolExecutorCoreTests` (confinement incl.
`..`/absolute/symlink escapes, undo payloads, tier gating through the host,
talk-surface denial, integration read/write split + writeEnabled flag,
inner-schema validation, Perry create/schedule/settings, catalog
registration), `MCPConnectorTests` (fake-transport handshake, cursor
pagination, executor tier bridging, `StdioMCPTransport` live against
`Fixtures/fake-mcp-server.py`), plus MCPServer empty-list/annotation tests.

Other packages re-run: PerryCore 82, PerryRuntimes 187 (10 skipped),
PerryOverlay 18, PerryCapture 9 — all green. PerryGuide 268 with **1
pre-existing environment failure**:
`HardwareAndKeysTests.testKeychainRoundTrip` → `errSecInteractionNotAllowed`
(-25308), headless keychain on the mini; unrelated to this diff
(PerryGuide does not depend on PerryBrain).

## Still open (main-machine handoff)

- App executors over Cua/overlay: `screen.*`, `browser.*`, `document.read`,
  `clipboard.read`, draw tools, `ui.*`, `app.launch`.
- `AppController`: `PerryToolHost(executors: [])` → `ToolCatalog.agentExecutors`
  + app executors; `WorkspaceFileRuntime` adapter if journaled receipts are
  wanted over `LocalWorkspaceFiles`; `IntegrationBackend` adapter over
  `RemoteIntegrations`; intent-card `approve` hook (`AppMCPBridge.approve`
  still nil → orange/red fail closed, which is correct-but-unusable).
- Foreground/Background task-path consolidation + typed-plan deletion.
