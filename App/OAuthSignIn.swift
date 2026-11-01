import AppKit
import AuthenticationServices
import Foundation
import PerryBrain

typealias OAuthTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

enum OAuthRedirectKind: Equatable, Sendable {
    case customScheme
    case loopback
    case deviceFlow
}

enum OAuthRevocation: Equatable, Sendable {
    case tokenForm(URL, sendsTypeHint: Bool)
    case bearerHeader(URL)
    case basicJSON(URL)

    var url: URL {
        switch self {
        case .tokenForm(let url, _), .bearerHeader(let url), .basicJSON(let url):
            return url
        }
    }
}

struct BundledClientKeys: Equatable, Sendable {
    let clientIDKey: String
    let clientSecretKey: String?
}

struct OAuthClientCredentials: Equatable, Sendable {
    let clientID: String
    let clientSecret: String?
}

struct DeviceCodePrompt: Equatable, Sendable {
    let userCode: String
    let verificationURL: URL
}

struct BundledOAuthClients: Sendable {
    private let values: [String: String]

    init(infoDictionary: [String: Any]?) {
        values = (infoDictionary ?? [:]).compactMapValues { $0 as? String }
    }

    static let main = BundledOAuthClients(infoDictionary: Bundle.main.infoDictionary)

    func client(for definition: RemoteIntegrationDefinition) -> OAuthClientCredentials? {
        guard let keys = definition.bundledClientKeys,
              let clientID = value(keys.clientIDKey) else { return nil }
        return OAuthClientCredentials(clientID: clientID, clientSecret: keys.clientSecretKey.flatMap(value))
    }

    private func value(_ key: String) -> String? {
        guard let raw = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              !raw.hasPrefix("$(") else { return nil }
        return raw
    }
}

@MainActor
final class WebAuthenticationSessionUserAgent: NSObject, MCPAuthorizationUserAgent, ASWebAuthenticationPresentationContextProviding {
    private let redirectURI: URL
    private var session: ASWebAuthenticationSession?

    init(redirectURI: URL) {
        self.redirectURI = redirectURI
        super.init()
    }

    func authorize(_ makeAuthorizationURL: @Sendable (URL) async throws -> URL) async throws -> URL {
        let url = try await makeAuthorizationURL(redirectURI)
        guard !Task.isCancelled else { throw OAuthError.cancelled }
        defer { session = nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = makeSession(url: url) { callbackURL, error in
                    if let error {
                        continuation.resume(throwing: WebAuthenticationSessionUserAgent.normalized(error))
                    } else if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else {
                        continuation.resume(throwing: OAuthError.cancelled)
                    }
                }
                self.session = session
                if Task.isCancelled || !session.start() {
                    continuation.resume(throwing: OAuthError.cancelled)
                }
            }
        } onCancel: {
            Task { @MainActor in self.session?.cancel() }
        }
    }

    nonisolated static func normalized(_ error: Error) -> Error {
        (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin ? OAuthError.cancelled : error
    }

    func makeSession(
        url: URL,
        completion: @escaping ASWebAuthenticationSession.CompletionHandler
    ) -> ASWebAuthenticationSession {
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: redirectURI.scheme, completionHandler: completion)
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        return session
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow(
            contentRect: .zero,
            styleMask: [],
            backing: .buffered,
            defer: true
        )
    }
}
