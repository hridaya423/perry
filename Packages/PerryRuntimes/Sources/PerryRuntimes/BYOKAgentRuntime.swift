import Foundation
import CoreFoundation
import PerryCore

public struct BYOKAgentEndpoint: Equatable, Sendable {
    public let baseURL: URL
    public let model: String

    public init(baseURL: URL, model: String) {
        self.baseURL = baseURL
        self.model = model
    }
}

public struct BYOKAgentRuntime: TaskPlanner {
    public let id = "byok.vision"
    public let capabilities = RuntimeCapabilities(guiGrounding: true, fileIO: false, browser: false, remoteIntegrations: true, latencyClass: .slow)

    private let endpoint: BYOKAgentEndpoint
    private let apiKeyProvider: @Sendable () -> String?
    private let transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public init(
        endpoint: BYOKAgentEndpoint,
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
                    throw PlanError(message: "provider returned a non-HTTP response")
                }
                return (data, http)
            }
        }
    }

    public func plan(_ request: PlanningRequest) async throws -> ExecutionPlan {
        guard case .screen(let context) = request.context else {
            throw PlanningError.contextRequired
        }
        let text = try await planText(
            prompt: TypedPlanningPrompt.make(goal: request.goal, context: context),
            context: context
        )
        return try TypedPlanParser.plan(
            text,
            request: request,
            bindings: .init(request: request, context: context)
        )
    }

    private func planText(prompt: String, context: ScreenContext) async throws -> String {
        do {
            try NetworkEndpointPolicy.requireSafe(endpoint.baseURL)
        } catch {
            throw PlanError(message: String(describing: error))
        }
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw PlanError(message: "no BYOK vision API key is configured")
        }

        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        if let image = context.screenshotJPEGData {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:\(context.screenshotMIMEType);base64,\(image.base64EncodedString())"],
            ])
        }

        let body: [String: Any] = [
            "model": endpoint.model,
            "temperature": 0,
            "max_tokens": 768,
            "messages": [["role": "user", "content": content]],
        ]
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw PlanError(message: "vision provider returned HTTP \(response.statusCode)")
        }
        guard let text = Self.responseText(from: data) else {
            throw PlanError(message: "vision provider returned no planner text")
        }
        return text
    }

    static func responseText(from data: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = payload["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }
}
