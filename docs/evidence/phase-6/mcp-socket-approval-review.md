# Phase 6 security review: MCP socket + tool approval paths

Reviewed 2026-10-14 on the code at `64175dd` (post token-rotation) plus
`ff303e0`. Review type: code read of the admission path, request handling,
and approval presenter — not a fuzzing or dynamic-exploit pass.

## MCP Unix socket (`App/Tools/PerryMCPSocket.swift`)

- Socket file lives under Perry's support container and is chmod `0600`
  immediately after bind; verified by
  `MCPServerTests.testSocketPermissionsAreOwnerOnly`.
- Peer authentication is mandatory: `getpeereid` same-UID check on every
  connection, before any request handling. On signed builds an additional
  `LOCAL_PEERPID` → `SecCodeCopyGuestWithAttributes` check requires the
  peer to carry Perry's team identifier.
- Token handshake: clients must present the admission token on the first
  line; comparison is constant-time (`SocketAuth`). As of `64175dd` the
  token is re-minted at every socket startup/admission era instead of
  persisting across launches, and `closeAdmission` terminates existing
  clients before the next era.
- Request framing is line-delimited and capped at 1 MiB; oversized or
  malformed lines terminate the connection, not the server.
- Startup is delayed until first need and suspended during maintenance;
  `MCPSocketLifecycle` erases the token file on shutdown.

Residual (honest) gaps:

- On unsigned/dev builds the team-identifier peer check is skipped —
  same-UID + rotating token is the whole boundary there. Same-UID
  processes that can read the token file can authenticate; this is the
  documented local-trust model, not a bug, but it means dev builds are
  not hardened against other code running as the user.
- The token file remains the channel for external `perry-mcp` clients
  (Claude Code, OpenCode); env-passing exists but third-party clients
  cannot inherit it. `0600` + per-era rotation bounds exposure.

## Tool approval (`App/Tools/ToolApprovalPresenter.swift`)

- Orange-tier actions may carry a per-thread "Always allow" grant; the
  grant is scoped to thread + action signature, not global.
- Red-tier actions always require typed confirmation — the per-thread
  grant path is checked non-red before it applies.
- Unattended/background turns deny immediately when no stored grant
  exists; approval requests never block a background run.
- Decisions other than `.run`/`.stepThrough` deny.
- Approval cards can anchor to the target window frame; target summaries
  expose only whitelisted locator keys, never raw argument text.

## Diagnostics (`App/DiagnosticsReporter.swift`)

- Export contains environment/permission/runtime/count data; request
  bodies, paths, transcripts, and memory text are excluded.
- `redactedLogTail` caps the bundled codex `app-server-stderr.log` at
  ~32 KiB, drops partial first lines, masks `NSHomeDirectory()`, and
  strips bearer/API-key/token-shaped strings.
- `DiagnosticsReporterTests.testSeededSensitiveValuesNeverEnterDiagnosticsExport`
  covers the seeded-secret case.

## Conclusion

No trust bypass found in the reviewed paths. The trust boundary is
explicit and fail-closed: unsigned builds degrade to same-UID + rotating
token; unattended turns cannot silently inherit grants; red-tier always
asks a human.
