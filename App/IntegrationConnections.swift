import Foundation

/// What Settings needs to connect, check, preview, and disconnect a remote
/// integration — and nothing else from the app.
@MainActor
final class IntegrationConnections {
    private let oauth: OAuthCoordinator
    private let client: RemoteIntegrationClient
    private let permissions: RemoteIntegrationPermissionStore

    init(oauth: OAuthCoordinator, client: RemoteIntegrationClient, permissions: RemoteIntegrationPermissionStore) {
        self.oauth = oauth
        self.client = client
        self.permissions = permissions
    }

    func isConnected(_ definition: RemoteIntegrationDefinition) async throws -> Bool {
        try await oauth.hasCredential(for: definition)
    }

    func connect(
        _ definition: RemoteIntegrationDefinition,
        clientID: String,
        clientSecret: String? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        oauth.authorize(
            definition: definition,
            configuration: OAuthConfiguration(
                clientID: clientID,
                clientSecret: clientSecret,
                scopes: definition.scopes
            )
        ) { result in
            completion(result.map { _ in () })
        }
    }

    func disconnect(_ definition: RemoteIntegrationDefinition) async throws {
        try await oauth.disconnect(definition)
        permissions.setWritesEnabled(false, for: definition)
    }

    func test(
        _ definition: RemoteIntegrationDefinition,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        Task { @MainActor in
            do {
                let summary = try await client.testConnection(definition: definition)
                completion(.success(summary))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func preview(
        _ definition: RemoteIntegrationDefinition,
        action: RemoteIntegrationQuickAction,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        Task { @MainActor in
            do {
                let summary = try await client.preview(definition: definition, action: action)
                completion(.success(summary))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
