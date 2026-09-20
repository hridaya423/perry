import Foundation
import PerryRuntimes

struct ProductionRuntimeSelection {
    let provider: RuntimeProvider
    let explanation: RuntimeRouteExplanation

    var providerID: RuntimeProviderID { provider.id }
    var displayName: String { provider.descriptor.displayName }

    var routingSummary: String {
        guard let fallbackReason = explanation.fallbackReason else {
            return "Selected \(displayName)."
        }
        return "Selected \(displayName). \(fallbackReason)."
    }
}

struct ProductionRuntimeSelector {
    func select(
        from registry: RuntimeProviderRegistry,
        preferredProviderID: RuntimeProviderID? = nil,
        requiredCapabilities: Set<RuntimeCapability> = [],
        requiredOperations: Set<RuntimeOperation> = [.planning]
    ) -> ProductionRuntimeSelection? {
        let request = RuntimeRouteRequest(
            requiredCapabilities: requiredCapabilities,
            requiredOperations: requiredOperations,
            preferredProviderID: preferredProviderID,
            requiredConfinement: .bounded,
            allowDegradedHealth: false
        )
        guard case .selected(let decision) = registry.resolve(request) else { return nil }
        return ProductionRuntimeSelection(
            provider: decision.provider,
            explanation: decision.explanation
        )
    }
}
