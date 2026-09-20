import Foundation
import XCTest
import PerryCore
@testable import Perry

final class RemoteIntegrationPolicyTests: XCTestCase {
    func testDesktopOAuthPoliciesMatchProviderRequirements() {
        let slack = definition(id: "slack")
        let linear = definition(id: "linear")
        let google = definition(id: "google-workspace")

        XCTAssertEqual(slack.authorizationScopeParameter, "user_scope")
        XCTAssertEqual(slack.authorizationScopeSeparator, ",")
        XCTAssertFalse(slack.requiresClientSecret)
        XCTAssertEqual(linear.authorizationScopeSeparator, ",")
        XCTAssertEqual(google.authorizationScopeSeparator, " ")
        XCTAssertEqual(OAuthConfiguration.defaultRedirectURI.absoluteString, "dev.perry.perry:/oauth/callback")
    }

    func testReadOnlyRequestsCannotSmuggleMutationMethods() {
        let notion = definition(id: "notion")
        let linear = definition(id: "linear")

        XCTAssertFalse(notion.allowsRemoteRequest(path: "/v1/pages/123", method: "DELETE", body: nil, readOnlyRequest: true))
        XCTAssertTrue(notion.allowsRemoteRequest(path: "/v1/search", method: "POST", body: Data(#"{"page_size":10}"#.utf8), readOnlyRequest: true))
        XCTAssertFalse(notion.allowsRemoteRequest(path: "/v1/pages", method: "POST", body: Data(#"{"parent":{}}"#.utf8), readOnlyRequest: true))
        XCTAssertFalse(linear.allowsRemoteRequest(path: "/graphql", method: "POST", body: Data(#"{"query":"mutation { deleteIssue }"}"#.utf8), readOnlyRequest: true))
    }

    func testLinearUsesExplicitGraphQLOperationKinds() {
        let linear = definition(id: "linear")
        let queryWithMutationText = Data(#"{"query":"query { viewer(filter: \"mutation\") { id } }"}"#.utf8)
        let unknownOperation = Data(#"{"query":"persisted { viewer { id } }"}"#.utf8)
        let mutation = Data(#"{"query":"mutation { issueUpdate { success } }"}"#.utf8)

        XCTAssertTrue(linear.allowsRemoteRequest(path: "/graphql", method: "POST", body: queryWithMutationText, readOnlyRequest: true))
        XCTAssertFalse(linear.allowsRemoteRequest(path: "/graphql", method: "POST", body: unknownOperation, readOnlyRequest: true))
        XCTAssertTrue(linear.allowsRemoteRequest(path: "/graphql", method: "POST", body: mutation, readOnlyRequest: false))
    }

    func testUnknownProviderOperationsFailClosed() {
        let unknown = RemoteIntegrationDefinition(
            descriptor: IntegrationDescriptor(id: "future", displayName: "Future"),
            baseURL: URL(string: "https://future.example.com")!,
            authorizationURL: URL(string: "https://future.example.com/authorize")!,
            tokenURL: URL(string: "https://future.example.com/token")!,
            scopes: [],
            writesEnabledByDefault: false,
            oauthStyle: .pkce,
            authorizationParameters: [:]
        )

        XCTAssertFalse(unknown.allowsRemoteRequest(path: "/anything", method: "GET", body: nil, readOnlyRequest: true))
        XCTAssertFalse(unknown.allowsRemoteRequest(path: "/anything", method: "POST", body: Data(#"{}"#.utf8), readOnlyRequest: false))
    }

    func testWritePathsAndMethodsStayProviderScoped() {
        let slack = definition(id: "slack")
        let linear = definition(id: "linear")

        XCTAssertTrue(slack.allowsRemoteRequest(path: "/chat.postMessage", method: "POST", body: Data(#"{"channel":"C1","text":"hello"}"#.utf8), readOnlyRequest: false))
        XCTAssertFalse(slack.allowsRemoteRequest(path: "/conversations.list", method: "POST", body: Data(#"{}"#.utf8), readOnlyRequest: false))
        XCTAssertTrue(linear.allowsRemoteRequest(path: "/graphql", method: "POST", body: Data(#"{"query":"mutation { issueUpdate }"}"#.utf8), readOnlyRequest: false))
        XCTAssertFalse(linear.allowsRemoteRequest(path: "/graphql", method: "PUT", body: nil, readOnlyRequest: false))
    }

    func testSlackAlwaysUsesBearerAuthorization() {
        let slack = definition(id: "slack")
        let token = OAuthToken(accessToken: "xoxp-token", tokenType: "user")

        XCTAssertEqual(slack.authorizationHeader(for: token), "Bearer xoxp-token")
    }

    func testRemoteWritesStayDisabledUntilEnabledPerIntegration() {
        let suiteName = "dev.perry.tests.remote-writes.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = RemoteIntegrationPermissionStore(suiteName: suiteName)
        let slack = definition(id: "slack")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(store.writesEnabled(for: slack))
        store.setWritesEnabled(true, for: slack)
        XCTAssertTrue(store.writesEnabled(for: slack))
    }

    private func definition(id: String) -> RemoteIntegrationDefinition {
        RemoteIntegrationDefinition.catalog.first { $0.id == id }!
    }
}
