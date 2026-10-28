import Foundation
import PerryBrain

struct LocalEngineProvider: ModelProvider {
    let id: ProviderID
    let displayName: String
    let capabilities: ModelCapabilities = [.tools, .vision, .streaming, .local]
    let endpoint: @Sendable () async throws -> LocalEngine.Endpoint

    init(rung: ModelRung, endpoint: @escaping @Sendable () async throws -> LocalEngine.Endpoint) {
        id = ProviderID(rawValue: "local.perry.\(rung.id)")
        displayName = "\(LocalModelList.modelName(rung)) (on this Mac)"
        self.endpoint = endpoint
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in try await server().stream(request) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func warm() async {
        _ = try? await endpoint()
    }

    func contextWindow(for tier: ModelTier) async throws -> Int? {
        LocalEngine.contextTokens
    }

    private func server() async throws -> OpenAIChatCompatibleProvider {
        let live = try await endpoint()
        return OpenAIChatCompatibleProvider(
            id: id, displayName: displayName, baseURL: live.baseURL.deletingLastPathComponent(),
            apiKeyProvider: { live.apiKey }, models: BrainModelDefaults(fast: "local", deep: "local"),
            capabilities: capabilities
        )
    }
}
