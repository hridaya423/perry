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

var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = iterator.next() {
    switch arg {
    case "--provider": providerName = iterator.next() ?? providerName
    case "--image": imagePath = iterator.next()
    case "--tier": tier = iterator.next() == "deep" ? .deep : .fast
    case "--codex-home": codexHome = iterator.next() ?? codexHome
    case "--codex-bin": codexBinary = iterator.next() ?? codexBinary
    case "--login": login = true
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
    let parts = providerName.split(separator: ":").map(String.init)
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
    case "ollama":
        guard parts.count > 1 else { throw ModelProviderError(kind: .notConfigured, provider: "local", message: "usage: ollama:<model>") }
        return OpenAIChatCompatibleProvider(
            id: "local.ollama", displayName: "Ollama \(parts[1])",
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            models: BrainModelDefaults(fast: parts[1], deep: parts[1]),
            capabilities: [.vision, .streaming]
        )
    case "lmstudio":
        guard parts.count > 1 else { throw ModelProviderError(kind: .notConfigured, provider: "local", message: "usage: lmstudio:<model>") }
        return OpenAIChatCompatibleProvider(
            id: "local.lmstudio", displayName: "LM Studio \(parts[1])",
            baseURL: URL(string: "http://127.0.0.1:1234")!,
            models: BrainModelDefaults(fast: parts[1], deep: parts[1]),
            capabilities: [.vision, .streaming]
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
    if let url = try await codexProvider.account.signIn() {
        print("open this URL to sign in: \(url)")
    }
    for await event in loginEvents {
        switch event {
        case .completed(let success, _, let error):
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
