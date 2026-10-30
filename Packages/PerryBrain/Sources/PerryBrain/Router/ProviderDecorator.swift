import Foundation

protocol ProviderDecorator: ModelProvider {
    var base: any ModelProvider { get }
}

extension ProviderDecorator {
    var id: ProviderID { base.id }
    var displayName: String { base.displayName }
    var capabilities: ModelCapabilities { base.capabilities }
    var executesTools: Bool { base.executesTools }

    func warm() async { await base.warm() }

    func contextWindow(for tier: ModelTier) async throws -> Int? {
        try await base.contextWindow(for: tier)
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        base.stream(request)
    }

    func stream(_ request: ModelRequest, executeTool: @escaping ToolExecutionHandler) -> AsyncThrowingStream<ModelEvent, Error> {
        base.stream(request, executeTool: executeTool)
    }
}
