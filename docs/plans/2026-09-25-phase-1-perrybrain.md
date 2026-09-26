# Phase 1 — PerryBrain Implementation Plan

**Goal:** One streaming, tool-capable, provider-agnostic model layer so Perry works zero-key (ChatGPT sign-in via bundled Codex), with any BYOK key, or fully local — replacing the single-shot `DirectProviderClient` path over Phases 2/6/7.

**Architecture:** New local Swift package `Packages/PerryBrain` (depends only on `PerryCore`). Pure protocol + providers + router; all network/process I/O behind injectable transports so unit tests use recorded fixtures and a fake app-server. The app composes providers in `App/Brain/BrainController.swift` from Keychain + UserDefaults + the bundled Codex binary.

**Tech stack:** Swift 5.9+, Foundation `URLSession.bytes`, `Process` + pipes, `FoundationModels` (macOS 26, `#if canImport`). No new third-party dependencies.

Master plan: `~/.devin/plans/plan-c221ed45bb308d87.md` §6.1, Phase 1.

---

## Settled interfaces (do not redesign)

`Packages/PerryBrain/Sources/PerryBrain/ModelTypes.swift`

```swift
public struct ModelCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let vision = Self(rawValue: 1 << 0)
    public static let tools = Self(rawValue: 1 << 1)
    public static let streaming = Self(rawValue: 1 << 2)
    public static let realtimeAudio = Self(rawValue: 1 << 3)
    public static let local = Self(rawValue: 1 << 4)
    public static let longContext = Self(rawValue: 1 << 5)
}
public enum ModelTier: String, Sendable, Codable { case fast, deep }
public struct ProviderID: RawRepresentable, Hashable, Sendable, Codable { public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue } }

public enum ModelContentPart: Sendable, Equatable {
    case text(String)
    case image(data: Data, mimeType: String)          // in-memory only, never persisted
}
public enum ModelMessage: Sendable, Equatable {
    case user([ModelContentPart])
    case assistant(text: String, toolCalls: [ToolCall])
    case toolResult(callID: String, content: [ModelContentPart], isError: Bool)
}
public struct ToolSpec: Sendable, Equatable { public let name: String; public let description: String; public let inputSchema: JSONValue }
public struct ToolCall: Sendable, Equatable { public let id: String; public let name: String; public let arguments: JSONValue }

public struct ModelRequest: Sendable {
    public var system: String
    public var messages: [ModelMessage]
    public var tools: [ToolSpec]
    public var tier: ModelTier
    public var maxOutputTokens: Int           // default 4096
}
public enum ModelStopReason: Sendable, Equatable { case endTurn, toolUse, maxTokens, cancelled, other(String) }
public enum ModelEvent: Sendable, Equatable {
    case textDelta(String)
    case toolCall(ToolCall)                   // emitted once, arguments fully assembled + parsed
    case usage(inputTokens: Int, outputTokens: Int)
    case done(ModelStopReason)
}
public struct ModelProviderError: Error, Equatable, LocalizedError {
    public enum Kind: Equatable { case notConfigured, unauthenticated, rateLimited(resetAt: Date?), http(Int), network, malformed, unavailable, cancelled }
    public let kind: Kind; public let provider: ProviderID; public let message: String
    public var errorDescription: String? { message }
}
public protocol ModelProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var capabilities: ModelCapabilities { get }
    /// Tool calls are surfaced as events; the caller (AgentLoop / TalkSession) executes them
    /// and continues with a new request containing `.toolResult`. Codex is the exception:
    /// it calls back through `ToolCallHandler` (see CodexAppServerProvider).
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error>
    func warm() async
}
```

`JSONValue.swift`: `public enum JSONValue: Codable, Sendable, Equatable { case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue]) }` with `init(parsing: Data) throws` and `func data() throws -> Data` (sorted keys).

Transport seam — `HTTPStreaming.swift`:

```swift
public protocol HTTPLineStreaming: Sendable {
    /// Returns status + an async sequence of raw lines (without trailing newline).
    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>)
}
public struct URLSessionLineStreaming: HTTPLineStreaming { /* URLSession.shared.bytes(for:) → .lines */ }
public struct SSEEvent: Equatable, Sendable { public var event: String?; public var data: String }
public struct SSEParser { public mutating func feed(line: String) -> SSEEvent? }   // blank line dispatches; multi-line data joined with \n; ignores ":" comments
```

Non-2xx: read up to 8 KiB body, map 401/403 → `.unauthenticated`, 429 → `.rateLimited(resetAt:)` (parse `retry-after` / `x-ratelimit-reset-requests`), else `.http(code)`. Every provider calls `NetworkEndpointPolicy.requireSafe(baseURL)` before any request. Cancellation of the consuming task cancels the URLSession task and yields `.done(.cancelled)` is NOT emitted — the stream just finishes with `CancellationError`.

## Phase 0 spike facts (authoritative — see docs/evidence/phase-0/spikes.md)

- Framing is newline-delimited JSON-RPC over stdio; `scripts/lab/codex-appserver-spike.swift` is a working reference for initialize → account/read → model/list → thread/start → turn/start. Reuse its message shapes.
- Under ChatGPT auth only `gpt-5.5` runs (gpt-5.4 / -mini rejected). So Codex tier mapping = same model, `effort: "low"` for `.fast`, default for `.deep`; `minimal` is rejected while built-in tools are attached. Resolve models from `model/list` but fall back to the first model that the account accepts; surface the rejection message as `.unavailable` rather than retrying blindly.
- Image input: `localImage` (a file path) is accepted. Write the JPEG to a Perry-owned temp dir with 0600 perms, pass the path, delete it when the turn ends (success, error, or cancel). Data-URL `image` also appears in schema — prefer it if it works in the fake/real server, since it avoids touching disk.
- `thread/start` has no top-level `dynamicTools` in 0.132.0; send `capabilities.experimentalApi: true` in initialize and check the `--experimental` schema for the exact field. If absent, `.tools` is omitted from capabilities.
- First-delta is 6–34 s → Codex is the "deep" brain, never the Talk fast path. Router must therefore prefer a fast provider (BYOK fast model, local, or Apple FM) for `.fast` requirements and use Codex for `.fast` only when nothing else exists (explanation says so).

## Providers (one file each, in `Sources/PerryBrain/Providers/`)

1. **`OpenAIResponsesProvider`** — `POST {base}/v1/responses`, `stream: true`, `instructions` = system, `input` items (`input_text`, `input_image` with data URL, `function_call` / `function_call_output` for history), `tools: [{type:"function", name, description, parameters}]`, `max_output_tokens`. Events: `response.output_text.delta` → textDelta; `response.output_item.added` (type function_call → start buffer by item id, capture call_id+name); `response.function_call_arguments.delta` → append; `response.output_item.done` (function_call) → parse args → toolCall; `response.completed` → usage + done(toolUse if any tool calls else endTurn); `response.incomplete` with max_output_tokens → done(.maxTokens); `error` / `response.failed` → throw malformed/http. Models: fast/deep configurable, defaults read from `BrainModelDefaults.openAI` (fast `gpt-5-mini`, deep `gpt-5`) — overridable in settings.
2. **`OpenAIChatCompatibleProvider`** — `POST {base}/v1/chat/completions` stream; for OpenRouter, Ollama (`http://127.0.0.1:11434`), LM Studio (`http://127.0.0.1:1234`), MLX servers, custom. Accumulate `choices[0].delta.tool_calls[index]` fragments; `finish_reason` maps stop/tool_calls/length. `stream_options: {include_usage: true}`. Capabilities passed in by the constructor (local discovery decides vision). Marks `.local` when host is loopback.
3. **`AnthropicMessagesProvider`** — `POST {base}/v1/messages`, headers `x-api-key`, `anthropic-version: 2023-06-01`, `stream: true`. Events: `content_block_start` (tool_use → id,name), `content_block_delta` (`text_delta` / `input_json_delta` partial_json), `content_block_stop` → emit toolCall, `message_delta` usage + stop_reason, `message_stop`.
4. **`GeminiProvider`** — `POST {base}/v1beta/models/{model}:streamGenerateContent?alt=sse`, header `x-goog-api-key`; `systemInstruction`, `contents`, `tools: [{functionDeclarations}]`; parts `text` / `functionCall{name,args}` (ids synthesized `gemini-<n>`); `usageMetadata`; `finishReason`.
5. **`AppleFoundationModelProvider`** — `#if canImport(FoundationModels)` + `@available(macOS 26, *)`. Text-only (no `.vision`), `.local | .streaming`. Uses `LanguageModelSession(instructions:)` + `streamResponse(to:)`; emits deltas by diffing cumulative snapshots. `isAvailable` reflects `SystemLanguageModel.default.availability`. Ignores tools (capabilities omit `.tools`).
6. **`CodexAppServerProvider`** — see next section.

## CodexAppServerProvider (the zero-key brain)

Files: `Codex/JSONRPCConnection.swift`, `Codex/CodexAppServerProcess.swift`, `Codex/CodexAppServerProvider.swift`, `Codex/CodexAccount.swift`.

- **Protocol ground truth:** regenerate the schema into `Packages/PerryBrain/Tests/PerryBrainTests/Fixtures/codex-app-server-schema/` with `CODEX_HOME=$(mktemp -d) App/Resources/CodexRuntime/bin/codex app-server generate-json-schema --experimental --out <dir>` and commit only `codex_app_server_protocol.v2.schemas.json` + `ClientRequest.json` + `ServerRequest.json` + `ServerNotification.json`. Derive every method/field name from these files. First verify framing by hand: spawn the binary, send one `initialize` request, observe whether it's newline-delimited JSON (expected) or Content-Length framed; implement what's observed.
- **Process:** binary `Bundle.main.resourceURL/CodexRuntime/bin/codex` (injected URL), args `["app-server"]` plus config overrides that confine it for Perry use: sandbox read-only, approval policy never, `cwd` = an empty Perry-owned temp dir, and disable built-in shell/patch/web tools if a config/feature key exists (check `codex features list` and the config schema; record what was possible in the phase evidence — if the shell tool cannot be disabled, it must be sandboxed read-only in an empty cwd and that limitation is documented). Env: the app passes the filtered environment (reuse `CLIRuntime.processEnvironment(from:profile: .codex(runtimeHome))` — make it `public` if needed) so `CODEX_HOME` is Perry's own support directory, never `~/.codex`. Lazy spawn on first `warm()`/`stream()`, restart with backoff (0.5s, 2s, 8s; give up after 3 in 60 s → `.unavailable`), terminate on `deinit`/app quit (reuse `CLIRuntime.stopProcess`).
- **Account:** `CodexAccount` exposes `status() async -> CodexAccountStatus { .signedIn(email:plan:), .signedOut, .unknown }` via `account/read`; `signIn() async throws -> URL?` via `account/login/start {type:"chatgpt"}` → returns the auth URL for the app to open; completion observed from the `account/login/completed` notification (AsyncStream `loginEvents`); `signOut()`; `rateLimits() async -> CodexRateLimits?` via `account/rateLimits/read`.
- **Turns:** one `thread/start` per `ModelRequest` conversation key. Talk uses `ephemeral: true`; `baseInstructions`/`developerInstructions` = request.system. `turn/start` with `input` = text + image items (`{type:"image", url:"data:image/jpeg;base64,..."}`), `model` = tier model from `model/list` (pick smallest/fastest for `.fast`; flagship for `.deep`; overridable), `effort` low for fast, medium for deep. Map agent-message delta notifications → textDelta, turn completion → done, token usage notifications → usage. Cancellation → `turn/interrupt`.
- **Tools:** If `thread/start` accepts dynamic tools in the `--experimental` schema, register `request.tools` there and answer server requests `DynamicToolCallParams` through an injected `ToolCallHandler` (`@Sendable (ToolCall) async -> ToolCallResult`), also emitting `.toolCall` events for observability. If not available, capabilities omit `.tools` (Talk falls back to inline draw tags — Phase 2) and log the reason.
- Any approval request from the server (command/file-change/permissions) is auto-**denied** in Phase 1 (Perry's own tool host owns all side effects).

## ProviderRouter + discovery

`Router/ProviderRouter.swift`:

```swift
public struct RouteRequirement: Sendable { public var capabilities: ModelCapabilities; public var tier: ModelTier }
public struct RouteDecision: Sendable { public let provider: any ModelProvider; public let explanation: String }  // e.g. "ChatGPT (fast) — OpenAI key not set"
public actor ProviderRouter {
    public init(providers: [any ModelProvider], preference: [ProviderID])
    public func route(_ requirement: RouteRequirement) throws -> RouteDecision   // throws .notConfigured when none qualify
    public func reportFailure(_ id: ProviderID)   // 2 consecutive failures → unhealthy 60 s
    public func reportSuccess(_ id: ProviderID)
}
```

Order: user preference list first, then default order by tier — `.fast`: `openAI, anthropic, gemini, openRouter, local, apple, codex`; `.deep`: `codex, openAI, anthropic, gemini, openRouter, local, apple`. Skip unhealthy/unqualified. Explanation names the chosen provider and why earlier preferred ones were skipped (≤80 chars).

`Router/TierClassifier.swift`: pure `static func tier(question: String, bindingCount: Int, elementCount: Int) -> ModelTier` — deep if question > 160 chars, or contains why/how-do/explain/compare/step/write/draft (+ multilingual basics), or elementCount > 400, or bindingCount > 2; else fast. (Foundation Models classifier is a Phase 2 enhancement.)

`Router/LocalServerDiscovery.swift`: probes `GET http://127.0.0.1:11434/api/tags` (Ollama; vision if model details families contain `clip`/`mllama` or name matches `llava|vision|vl|gemma3|qwen2.5vl|qwen3-vl|llama3.2-vision|minicpm-v`) and `GET http://127.0.0.1:1234/v1/models` (LM Studio). 300 ms timeout each. Returns `[LocalModel{server, baseURL, name, supportsVision}]`.

## App wiring (minimal in Phase 1)

`App/Brain/BrainController.swift` (`@MainActor final class BrainController: ObservableObject`):
- `@Published var account: CodexAccountStatus`, `@Published var localModels: [LocalModel]`, `@Published var activeExplanation: String`.
- Builds providers: Codex (bundled binary), direct providers for any Keychain account `brain.openai|brain.anthropic|brain.gemini|brain.openrouter` (migrate existing `byok.vision` key+endpoint into the matching `brain.*` account on first launch, keep reading the old one as fallback), local servers from discovery, Apple FM on 26.
- `func router() -> ProviderRouter`, `func signInWithChatGPT()` (opens URL via `NSWorkspace`), `func signOut()`, `func refresh()`.
- Owned by `AppController` (one property + init line only). No UI in Phase 1 beyond a DEBUG menu item "Brain smoke test" that routes `.fast` + `.vision`, sends "Describe this screen in one sentence" with a Cua screenshot of the front window, and shows the streamed text + first-delta ms in the status line.

## Smoke executable

`Packages/PerryBrain/Sources/perry-brain-smoke/main.swift`: `swift run --package-path Packages/PerryBrain perry-brain-smoke --provider codex|openai|anthropic|gemini|ollama:<model>|lmstudio:<model>|apple [--image path.jpg] [--tier fast|deep] "prompt"` → prints streamed text, then `first_delta_ms=… total_ms=… provider=… model=…`. Keys from env (`OPENAI_API_KEY` etc.); codex uses `PERRY_CODEX_BIN` (default repo bundled path) and `PERRY_CODEX_HOME` (default `~/Library/Application Support/Perry/CodexRuntime`). `--login` performs ChatGPT sign-in and prints the URL.

## Tests (`Tests/PerryBrainTests/`, all offline)

- `SSEParserTests`: multi-line data, comments, CRLF, missing trailing blank line at EOF flushed.
- `JSONValueTests`: round trip, sorted keys, number vs bool.
- Per provider (`OpenAIResponsesProviderTests`, `OpenAIChatCompatibleProviderTests`, `AnthropicMessagesProviderTests`, `GeminiProviderTests`): recorded SSE fixture files under `Fixtures/sse/*.txt` (hand-written from provider docs, realistic) fed through a `FixtureLineStreaming` double. Assert: request body shape (system, image encoding, tools), exact event sequence for text-only, one tool call with fragmented args, two parallel tool calls, max-tokens stop, 401 → unauthenticated, 429 with retry-after → rateLimited(resetAt), malformed JSON in args → throws `.malformed`, plaintext non-loopback base URL → throws before any request.
- `CodexAppServerProviderTests`: `Fixtures/fake-codex-app-server.py` (python3 stdlib) reads JSONL requests and replies from a scripted scenario chosen by env var: (a) signed-out → login start returns URL → emits login completed; (b) turn streams 3 deltas then completes with usage; (c) server issues a dynamic tool call → provider invokes handler → fake asserts the response payload and then finishes; (d) process exits mid-turn → stream throws `.unavailable`, next call respawns; (e) cancellation sends `turn/interrupt`. Also a schema test that every method name the provider sends exists in the committed `ClientRequest.json`.
- `ProviderRouterTests`: preference order, capability filtering (vision required skips Apple FM), unhealthy after 2 failures and recovery after 60 s (injected clock), explanation text.
- `TierClassifierTests`, `LocalServerDiscoveryTests` (fixture JSON for both servers, timeout → empty).

## Commands

- `swift test --package-path Packages/PerryBrain` → all pass.
- `build/tools/xcodegen/bin/xcodegen generate --spec project.yml && xcodebuild build -project Perry.xcodeproj -scheme Perry -configuration Debug -derivedDataPath build/debug-p1 -destination 'platform=macOS,arch=arm64'` → BUILD SUCCEEDED.
- Live (after the user signs in once): `swift run --package-path Packages/PerryBrain perry-brain-smoke --provider codex --tier fast --image <screenshot.jpg> "What app is this?"` and the same for `ollama:<vision model>` if one is installed; record first_delta_ms (3 runs each) into `docs/evidence/phase-1/latency.md`.

## Acceptance

1. All PerryBrain tests green; app builds; no existing test regresses (`swift test` for PerryRuntimes/PerryGuide unchanged).
2. ChatGPT sign-in works from the smoke tool and from the DEBUG menu; streamed vision answer with measured first delta.
3. Local path answers offline via Ollama/LM Studio when a vision model is present (else documented as "no local vision model installed").
4. Network pulled mid-stream → error surfaced and idle within 2 s.
5. Evidence doc lists: framing observed, whether dynamic tools and built-in-tool disabling were available, latency table, and the Phase-0 decision (fast path) per master plan.

Commit per logical unit (package scaffold+types, SSE+OpenAI, other HTTP providers, Codex, router/discovery, app wiring, smoke tool).
