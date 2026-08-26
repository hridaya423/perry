import Foundation
import PerryCore

public protocol AgentRuntime: Sendable {
    var id: String { get }
    var capabilities: RuntimeCapabilities { get }
    func plan(goal: String, context: ScreenContext) async throws -> Plan
    func execute(_ step: Step, consent: ConsentHandle?) async throws -> StepResult
}

public struct CLIUnavailableError: Error, CustomStringConvertible {
    public let searchedPaths: [String]

    public init(searchedPaths: [String]) {
        self.searchedPaths = searchedPaths
    }

    public var description: String {
        "no coding-agent CLI found. Searched:\n" + searchedPaths.map { "  \($0)" }.joined(separator: "\n")
    }
}
