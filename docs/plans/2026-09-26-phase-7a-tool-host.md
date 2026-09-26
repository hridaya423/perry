# Phase 7a: Tool host + AgentLoop core (PerryBrain, headless)

Master plan §6.2/§6.3/§7 items 1–2 and the loop skeleton. App executors
(`App/Tools/*`), ghost cursor, intent cards, `perry-mcp`, and coordinator
collapse are 7b.

All code in `Packages/PerryBrain/Sources/PerryBrain/Tools/`, tests in
`Tests/PerryBrainTests/`. No new deps.

## Extend `ToolSpec` (ModelTypes.swift)

Add `tier: TrustTier` (default `.green`) and `surfaces: Set<ToolSurface>`
(default all three) to `ToolSpec` — defaulted params keep existing callers.
Tiers use the existing `PerryCore.TrustTier` (green/yellow/orange/red); a spec's
tier is set by the executor author and cannot be lowered per-call.

## `Tools/ToolHost.swift`

```swift
public struct ToolResult: Sendable, Equatable {
    public var callID: String; public var content: [ModelContentPart]; public var isError: Bool
    public static func text(_ callID: String, _ s: String, isError: Bool = false) -> ToolResult
}
public struct ToolContext: Sendable {
    public var surface: ToolSurface
    public var threadID: String?
    /// Set by the UI only after the user typed the confirmation phrase for THIS call.
    public var redConfirmed: Bool = false
    /// App-injected approval for orange/red intent cards.
    public var approve: (@Sendable (ToolCall, ToolSpec) async -> Bool)?
}
public enum ToolHostError: Error, Sendable, Equatable {
    case unknownTool(String)
    case surfaceDenied(callID: String, name: String, surface: ToolSurface)
    case schemaViolation(name: String, detail: String)
    case confirmationRequired(name: String, tier: TrustTier)
    case approvalDenied(name: String)
}
public protocol ToolExecutor: Sendable {
    var spec: ToolSpec { get }
    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult
}
public final class PerryToolHost: Sendable {
    public init(executors: [any ToolExecutor])
    public func specs(for surface: ToolSurface) -> [ToolSpec]  // spec.surfaces ∋ surface AND ToolGate.allows
    public func handle(_ call: ToolCall, context: ToolContext) async -> ToolResult // errors → isError, never throws
    public static func validate(_ arguments: JSONValue, against schema: JSONValue) -> String?
}
```

`handle` order: unknown executor → `unknownTool` → surface gate via
`ToolGate.check` (rejected call logged, executor never runs) → schema validate
→ tier: `.orange` requires `context.approve` returning true; `.red` requires
`approve` true AND `context.redConfirmed`; denial → `approvalDenied` → run
executor; thrown errors become `isError` results.

`validate`: JSON-Schema subset — top-level `type:"object"` enforced;
`required` keys present; `properties` types checked recursively
(string/number/integer/boolean/array/object, `enum` list); unknown keys
rejected (additionalProperties is strict by default — spec: "Every tool
validates its schema and rejects unknown keys"); property schemas without
`type` accept anything. Returns a short detail string or nil.

## `Tools/AgentLoop.swift`

```swift
public enum AgentFinish: Sendable, Equatable {
    case completed, interrupted, paused, budgetToolCalls, budgetTime, providerError(String)
}
public enum AgentLoopEvent: Sendable, Equatable {
    case textDelta(String)
    case toolCallStarted(ToolCall)
    case toolCallFinished(ToolResult)
    case note(String)               // steer applied, paused, budget notices
    case finished(AgentFinish)
}
public actor AgentLoop {
    public struct Budgets: Sendable { public var maxToolCalls = 60; public var wallClock: TimeInterval = 1200 }
    public init(provider: any ModelProvider, host: PerryToolHost, budgets: Budgets = .init())
    public func steer(_ text: String)      // queued; injected as user message at next boundary
    public func pause()                    // takes effect at the next tool boundary
    public func interrupt()                // cancels immediately
    /// Streams events. `run` is nonisolated; the loop task reads control flags via actor calls.
    public nonisolated func run(system: String, messages: [ModelMessage],
                                context: ToolContext) -> AsyncStream<AgentLoopEvent>
}
```

Loop: drain steer queue → check interrupt/pause/deadline →
`provider.stream(request(tools: host.specs(for: context.surface)))` → relay
textDeltas, collect toolCalls → no calls: `.finished(.completed)` → else
execute calls sequentially through `host.handle`, appending
`.assistant(text:toolCalls:)` + `.toolResult` messages → repeat. Tool-call
budget checked before each call; wall-clock before each provider round.
`pause()` finishes `.paused` at the boundary (state resumable by the caller
re-invoking with the accumulated messages — the loop emits final `messages`
via `.note`? No: run takes `messages` inout? Keep it simple: caller owns
persistence; on `.paused` the loop emits `.note("paused after N tool calls")`
and ThreadStore holds what the caller persisted per turn).

Task cancellation/interrupt: `interrupt()` cancels the loop task; the stream
finishes with `.finished(.interrupted)` if not already finished.

## Tests (`Tests/PerryBrainTests/`)

`ScriptedProvider` in Support: returns a queued `[ModelEvent]` list per stream
call and records requests.

ToolHostTests:
- unknown key rejected (`schemaViolation`, executor not run — counting executor)
- missing required rejected; nested object violation path names the key
- `ui.click` on `.talk` → `surfaceDenied`, executor count 0
- orange without approver → `confirmationRequired`; with approving approver → runs;
  denying approver → `approvalDenied`
- red without `redConfirmed` → `confirmationRequired` even when approver allows;
  red + redConfirmed + approve → runs
- `specs(for: .talk)` returns only observe/draw specs even when an executor
  registered a `.agent`-only tool
- thrown executor error → `isError` result (not throw)

AgentLoopTests (ScriptedProvider):
- text-only turn → deltas + `.completed`
- one tool call → second request contains `.assistant` + `.toolResult`; answer
  text after call is relayed
- steer queued mid-run lands as `.user` message in next request
- interrupt mid-stream → `.interrupted`
- maxToolCalls=2 with a provider that always calls → `.budgetToolCalls` after 2
- pause between calls → `.paused`

## Verify

`swift test --package-path Packages/PerryBrain` green; app build still green;
`git diff --check` clean.
