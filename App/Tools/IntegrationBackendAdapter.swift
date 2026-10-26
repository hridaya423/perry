import Foundation
import PerryBrain

/// `IntegrationBackend` over the app's OAuth integration stack. Reads map to
/// each definition's curated quick actions; writes map to the typed
/// `RemoteIntegrationWriteParameters` set. `integrations.write` is orange at
/// the host, so by the time `perform` sees a write the intent card already
/// ran — the `RemoteIntegrationApproval` minted here is the credential-layer
/// record of that approval (the client's `matches` requires it).
private struct IntegrationBackendError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct AppIntegrationBackend: IntegrationBackend {
    let client: RemoteIntegrationClient
    let oauth: OAuthCoordinator
    let permissionStore: RemoteIntegrationPermissionStore
    var calendar = SystemCalendar()

    func services() async throws -> [IntegrationService] {
        var result: [IntegrationService] = []
        for definition in RemoteIntegrationDefinition.catalog {
            let connected = (try? await oauth.hasCredential(for: definition)) ?? false
            var operations = definition.quickActions.map {
                IntegrationOperation(name: $0.id, description: $0.title, isWrite: false)
            }
            for operation in RemoteIntegrationWriteOperation.allCases where operation.providerID == definition.id {
                operations.append(IntegrationOperation(
                    name: operation.rawValue,
                    description: "Write: \(operation.rawValue)",
                    isWrite: true
                ))
            }
            result.append(IntegrationService(
                id: definition.id,
                name: definition.displayName,
                connected: connected,
                writeEnabled: permissionStore.writesEnabled(for: definition),
                operations: operations
            ))
        }
        result.append(IntegrationService(
            id: Self.calendarServiceID,
            name: "Calendar (this Mac)",
            connected: calendar.state == .granted,
            writeEnabled: false,
            operations: [IntegrationOperation(name: "upcoming", description: "Read upcoming events", isWrite: false)]
        ))
        return result
    }

    private static let calendarServiceID = "apple-calendar"

    func perform(service: String, operation: String, arguments: JSONValue) async throws -> JSONValue {
        if service == Self.calendarServiceID {
            guard operation == "upcoming" else {
                throw IntegrationBackendError("integrations: \(service) has no operation \"\(operation)\"")
            }
            let days = arguments["days"]?.doubleValue.map { Int(min(max($0, 1), 14)) } ?? 7
            return .object(["summary": .string(try calendar.upcoming(days: days))])
        }
        guard let definition = RemoteIntegrationDefinition.catalog.first(where: { $0.id == service }) else {
            throw IntegrationBackendError("integrations: unknown service \"\(service)\"")
        }
        if let action = definition.quickActions.first(where: { $0.id == operation }) {
            return .object(["summary": .string(try await read(definition: definition, action: action, arguments: arguments))])
        }
        if let writeOperation = RemoteIntegrationWriteOperation(rawValue: operation) {
            return .object(["summary": .string(try await write(definition: definition, operation: writeOperation, arguments: arguments))])
        }
        throw IntegrationBackendError("integrations: \(service) has no operation \"\(operation)\"")
    }

    private func read(
        definition: RemoteIntegrationDefinition,
        action: RemoteIntegrationQuickAction,
        arguments: JSONValue
    ) async throws -> String {
        // Notion search takes a query; every other quick action is a fixed
        // read — extra arguments are ignored rather than merged into a body
        // the provider hasn't vetted.
        var action = action
        if definition.id == "notion", action.id == "search",
           let query = arguments["query"]?.stringValue, !query.isEmpty {
            action = RemoteIntegrationQuickAction(
                id: action.id, title: action.title, method: action.method,
                path: action.path, body: #"{"query":""# + Self.jsonEscaped(query) + #","page_size":10}"#,
                readOnly: action.readOnly
            )
        }
        return try await client.preview(definition: definition, action: action)
    }

    private func write(
        definition: RemoteIntegrationDefinition,
        operation: RemoteIntegrationWriteOperation,
        arguments: JSONValue
    ) async throws -> String {
        func arg(_ key: String) throws -> String {
            guard let value = arguments[key]?.stringValue, !value.isEmpty else {
                throw IntegrationBackendError("integrations.write: missing \"\(key)\"")
            }
            return value
        }
        let parameters: RemoteIntegrationWriteParameters
        switch operation {
        case .notionCreatePage: parameters = .notionCreatePage(parentID: try arg("parentID"), title: try arg("title"))
        case .notionUpdatePage: parameters = .notionUpdatePage(pageID: try arg("pageID"), title: try arg("title"))
        case .notionAppendBlock: parameters = .notionAppendBlock(blockID: try arg("blockID"), text: try arg("text"))
        case .slackSendMessage: parameters = .slackSendMessage(channel: try arg("channel"), text: try arg("text"))
        case .linearUpdateIssue: parameters = .linearUpdateIssue(issueID: try arg("issueID"), title: try arg("title"))
        }
        guard let request = RemoteIntegrationWriteRequest(parameters: parameters) else {
            throw IntegrationBackendError("integrations.write: malformed arguments for \(operation.rawValue)")
        }
        // stepID needs only be non-empty — the user-facing approval already
        // happened in the host's intent card for this orange-tier call.
        let approval = RemoteIntegrationApproval(
            stepID: UUID().uuidString,
            integrationID: definition.id,
            operation: operation,
            tier: .orange,
            approvedScopes: request.requiredScopes,
            request: request
        )
        let data = try await client.request(definition: definition, write: request, approval: approval)
        return await client.summarizedResponse(for: definition, data: data)
    }

    private static func jsonEscaped(_ string: String) -> String {
        (try? JSONSerialization.data(withJSONObject: ["v": string]))
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { $0.dropFirst(6).dropLast(1) }  // {"v":"…"} → …
            .map(String.init) ?? ""
    }
}
