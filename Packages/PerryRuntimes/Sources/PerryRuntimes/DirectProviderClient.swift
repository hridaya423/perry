import Foundation
import PerryCore

/// Shared direct-to-provider client used by every feature that talks to an
/// LLM from the device: typed task planning (DirectProviderRuntime) and Guide
/// step planning (RuntimeGuidePlanner). One adapter set — OpenAI, Anthropic,
/// Gemini, OpenRouter, and safe custom endpoints — so no feature grows its
/// own HTTP copy. Keys come from the caller; calls go device → provider
/// directly through the injected transport.
public struct DirectProviderClient: Sendable {
    public let configuration: DirectProviderConfiguration

    private let apiKeyProvider: @Sendable () -> String?
    private let transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public init(
        configuration: DirectProviderConfiguration,
        apiKeyProvider: @escaping @Sendable () -> String?,
        transport: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil
    ) {
        self.configuration = configuration
        self.apiKeyProvider = apiKeyProvider
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw PlanError(message: "provider returned a non-HTTP response")
            }
            return (data, response)
        }
    }

    /// Sends one prompt (plus optional in-memory screenshot) and returns the
    /// provider's response text.
    public func complete(prompt: String, screenshot: (data: Data, mimeType: String)? = nil) async throws -> String {
        try requireConfiguration()
        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw PlanError(message: "\(configuration.provider.displayName) authentication is missing")
        }
        let request = try makeRequest(prompt: prompt, screenshot: screenshot, apiKey: apiKey)
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw PlanError(message: "\(configuration.provider.displayName) returned HTTP \(response.statusCode)")
        }
        guard let text = responseText(from: data) else {
            throw PlanError(message: "\(configuration.provider.displayName) returned no planner text")
        }
        return text
    }

    func makeRequest(prompt: String, screenshot: (data: Data, mimeType: String)?, apiKey: String) throws -> URLRequest {
        let image = screenshot?.data
        let mimeType = screenshot?.mimeType ?? "image/jpeg"
        switch configuration.provider {
        case .openAI, .openRouter:
            return try makeOpenAIRequest(prompt: prompt, image: image, mimeType: mimeType, apiKey: apiKey)
        case .anthropic:
            return try makeAnthropicRequest(prompt: prompt, image: image, mimeType: mimeType, apiKey: apiKey)
        case .gemini:
            return try makeGeminiRequest(prompt: prompt, image: image, mimeType: mimeType, apiKey: apiKey)
        }
    }

    func responseText(from data: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch configuration.provider {
        case .openAI, .openRouter:
            return BYOKAgentRuntime.responseText(from: data)
        case .anthropic:
            let content = payload["content"] as? [[String: Any]]
            return joinedText(content)
        case .gemini:
            let candidates = payload["candidates"] as? [[String: Any]]
            let content = candidates?.first?["content"] as? [String: Any]
            return joinedText(content?["parts"] as? [[String: Any]])
        }
    }

    private func requireConfiguration() throws {
        do {
            try NetworkEndpointPolicy.requireSafe(configuration.baseURL)
        } catch {
            throw PlanError(message: String(describing: error))
        }
        guard !configuration.model.isEmpty else {
            throw PlanError(message: "\(configuration.provider.displayName) model is missing")
        }
    }

    private func makeOpenAIRequest(prompt: String, image: Data?, mimeType: String, apiKey: String) throws -> URLRequest {
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        if let image {
            content.append(["type": "image_url", "image_url": ["url": dataURL(image, mimeType: mimeType)]])
        }
        let body: [String: Any] = [
            "model": configuration.model,
            "temperature": 0,
            "max_tokens": 768,
            "messages": [["role": "user", "content": content]],
        ]
        var request = request(path: "v1/chat/completions")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoded(body)
        return request
    }

    private func makeAnthropicRequest(prompt: String, image: Data?, mimeType: String, apiKey: String) throws -> URLRequest {
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        if let image {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": mimeType, "data": image.base64EncodedString()],
            ])
        }
        let body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": 768,
            "temperature": 0,
            "messages": [["role": "user", "content": content]],
        ]
        var request = request(path: "v1/messages")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try encoded(body)
        return request
    }

    private func makeGeminiRequest(prompt: String, image: Data?, mimeType: String, apiKey: String) throws -> URLRequest {
        var parts: [[String: Any]] = [["text": prompt]]
        if let image {
            parts.append(["inline_data": ["mime_type": mimeType, "data": image.base64EncodedString()]])
        }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["temperature": 0, "maxOutputTokens": 768, "responseMimeType": "application/json"],
        ]
        var request = request(path: "v1beta/models/\(configuration.model):generateContent")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try encoded(body)
        return request
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func encoded(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func dataURL(_ data: Data, mimeType: String) -> String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    private func joinedText(_ parts: [[String: Any]]?) -> String? {
        let text = parts?.compactMap { $0["text"] as? String }.joined()
        return text?.isEmpty == false ? text : nil
    }
}
