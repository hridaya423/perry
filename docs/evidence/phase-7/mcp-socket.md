# Phase 7 evidence — authenticated MCP socket + perry-mcp proxy

Date: 2026-09-26 (live, main machine, Perry pid 69822)

## Setup

- `AppController` starts `PerryMCPSocket` ~1s after launch when the support dir is resolvable.
- Socket: `~/Library/Application Support/Perry/perry-mcp.sock` (`srwxr-xr-x`)
- Token: `~/Library/Application Support/Perry/perry-mcp.token` (`-rw-------`, 64-hex random per mint)

## Live transcript

Bad token → connection closed with no data (verified earlier with python client).

Real `perry-mcp` binary, stdin-fed three JSON-RPC lines:

```
{"id":1,"jsonrpc":"2.0","result":{"capabilities":{"tools":{}},"protocolVersion":"2024-11-05","serverInfo":{"name":"perry","version":"1.0"}}}
{"id":2,"jsonrpc":"2.0","result":{"tools":[]}}
{"id":3,"jsonrpc":"2.0","result":{"content":[{"text":"unknown tool: ui.click","type":"text"}],"isError":true}}
```

- `initialize` → MCP handshake (protocolVersion 2024-11-05)
- `tools/list` → `[]` — no app executors registered yet (Phase 7b follow-up)
- `tools/call ui.click` → bridged to `PerryToolHost` on `.agent` surface → `isError: true` result, not a transport error
- Perry stayed alive throughout (pid unchanged)

## Bug found + fixed during live drill

First `perry-mcp` runs were silently refused. Wire capture against a python
echo server showed the hello was `{"token":"…hex}` — missing the closing quote
(raw-string literal `#"{"token":""#` only produced the opening quote). Python
sent correct JSON so the server path was proven first; fixed the client hello
to `{"token":"\(token)"}`.

Also fixed earlier in this slice: `FileHandle` on raw sockets raises uncatchable
`NSFileHandleOperationException` — both server (`PerryMCPSocket.serve`) and
client (`perry-mcp` pump) now use raw POSIX `recv`/`send`.

## Client affordances

- `PERRY_MCP_TOKEN` env override (else reads the token file)
- `PERRY_MCP_SOCKET` env override for the socket path (used for the echo-server isolation test)
- `PERRY_MCP_DEBUG` env → stderr trace

## Not yet done

- Foreground/Background controller consolidation (typed-plan retirement)
- `files.trash` hangs with a locked display (FileManager.trashItem waits on
  session UI — Finder XPC); observed live, app survives, connection stalls

## Full catalog live (third drill, same day)

Package executor cores bound in `AppController.packageExecutors()`:
`LocalWorkspaceFiles` (root `…/Perry/workspace`, auto-created),
`MemoryFiles` (`…/Perry/memory`), `AppIntegrationBackend` (OAuth stack:
quick-action reads + typed write params + credential-layer approval records),
`PerryStore` (`…/Perry/perrys`), `AppTools` (`app.launch`, orange).

Live through the socket (pid fresh launch):

- `tools/list` → **37 tools**: draw 7 + screen 4 + ui 8 + browser 1 +
  files 7 + memory 2 + integrations 3 + perry 4 + app.launch
- `files.list` → `{"entries":[]}` (fresh workspace)
- `files.write` → `{"created":true,…,"undo":{"tool":"files.trash",…}}`
- `files.read` → round-trips the written bytes
- `files.read ../../etc/hosts` → refused: "path escapes the workspace"
- `memory.write` without `section` → schema violation (validation live)
- `integrations.list` → notion/slack/linear/google-workspace with real
  operation lists, `connected:false` (no OAuth creds — honest)
- `perry.list` → `{"perrys":[]}`
- `app.launch {}` → orange tier → intent card presented (locked display:
  card stayed pending, connection waited — fail-closed, app healthy)

## Approvals + coordination landed

- `AppMCPBridge.approve` → `ToolApprovalPresenter` → IntentCardWindow
  near cursor; orange = approve/stop, red = typed phrase (enforced by the
  card before Approve enables).
- `approve` returns `ToolApproval` (denied/approvedOnce/approvedTyped) —
  red passes only via typed answer or preflighted `redConfirmed`.
- `AgentConsentStore`: "Always allow" grants per thread (UserDefaults),
  orange only; red never auto-approves.
- `AgentCoordinator`: AgentLoop per thread (deep+tools+vision route),
  steer/pause/stop, turn persisted to ThreadStore; Home composer is the
  entry point (completer fallback on provider failure); `runningThreads`
  drives a "Perry is working" row + Send disabled.
- Ghost cursor: ui.* actuation points publish a `PerryExternalCursor`
  (green) on the overlay — the real pointer never moves.

## App executors live (second drill, same day)

`App/Tools/`: `AgentObservationStore` (per-thread element index from the last
observe), `DrawTools` (7 verbs), `ScreenTools` (observe/desktop/zoom/clipboard),
`UITools` (8 actuation tools, agent surface only), `BrowserTools`
(`browser.read`). `AppController.toolHost` is now lazy so executors bind
`workers` + `overlayState`.

Live through `perry-mcp` against the fresh app (pid 7231):

- `tools/list` → 20 tools (was `[]`)
- `clear` → `"cleared"`
- `clipboard.read` → real clipboard read
- `ui.drag` → `isError: "ui.drag needs orange confirmation"` — tier
  enforcement fails closed until intent-card approvals land
- Perry stayed alive throughout
