import Foundation

@MainActor
final class IntegrationConnections {
    private let oauth: OAuthCoordinator
    private let client: RemoteIntegrationClient
    private let permissions: RemoteIntegrationPermissionStore
    private let bundled: BundledOAuthClients

    init(
        oauth: OAuthCoordinator,
        client: RemoteIntegrationClient,
        permissions: RemoteIntegrationPermissionStore,
        bundled: BundledOAuthClients = .main
    ) {
        self.oauth = oauth
        self.client = client
        self.permissions = permissions
        self.bundled = bundled
    }

    func isConnected(_ definition: RemoteIntegrationDefinition) async throws -> Bool {
        try await oauth.hasCredential(for: definition)
    }

    func hasBundledClient(_ definition: RemoteIntegrationDefinition) -> Bool {
        bundled.client(for: definition) != nil
    }

    func connect(
        _ definition: RemoteIntegrationDefinition,
        clientID: String = "",
        clientSecret: String? = nil,
        deviceCodePrompt: ((DeviceCodePrompt) -> Void)? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let own = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = own.isEmpty
            ? bundled.client(for: definition)
            : OAuthClientCredentials(clientID: own, clientSecret: clientSecret)
        authorize(definition, client: client, scopes: definition.scopes, deviceCodePrompt: deviceCodePrompt) { result in
            completion(result.map { _ in () })
        }
    }

    func cancel() {
        oauth.cancelAuthorization()
    }

    func setWrites(
        _ enabled: Bool,
        for definition: RemoteIntegrationDefinition,
        deviceCodePrompt: ((DeviceCodePrompt) -> Void)? = nil,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        guard enabled else {
            permissions.setWritesEnabled(false, for: definition)
            completion(.success(false))
            return
        }
        Task { @MainActor in
            do {
                let stored = try await oauth.storedCredential(for: definition)
                let missing = Set(definition.writeScopes).subtracting(stored?.grantedScopes ?? [])
                guard !missing.isEmpty else {
                    permissions.setWritesEnabled(true, for: definition)
                    completion(.success(true))
                    return
                }
                let client = stored.flatMap { $0.clientID.isEmpty ? nil : OAuthClientCredentials(clientID: $0.clientID, clientSecret: $0.clientSecret) }
                    ?? bundled.client(for: definition)
                authorize(
                    definition,
                    client: client,
                    scopes: definition.scopes + definition.writeScopes,
                    deviceCodePrompt: deviceCodePrompt
                ) { [permissions] result in
                    switch result {
                    case .success:
                        permissions.setWritesEnabled(true, for: definition)
                        completion(.success(true))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    @discardableResult
    func disconnect(_ definition: RemoteIntegrationDefinition) async throws -> Bool {
        let revoked = try await oauth.disconnect(definition)
        permissions.setWritesEnabled(false, for: definition)
        return revoked
    }

    private func authorize(
        _ definition: RemoteIntegrationDefinition,
        client: OAuthClientCredentials?,
        scopes: [String],
        deviceCodePrompt: ((DeviceCodePrompt) -> Void)?,
        completion: @escaping (Result<OAuthToken, Error>) -> Void
    ) {
        guard let client else {
            completion(.failure(OAuthError.invalidClient))
            return
        }
        oauth.authorize(
            definition: definition,
            configuration: OAuthConfiguration(
                clientID: client.clientID,
                clientSecret: client.clientSecret,
                scopes: scopes
            ),
            deviceCodePrompt: deviceCodePrompt,
            completion: completion
        )
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
