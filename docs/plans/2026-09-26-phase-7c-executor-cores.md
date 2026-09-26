# Phase 7c: package-level tool executors + MCP connectors (PerryBrain, headless)

Master plan §6.2 tool catalog (`files.*`, `integrations.*`, `memory.*`,
`perry.*`) and §7 Phase 9 "custom MCP connectors". App-side executors that
need the overlay or Cua driver (screen/draw/ui/browser), `AgentCoordinator`,
and intent-card wiring stay on the main machine — this slice delivers every
executor whose core is pure file/memory/integration/agent state, plus the
schemas and trust tiers the host enforces.

All code in `Packages/PerryBrain/Sources/PerryBrain/Tools/` and `MCP/`.
Tests in `Tests/PerryBrainTests/`. No new deps.

## `ToolSpec.readOnly` (ModelTypes.swift)

Add `readOnly: Bool = false`. Feeds MCP `tools/list` `annotations`
(`readOnlyHint`, `destructiveHint = tier >= .orange`).

## `Tools/FileTools.swift`

`WorkspaceFileBackend` protocol — relative-path file ops inside a workspace
root: `list`, `read` (text + byteCount + truncated), `write` (create-only),
`overwrite` (returns previous text when snapshot-able), `makeDirectory`,
`move`, `trash` (returns trashed-entry URL string).

`LocalWorkspaceFiles` — concrete backend. Root resolved once at init;
every op resolves `..`/symlinks and refuses paths that escape the root.
Write contents capped at 8 MiB (matches `WorkspaceFileRuntime`), reads cap
at `maxBytes` param ≤ 8 MiB.

Executors (surfaces `[.agent]` only — ToolGate already denies everything
outside observe/draw on talk/guide):

| tool | tier | notes |
|---|---|---|
| `files.list` | green, readOnly | `{path?}` → entries |
| `files.read` | green, readOnly | `{path, maxBytes?}` → text |
| `files.write` | yellow | `{path, contents}` create-only; undo = trash |
| `files.overwrite` | orange | `{path, contents}`; undo = restore snapshot |
| `files.mkdir` | yellow | `{path}` intermediate dirs; undo = trash |
| `files.move` | yellow | `{source, destination}`; undo = move back |
| `files.trash` | orange | `{path}` real Trash (undo via app engine) |

Results are JSON text including an `undo` object `{tool, arguments}` when a
simple verified inverse exists.

## `Tools/MemoryTools.swift`

Over `MemoryFiles`: `memory.read` (green, readOnly; `{section?}`) and
`memory.write` (yellow; `{section, text, mode?}` replace|append).

## `Tools/IntegrationTools.swift`

`IntegrationBackend` protocol (app wraps `RemoteIntegrations`):
`services() -> [IntegrationService]` where each service lists
`IntegrationOperation`s (name, description, isWrite, inputSchema), and
`perform(service:operation:arguments:) -> JSONValue`.

Executors: `integrations.list` (green), `integrations.read` (green,
readOnly — refuses write ops), `integrations.write` (orange — requires
`isWrite` op AND `service.writeEnabled`; inner args validated against the
op's schema).

## `Tools/PerryTools.swift`

Over `PerryStore`: `perry.list` (green), `perry.createPerry`
(yellow; `{job, name?, folderPath?}`, auto two-word name), `perry.schedule`
(yellow; `{perry, kind: daily|interval|once|off, hour?, minute?, seconds?,
at?}`), `perry.settings.open` (green; `{page?}` enum of the Home settings
pages, injected `openSettings` handler since UI is app-side).

## `Tools/ToolCatalog.swift`

`static func agentExecutors(...) -> [any ToolExecutor]` — one-call wiring
for the app composition root.

## `MCP/MCPConnector.swift` (Phase 9 custom connectors)

- `MCPTransport` protocol: `request(method:params:) -> JSONValue`,
  `notify(method:params:)`, `close()`.
- `StdioMCPTransport`: launches a user-supplied command, NDJSON over pipes,
  id-matched responses, pending calls failed on exit.
- `MCPConnector` actor: `initialize` (+ `notifications/initialized`),
  `listTools` with cursor pagination, `callTool` → `ToolResult` content
  (text + base64 image parts).
- `makeExecutors(prefix:tierOverrides:)`: each remote tool becomes
  `mcp.<server>.<tool>` on the `.agent` surface. Default tier `.orange`
  (unknown effect); `readOnlyHint` annotation or an explicit override
  lowers to green / sets `readOnly`.

## `MCPServer.swift` additions

`resources/list` → `{resources:[]}`, `resources/templates/list` →
`{resourceTemplates:[]}`, `prompts/list` → `{prompts:[]}`,
`logging/setLevel` → `{}` (clients probe these; today they get
method-not-found noise). `tools/list` emits `annotations`.

## Tests

- `ToolExecutorCoreTests.swift`: confinement (`..`, symlink escape,
  absolute path), list/read/write/overwrite/move/mkdir/trash happy paths,
  undo payloads, tiers enforced through `PerryToolHost` (trash/write denied
  without approver, files.* denied on `.talk`), memory round-trip,
  integration read/write gating + inner schema validation, Perry
  create/list/schedule/settings.
- `MCPConnectorTests.swift`: fake transport handshake, paginated
  tools/list, executor bridging + orange-tier approval gate, image part
  mapping; `StdioMCPTransport` against `Fixtures/fake-mcp-server.py`
  (`/usr/bin/python3`, same pattern as the Codex fixture).
- `MCPServerTests.swift`: new empty-list methods, annotations, setLevel.

## Verify

`swift test --package-path Packages/PerryBrain` green; other package
suites unaffected; `git diff --check` clean.
