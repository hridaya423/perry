import Foundation

public struct RouteRequirement: Sendable {
    public var capabilities: ModelCapabilities
    public var tier: ModelTier
    public var providerID: ProviderID?

    public init(capabilities: ModelCapabilities = [], tier: ModelTier = .fast, providerID: ProviderID? = nil) {
        self.capabilities = capabilities
        self.tier = tier
        self.providerID = providerID
    }
}

public struct RouteDecision: Sendable {
    public let provider: any ModelProvider
    public let explanation: String
}

public actor ProviderRouter {
    public static let fastOrder: [ProviderID] = [.openAI, .anthropic, .gemini, .openRouter, .local, .apple, .codex]
    public static let deepOrder: [ProviderID] = [.codex, .openAI, .anthropic, .gemini, .openRouter, .local, .apple]

    private let providers: [any ModelProvider]
    private let preference: [ProviderID]
    private let clock: @Sendable () -> Date
    private var failures: [ProviderID: (count: Int, unhealthyUntil: Date?)] = [:]

    public init(
        providers: [any ModelProvider],
        preference: [ProviderID] = [],
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.providers = providers
        self.preference = preference
        self.clock = clock
    }

    public func route(_ requirement: RouteRequirement) throws -> RouteDecision {
        let now = clock()
        let order = requirement.providerID.map { [$0] } ?? Self.order(preference: preference, tier: requirement.tier)
        var skipped: [String] = []
        var chosen: (any ModelProvider)?
        for entry in order {
            for provider in providers where Self.matches(entry, provider.id) {
                if !provider.capabilities.isSuperset(of: requirement.capabilities) {
                    if chosen == nil { skipped.append(provider.id.rawValue) }
                    continue
                }
                if let state = failures[provider.id], state.count >= 2,
                   let until = state.unhealthyUntil, until > now {
                    if chosen == nil { skipped.append("\(provider.id.rawValue)(down)") }
                    continue
                }
                chosen = provider
                break
            }
            if chosen != nil { break }
        }
        guard let provider = chosen else {
            let message = requirement.capabilities.contains(.local)
                ? "No on-device model supports this request. Set up a compatible model in Settings, then try again. No remote model was used."
                : "The selected model is unavailable or cannot handle this request. Check its connection and capabilities in Settings."
            throw ModelProviderError(kind: .notConfigured, provider: "router", message: message)
        }
        let explanation: String
        if skipped.isEmpty {
            explanation = "\(provider.displayName)"
        } else {
            explanation = String("\(provider.displayName) — skipped \(skipped.joined(separator: ", "))".prefix(80))
        }
        return RouteDecision(provider: HealthReportingProvider(base: provider, router: self), explanation: explanation)
    }

    public func reportFailure(_ id: ProviderID) {
        let state = failures[id] ?? (count: 0, unhealthyUntil: nil)
        let count = state.count + 1
        failures[id] = (
            count: count,
            unhealthyUntil: count >= 2 ? clock().addingTimeInterval(60) : nil
        )
    }

    public func reportSuccess(_ id: ProviderID) {
        failures.removeValue(forKey: id)
    }

    public func isHealthy(_ id: ProviderID) -> Bool {
        guard let state = failures[id], state.count >= 2,
              let until = state.unhealthyUntil else { return true }
        return until <= clock()
    }

    static func order(preference: [ProviderID], tier: ModelTier) -> [ProviderID] {
        var order: [ProviderID] = []
        var seen = Set<ProviderID>()
        for id in preference + (tier == .fast ? fastOrder : deepOrder) where !seen.contains(id) {
            seen.insert(id)
            order.append(id)
        }
        return order
    }

    static func matches(_ entry: ProviderID, _ providerID: ProviderID) -> Bool {
        providerID == entry || providerID.rawValue.hasPrefix(entry.rawValue + ".")
    }
}

private struct HealthReportingProvider: ProviderDecorator {
    let base: any ModelProvider
    let router: ProviderRouter

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        HealthReportingStream.wrap(base.stream(request), providerID: id, router: router)
    }

    func stream(_ request: ModelRequest, executeTool: @escaping ToolExecutionHandler) -> AsyncThrowingStream<ModelEvent, Error> {
        HealthReportingStream.wrap(base.stream(request, executeTool: executeTool), providerID: id, router: router)
    }
}

private enum HealthReportingStream {
    static func wrap(
        _ base: AsyncThrowingStream<ModelEvent, Error>,
        providerID: ProviderID,
        router: ProviderRouter
    ) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var finished = false
                do {
                    for try await event in base {
                        if case .done = event { finished = true }
                        continuation.yield(event)
                    }
                    // Cancelling the consumer ends the base iteration with
                    // nil rather than an error — a user-cancelled turn is not
                    // a provider health signal.
                    if finished {
                        await router.reportSuccess(providerID)
                    } else if !Task.isCancelled {
                        await router.reportFailure(providerID)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    await router.reportFailure(providerID)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
