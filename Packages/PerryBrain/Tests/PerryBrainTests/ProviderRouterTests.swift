import Foundation
@testable import PerryBrain
import XCTest

private struct StubProvider: ModelProvider {
    let id: ProviderID
    let displayName: String
    let capabilities: ModelCapabilities

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func warm() async {}
}

private final class ScriptableProvider: ModelProvider, @unchecked Sendable {
    let id: ProviderID
    let displayName = "Scriptable"
    let capabilities: ModelCapabilities
    var events: [ModelEvent]
    var error: Error?

    init(id: ProviderID, capabilities: ModelCapabilities, events: [ModelEvent] = [.done(.endTurn)], error: Error? = nil) {
        self.id = id
        self.capabilities = capabilities
        self.events = events
        self.error = error
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let events = self.events
        let error = self.error
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }
    func warm() async {}
}

private struct HangingProvider: ModelProvider {
    let id: ProviderID
    let displayName = "Hanging"
    let capabilities: ModelCapabilities

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { _ in }
    }
    func warm() async {}
}

private struct ScriptableToolProvider: ModelProvider {
    let executesTools = true
    let id: ProviderID
    let displayName = "Scriptable tools"
    let capabilities: ModelCapabilities

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { $0.yield(.done(.endTurn)); $0.finish() }
    }
    func stream(_ request: ModelRequest, executeTool: @escaping ToolExecutionHandler) -> AsyncThrowingStream<ModelEvent, Error> {
        stream(request)
    }
    func warm() async {}
}

final class ProviderRouterTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private lazy var clock: @Sendable () -> Date = { self.now }

    private func router(_ providers: [any ModelProvider], preference: [ProviderID] = []) -> ProviderRouter {
        ProviderRouter(providers: providers, preference: preference, clock: clock)
    }

    func testFastTierPrefersOpenAIOverCodex() async throws {
        let router = router([
            StubProvider(id: .codex, displayName: "Codex", capabilities: [.vision, .tools, .streaming]),
            StubProvider(id: .openAI, displayName: "OpenAI", capabilities: [.vision, .tools, .streaming]),
        ])
        let decision = try await router.route(RouteRequirement(capabilities: [.vision], tier: .fast))
        XCTAssertEqual(decision.provider.id, .openAI)
    }

    func testDeepTierPrefersCodex() async throws {
        let router = router([
            StubProvider(id: .openAI, displayName: "OpenAI", capabilities: [.vision, .tools, .streaming]),
            StubProvider(id: .codex, displayName: "Codex", capabilities: [.vision, .tools, .streaming]),
        ])
        let decision = try await router.route(RouteRequirement(capabilities: [.vision], tier: .deep))
        XCTAssertEqual(decision.provider.id, .codex)
    }

    func testCapabilityFiltering() async throws {
        let router = router([
            StubProvider(id: .apple, displayName: "Apple", capabilities: [.local, .streaming]),
            StubProvider(id: .openAI, displayName: "OpenAI", capabilities: [.vision, .streaming]),
        ], preference: [.apple])
        let decision = try await router.route(RouteRequirement(capabilities: [.vision], tier: .fast))
        XCTAssertEqual(decision.provider.id, .openAI)
        XCTAssertTrue(decision.explanation.contains("apple"))
    }

    func testPreferenceBeatsDefaultOrder() async throws {
        let router = router(
            [
                StubProvider(id: .codex, displayName: "Codex", capabilities: [.vision, .streaming]),
                StubProvider(id: .gemini, displayName: "Gemini", capabilities: [.vision, .streaming]),
            ],
            preference: [.gemini]
        )
        let decision = try await router.route(RouteRequirement(capabilities: [.vision], tier: .fast))
        XCTAssertEqual(decision.provider.id, .gemini)
    }

    func testUnhealthySkippedAndRecovers() async throws {
        let router = router([
            StubProvider(id: .openAI, displayName: "OpenAI", capabilities: [.vision, .streaming]),
            StubProvider(id: .gemini, displayName: "Gemini", capabilities: [.vision, .streaming]),
        ])
        await router.reportFailure(.openAI)
        var decision = try await router.route(RouteRequirement(capabilities: [.vision], tier: .fast))
        XCTAssertEqual(decision.provider.id, .openAI)
        await router.reportFailure(.openAI)
        decision = try await router.route(RouteRequirement(capabilities: [.vision], tier: .fast))
        XCTAssertEqual(decision.provider.id, .gemini)
        XCTAssertTrue(decision.explanation.contains("openai(down)"))
        now = now.addingTimeInterval(61)
        decision = try await router.route(RouteRequirement(capabilities: [.vision], tier: .fast))
        XCTAssertEqual(decision.provider.id, .openAI)
    }

    func testReportSuccessClearsHealth() async throws {
        let router = router([StubProvider(id: .openAI, displayName: "OpenAI", capabilities: [.streaming])])
        await router.reportFailure(.openAI)
        await router.reportFailure(.openAI)
        await router.reportSuccess(.openAI)
        let healthy = await router.isHealthy(.openAI)
        XCTAssertTrue(healthy)
    }

    func testStreamOutcomesDriveProviderHealth() async throws {
        let flaky = ScriptableProvider(id: .openAI, capabilities: [.vision, .streaming], error: ModelProviderError(kind: .unavailable, provider: .openAI, message: "fixture"))
        let router = router([
            flaky,
            ScriptableProvider(id: .gemini, capabilities: [.vision, .streaming]),
        ])
        let request = ModelRequest(messages: [.user([.text("hi")])], tier: .fast)

        // First failure: counted but still routable.
        var decision = try await router.route(RouteRequirement(capabilities: [.vision], tier: .fast))
        XCTAssertEqual(decision.provider.id, .openAI)
        do {
            for try await _ in decision.provider.stream(request) {}
            XCTFail("fixture must throw")
        } catch {}

        // Second failure: two strikes marks it down for the window.
        decision = try await router.route(RouteRequirement(capabilities: [.vision], tier: .fast))
        XCTAssertEqual(decision.provider.id, .openAI)
        do {
            for try await _ in decision.provider.stream(request) {}
            XCTFail("fixture must throw")
        } catch {}
        decision = try await router.route(RouteRequirement(capabilities: [.vision], tier: .fast))
        XCTAssertEqual(decision.provider.id, .gemini)
        XCTAssertTrue(decision.explanation.contains("openai(down)"))

        // After the window a successful stream resets the failure count:
        // one fresh failure alone is not enough to be skipped again.
        now = now.addingTimeInterval(61)
        flaky.error = nil
        flaky.events = [.done(.endTurn)]
        decision = try await router.route(RouteRequirement(capabilities: [.vision], tier: .fast))
        XCTAssertEqual(decision.provider.id, .openAI)
        for try await _ in decision.provider.stream(request) {}
        flaky.error = ModelProviderError(kind: .unavailable, provider: .openAI, message: "fixture")
        flaky.events = []
        do {
            for try await _ in decision.provider.stream(request) {}
            XCTFail("fixture must throw")
        } catch {}
        decision = try await router.route(RouteRequirement(capabilities: [.vision], tier: .fast))
        XCTAssertEqual(decision.provider.id, .openAI, "a post-recovery single failure must not re-mark the provider down")
    }

    func testCancelledStreamDoesNotMarkProviderDown() async throws {
        let router = router([
            HangingProvider(id: .codex, capabilities: [.vision, .streaming]),
        ])
        let request = ModelRequest(messages: [.user([.text("hi")])], tier: .fast)

        for _ in 0..<2 {
            let decision = try await router.route(RouteRequirement(capabilities: [.vision], tier: .fast))
            let consumer = Task { for try await _ in decision.provider.stream(request) {} }
            try await Task.sleep(for: .milliseconds(20))
            consumer.cancel()
            _ = await consumer.result
        }

        let decision = try await router.route(RouteRequirement(capabilities: [.vision], tier: .fast))
        XCTAssertEqual(decision.provider.id, .codex, "cancelling a turn must not count against provider health")
    }

    func testHealthWrapKeepsToolExecutingConformance() async throws {
        let router = router([
            ScriptableToolProvider(id: .openAI, capabilities: [.vision, .tools, .streaming]),
        ])
        let decision = try await router.route(RouteRequirement(capabilities: [.vision, .tools], tier: .fast))
        XCTAssertTrue(decision.provider.executesTools)
    }

    func testNoQualifyingProviderThrows() async throws {
        let router = router([StubProvider(id: .apple, displayName: "Apple", capabilities: [.streaming])])
        do {
            _ = try await router.route(RouteRequirement(capabilities: [.vision], tier: .fast))
            XCTFail("expected notConfigured")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error.kind, .notConfigured)
        }
    }

    func testLocalSubIDMatchesLocalOrderEntry() async throws {
        let router = router([
            StubProvider(id: "local.ollama", displayName: "Ollama", capabilities: [.vision, .streaming]),
        ])
        let decision = try await router.route(RouteRequirement(capabilities: [.vision], tier: .fast))
        XCTAssertEqual(decision.provider.id, "local.ollama")
    }

    func testExplicitProviderCannotFallBackWhenMissingIncapableOrUnhealthy() async throws {
        let router = router([
            StubProvider(id: .openAI, displayName: "OpenAI", capabilities: [.vision, .tools, .streaming]),
            StubProvider(id: "local.text", displayName: "Local text", capabilities: [.local, .streaming]),
        ])
        let selected = try await router.route(RouteRequirement(providerID: "local.text"))
        XCTAssertEqual(selected.provider.id, "local.text")
        await router.reportFailure("local.text")
        await router.reportFailure("local.text")
        for requirement in [
            RouteRequirement(providerID: "missing"),
            RouteRequirement(capabilities: [.vision], providerID: "local.text"),
            RouteRequirement(providerID: "local.text"),
            RouteRequirement(capabilities: [.local, .vision])
        ] {
            do {
                _ = try await router.route(requirement)
                XCTFail("A restricted request must not escape to OpenAI")
            } catch let error as ModelProviderError {
                XCTAssertEqual(error.kind, .notConfigured)
                XCTAssertTrue(error.localizedDescription.contains("Settings"))
                XCTAssertFalse(error.localizedDescription.contains("router:"))
                if requirement.capabilities.contains(.local) {
                    XCTAssertTrue(error.localizedDescription.contains("No remote model was used"))
                }
            }
        }
    }
}
