# Perry providers and runtimes audit

Date: 2026-10-24. Scope: read-only. Perry tree read as-is (large uncommitted changes, branch `codex/living-ink-redesign`). T3 Code cloned shallow at `/tmp/perry-audit/t3code` (commit `d53873b`, MIT). Nothing in the Perry repo was edited, built, or run.

Tags: **[V]** verified in code, docs, or by running a read-only command. **[I]** inferred.

---

## Bottom line

1. The user is half right. Perry has **one agent runtime in the strict sense**: its own `AgentLoop`. It drives any `ModelProvider` and gives the model Perry's own tools. The **only external agent process Perry runs is bundled Codex**. It runs in two roles. As a "model" it runs read-only through `app-server` (`CodexAppServerProvider`). As a coding task it runs `codex exec` (`CodexRuntime.runCodingTask`).
2. Perry is **not** Codex-only on the model side. It implements 6 model providers: Codex, OpenAI Responses, Anthropic, Gemini, an OpenAI-compatible adapter (OpenRouter, custom, local), and Apple Foundation Models. A user can reach OpenAI, Anthropic, Gemini, OpenRouter, any custom OpenAI-compatible endpoint, Ollama, and LM Studio. Only one BYOK provider can be active at a time.
3. Claude Code and OpenCode are **detect-and-authenticate-only rows in Settings**. Nothing launches them for a task. Docs say otherwise (see Surprises).
4. There is **no ACP code at all** (`grep` for ACP, Agent Client Protocol, gemini-cli, cursor-agent: zero hits).
5. T3 Code has the agent-runtime half (Codex, Claude, ACP registry, Cursor, OpenCode, Pi, and more). It has **no BYOK model layer**. For (b) Perry already has more than T3 does.

---

## Part 1: Perry today

### 1.1 Inventory

| Thing | State | Evidence |
|---|---|---|
| Perry `AgentLoop` (stream, tool calls, host, results, loop; budgets 60 calls / 20 min; steer, pause, interrupt) | Implemented, **exposed** (Talk, Do, background tasks) | `Packages/PerryBrain/Sources/PerryBrain/Tools/AgentLoop.swift:19-60`; constructed at `App/Tools/AgentCoordinator.swift:278` |
| `ModelProvider` protocol + `ModelEvent` stream (`textDelta`, `toolCall`, `usage`, `done`) | Implemented | `.../PerryBrain/ModelTypes.swift:118-149` |
| `ToolExecutingModelProvider` (provider runs the loop and calls back for tools) | Implemented, only Codex uses it | `ModelTypes.swift:153`; `AgentLoop.swift:149-151` |
| Codex via `codex app-server` (JSON-RPC over stdio) as a **brain** | Implemented, **exposed** ("ChatGPT" choice, in-app ChatGPT sign-in) | `.../Codex/CodexAppServerProvider.swift:21`; `App/Brain/BrainController.swift:498-508` |
| Codex confinement: `approvalPolicy: never`, `sandbox: read-only`, `shell_tool`, `unified_exec`, `computer_use`, `browser_use`, `plugins`, `hooks`, `multi_agent`, `web_search` all disabled; Perry tools injected as `dynamicTools` | Implemented | `CodexAppServerProvider.swift:228-246, 291-296`; `CodexAppServerProcess.swift:36-60` |
| Codex `app-server` process: spawn, `initialize`, restart budget (3 per 60 s, backoff), env filter, private `CODEX_HOME` | Implemented | `CodexAppServerProcess.swift:63-275` |
| Codex account: `account/read`, `login/start`, `login/cancel`, `logout`, `rateLimits/read` | Implemented, exposed | `.../Codex/CodexAccount.swift:27-96` |
| Codex as a **coding agent** (`codex exec --json -s workspace-write --ephemeral`) | Implemented; reachable only through the typed-plan `.shell(.codingTask)` step, and only for `runtimeID == "cli.codex"` | `PerryRuntimes/CodexRuntime.swift:90-98`; `App/ForegroundTaskController.swift:797-807`; `App/TypedActionRouter.swift:50-57` |
| Claude Code: locate, `auth status`, sha/identity check | Detect and auth status **only**. No code starts a Claude task. `CLIRuntime.invoke` (`CLIRuntime.swift:111`) has no non-test caller | `PerryRuntimes/CLIRuntime.swift:56-144`; `App/RuntimeInventory.swift:203-211` |
| OpenCode: locate, `auth list`, **pinned to 1.18.32 + exact SHA-256** | Detect and auth status only. Any other OpenCode build is rejected as "does not match Perry's pinned release". The ACP registry lists OpenCode 1.19.4 and opencode-v2 2.1.4 [V], so a current install is rejected | `PerryRuntimes/OpenCodeRuntime.swift:5-6`; `App/RuntimeExecutableVerifier.swift:73-92` |
| ACP (any agent) | **Absent** | zero grep hits |
| OpenAI Responses (`v1/responses`, Bearer) | Implemented, exposed | `Providers/OpenAIResponsesProvider.swift:129-134` |
| Anthropic Messages (`v1/messages`, `x-api-key`, `anthropic-version 2023-06-01`) | Implemented, exposed | `Providers/AnthropicMessagesProvider.swift:136-142` |
| Gemini (`v1beta/models/{m}:streamGenerateContent`, `x-goog-api-key`) | Implemented, exposed | `Providers/GeminiProvider.swift:101-112` |
| OpenAI-compatible chat (`v1/chat/completions`, Bearer optional) | Implemented, exposed. Serves OpenRouter, "custom", and local | `Providers/OpenAIChatCompatibleProvider.swift:131-134` |
| Apple Foundation Models (macOS 26+) | Implemented, exposed (on-device route) | `Providers/AppleFoundationModelProvider.swift`; `BrainController.swift:166-172` |
| Local discovery: Ollama `127.0.0.1:11434/api/tags`, LM Studio `127.0.0.1:1234/v1/models`; context window via `api/ps` or `api/v1/models` | Implemented, exposed | `Router/LocalServerDiscovery.swift:39-100` |
| llama.cpp, vLLM, MLX, Jan, other local servers | **Absent** from discovery. Reachable only by typing a loopback URL into "Custom" | `NetworkEndpointPolicy.swift:33-39` allows loopback http |
| Capability probe (text echo, image digit read, tool round trip, 60 s timeout each) | Implemented, exposed **for local models only** ("Check" button). Not run for cloud BYOK | `Router/ModelCapabilityProbe.swift:32-70`; `BrainController.swift:113-146` |
| `ProviderRouter` (preference order, capability filter, 2 failures then 60 s unhealthy, health-reporting wrapper) | Implemented | `Router/ProviderRouter.swift:20-186` |
| Perry as MCP **server**: `perry-mcp` stdio proxy to a token-guarded Unix socket; `PerryMCPSocket` serves `PerryToolHost` on the `.agent` surface | Implemented, socket starts with the app. **Nothing in Perry launches an agent with it.** No writer of `--mcp-config`, `mcpServers`, or `opencode.json`. `perry-mcp` is not in `project.yml` (not bundled) | `App/Tools/PerryMCPSocket.swift`; `Packages/PerryBrain/Sources/perry-mcp/main.swift`; `App/AppSubsystems.swift:90`; grep of `project.yml` |
| Perry as MCP **client** (user-added connectors) | Implemented. Unrelated to hosting agents | `PerryBrain/MCP/MCPConnector.swift`; `App/CustomConnectors.swift` |
| Dictation cleanup via LLM | **Absent**. `DictationController.swift` has no provider or brain reference (grep). Dictation is on-device speech only | grep |
| Realtime voice BYOK (OpenAI GA/beta or "compatible" WebSocket) | Implemented, separate key and path | `App/RealtimeVoiceSession.swift:6-17, 1021-1028`; `VoiceController.swift:64` |

### 1.2 Which feature uses which path [V]

| Feature | Path |
|---|---|
| Talk / Ask / spatial answers | `TalkSession` runs `AgentCoordinator`. It uses `app.brain.route(requirement).provider` (`AppSubsystems.swift:480-483`), then `AgentLoop`. Tools come from the `.talk` surface (observe and draw only: `Talk/ToolSurface.swift:19-25`). |
| Do-mode / background tasks | Same `AgentCoordinator` and `AgentLoop`, `.agent` surface (all tools). Approval goes through `ToolApprovalPresenter` via `ToolContext.approve`. The loop runs inside `workerLease.withRun` when the model has `.tools`. |
| Guide | `BrainController.makeGuidePlanner` (`BrainController.swift:283-325`). It routes to `vision+streaming`, deep tier, JSON only, no tools. |
| Routine naming | `brain.completeText` (`AppSubsystems.swift:579-581`; `BrainController.swift:263`), fast tier. |
| Suggestions | `brain.route(vision+streaming, fast)` (`AppSubsystems.swift:259`). |
| Typed-plan "delegate" step | `CodexRuntime.runCodingTask`, Codex only. |
| Dictation | No model. |

Routing: `BrainController.ModelChoice` has three values: `chatGPT`, `direct`, `local` (`BrainController.swift:11-21`). `route()` pins the provider by choice (`:238-259`). `chatGPT` pins `.codex`. `direct` pins one provider chosen by the endpoint host, or `"custom"`. `local` requires `.local` capability. **There is no per-feature model choice and no fallback across choices. A failed capability check stops the request on purpose.**

### 1.3 How keys, endpoints, and models are stored [V]

- Keys live in Keychain, service `dev.perry.keys`, via `KeychainStore` (`PerryGuide/HardwareAndKeys.swift:5-60`).
- Settings writes **one** account, `byok.vision` (`RuntimeCatalog.swift:12`; `SettingsView.swift:639`).
- Endpoint URL and model ID are plain UserDefaults: `perry.byok.vision.endpoint` and `perry.byok.vision.model` (`PerryPreferences.swift:58-59`).
- `BrainController.keychainAccount(for:)` reads `brain.<provider>` (`BrainController.swift:91, 487`). **Nothing writes those accounts.** The per-provider key slots are dead code and the legacy `byok.vision` fallback is the only live path.
- Consequence: one endpoint, one model string, one key. The model string is used for both fast and deep tiers (`BrainController.swift:442-445`). There is no model list, no model picker, no second provider, and no switching without re-entering a key.
- Built-in model defaults per provider are hardcoded (`BrainModelDefaults.swift:20-28`: `gpt-5-mini/gpt-5`, `claude-haiku-4-5/claude-sonnet-4-5`, `gemini-2.5-flash/pro`, ...). They apply only if the user's endpoint matches no entered model.
- The Settings picker offers: OpenAI, Anthropic, Gemini, OpenRouter, Custom OpenAI-compatible (`SettingsView.swift:960-1003`). `DirectAIProvider` has the same four named cases (`PerryRuntimes/DirectAIProvider.swift:4-39`).
- The chat adapter appends `v1/chat/completions` unconditionally to the base URL (`OpenAIChatCompatibleProvider.swift:131`). Presets whose documented base already ends in `/v1` (Mistral, Together, DeepSeek variants, Ollama's `/v1`) produce `/v1/v1/...` unless the user trims the URL. [I: exact vendor base URLs vary and need checking per vendor.]
- Custom provider capabilities are hardcoded `[.vision, .tools, .streaming]` with no probe (`BrainController.swift:462-466`). A text-only model will fail at runtime.
- `NetworkEndpointPolicy`: https anywhere, http only for loopback (`PerryCore/NetworkEndpointPolicy.swift:33-39`). A LAN Ollama box over http is blocked.

### 1.4 How each runtime gets Perry's computer-use tools [V]

| Runtime | Mechanism |
|---|---|
| Perry `AgentLoop` + any BYOK or local model | Tool specs are sent as native function calling. The loop executes each `ToolCall` through `PerryToolHost` (`AgentLoop.swift:149-205`). |
| Codex app-server | `dynamicTools` in `thread/start` (names mangled `perry_<i>_<name>`). Codex asks Perry to run each (`item/tool/call`). Perry runs it through the same `executeTool` handler (`CodexAppServerProvider.swift:235-245`). **Not via MCP.** |
| Codex `exec` (coding task) | No Perry tools. Sandboxed to a workspace directory. |
| Claude Code, OpenCode | Never launched. The only designed route is `perry-mcp` over the Unix socket (docs say so). No code registers it with either tool, and the binary is not bundled. |
| ACP agents | Not implemented. |

### 1.5 What is missing or half-wired

1. Only one BYOK profile. The per-provider Keychain design exists in `BrainController` but has no writer.
2. No model catalog. No `GET /v1/models`, no model picker, no per-model options (reasoning effort is hardcoded: `effort: none` for the fast tier, `CodexAppServerProvider.swift:300`).
3. Missing provider presets: xAI, Groq, Mistral, DeepSeek, Together, Fireworks, Cerebras, Azure OpenAI, Bedrock, Vertex. Most are OpenAI-compatible, so they are reachable via "Custom" with manual URL entry (subject to the `/v1` caveat).
4. Local: only Ollama and LM Studio are discovered. Custom loopback endpoints skip the capability probe.
5. Claude Code and OpenCode rows promise something the app does not do (see Surprises).
6. `perry-mcp` is not packaged in the app bundle.
7. `runtimes.choices` (the "Automatic / cli.* / direct.*" list) is not a selector. Its only consumer is a warning banner (`SessionPanelView.swift:161`).
8. Codex-as-agent is wired to one step type and one runtime ID. `defaultConfinementArguments` disable every agent capability on the `app-server` path.
9. Not sandboxed (`Perry.entitlements` has only Apple Events and audio input), so Perry can spawn external CLIs and read their config dirs. [V]

### 1.6 Surprises (evidence, not workaround)

- **Docs contradict code.** `docs/capabilities.md` says "Open-ended work requires a signed-in agent runtime (Claude Code / OpenCode / bundled Codex)". `PRD.md:57-67` describes a "Capability ladder" where Claude and OpenCode plan after verification and "Routing uses the task's required capabilities". The code comment at `RuntimeInventory.swift:8-11` and `RuntimeStatus.swift:1-6` says the provider registry and routing "was deleted with typed planning: nothing routes through providers anymore". Commit `24b57c3` ("Collapse the typed-planner runtime stack into agent runs + setup inspection") did that.
- `PerryRuntimes/AgentRuntime.swift` is **not** a runtime protocol. It holds `ActionExecutionResult` and the `ExecutableActionExecutor` protocol. The name `AgentRuntime` is taken, so the new seam needs another name.
- `RuntimeSettingsState` shows "Looking for agent runtimes…" (`RuntimeSettingsState.swift:11`), but only three CLIs are ever probed (`RuntimeInventory.swift:180-221`).

---

## Part 2: T3 Code's provider architecture

Repo: `/tmp/perry-audit/t3code`, TypeScript, Effect, pnpm monorepo. License **MIT, Copyright 2026 T3 Tools Inc** (`LICENSE`). Contributing guide says outside PRs are not sought.

### 2.1 Shape [V]

| Concept | Where | What it is |
|---|---|---|
| **Driver kind** | `packages/contracts/src/providerInstance.ts:15-20` | Slug string, branded (`codex`, `claudeAgent`, `cursor`, `grok`, `opencode`, `pi`, `muse`, `antigravity`, `acpRegistry`). Built-ins listed at `apps/server/src/provider/builtInDrivers.ts:36-46`. |
| **Provider instance** | `providerInstance.ts:22-27, 46-62` | `{instanceId, driver, displayName, enabled, environment[], config}`. Many instances of one driver are allowed (`supportsMultipleInstances`). Driver config is `Schema.Unknown` and decoded by each driver. Unknown drivers round-trip untouched. |
| **Driver** | `packages/provider-core/src/server/driver.ts:92-117` | `{driverKind, metadata, configSchema, defaultConfig, create(input) → ProviderInstance}`. Failures become "unavailable shadow snapshots". Drivers must not throw. |
| **ProviderInstance** | `driver.ts:48-90` | `{snapshot (health), refreshModels, orchestrationAdapter, textGeneration, auth?, acpSessionManagement?}` |
| **Adapter** | `packages/provider-core/src/server/ProviderAdapter.ts:647-664` | `getCapabilities()`, `planSelectionTransition()`, `openSession()`. A session exposes `ensureThread`, `resumeThread`, `startTurn`, `steerTurn`, `interruptTurn`, `respondToRuntimeRequest`, `readThreadSnapshot`, `rollbackThread`, `forkThread`, and an event stream. |
| **Normalized events** | `ProviderAdapter.ts:90-152` | One union: `provider_session.updated`, `provider_turn.updated`, `node.updated`, `message.updated`, `turn_item.updated`, `command_output.delta`, `runtime_request.updated`, `plan.updated`, `turn.terminal`. |
| **ModelSelection** | `packages/contracts/src/modelSelection.ts:6-10` | `{instanceId, model, options[]}` everywhere. |
| **Model catalog and options** | `packages/contracts/src/model.ts:7-103`; `provider-core/.../ModelCatalog.ts`; `apps/server/src/provider/ClaudeModelCatalog.ts`, `ModelManifest.ts`, `docs/internals/model-manifest.md` | Per-model `optionDescriptors` of type `select` or `boolean`. A bundled manifest is refreshed in the background. Users can add custom models. |
| **Runtime modes** | `packages/contracts/src/providerPolicy.ts:25-31` | `approval-required`, `auto-accept-edits`, `auto`, `full-access`, plus `interactionMode` `default` / `plan`. Per driver, only modes the agent enforces natively are offered (`docs/internals/adding-a-provider.md`). |
| **Approvals** | `providerPolicy.ts:52-73`; `OrchestrationV2RuntimeRequest` at `orchestrationV2.ts:1035` | Kinds: command, file-read, file-change, mcp-elicitation, permission, dynamic_tool_call, user_input, auth_refresh. Decisions: accept, acceptForSession, acceptAlways, decline, cancel. |
| **Capability flags** | `orchestrationV2.ts:329-346` | sessions, threads, turns, streaming, tools, approvals, planning, subagents, context, checkpointing, identity, runtimePolicy. UI branches on capabilities, never on driver kind. |
| **Health snapshot** | `contracts/src/server.ts:217-257`; `provider-core/.../snapshot.ts`; `snapshotProbe.ts`; `managedProvider.ts` | `ServerProvider`: installed, version, auth, models, `setup{canAuthenticate, canInstall}`, `supportedRuntimeModes`, `nativeSessions`, usage limits. It is cached with a change stream and a fresh-refresh option. Docs rule: background status checks must not open a session that can start MCP, run hooks, or launch a login. |
| **Credentials** | `apps/server/src/provider/ProviderCredentialStore.ts` | Per `(driver, bindingId)`, hashed key name in a server secret store. The doc rule is to strip ambient credentials the instance did not configure. |
| **Text generation** | `provider-core/.../textGeneration.ts` | Each instance also supplies commit / PR / title generation, so a "provider" is also a small model endpoint. |

### 2.2 How each runtime is wrapped [V]

- **Codex.** Spawns `codex app-server` and talks JSON-RPC over stdio through `packages/effect-codex-app-server`. The schema client is **generated** from the upstream `codex-rs/app-server-protocol` at a pinned git ref (`scripts/generate.ts`). Adapter: `apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts`. T3's MCP server is injected per thread as `config["mcp_servers.t3-code"] = {url, http_headers.Authorization, tool_timeout_sec}` (`CodexAdapterV2.ts:1380-1386`). A "managed" setup mode manages a private `CODEX_HOME` and ChatGPT auth (`CodexManagedRuntime.ts`, `CodexChatGptAuth.ts`).
- **Claude.** Uses `@anthropic-ai/claude-agent-sdk ^0.3.276` (`apps/server/package.json:35`) **inside its Node server**. It calls `query({prompt: AsyncIterable<SDKUserMessage>, options})` with `permissionMode`, `canUseTool`, `includePartialMessages`, `resume`, `pathToClaudeCodeExecutable` (user's installed `claude`), and `spawnClaudeCodeProcess` (process-group control). MCP servers go over the CLI's stdin control channel via `queryRuntime.setMcpServers()`, deliberately not `--mcp-config` argv, so credentials stay out of `ps` (`ClaudeAdapterV2.ts:923-985`). Runtime mode maps to Claude `permissionMode` in `permissionModeForClaudeRuntimePolicy` (`:2048-2090`). Binary path and `CLAUDE_CONFIG_DIR` are per-instance settings (`contracts/src/settings.ts:673-742`).
- **ACP.** First-class. `packages/effect-acp` is a generated client for the ACP schema (v1 and v2 preview). `packages/provider-acp` is the shared adapter (`adapter.ts` 8.5k lines; `AcpSessionRuntime.ts`: `initialize` with `protocolVersion`, `clientCapabilities`, `authenticate`, `newSession` / `loadSession`, `mcpServers` in session setup, optional MCP-over-ACP bridge). `clientPolicy.ts` decides allow / ask / deny for agent file and terminal requests from the runtime mode and cwd. `clientTerminals.ts` implements the agent-to-client terminal methods.
- **ACP registry.** `packages/provider-acp-registry`. Fetches `https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json` (`AcpRegistrySupport.ts:50`). Each agent is `binary` (per-platform, sha256 or registry integrity), `npx` (exact version required), or `uvx` (exact version). It installs into per-agent roots and offers a **"Local ACP command"** escape hatch (`docs/user/providers-acp.md`). Per-agent quirks live in small flavor files (`claudeAcp.ts`, `devinAcp.ts`, `copilotAcp.ts`, `droidAcp.ts`). The rule is "never add agent-id checks to the generic adapter" (`docs/internals/adding-a-provider.md`).
- **Others.** Cursor via `CursorAgentSdk` and API key, plus keychain (`provider-cursor`). OpenCode by spawning `opencode serve` and using an HTTP+SSE client with a server password (`provider-opencode/.../OpenCodeRuntime.ts`; minimum version check). Pi via its own RPC (`provider-pi/.../rpc.ts`) with an injected MCP extension. Grok is ACP plus an xAI extension. Muse and Antigravity are custom SDK or ACP drivers.
- **Testing.** Record real provider transcripts to NDJSON and replay them through the real orchestrator (`apps/server/scripts/record-*-replay-fixture.ts`; `packages/provider-testing`).

### 2.3 What T3 does not have [V, by file listing and grep]

- **No BYOK model-provider layer.** No OpenAI-compatible, Anthropic-API, Gemini-API, Ollama, or LM Studio client. Grep for `chat/completions` or vendor API hosts in non-test source matches only auth and usage files (Codex ChatGPT auth, Claude reset credits). Models, keys, and local servers are the agent's problem: OpenCode and Pi route models themselves, Cursor uses its own key.
- No loop of its own. All loops belong to the agents.
- No cross-agent model routing or failover.
- No native Claude via ACP-free direct stream-json. It uses the SDK.

T3 matches the user's list (a). It does not help with list (b).

---

## Part 3: Recommendation for Perry

### 3.1 Two seams, not one

Perry needs two different seams. The audit shows they are different things.

- **`ModelProvider`** (exists). One request in, a stream of `ModelEvent` out. Perry owns the loop, the tools, and the approvals. Every BYOK and local model goes here.
- **`AgentBackend`** (new). A harness owns the loop and its own tools: Codex, Claude Code, ACP agents. Perry gives it a goal, context, and a tool endpoint. It gets events and approval requests back.

Name note: `AgentRuntime.swift` already exists in `PerryRuntimes` for an unrelated protocol, so use `AgentBackend`.

Sketch, kept small on purpose [I]:

```swift
public struct BackendInstance: Codable, Sendable, Identifiable {
    public let id: String                 // "codex", "claude", "acp.gemini", "acp.local.dsh"
    public var kind: Kind                 // .codex, .claudeCode, .acp(agentID: String?), .modelLoop
    public var executable: URL?           // user override
    public var environment: [String: String]
    public var enabled: Bool
}

public struct BackendHealth: Sendable {   // cheap probe, never opens a session
    var installed: Bool; var version: String?
    var auth: RuntimeAuthenticationStatus // type already exists in RuntimeStatus.swift
    var models: [BackendModel]            // slug, name, options: [select|boolean descriptors]
    var modes: Set<ApprovalMode>          // only what the agent enforces natively
    var caps: BackendCapabilities         // steer, resume, plan, mcpStdio, images
}

public protocol AgentBackend: Sendable {
    func probe() async -> BackendHealth
    func start(_ task: AgentTask) async throws -> any AgentRun
}
public protocol AgentRun: Sendable {
    var events: AsyncThrowingStream<AgentLoopEvent, Error> { get }  // reuse the existing enum
    func respond(to approval: ApprovalID, _ decision: ApprovalDecision) async
    func steer(_ text: String) async throws
    func interrupt() async
}
```

Reuse `AgentLoopEvent` (`AgentLoop.swift:8-15`: `textDelta`, `toolCallStarted`, `toolCallFinished`, `note`, `finished`) so `AgentCoordinator`, the transcript store, and the UI do not change. Add only `thought`, `plan`, and `usage` if needed. The existing model-driven path becomes the backend of kind `.modelLoop` (wrap `AgentLoop` + `ModelProvider`) so there is one entry point. [I]

**Safety stance, from Perry's PRD and today's Codex confinement.** Keep "Perry tools only" as the default for every external backend:
- Codex: keep the `--disable shell_tool` set (already there).
- Claude Code: `--permission-mode dontAsk` with allow-list `mcp__perry__*` only.
- ACP: advertise `fs` and `terminal` client capabilities as **false**, and deny `session/request_permission` for anything that is not a Perry tool.
- Offer a separate, explicit "coding" mode (workspace-write, approvals bridged to Perry's intent cards) for the existing delegate case.

This keeps Perry's trust tiers meaningful. An unconfined external agent bypasses them.

### 3.2 Hosting the Claude Agent SDK from Swift

| Option | How | Pros | Cons |
|---|---|---|---|
| **A. Claude Code CLI, stream-json, direct from Swift** | `claude -p --input-format stream-json --output-format stream-json --include-partial-messages --permission-mode <m> --permission-prompts host --mcp-config <json> --resume <id>`. Flags confirmed on installed Claude Code 2.1.309 [V]. Permission prompts and control messages ride the same stdio stream. | No Node, no bundle, no new dependency. Reuses `Process` + a line reader. Perry already verifies the exact `claude` binary (`RuntimeExecutableVerifier.claude`). User's own login and subscription. | The control-message shapes (permission request, interrupt, set-MCP) are defined by the SDK, not by public docs. [I] Wire changes can break Perry. Needs fixture tests against recorded transcripts. |
| **B. Bundled Node sidecar running `@anthropic-ai/claude-agent-sdk`** | What T3 does, but in a Perry-shipped Node. | Official API surface; SDK tracks the protocol. | Ship Node (+SDK) in a Swift app; second runtime to sign, notarize, update, and audit. The SDK is under Anthropic's commercial terms, not an OSS license [I]; redistribution needs review. Heavy for one backend. |
| **C. `claude-acp` (ACP adapter around the SDK)** | Registry id `claude-acp` 0.95.0, npx [V]. Perry talks ACP. | Zero Claude-specific Swift code once ACP exists. | Needs Node on the user's machine (`npx`). Proprietary package. Adds a hop. |
| D. Python SDK sidecar | — | — | Worse than B. |

**Recommend A for Claude, ACP for everything else.** A keeps Perry dependency-free and consistent with how it already treats Codex. Treat the stream-json handler as a thin, fixture-tested adapter, and run T3's replay-fixture approach against it. Offer C as a fallback if the control protocol churns. B is not worth it for one backend.

### 3.3 ACP over stdio: reuse `JSONRPCConnection` [V code, I wire details]

`PerryBrain/Codex/JSONRPCConnection.swift` already fits ACP well:
- newline-delimited JSON over a `FileHandle` pair (`:84-107`), the same framing ACP uses over stdio
- ordered dispatch of responses and notifications (`:109-123`)
- **incoming requests** are surfaced (`.incomingRequest`, `:116-117`) and answerable with `respond` / `respondError`. ACP's `session/request_permission`, `fs/*`, and `terminal/*` are exactly agent-to-client requests.
- cancellation-safe `request` (`:149-174`), close handling

Gaps to close (all small):
1. It writes `{"id","method","params"}` with **no `"jsonrpc":"2.0"`** (`:161-165`). Codex tolerates this; ACP agents may reject it. [I] Add an init flag to include the tag.
2. Move it out of the `Codex/` folder (it is generic). It also lacks per-request timeouts.
3. Write ~10 ACP messages by hand over `JSONValue` instead of generating a schema: `initialize` (protocolVersion 1, `clientCapabilities`), `authenticate`, `session/new` (cwd, `mcpServers`), `session/prompt`, `session/cancel`, `session/update` notifications (message chunks, thought chunks, tool_call, tool_call_update, plan), `session/request_permission` response. T3 targets ACP v2 preview with v1 fallback (`docs/user/providers-acp.md`); target stable v1 first. [I: confirm against the ACP spec before building.]
4. `CodexAppServerProcess` (process, restart budget, capped stderr log, env filter) generalizes into a `StdioAgentProcess`. Reuse, do not rewrite.

`perry-mcp` is already a stdio MCP server, which ACP's `session/new.mcpServers` accepts as `{name, command, args, env}` for any agent (stdio MCP is baseline in ACP [I]). It, Claude (`--mcp-config`), and Codex (`-c mcp_servers.perry={command=...}` [I]) can all point at the **same** binary and socket. Required first: bundle `perry-mcp` in the app (it is not in `project.yml`), and check that the socket handshake token reaches the child process safely (T3 hardened the equivalent in `ClaudeAdapterV2.ts:923`).

### 3.4 `ModelProvider` for BYOK: three adapters plus a preset table

Perry already has all three wire adapters. The missing piece is data, not code.

```swift
struct ProviderPreset: Codable, Sendable, Identifiable {
    let id: String               // "groq"
    let name: String
    let wire: Wire               // .openAIChat, .openAIResponses, .anthropic, .gemini
    let baseURL: URL
    let chatPath: String         // "v1/chat/completions" | "openai/v1/chat/completions" | ...
    let modelsPath: String?      // GET to list models; nil = manual ID only
    let auth: Auth               // .bearer, .header("x-api-key"), .none
    let extraHeaders: [String:String]
    let keyRequired: Bool
    let defaults: BrainModelDefaults?   // fast / deep suggestions
    let tools: Bool?; let vision: Bool? // static hint; confirmed by probe
}
```

Collapse table [I: URLs and quirks need per-vendor verification before shipping]:

| Group | Presets | Wire |
|---|---|---|
| OpenAI-compatible chat | OpenRouter, Groq, Mistral, DeepSeek, Together, Fireworks, xAI, Cerebras, Perplexity, Azure OpenAI (v1 API path), Bedrock (its OpenAI-compatible endpoint), custom | `OpenAIChatCompatibleProvider` (exists) |
| OpenAI | OpenAI | `OpenAIResponsesProvider` (exists) |
| Anthropic | Anthropic (also reachable through OpenAI-compat on some gateways) | `AnthropicMessagesProvider` (exists) |
| Gemini | Google AI Studio | `GeminiProvider` (exists) |
| Local, OpenAI-compatible | Ollama `:11434`, LM Studio `:1234`, llama.cpp server `:8080`, vLLM `:8000`, MLX `mlx_lm.server`, Jan | `OpenAIChatCompatibleProvider` + `LocalServerDiscovery` extended to probe `GET /v1/models` on known ports |
| Hard cases | Vertex AI (OAuth/ADC), native Bedrock (SigV4) | Skip; reach via OpenRouter or a gateway until demand is proven |

Also: persist a list of **profiles** `(presetID, keyAccount, model, options)` instead of one endpoint, with Keychain account `brain.<profileID>` (the unused design in `BrainController.swift:91` already points there). Add `GET <modelsPath>` for the picker, and run `ModelCapabilityProbe` (exists) for every profile, caching `(profile, model) → capabilities`. This replaces the hardcoded `[.vision,.tools,.streaming]`. Selection becomes one value `ModelSelection(profileID, model, options)`, as in T3 (`modelSelection.ts`), instead of the three-way `ModelChoice`.

Keep the existing router rule that Perry never silently falls back to another provider.

### 3.5 What to steal from T3 (concepts only)

1. **Kind vs instance split**, with per-instance executable path, home dir, and env overrides (`providerInstance.ts`; `settings.ts` `binaryPath`, `homePath`). Lets users add a second Codex or a custom ACP command without a new code path.
2. **`ModelSelection = (instance, model, options[])`** as the only model reference.
3. **Per-model option descriptors** (`select` / `boolean`) instead of hardcoded `effort: none`.
4. **Capability flags drive UI; never branch on driver kind** (`docs/internals/adding-a-provider.md`).
5. **Health snapshot that never opens a session** (no hooks, no MCP start, no login in background probes). Perry's `RuntimeSetupRecord` is the start of this.
6. **Offer only runtime modes the agent enforces natively**; do not fake approvals in the host.
7. **Inject the host's own tool server per session in each runtime's native way**: Codex thread config, Claude control channel (not argv), ACP `session/new.mcpServers`.
8. **ACP registry model**: fetch registry JSON, pin exact versions, check sha256 for binaries, per-agent install root, plus a "Local ACP command" escape hatch. Keep agent-specific quirks in small flavor files, never in the generic adapter.
9. **Replay-fixture tests**: record real NDJSON transcripts per backend and replay them through the adapter. Perry already has fake-process hooks (`PERRY_FAKE_STDERR`, `CodexAppServerProcess` test seams).
10. **Generate protocol bindings from upstream schema** (`codex app-server generate-json-schema` exists on 0.164.0 [V]). For Swift, use the generated JSON Schema as a reference to hand-write the few `Codable` shapes you need, not as a build step.

Do not copy: Effect-based service graph, the orchestration-v2 event store, thread forking / lineage, multi-device relay. They solve a coding-IDE problem Perry does not have.

### 3.6 Licensing [V unless noted]

- **T3 Code: MIT, Copyright 2026 T3 Tools Inc.** Reading it and re-implementing concepts in Swift needs no notice. Copying any file or substantial portion (including generated schema files or text of `docs/`) requires keeping the copyright and permission notice. Nothing proposed needs a copy.
- ACP spec and schema: license not checked here. [I: Apache-2.0; confirm in the ACP repo before vendoring any schema.]
- Registry entries have mixed licenses: Apache-2.0, MIT, GPL-3.0 (`corust-agent`), AGPL-3.0 (`minion-code`), and many proprietary (Claude, Cursor, Devin, Copilot, and others) (registry JSON fetched 2026-10-24, 43 agents). **Perry must not bundle third-party agents.** The user installs them. Only metadata would ship.
- Bundled Codex stays Apache-2.0 (already shipped, pinned).
- Claude Code and the Claude Agent SDK are proprietary. Do not bundle or redistribute. [I]
- **Privacy conflict.** `features.json` records `privacy.no-telemetry` "zero outbound network while opted out" as live-tested. Fetching `cdn.agentclientprotocol.com` must be a user-initiated action, shown as such, or ship a bundled registry snapshot.
- No new third-party dependencies without approval (AGENTS.md). Everything above is stdlib `Process`, `URLSession`, and `JSONValue`.

### 3.7 Ordered build list

| # | Step | Effort | Notes |
|---|---|---|---|
| 0 | Fix the contradiction between `docs/capabilities.md`, `PRD.md:57-67`, and the code; stop listing Claude Code and OpenCode as task runners until they are | S | Honest status first. |
| 1 | `ProviderPreset` table + multi-profile store + per-profile Keychain account + `chatPath` field | M | Unblocks all of (b). Reuse the 3 existing wire adapters. |
| 2 | Model list fetch (`/v1/models`) + picker + run `ModelCapabilityProbe` for every profile, cache results | M | Replaces hardcoded custom-provider capabilities. |
| 3 | Local presets: add llama.cpp, vLLM, MLX, Jan to discovery; allow user-added loopback profiles with probe | S | Discovery code at `LocalServerDiscovery.swift` is already generic. |
| 4 | `ModelSelection` + per-model option descriptors (replace `ModelChoice`, hardcoded effort) | M | Touches `BrainController`, Settings, Talk. |
| 5 | Bundle `perry-mcp` in the app; harden how the token and socket reach a child process | S | Prerequisite for every external backend. |
| 6 | Generalize `JSONRPCConnection` (`jsonrpc` flag, timeouts, move out of `Codex/`) and `CodexAppServerProcess` to a `StdioAgentProcess` | S | |
| 7 | `AgentBackend` / `AgentRun` + wrap today's `AgentLoop` as the `.modelLoop` backend; `AgentCoordinator` picks a backend by `BackendInstance` | M | Zero behavior change at this step. |
| 8 | `AcpBackend` MVP: stdio spawn, `initialize`, `session/new` with `perry-mcp`, `prompt`, `update` to `AgentLoopEvent`, `request_permission` to Perry approval, `cancel`. fs/terminal off. Test with one binary agent (e.g. OpenCode) and one npx agent (Gemini CLI) | L | Biggest single item. Fixture-test first. |
| 9 | ACP registry: user-initiated fetch, binary/npx/uvx install with version pin + sha256, "Local ACP command" | M | Mind the privacy rule (3.6). |
| 10 | `CodexBackend`: promote `CodexAppServerProvider` to a backend with workspace-write mode and approval bridging (`item/commandExecution/requestApproval` etc., already stubbed in `handleServerRequest`) | M | Keeps read-only brain mode as is. |
| 11 | `ClaudeCodeBackend` over stream-json (option A), pinned to the verifier Perry already has | M–L | Highest protocol risk; fixture-test against recorded transcripts. Fall back to `claude-acp` via step 8 if it churns. |
| 12 | Settings "Agents" pane: instances, health snapshot, enable/disable, sign-in hints; relax or version-range the OpenCode pin | M | |
| 13 | Azure OpenAI, Bedrock (OpenAI-compatible endpoint), Vertex | M each | Only on demand. |

Smallest path to the user's two asks: **steps 1, 2, 3 deliver (b)** (many providers, custom, local) with almost no new protocol code. **Steps 5 to 9 deliver (a)** (ACP agents, including Gemini, OpenCode, Devin, Cursor, Pi through one backend). Steps 10 and 11 add first-party Codex and Claude Code as agents.

---

## Open questions for the user

1. Should external agents be allowed their own shell and file tools (coding mode), or stay "Perry tools only" by default? This changes the approval design.
2. Is a one-time, user-initiated ACP registry fetch acceptable under the no-telemetry promise?
3. Is requiring Node (for `npx` ACP agents) acceptable, or should the first release support binary-distributed agents only?

## Files read (Perry)

`App/RuntimeCatalog.swift`, `RuntimeInventory.swift`, `RuntimeSetup.swift`, `RuntimeSettingsState.swift`, `RuntimeExecutableVerifier.swift`, `App/Brain/BrainController.swift`, `BrainModelSettingsView.swift`, `App/SettingsView.swift` (runtimes tab, `RuntimeProviderSetupChoice`), `App/ForegroundTaskController.swift:780-830`, `App/TypedActionRouter.swift`, `App/Tools/AgentCoordinator.swift`, `PerryMCPSocket.swift`, `App/AppSubsystems.swift`, `PerryBrain/{Providers,Router,Codex,MCP,Tools,ModelTypes,BrainModelDefaults}`, `perry-mcp/main.swift`, `PerryRuntimes/{AgentRuntime,CLIRuntime,CodexRuntime,OpenCodeRuntime,DirectAIProvider,RuntimeStatus,BYOKAgentEndpoint}`, `PerryGuide/HardwareAndKeys.swift`, `PerryCore/NetworkEndpointPolicy.swift`, `PRD.md`, `docs/capabilities.md`, `docs/evidence/phase-7/mcp-socket.md`, `docs/release-readiness/features.json`, `App/Perry.entitlements`, `project.yml`.

## Files read (T3 Code, `/tmp/perry-audit/t3code`)

`LICENSE`, `README.md`, `packages/contracts/src/{providerInstance,providerPolicy,modelSelection,model,acpRegistry,settings,server,orchestrationV2}.ts`, `packages/provider-core/src/server/{driver,ProviderAdapter,ModelCatalog,snapshot,mcpSession,McpProviderSessions}.ts`, `apps/server/src/provider/{builtInDrivers,ProviderCredentialStore}.ts`, `apps/server/src/provider/Drivers/ClaudeDriver.ts`, `apps/server/src/orchestration-v2/Adapters/{ClaudeAdapterV2,CodexAdapterV2}.ts`, `packages/provider-acp/src/server/{AcpSessionRuntime,clientPolicy,mcpOverAcpBridge}.ts`, `packages/provider-acp-registry/src/server/{AcpRegistrySupport,claudeAcp,devinAcp}.ts`, `packages/effect-codex-app-server/{src/client.ts,scripts/generate.ts}`, `docs/internals/adding-a-provider.md`, `docs/user/providers-acp.md`, `docs/orchestration-v2/README.md`.

External read-only checks: `claude --help`, `claude --version`, `codex --version`, `codex app-server --help`, ACP registry JSON (saved at `/tmp/perry-audit/fetch/registry.json`).
