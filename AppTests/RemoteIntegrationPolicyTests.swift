import Foundation
import XCTest
import PerryBrain
import PerryCore
@testable import Perry

final class RemoteIntegrationPolicyTests: XCTestCase {
    func testDesktopOAuthPoliciesMatchProviderRequirements() {
        let slack = definition(id: "slack")
        let linear = definition(id: "linear")
        let google = definition(id: "google-calendar")

        XCTAssertEqual(slack.authorizationScopeParameter, "user_scope")
        XCTAssertEqual(slack.authorizationScopeSeparator, ",")
        XCTAssertFalse(slack.requiresClientSecret)
        XCTAssertEqual(linear.authorizationScopeSeparator, ",")
        XCTAssertEqual(google.authorizationScopeSeparator, " ")
        XCTAssertEqual(OAuthConfiguration.defaultRedirectURI.absoluteString, "dev.perry.perry:/oauth/callback")
    }

    func testReadsStayInsideTheProvidersReadPaths() {
        let notion = definition(id: "notion")

        XCTAssertTrue(notion.allowsRead(path: "/v1/search"))
        XCTAssertTrue(notion.allowsRead(path: "/v1/pages/123"))
        XCTAssertFalse(notion.allowsRead(path: "/v1/oauth/token"))
        XCTAssertFalse(notion.allowsRead(path: "/v1/pages/../oauth/token"))
        XCTAssertFalse(notion.allowsRead(path: "/v1/search?client_secret=leaked"))
    }

    func testEveryQuickActionIsAllowedByItsOwnDefinition() {
        for definition in RemoteIntegrationDefinition.catalog {
            for action in definition.quickActions + [definition.connectionTest] {
                XCTAssertTrue(definition.allowsRead(path: action.resolvedPath()), "\(definition.id).\(action.id)")
            }
        }
    }

    func testNotionSearchTextIsEncodedIntoTheBody() throws {
        let search = try XCTUnwrap(definition(id: "notion").quickActions.first { $0.id == "search" })
        let query = #"quote " and \ slash"#

        let body = try JSONValue(parsing: XCTUnwrap(search.searching(query).bodyData))

        XCTAssertEqual(body["query"], .string(query))
        XCTAssertEqual(body["page_size"], .number(10))
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

        XCTAssertFalse(unknown.allowsRead(path: "/anything"))
    }

    func testWritesStayProviderScoped() throws {
        let slack = definition(id: "slack")
        let linear = definition(id: "linear")
        let message = try XCTUnwrap(RemoteIntegrationWriteRequest(parameters: .slackSendMessage(channel: "C1", text: "hello")))
        let issue = try XCTUnwrap(RemoteIntegrationWriteRequest(parameters: .linearUpdateIssue(issueID: "ENG-1", title: "Fix")))

        XCTAssertTrue(slack.allowsRemoteWrite(message))
        XCTAssertFalse(slack.allowsRemoteWrite(issue))
        XCTAssertTrue(linear.allowsRemoteWrite(issue))
        XCTAssertFalse(linear.allowsRemoteWrite(message))
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
