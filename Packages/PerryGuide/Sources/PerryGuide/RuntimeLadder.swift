import Foundation
import PerryCore
import PerryRuntimes

/// PRD §4 runtime ladder, tier 2: BYOK cloud computer-use against screenshots
/// for GUI-heavy targets. This planner talks to any OpenAI-compatible
/// endpoint; keys come from the Keychain, calls go device → provider directly.
public struct BYOKPlanner: GuidePlanning {
    public struct Endpoint: Sendable {
        public let baseURL: URL
        public let model: String

        public init(baseURL: URL, model: String) {
            self.baseURL = baseURL
            self.model = model
        }

        public static let anthropic = Endpoint(baseURL: URL(string: "https://api.anthropic.com")!, model: "claude-sonnet-4-20250514")
        public static let openAI = Endpoint(baseURL: URL(string: "https://api.openai.com")!, model: "gpt-4o")
        public static let openRouter = Endpoint(baseURL: URL(string: "https://openrouter.ai/api")!, model: "anthropic/claude-sonnet-4")
    }

    private let endpoint: Endpoint
    private let apiKeyProvider: @Sendable () -> String?
    private let transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public init(
        endpoint: Endpoint,
        apiKeyProvider: @escaping @Sendable () -> String?,
        transport: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil
    ) {
        self.endpoint = endpoint
        self.apiKeyProvider = apiKeyProvider
        if let transport {
            self.transport = transport
        } else {
            self.transport = { request in
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw PlanError(message: "non-HTTP response from provider")
                }
                return (data, http)
            }
        }
    }

    /// Plans Guide steps from an AX snapshot. No network in tests: when no key
    /// is configured this throws before any request is built.
    public func plan(goal: String, snapshot: AXSnapshot) async throws -> GuidePlan {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw PlanError(message: "no API key configured for \(endpoint.baseURL.host() ?? "provider")")
        }

        let controlList = snapshot.actionableElements()
            .prefix(40)
            .map { "[\($0.stableID)] \($0.role.rawValue) \($0.label ?? "")" }
            .joined(separator: "\n")

        let body: [String: Any] = [
            "model": endpoint.model,
            "max_tokens": 512,
            "messages": [[
                "role": "user",
                "content": """
                Goal: \(goal)
                Visible controls:
                \(controlList)
                Reply with one JSON object: {"steps":[{"id":"<stable id or null>","instruction":"<what to do>"}]}
                JSON only.
                """,
            ]],
        ]

        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport(request)
        guard response.statusCode == 200 else {
            throw PlanError(message: "provider returned \(response.statusCode)")
        }
        return try Self.parsePlan(data: data, goal: goal)
    }

    static func parsePlan(data: Data, goal: String) throws -> GuidePlan {
        guard
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = payload["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String,
            let jsonStart = content.firstIndex(of: "{"),
            let jsonEnd = content.lastIndex(of: "}"),
            let stepsJSON = try? JSONSerialization.jsonObject(
                with: Data(content[jsonStart...jsonEnd].utf8)
            ) as? [String: Any],
            let stepList = stepsJSON["steps"] as? [[String: Any]]
        else {
            throw PlanError(message: "could not parse planner response")
        }

        let steps = stepList.compactMap { step -> GuideStep? in
            guard let instruction = step["instruction"] as? String else { return nil }
            if let id = step["id"] as? String, id != "null", !id.isEmpty {
                return GuideStep(instruction: instruction, target: .axElement(stableID: id))
            }
            return GuideStep(instruction: instruction, target: .verbalOnly)
        }
        return GuidePlan(goal: goal, steps: steps)
    }
}

/// Runtime router per PRD §4: CLI runtimes take file/dev/browser tasks;
/// GUI grounding routes to vision-capable runtimes; local tier only when the
/// hardware probe passes and the experimental flag is on.
public struct RuntimeRouter: Sendable {
    public enum TaskKind: String, Sendable {
        case fileOrDev
        case guiGrounding
    }

    public struct Decision: Equatable, Sendable {
        public let runtimeID: String
        public let reason: String
    }

    private let cliAvailable: Bool
    private let byokAvailable: Bool
    private let localPassesFloor: Bool
    private let localExperimentalFlagOn: Bool

    public init(
        cliAvailable: Bool,
        byokAvailable: Bool,
        localPassesFloor: Bool,
        localExperimentalFlagOn: Bool = false
    ) {
        self.cliAvailable = cliAvailable
        self.byokAvailable = byokAvailable
        self.localPassesFloor = localPassesFloor
        self.localExperimentalFlagOn = localExperimentalFlagOn
    }

    public func route(task: TaskKind) -> Decision {
        switch task {
        case .fileOrDev:
            if cliAvailable { return Decision(runtimeID: "cli.claude-code", reason: "installed CLI handles files and dev tasks natively") }
            if byokAvailable { return Decision(runtimeID: "byok.cloud", reason: "cloud fallback with no CLI installed") }
            return Decision(runtimeID: "none", reason: "install a coding-agent CLI or add a cloud key")
        case .guiGrounding:
            if byokAvailable { return Decision(runtimeID: "byok.cloud", reason: "vision-capable cloud model grounds GUI elements") }
            if cliAvailable { return Decision(runtimeID: "cli.claude-code", reason: "CLI fallback; screenshot-driven but weaker at pixel pointing") }
            return Decision(runtimeID: "none", reason: "add a cloud vision key for reliable GUI grounding")
        }
    }

    /// Local tier gate: passes floor AND explicit opt-in flag.
    public func isLocalTierOffered() -> Bool {
        localPassesFloor && localExperimentalFlagOn
    }
}
