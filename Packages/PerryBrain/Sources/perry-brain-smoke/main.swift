import Foundation
import PerryBrain

var providerName = "codex"
var imagePath: String?
var tier: ModelTier = .fast
var codexHome = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Perry/CodexRuntime").path
var codexBinary = ""
var prompt = "Describe this screen in one sentence."
var login = false
var contextCheck = false
var toolCheck = false
var capacityCheck = false

var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = iterator.next() {
    switch arg {
    case "--provider": providerName = iterator.next() ?? providerName
    case "--image": imagePath = iterator.next()
    case "--tier": tier = iterator.next() == "deep" ? .deep : .fast
    case "--codex-home": codexHome = iterator.next() ?? codexHome
    case "--codex-bin": codexBinary = iterator.next() ?? codexBinary
    case "--login": login = true
    case "--context-check": contextCheck = true
    case "--tool-check": toolCheck = true
    case "--context-capacity": capacityCheck = true
    default:
        if arg.hasPrefix("--") {
            fputs("unknown option: \(arg)\n", stderr)
            exit(2)
        }
        prompt = arg
    }
}

if codexBinary.isEmpty {
    let candidates = [
        FileManager.default.currentDirectoryPath + "/App/Resources/CodexRuntime/bin/codex",
        ProcessInfo.processInfo.environment["PERRY_CODEX_BIN"] ?? "",
    ]
    codexBinary = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
}
if let env = ProcessInfo.processInfo.environment["PERRY_CODEX_HOME"], codexHome.isEmpty == false,
   ProcessInfo.processInfo.environment["PERRY_CODEX_HOME"] != nil,
   !CommandLine.arguments.contains("--codex-home") {
    codexHome = env
}

func codexProcess() -> CodexAppServerProcess {
    CodexAppServerProcess(configuration: CodexAppServerConfiguration(
        binaryURL: URL(fileURLWithPath: codexBinary),
        codexHome: URL(fileURLWithPath: codexHome),
        workingDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-brain-smoke", isDirectory: true)
    ))
}

func env(_ name: String) -> String? {
    ProcessInfo.processInfo.environment[name]
}

func makeProvider() throws -> any ModelProvider {
    let parts = providerName.split(separator: ":", maxSplits: 1).map(String.init)
    switch parts[0] {
    case "codex":
        return CodexAppServerProvider(process: codexProcess())
    case "openai":
        return OpenAIResponsesProvider(apiKeyProvider: { env("OPENAI_API_KEY") })
    case "anthropic":
        return AnthropicMessagesProvider(apiKeyProvider: { env("ANTHROPIC_API_KEY") })
    case "gemini":
        return GeminiProvider(apiKeyProvider: { env("GEMINI_API_KEY") })
    case "openrouter":
        return OpenAIChatCompatibleProvider(
            id: .openRouter, displayName: "OpenRouter",
            baseURL: URL(string: "https://openrouter.ai/api")!,
            apiKeyProvider: { env("OPENROUTER_API_KEY") },
            models: BrainModelCatalog.openRouter,
            capabilities: [.vision, .tools, .streaming]
        )
    case "ollama", "lmstudio":
        guard parts.count > 1 else { throw ModelProviderError(kind: .notConfigured, provider: "local", message: "usage: \(parts[0]):<model>") }
        let model = LocalModel(
            server: parts[0] == "ollama" ? .ollama : .lmStudio,
            baseURL: URL(string: parts[0] == "ollama" ? "http://127.0.0.1:11434" : "http://127.0.0.1:1234")!, name: parts[1]
        )
        return OpenAIChatCompatibleProvider(
            id: model.id, displayName: "\(model.server.rawValue) \(model.name)", baseURL: model.baseURL,
            models: BrainModelDefaults(fast: model.name, deep: model.name), capabilities: [.vision, .streaming],
            contextWindow: { _ in try await LocalServerDiscovery(timeout: 2).loadedContextWindow(for: model) }
        )
    case "apple":
        if #available(macOS 26, *) {
            return AppleFoundationModelProvider()
        }
        throw ModelProviderError(kind: .unavailable, provider: .apple, message: "requires macOS 26")
    default:
        fputs("unknown provider: \(providerName)\n", stderr)
        exit(2)
    }
}

let codexProvider: CodexAppServerProvider? = providerName == "codex"
    ? CodexAppServerProvider(process: codexProcess())
    : nil

if login {
    guard let codexProvider else {
        fputs("--login only applies to --provider codex\n", stderr)
        exit(2)
    }
    let loginEvents = try await codexProvider.account.loginEvents()
    let session = try await codexProvider.account.signIn()
    print("open this URL to sign in: \(session.url)")
    for await event in loginEvents {
        switch event {
        case .completed(let success, let id, let error):
            guard id == session.id else { continue }
            print(success ? "login completed" : "login failed: \(error ?? "?")")
            exit(success ? 0 : 1)
        }
    }
    exit(1)
}

let provider: any ModelProvider
if let codexProvider {
    provider = codexProvider
} else {
    provider = try makeProvider()
}

actor SmokeToolReceipt {
    private(set) var calls = 0
    func record() { calls += 1 }
}

func checkToolCallback(provider: any ModelProvider) async throws -> Bool {
    guard let provider = provider as? any ToolExecutingModelProvider else { return false }
    let receipt = SmokeToolReceipt()
    let spec = ToolSpec(name: "fixture_read", description: "Read the synthetic fixture value.", inputSchema: .object(["type": .string("object"), "properties": .object([:])]), readOnly: true)
    let request = ModelRequest(system: "Use fixture_read exactly once. Return its value only. Use no other tools.", messages: [.user([.text("Read the synthetic fixture now.")])], tools: [spec], tier: .deep)
    var answer = ""
    var completed = false
    for try await event in provider.stream(request, executeTool: { call in
        guard call.name == spec.name else { return .text(call.id, "Unexpected tool", isError: true) }
        await receipt.record()
        return .text(call.id, "orchid-tool-confirmed")
    }) {
        if case .textDelta(let text) = event { answer += text }
        if case .done(.endTurn) = event { completed = true }
    }
    let count = await receipt.calls
    let passed = completed && count == 1 && answer.contains("orchid-tool-confirmed")
    print("tool_calls=\(count) tool_check=\(passed ? "passed" : "failed") answer=\(answer)")
    return passed
}

if capacityCheck {
    if let tokens = try await provider.contextWindow(for: tier) {
        print("loaded_context_tokens=\(tokens)")
    } else {
        print("loaded_context_tokens=unknown")
    }
    exit(0)
}

if toolCheck {
    await provider.warm()
    let passed = try await checkToolCallback(provider: provider)
    exit(passed ? 0 : 1)
}

func checkConversationContext(provider: any ModelProvider) async throws -> Bool {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("perry-context-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ThreadStore(directory: root)
    var turns = [PerryThread.Turn(question: "Remember this fictional project: Orchid-73 ships Thursday.", answer: "Orchid-73 ships Thursday.")]
    turns += (0..<20).map { index in
        .init(question: "Fictional journal entry \(index)", answer: String(repeating: "The garden is quiet and the paths are clear. ", count: 10))
    }
    let original = try await store.upsert(PerryThread(turns: turns))
    let question = "What is the fictional project name and shipping day I gave at the beginning? Reply with only those two facts."
    let thread = try await store.beginTurn(to: original.id, question: question)
    guard let runID = thread.pendingTurn?.id else { return false }
    var request = ModelRequest(system: "Answer using the supplied conversation context only.", messages: [.user([.text(question)])], tier: .deep, maxOutputTokens: 256)
    let capacity = try await provider.contextWindow(for: .deep)
    print("context_check_capacity=\(capacity.map(String.init) ?? "unknown")")
    do {
        request.messages = try await ConversationContext().prepare(thread: thread, question: question, runID: runID, store: store, provider: provider, baseRequest: request)
    } catch {
        let saved = await store.thread(id: thread.id)
        print("context_check=failed error=\(error.localizedDescription)")
        print("context_summary=\(saved?.contextSummary?.text ?? "missing") retained_turns=\(saved?.turns.count ?? 0)")
        return false
    }
    let restored = await ThreadStore(directory: root).thread(id: thread.id)
    guard restored?.contextSummary != nil, restored?.turns.count == turns.count else { return false }
    print("context_summary=\(restored?.contextSummary?.text ?? "missing")")
    var answer = ""
    var completed = false
    for try await event in provider.stream(request) {
        if case .textDelta(let text) = event { answer += text }
        if case .done(.endTurn) = event { completed = true }
    }
    let passed = completed && answer.contains("Orchid-73") && answer.localizedCaseInsensitiveContains("Thursday")
    print("summary_source_turns=\(restored?.contextSummary?.sourceTurnCount ?? 0) retained_turns=\(restored?.turns.count ?? 0)")
    print("context_answer=\(answer) context_check=\(passed ? "passed" : "failed")")
    return passed
}

if contextCheck {
    await provider.warm()
    let passed = try await checkConversationContext(provider: provider)
    exit(passed ? 0 : 1)
}

var parts: [ModelContentPart] = [.text(prompt)]
if let imagePath {
    parts.append(.image(data: try Data(contentsOf: URL(fileURLWithPath: imagePath)), mimeType: "image/jpeg"))
}

await provider.warm()

let request = ModelRequest(
    system: "You are Perry, a terse on-screen assistant.",
    messages: [.user(parts)],
    tier: tier
)

let clock = ContinuousClock()
let start = clock.now
var firstDelta: Duration?
var stop: ModelStopReason?

let stream = provider.stream(request)
do {
    for try await event in stream {
        switch event {
        case .textDelta(let text):
            if firstDelta == nil { firstDelta = clock.now - start }
            print(text, terminator: "")
            fflush(stdout)
        case .toolCall(let call):
            print("\n<toolCall \(call.name)>")
        case .usage(let input, let output):
            print("\nusage in=\(input) out=\(output)")
        case .done(let reason):
            stop = reason
        }
    }
} catch {
    print("\nerror: \(error)")
}

let total = clock.now - start
func ms(_ d: Duration) -> Int {
    let c = d.components
    return Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
}
print("\nfirst_delta_ms=\(firstDelta.map { ms($0) } ?? -1) total_ms=\(ms(total)) provider=\(provider.id.rawValue) stop=\(String(describing: stop))")
exit(stop == nil ? 1 : 0)
