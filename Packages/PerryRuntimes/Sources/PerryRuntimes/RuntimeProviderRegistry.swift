import Foundation

public enum RuntimeCapability: String, CaseIterable, Codable, Hashable, Sendable {
    case guiGrounding
    case fileIO
    case browser
    case remoteIntegrations
}

public enum RuntimeOperation: String, CaseIterable, Codable, Hashable, Sendable {
    case planning
    case execution
}

extension RuntimeCapabilities: Equatable {
    public static func == (left: RuntimeCapabilities, right: RuntimeCapabilities) -> Bool {
        left.guiGrounding == right.guiGrounding
            && left.fileIO == right.fileIO
            && left.browser == right.browser
            && left.remoteIntegrations == right.remoteIntegrations
            && left.latencyClass == right.latencyClass
    }
}

extension RuntimeCapabilities {
    public var capabilitySet: Set<RuntimeCapability> {
        Set(RuntimeCapability.allCases.filter(supports))
    }

    public func supports(_ capability: RuntimeCapability) -> Bool {
        switch capability {
        case .guiGrounding:
            return guiGrounding
        case .fileIO:
            return fileIO
        case .browser:
            return browser
        case .remoteIntegrations:
            return remoteIntegrations
        }
    }
}

public struct RuntimeCapabilityRequirements: Equatable, Sendable {
    public let required: Set<RuntimeCapability>

    public init(_ required: Set<RuntimeCapability> = []) {
        self.required = required
    }

    public init(_ capabilities: RuntimeCapabilities) {
        self.required = capabilities.capabilitySet
    }

    public init(
        guiGrounding: Bool = false,
        fileIO: Bool = false,
        browser: Bool = false,
        remoteIntegrations: Bool = false
    ) {
        var required = Set<RuntimeCapability>()
        if guiGrounding { required.insert(.guiGrounding) }
        if fileIO { required.insert(.fileIO) }
        if browser { required.insert(.browser) }
        if remoteIntegrations { required.insert(.remoteIntegrations) }
        self.required = required
    }

    public static let none = RuntimeCapabilityRequirements()

    public var requiredCapabilities: Set<RuntimeCapability> { required }

    public var isEmpty: Bool { required.isEmpty }

    public func isSatisfied(by capabilities: RuntimeCapabilities) -> Bool {
        required.allSatisfy(capabilities.supports)
    }

    public func missing(from capabilities: RuntimeCapabilities) -> [RuntimeCapability] {
        required.filter { !capabilities.supports($0) }.sorted { $0.rawValue < $1.rawValue }
    }
}

public struct RuntimeProviderID: RawRepresentable, Codable, Equatable, Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init?(rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        self.rawValue = normalized
    }

    public init(_ rawValue: String) {
        guard let value = RuntimeProviderID(rawValue: rawValue) else {
            preconditionFailure("runtime provider ID must not be empty")
        }
        self = value
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String { rawValue }
}

public enum RuntimeProviderKind: String, Codable, CaseIterable, Equatable, Sendable {
    case local
    case cli
    case cloud
    case byok
    case scripted
    case custom
}

public enum RuntimeInstallationSource: String, Codable, CaseIterable, Equatable, Sendable {
    case bundled
    case officialCLI
    case directAPI
    case local
    case customEndpoint
}

public struct RuntimeInstallationIdentity: Equatable, Sendable {
    public let source: RuntimeInstallationSource
    public let version: String?
    public let executablePath: String?
    public let artifactSHA256: String?

    public init(
        source: RuntimeInstallationSource,
        version: String? = nil,
        executablePath: String? = nil,
        artifactSHA256: String? = nil
    ) {
        self.source = source
        self.version = version
        self.executablePath = executablePath
        self.artifactSHA256 = artifactSHA256
    }
}

public enum RuntimeInstallationStatus: Equatable, Sendable {
    case notApplicable(RuntimeInstallationSource)
    case verified(RuntimeInstallationIdentity)
    case unverified(reason: String)

    public var isUsable: Bool {
        switch self {
        case .notApplicable, .verified:
            return true
        case .unverified:
            return false
        }
    }

    public var explanation: String {
        switch self {
        case .notApplicable(let source):
            return "installation verification is not applicable to \(source.rawValue)"
        case .verified:
            return "installation identity is verified"
        case .unverified(let reason):
            return reason.isEmpty ? "installation identity is unverified" : "installation identity is unverified: \(reason)"
        }
    }
}

public struct RuntimeProviderIdentity: Codable, Equatable, Sendable {
    public let id: RuntimeProviderID
    public let displayName: String
    public let kind: RuntimeProviderKind

    public init(
        id: RuntimeProviderID,
        displayName: String? = nil,
        kind: RuntimeProviderKind = .custom
    ) {
        self.id = id
        let normalizedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.displayName = normalizedName.isEmpty ? id.rawValue : normalizedName
        self.kind = kind
    }

    public init(
        id: String,
        displayName: String? = nil,
        kind: RuntimeProviderKind = .custom
    ) {
        self.init(id: RuntimeProviderID(id), displayName: displayName, kind: kind)
    }

    public var name: String { displayName }
}

public enum RuntimeAuthenticationStatus: Equatable, Sendable {
    case notRequired
    case configured
    case authenticated
    case missing
    case invalid(reason: String)
    case unknown(reason: String)

    public var isUsable: Bool {
        switch self {
        case .notRequired, .configured, .authenticated:
            return true
        case .missing, .invalid, .unknown:
            return false
        }
    }

    public var explanation: String {
        switch self {
        case .notRequired:
            return "authentication is not required"
        case .configured:
            return "credential is configured but has not been verified by the provider"
        case .authenticated:
            return "authenticated"
        case .missing:
            return "authentication is missing"
        case .invalid(let reason):
            return reason.isEmpty ? "authentication is invalid" : "authentication is invalid: \(reason)"
        case .unknown(let reason):
            return reason.isEmpty ? "authentication status is unknown" : "authentication status is unknown: \(reason)"
        }
    }

}

public typealias RuntimeAuthentication = RuntimeAuthenticationStatus

public enum RuntimeHealthStatus: Equatable, Sendable {
    case healthy
    case degraded(reason: String)
    case unavailable(reason: String)
    case unknown(reason: String)

    public var selectionRank: Int {
        switch self {
        case .healthy:
            return 0
        case .degraded:
            return 1
        case .unavailable, .unknown:
            return 2
        }
    }

    public var explanation: String {
        switch self {
        case .healthy:
            return "healthy"
        case .degraded(let reason):
            return reason.isEmpty ? "health is degraded" : "health is degraded: \(reason)"
        case .unavailable(let reason):
            return reason.isEmpty ? "health is unavailable" : "health is unavailable: \(reason)"
        case .unknown(let reason):
            return reason.isEmpty ? "health status is unknown" : "health status is unknown: \(reason)"
        }
    }

}

public typealias RuntimeHealth = RuntimeHealthStatus

public enum RuntimeConfinement: String, Codable, CaseIterable, Equatable, Sendable {
    case unconfined
    case readOnly
    case workspace

    public func satisfies(_ requirement: RuntimeConfinementRequirement) -> Bool {
        switch requirement {
        case .any:
            return true
        case .bounded:
            return self != .unconfined
        case .readOnly:
            return self == .readOnly
        case .workspace:
            return self == .workspace
        }
    }
}

public enum RuntimeConfinementRequirement: String, Codable, CaseIterable, Equatable, Sendable {
    case any
    case bounded
    case readOnly
    case workspace

}

public struct RuntimeLatencyMeasurement: Codable, Equatable, Sendable {
    public let milliseconds: Double
    public let sampleCount: Int
    public let measuredAt: Date

    public init(
        milliseconds: Double,
        sampleCount: Int = 1,
        measuredAt: Date = Date()
    ) {
        precondition(milliseconds.isFinite && milliseconds >= 0)
        precondition(sampleCount > 0)
        self.milliseconds = milliseconds
        self.sampleCount = sampleCount
        self.measuredAt = measuredAt
    }

    public var duration: TimeInterval { milliseconds / 1_000 }
}

public typealias MeasuredLatency = RuntimeLatencyMeasurement

public struct RuntimeProviderDescriptor: Equatable, Sendable {
    public let identity: RuntimeProviderIdentity
    public let capabilities: RuntimeCapabilities
    public let operations: Set<RuntimeOperation>
    public let installation: RuntimeInstallationStatus
    public let authentication: RuntimeAuthenticationStatus
    public let health: RuntimeHealthStatus
    public let confinement: RuntimeConfinement
    public let measuredLatency: RuntimeLatencyMeasurement?
    public let priority: Int

    public var id: RuntimeProviderID { identity.id }
    public var displayName: String { identity.displayName }

    public init(
        identity: RuntimeProviderIdentity,
        capabilities: RuntimeCapabilities,
        operations: Set<RuntimeOperation> = [.planning, .execution],
        installation: RuntimeInstallationStatus,
        authentication: RuntimeAuthenticationStatus = .notRequired,
        health: RuntimeHealthStatus = .healthy,
        confinement: RuntimeConfinement = .unconfined,
        measuredLatency: RuntimeLatencyMeasurement? = nil,
        priority: Int = 0
    ) {
        self.identity = identity
        self.capabilities = capabilities
        self.operations = operations
        self.installation = installation
        self.authentication = authentication
        self.health = health
        self.confinement = confinement
        self.measuredLatency = measuredLatency
        self.priority = priority
    }

    public init(
        id: RuntimeProviderID,
        displayName: String? = nil,
        kind: RuntimeProviderKind = .custom,
        capabilities: RuntimeCapabilities,
        operations: Set<RuntimeOperation> = [.planning, .execution],
        installation: RuntimeInstallationStatus,
        authentication: RuntimeAuthenticationStatus = .notRequired,
        health: RuntimeHealthStatus = .healthy,
        confinement: RuntimeConfinement = .unconfined,
        measuredLatency: RuntimeLatencyMeasurement? = nil,
        priority: Int = 0
    ) {
        self.init(
            identity: RuntimeProviderIdentity(id: id, displayName: displayName, kind: kind),
            capabilities: capabilities,
            operations: operations,
            installation: installation,
            authentication: authentication,
            health: health,
            confinement: confinement,
            measuredLatency: measuredLatency,
            priority: priority
        )
    }

    public init(
        id: String,
        displayName: String? = nil,
        kind: RuntimeProviderKind = .custom,
        capabilities: RuntimeCapabilities,
        operations: Set<RuntimeOperation> = [.planning, .execution],
        installation: RuntimeInstallationStatus,
        authentication: RuntimeAuthenticationStatus = .notRequired,
        health: RuntimeHealthStatus = .healthy,
        confinement: RuntimeConfinement = .unconfined,
        measuredLatency: RuntimeLatencyMeasurement? = nil,
        priority: Int = 0
    ) {
        self.init(
            id: RuntimeProviderID(id),
            displayName: displayName,
            kind: kind,
            capabilities: capabilities,
            operations: operations,
            installation: installation,
            authentication: authentication,
            health: health,
            confinement: confinement,
            measuredLatency: measuredLatency,
            priority: priority
        )
    }

}

public struct RuntimeProvider: Sendable {
    public let descriptor: RuntimeProviderDescriptor
    public let planner: any TaskPlanner

    public init(
        planner: any TaskPlanner,
        descriptor: RuntimeProviderDescriptor
    ) {
        self.planner = planner
        self.descriptor = descriptor
    }

    public var id: RuntimeProviderID { descriptor.id }

    public func plan(_ request: PlanningRequest) async throws -> ExecutionPlan {
        guard descriptor.operations.contains(.planning) else {
            throw PlanError(message: "runtime provider does not support planning")
        }
        try Task.checkCancellation()
        let plan = try await planner.plan(request)
        try Task.checkCancellation()
        guard plan.taskID == request.taskID else {
            throw PlanningError.typedPlanRejected("task ID does not match the planning request")
        }
        guard plan.goal == request.goal else {
            throw PlanningError.typedPlanRejected("goal does not match the planning request")
        }
        for action in plan.actions {
            switch action.operation {
            case .shell(let workspace, _, _, _), .transform(let workspace, _):
                guard request.matchesWorkspace(workspace) else {
                    throw PlanningError.typedPlanRejected("workspace does not match the planning request")
                }
            case .computer, .integration, .askUser:
                break
            }
        }
        return plan
    }
}

public struct RuntimeRouteRequest: Equatable, Sendable {
    public let requiredCapabilities: Set<RuntimeCapability>
    public let requiredOperations: Set<RuntimeOperation>
    public let preferredProviderID: RuntimeProviderID?
    public let requiredConfinement: RuntimeConfinementRequirement
    public let allowDegradedHealth: Bool
    public let maximumLatencyMilliseconds: Double?

    public init(
        requiredCapabilities: Set<RuntimeCapability> = [],
        requiredOperations: Set<RuntimeOperation> = [.planning],
        preferredProviderID: RuntimeProviderID? = nil,
        requiredConfinement: RuntimeConfinementRequirement = .any,
        allowDegradedHealth: Bool = true,
        maximumLatencyMilliseconds: Double? = nil
    ) {
        if let maximumLatencyMilliseconds {
            precondition(maximumLatencyMilliseconds.isFinite && maximumLatencyMilliseconds >= 0)
        }
        self.requiredCapabilities = requiredCapabilities
        self.requiredOperations = requiredOperations
        self.preferredProviderID = preferredProviderID
        self.requiredConfinement = requiredConfinement
        self.allowDegradedHealth = allowDegradedHealth
        self.maximumLatencyMilliseconds = maximumLatencyMilliseconds
    }

    public init(
        requiredCapabilities: RuntimeCapabilityRequirements,
        requiredOperations: Set<RuntimeOperation> = [.planning],
        preferredProviderID: RuntimeProviderID? = nil,
        requiredConfinement: RuntimeConfinementRequirement = .any,
        allowDegradedHealth: Bool = true,
        maximumLatencyMilliseconds: Double? = nil
    ) {
        self.init(
            requiredCapabilities: requiredCapabilities.required,
            requiredOperations: requiredOperations,
            preferredProviderID: preferredProviderID,
            requiredConfinement: requiredConfinement,
            allowDegradedHealth: allowDegradedHealth,
            maximumLatencyMilliseconds: maximumLatencyMilliseconds
        )
    }

    public var capabilityRequirements: RuntimeCapabilityRequirements {
        RuntimeCapabilityRequirements(requiredCapabilities)
    }

    public var confinement: RuntimeConfinementRequirement { requiredConfinement }
}

public struct RuntimeProviderRejection: Equatable, Sendable {
    public let providerID: RuntimeProviderID
    public let reason: String

    public init(providerID: RuntimeProviderID, reason: String) {
        self.providerID = providerID
        self.reason = reason
    }
}

public enum RuntimeRouteFallback: Equatable, Sendable, CustomStringConvertible {
    case preferredProviderNotRegistered(RuntimeProviderID)
    case preferredProviderRejected(RuntimeProviderID, reason: String)

    public var description: String {
        switch self {
        case .preferredProviderNotRegistered(let providerID):
            return "preferred provider \(providerID) is not registered"
        case .preferredProviderRejected(let providerID, let reason):
            return "preferred provider \(providerID) was not eligible: \(reason)"
        }
    }
}

public struct RuntimeRouteExplanation: Equatable, Sendable {
    public let selectedProviderID: RuntimeProviderID?
    public let preferredProviderID: RuntimeProviderID?
    public let fallback: RuntimeRouteFallback?
    public let rejectedProviders: [RuntimeProviderRejection]

    public init(
        selectedProviderID: RuntimeProviderID?,
        preferredProviderID: RuntimeProviderID?,
        fallback: RuntimeRouteFallback?,
        rejectedProviders: [RuntimeProviderRejection]
    ) {
        self.selectedProviderID = selectedProviderID
        self.preferredProviderID = preferredProviderID
        self.fallback = fallback
        self.rejectedProviders = rejectedProviders
    }

    public var fallbackReason: String? { fallback?.description }

    public var reason: String {
        if let fallback {
            if let selectedProviderID {
                return "\(fallback.description); selected \(selectedProviderID) as fallback"
            }
            return "\(fallback.description); no eligible fallback provider"
        }
        if let selectedProviderID {
            return "selected provider \(selectedProviderID)"
        }
        return "no registered provider satisfies the request"
    }

    public var summary: String { reason }
}

public struct RuntimeRouteDecision: Sendable {
    public let provider: RuntimeProvider
    public let explanation: RuntimeRouteExplanation

    public var providerID: RuntimeProviderID { provider.id }
    public var descriptor: RuntimeProviderDescriptor { provider.descriptor }
    public var fallbackReason: String? { explanation.fallbackReason }
    public var usedFallback: Bool { explanation.fallback != nil }
    public var reason: String { explanation.reason }
}

public enum RuntimeRouteResult: Sendable {
    case selected(RuntimeRouteDecision)
    case unavailable(RuntimeRouteExplanation)

    public var decision: RuntimeRouteDecision? {
        guard case .selected(let decision) = self else { return nil }
        return decision
    }

    public var explanation: RuntimeRouteExplanation {
        switch self {
        case .selected(let decision):
            return decision.explanation
        case .unavailable(let explanation):
            return explanation
        }
    }
}

public struct RuntimeProviderRegistry: Sendable {
    public typealias Provider = RuntimeProvider
    public typealias Descriptor = RuntimeProviderDescriptor
    public typealias Request = RuntimeRouteRequest
    public typealias Decision = RuntimeRouteDecision

    private var registeredProviders: [RuntimeProvider]

    public init(providers: [RuntimeProvider] = []) {
        self.registeredProviders = []
        for provider in providers {
            register(provider)
        }
    }

    public var providers: [RuntimeProvider] { registeredProviders }
    public var count: Int { registeredProviders.count }

    public mutating func register(_ provider: RuntimeProvider) {
        if let index = registeredProviders.firstIndex(where: { $0.id == provider.id }) {
            registeredProviders[index] = provider
        } else {
            registeredProviders.append(provider)
        }
    }

    public func provider(for providerID: RuntimeProviderID) -> RuntimeProvider? {
        registeredProviders.first { $0.id == providerID }
    }

    public func provider(for providerID: String) -> RuntimeProvider? {
        guard let providerID = RuntimeProviderID(rawValue: providerID) else { return nil }
        return provider(for: providerID)
    }

    @discardableResult
    public mutating func remove(providerID: RuntimeProviderID) -> RuntimeProvider? {
        guard let index = registeredProviders.firstIndex(where: { $0.id == providerID }) else { return nil }
        return registeredProviders.remove(at: index)
    }

    @discardableResult
    public mutating func recordLatency(
        for providerID: RuntimeProviderID,
        milliseconds: Double,
        measuredAt: Date = Date()
    ) -> Bool {
        guard let index = registeredProviders.firstIndex(where: { $0.id == providerID }) else { return false }
        let provider = registeredProviders[index]
        let measurement = RuntimeLatencyMeasurement(milliseconds: milliseconds, measuredAt: measuredAt)
        let descriptor = provider.descriptor
        let updatedDescriptor = RuntimeProviderDescriptor(
            identity: descriptor.identity,
            capabilities: descriptor.capabilities,
            operations: descriptor.operations,
            installation: descriptor.installation,
            authentication: descriptor.authentication,
            health: descriptor.health,
            confinement: descriptor.confinement,
            measuredLatency: measurement,
            priority: descriptor.priority
        )
        registeredProviders[index] = RuntimeProvider(
            planner: provider.planner,
            descriptor: updatedDescriptor
        )
        return true
    }

    @discardableResult
    public mutating func recordLatency(
        for providerID: String,
        milliseconds: Double,
        measuredAt: Date = Date()
    ) -> Bool {
        guard let providerID = RuntimeProviderID(rawValue: providerID) else { return false }
        return recordLatency(for: providerID, milliseconds: milliseconds, measuredAt: measuredAt)
    }

    @discardableResult
    public mutating func recordLatency(
        for providerID: RuntimeProviderID,
        duration: TimeInterval,
        measuredAt: Date = Date()
    ) -> Bool {
        recordLatency(for: providerID, milliseconds: duration * 1_000, measuredAt: measuredAt)
    }

    public func resolve(_ request: RuntimeRouteRequest) -> RuntimeRouteResult {
        let evaluations = evaluate(request)
        let eligible = evaluations.filter { $0.rejection == nil }
        let fallback = fallback(for: request, evaluations: evaluations)
        let selected = selectedProvider(for: request, eligible: eligible)
        let explanation = RuntimeRouteExplanation(
            selectedProviderID: selected?.provider.id,
            preferredProviderID: request.preferredProviderID,
            fallback: fallback,
            rejectedProviders: evaluations.compactMap(\.rejection)
        )
        guard let selected else { return .unavailable(explanation) }
        return .selected(RuntimeRouteDecision(provider: selected.provider, explanation: explanation))
    }

    public func route(for request: RuntimeRouteRequest) -> RuntimeRouteDecision? {
        resolve(request).decision
    }

    public func route(
        requiredCapabilities: Set<RuntimeCapability> = [],
        requiredOperations: Set<RuntimeOperation> = [.planning],
        preferredProviderID: RuntimeProviderID? = nil,
        requiredConfinement: RuntimeConfinementRequirement = .any,
        allowDegradedHealth: Bool = true,
        maximumLatencyMilliseconds: Double? = nil
    ) -> RuntimeRouteDecision? {
        route(
            for: RuntimeRouteRequest(
                requiredCapabilities: requiredCapabilities,
                requiredOperations: requiredOperations,
                preferredProviderID: preferredProviderID,
                requiredConfinement: requiredConfinement,
                allowDegradedHealth: allowDegradedHealth,
                maximumLatencyMilliseconds: maximumLatencyMilliseconds
            )
        )
    }

    public func explain(_ request: RuntimeRouteRequest) -> RuntimeRouteExplanation {
        resolve(request).explanation
    }

    private struct Evaluation {
        let provider: RuntimeProvider
        let rejection: RuntimeProviderRejection?
        let healthRank: Int
    }

    private func evaluate(_ request: RuntimeRouteRequest) -> [Evaluation] {
        registeredProviders.map { provider in
            let descriptor = provider.descriptor
            let missingCapabilities = request.capabilityRequirements.missing(from: descriptor.capabilities)
            let missingOperations = request.requiredOperations.subtracting(descriptor.operations)
            var reasons: [String] = []
            if !missingCapabilities.isEmpty {
                reasons.append("missing capabilities: \(missingCapabilities.map(\.rawValue).joined(separator: ", "))")
            }
            if !missingOperations.isEmpty {
                reasons.append("missing operations: \(missingOperations.map(\.rawValue).sorted().joined(separator: ", "))")
            }
            if !descriptor.authentication.isUsable {
                reasons.append(descriptor.authentication.explanation)
            }
            if !descriptor.installation.isUsable {
                reasons.append(descriptor.installation.explanation)
            }
            if !descriptor.confinement.satisfies(request.requiredConfinement) {
                reasons.append("requires \(request.requiredConfinement.rawValue) confinement, provider is \(descriptor.confinement.rawValue)")
            }
            switch descriptor.health {
            case .healthy:
                break
            case .degraded where request.allowDegradedHealth:
                break
            case .degraded, .unavailable, .unknown:
                reasons.append(descriptor.health.explanation)
            }
            if let maximum = request.maximumLatencyMilliseconds {
                if let measured = descriptor.measuredLatency {
                    if measured.milliseconds > maximum {
                        reasons.append("measured latency \(measured.milliseconds) ms exceeds \(maximum) ms limit")
                    }
                } else {
                    reasons.append("latency is not measured")
                }
            }
            let rejection = reasons.isEmpty
                ? nil
                : RuntimeProviderRejection(providerID: descriptor.id, reason: reasons.joined(separator: "; "))
            return Evaluation(provider: provider, rejection: rejection, healthRank: descriptor.health.selectionRank)
        }
    }

    private func fallback(
        for request: RuntimeRouteRequest,
        evaluations: [Evaluation]
    ) -> RuntimeRouteFallback? {
        guard let preferredProviderID = request.preferredProviderID else { return nil }
        guard let evaluation = evaluations.first(where: { $0.provider.id == preferredProviderID }) else {
            return .preferredProviderNotRegistered(preferredProviderID)
        }
        guard let rejection = evaluation.rejection else { return nil }
        return .preferredProviderRejected(preferredProviderID, reason: rejection.reason)
    }

    private func selectedProvider(
        for request: RuntimeRouteRequest,
        eligible: [Evaluation]
    ) -> Evaluation? {
        guard !eligible.isEmpty else { return nil }
        if let preferredProviderID = request.preferredProviderID,
           let preferred = eligible.first(where: { $0.provider.id == preferredProviderID }) {
            return preferred
        }
        return eligible.sorted(by: isPreferred).first
    }

    private func isPreferred(_ left: Evaluation, _ right: Evaluation) -> Bool {
        if left.healthRank != right.healthRank {
            return left.healthRank < right.healthRank
        }
        if left.provider.descriptor.priority != right.provider.descriptor.priority {
            return left.provider.descriptor.priority < right.provider.descriptor.priority
        }
        let leftLatency = left.provider.descriptor.measuredLatency?.milliseconds
        let rightLatency = right.provider.descriptor.measuredLatency?.milliseconds
        switch (leftLatency, rightLatency) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        let leftClass = latencyRank(left.provider.descriptor.capabilities.latencyClass)
        let rightClass = latencyRank(right.provider.descriptor.capabilities.latencyClass)
        if leftClass != rightClass {
            return leftClass < rightClass
        }
        return left.provider.id.rawValue < right.provider.id.rawValue
    }

    private func latencyRank(_ latencyClass: RuntimeCapabilities.LatencyClass) -> Int {
        switch latencyClass {
        case .fast:
            return 0
        case .medium:
            return 1
        case .slow:
            return 2
        }
    }
}
