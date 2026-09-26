# Phase 1 — Codex app-server findings

- Framing: newline-delimited JSON-RPC 2.0 (no `jsonrpc` field required) over stdio.
- Schema fixture: `Packages/PerryBrain/Tests/PerryBrainTests/Fixtures/codex-app-server-schema/`
  generated with `codex app-server generate-json-schema --experimental`. The test
  `testSentMethodsExistInCommittedSchema` fails loudly if a pinned-runtime upgrade drops a
  method Perry sends.
- Dynamic tools: `ThreadStartParams.dynamicTools: [DynamicToolSpec{name, description, inputSchema, namespace?, deferLoading?}]`
  exists only in the `--experimental` schema; the client must send
  `initialize.capabilities.experimentalApi = true`. Calls arrive as server request
  `item/tool/call {threadId, turnId, callId, tool, arguments}` and are answered with
  `{contentItems: [{type: inputText|inputImage, ...}], success}`. Covered by fake-server
  scenario (c).
- Built-in tools: every capability Perry must not delegate is disabled per process with
  `--disable <feature>` (shell_tool, unified_exec, shell_snapshot, image_generation, browser_use,
  browser_use_external, computer_use, in_app_browser, apps, plugins, plugin_hooks, hooks,
  multi_agent, skill_mcp_dependency_install, workspace_dependencies, tool_suggest) plus
  `-c tools.web_search=false -c tools.view_image=false`. Threads additionally run with
  `sandbox: read-only`, `approvalPolicy: never`, an empty Perry-owned cwd, and any approval
  request the server still sends is declined.
- Models under ChatGPT auth: only `gpt-5.5` runs; tiers map to `effort: low` (fast) vs default
  (deep). `minimal` is rejected.
- Environment: the child gets an allowlisted environment with `CODEX_HOME` set to Perry's own
  support directory, never `~/.codex`.

## Bugs found and fixed while landing Phase 1

- Every HTTP provider and the Apple FM provider never finished their `AsyncThrowingStream` on
  success, so consumers hung forever. Fixed with one shared `BrainHTTP.eventStream` wrapper.
- JSON-RPC lines were dispatched on per-line `Task`s, so deltas could reorder, and the provider
  subscribed to events asynchronously after sending requests (notifications could be missed).
  Now one task dispatches lines in wire order and subscription completes before the first
  request; `CodexAccount.loginEvents()` likewise subscribes before returning.
- Pending JSON-RPC requests ignored task cancellation; they now resume with `CancellationError`.
- Test `withTimeout` used a task group, which waits for non-cancellable children, so a hang
  wedged the suite instead of failing it. It now races on a resume-once continuation.
