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

## Not yet done (Phase 7b+)

- `PerryToolHost(executors: [])` — real Screen/Draw/UI/Browser/File/Integration/Memory/Perry executors
- `AgentCoordinator`, intent-card approval wiring (`AppMCPBridge.approve`)
- Foreground/Background controller consolidation
