import XCTest
import PerryBrain
import PerryCore
import PerryGuide
import PerryRuntimes
@testable import Perry

@MainActor
final class BrainControllerTests: XCTestCase {
    private func isolatedDefaults() throws -> UserDefaults {
        let name = "BrainControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testErasedModelPreferenceReloadsWithoutRecreatingStoredData() async throws {
        let defaults = try isolatedDefaults()
        let brain = BrainController(defaults: defaults, codexFactory: { nil })
        brain.modelChoice = BrainController.ModelChoice.local.rawValue
        brain.closeAdmission()
        brain.modelChoice = BrainController.ModelChoice.direct.rawValue
        XCTAssertEqual(defaults.string(forKey: PerryPreferences.$modelChoice.key), BrainController.ModelChoice.local.rawValue)
        await brain.stopSetup()
        defaults.removeObject(forKey: PerryPreferences.$modelChoice.key)
        brain.reloadPreferences()
        brain.reopenAdmission()
        XCTAssertEqual(brain.modelChoice, BrainController.ModelChoice.chatGPT.rawValue)
        XCTAssertNil(defaults.object(forKey: PerryPreferences.$modelChoice.key))
    }

    func testMaintenanceRejectsRoutesAndDropsDiscoveryFromBeforeReset() async throws {
        let started = expectation(description: "Discovery suspended")
        var discovery: CheckedContinuation<[LocalModel], Never>?
        var suspend = true
        let model = LocalModel(server: .ollama, baseURL: URL(string: "http://127.0.0.1:11434")!, name: "fixture")
        let brain = BrainController(
            readCredential: { _ in nil }, defaults: try isolatedDefaults(),
            discoverLocalModels: {
                if suspend {
                    return await withCheckedContinuation {
                        discovery = $0
                        started.fulfill()
                    }
                }
                return [model]
            }, codexFactory: { nil }
        )
        brain.modelChoice = BrainController.ModelChoice.local.rawValue
        let oldRouter = try brain.router()
        let refresh = Task { await brain.refresh() }
        await fulfillment(of: [started], timeout: 2)
        brain.closeAdmission()
        XCTAssertThrowsError(try brain.router()) { XCTAssertTrue($0 is CancellationError) }
        await brain.stopSetup()
        brain.reopenAdmission()
        discovery?.resume(returning: [model])
        await refresh.value
        XCTAssertTrue(brain.localModels.isEmpty)
        XCTAssertEqual(brain.account, .unknown)
        XCTAssertFalse(try brain.router() === oldRouter)
        suspend = false
        await brain.refresh()
        XCTAssertEqual(brain.localModels, [model])
    }

    func testMaintenanceJoinsBrowserSignInBeforeItsHomeIsRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/PerryBrain/Tests/PerryBrainTests/Fixtures/fake-codex-app-server.py")
        let process = CodexAppServerProcess(configuration: .init(
            binaryURL: URL(fileURLWithPath: "/usr/bin/python3"), codexHome: root.appendingPathComponent("home"),
            workingDirectory: root.appendingPathComponent("work"), processArguments: ["-u", script.path],
            extraEnvironment: ["SCENARIO": "b", "FAKE_LOG": root.appendingPathComponent("requests.jsonl").path]
        ))
        var retainedProvider: CodexAppServerProvider? = CodexAppServerProvider(process: process)
        let opened = expectation(description: "Sign-in reached browser handoff")
        let brain = BrainController(
            defaults: try isolatedDefaults(), discoverLocalModels: { [] }, codexFactory: { retainedProvider },
            openAuthenticationURL: { url in
                XCTAssertEqual(url.host, "example.invalid")
                opened.fulfill()
                return true
            }
        )
        var completions: [Bool] = []
        brain.signInWithChatGPT { completions.append($0) }
        await fulfillment(of: [opened], timeout: 5)
        XCTAssertTrue(brain.isSigningIn)
        await brain.stopSetup()
        XCTAssertFalse(brain.isSigningIn)
        XCTAssertTrue(completions.isEmpty)
        XCTAssertNil(brain.signInError)
        retainedProvider = nil
        try FileManager.default.removeItem(at: root)
        brain.reopenAdmission()
        await brain.refresh()
        XCTAssertEqual(brain.account, .unknown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testMaintenanceRetiresProviderWhileAccountRefreshIsInitializing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/PerryBrain/Tests/PerryBrainTests/Fixtures/fake-codex-app-server.py")
        let log = root.appendingPathComponent("requests.jsonl")
        let process = CodexAppServerProcess(configuration: .init(
            binaryURL: URL(fileURLWithPath: "/usr/bin/python3"), codexHome: root.appendingPathComponent("home"),
            workingDirectory: root.appendingPathComponent("work"), processArguments: ["-u", script.path],
            extraEnvironment: ["SCENARIO": "blocked-initialize", "FAKE_LOG": log.path]
        ))
        let provider = CodexAppServerProvider(process: process)
        var retainedProvider: CodexAppServerProvider? = provider
        let brain = BrainController(
            readCredential: { _ in nil }, defaults: try isolatedDefaults(), discoverLocalModels: { [] },
            codexFactory: { retainedProvider }
        )
        let refresh = Task { await brain.refresh() }
        let deadline = Date().addingTimeInterval(5)
        while (try? String(contentsOf: log, encoding: .utf8).contains("blocked_pid")) != true {
            guard Date() < deadline else {
                await process.terminate()
                await refresh.value
                return XCTFail("Fixture did not enter initialization")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await brain.stopSetup()
        await refresh.value
        retainedProvider = nil
        brain.reopenAdmission()
        XCTAssertEqual(brain.account, .unknown)
        XCTAssertFalse(brain.isSigningIn)
        XCTAssertNil(brain.signInError)
        do {
            _ = try await process.connection()
            XCTFail("The previous provider must stay retired")
        } catch is CancellationError {
        }
    }

    private func guideObservation(image: Data? = nil) -> GuideObservation {
        GuideObservation(snapshot: AXSnapshot(appBundleID: "fixture.editor", windowTitle: "Synthetic document", elements: [
            AXElement(stableID: "save", role: .button, label: "Save", frame: AXElementFrame(x: 10, y: 10, width: 80, height: 30), isActionable: true),
            AXElement(stableID: "delete", role: .button, label: "Delete", frame: AXElementFrame(x: 100, y: 10, width: 80, height: 30), isActionable: true)
        ]), screenshotData: image, screenshotMIMEType: "image/png")
    }

    func testGuideUsesSelectedProviderAndValidatesBothPresentations() async throws {
        let transport = GuideBrainTransport(responses: [
            (#"{"step":{"instruction":"Click Save","target":"save"}}"#, "stop"),
            (#"{"steps":[{"instruction":"Click Save","target":"save"}]}"#, "stop")
        ])
        var model = "first-model"
        let brain = BrainController(
            readCredential: { $0 == RuntimeCatalog.byokVisionKeychainAccount ? "fixture-key" : nil },
            configuredEndpoint: { .init(baseURL: URL(string: "https://models.example.invalid/v1")!, model: model) },
            transport: transport, defaults: try isolatedDefaults()
        )
        brain.modelChoice = BrainController.ModelChoice.direct.rawValue
        let planner = brain.makeGuidePlanner(storageDirectory: nil) { _, request in
            var request = request
            request.messages.insert(.assistant(text: "Prior conversation: Orchid document", toolCalls: []), at: 0)
            return request
        }
        let image = Data("synthetic image fixture".utf8)
        let observation = guideObservation(image: image)
        let decision = try await planner.nextStep(goal: "Save this document", observation: observation, context: .empty)
        guard case .step(let step) = decision else { return XCTFail("Expected grounded step") }
        XCTAssertEqual(step.target, .axElement(stableID: "save"))
        model = "second-model"
        let path = try await planner.visiblePath(goal: "Save this document", observation: observation, context: .empty)
        XCTAssertEqual(path.map(\.target), [.axElement(stableID: "save")])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        let payloads = try requests.map { try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap($0.httpBody)) as? [String: Any]) }
        XCTAssertEqual(payloads.compactMap { $0["model"] as? String }, ["first-model", "second-model"])
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "models.example.invalid" })
        XCTAssertTrue(payloads.allSatisfy { $0["tools"] == nil })
        let sent = String(decoding: try XCTUnwrap(requests.first?.httpBody), as: UTF8.self)
        XCTAssertTrue(sent.contains(image.base64EncodedString()))
        XCTAssertTrue(sent.contains("Prior conversation: Orchid document"))
    }

    func testGuideRejectsIncompleteAndUngroundedResponses() async throws {
        let valid = #"{"step":{"instruction":"Click Save","target":"save"}}"#
        for response: (String, String?) in [
            (valid, "length"), (valid, nil),
            (#"{"step":{"instruction":"Invented control","target":"missing"}}"#, "stop"),
            (String(repeating: "x", count: 65_537), "stop")
        ] {
            let brain = BrainController(
                readCredential: { $0 == RuntimeCatalog.byokVisionKeychainAccount ? "fixture-key" : nil },
                configuredEndpoint: { .init(baseURL: URL(string: "https://models.example.invalid/v1")!, model: "fixture") },
                transport: GuideBrainTransport(responses: [response]), defaults: try isolatedDefaults()
            )
            brain.modelChoice = BrainController.ModelChoice.direct.rawValue
            do {
                _ = try await brain.makeGuidePlanner(storageDirectory: nil).nextStep(goal: "Save", observation: guideObservation(), context: .empty)
                XCTFail("Incomplete or ungrounded guidance must fail")
            } catch is ModelProviderError {
            } catch is GuidePlannerError {
            }
        }
    }

    func testGuideDoesNotEscapeUnavailableLocalChoice() async throws {
        let brain = BrainController(readCredential: { _ in
            XCTFail("Local Guide must not read remote credentials")
            return nil
        }, defaults: try isolatedDefaults())
        brain.modelChoice = BrainController.ModelChoice.local.rawValue
        do {
            _ = try await brain.makeGuidePlanner(storageDirectory: nil).nextStep(goal: "Save", observation: guideObservation(), context: .empty)
            XCTFail("No verified local vision model is available")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error.kind, .notConfigured)
        }
    }

    func testLiveChatGPTGuideUsesGroundedSyntheticControl() async throws {
        guard ProcessInfo.processInfo.environment["PERRY_LIVE_CHATGPT_TESTS"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_PERRY_LIVE_CHATGPT_TESTS=1 to use the signed-in account with synthetic data.")
        }
        let brain = BrainController(readCredential: { _ in
            XCTFail("ChatGPT Guide must not use BYOK credentials")
            return nil
        }, defaults: try isolatedDefaults())
        let planner = brain.makeGuidePlanner(storageDirectory: nil)
        let decision = try await planner.nextStep(
            goal: "Show the single button to save this synthetic document. Do not delete it.",
            observation: guideObservation(), context: .empty
        )
        guard case .step(let step) = decision else { return XCTFail("Expected a grounded Save instruction") }
        XCTAssertEqual(step.target, .axElement(stableID: "save"))
    }

    func testDiscoveredVisionNameCannotEnableUnverifiedScreenAccess() async throws {
        let brain = BrainController(
            readCredential: { _ in nil }, defaults: try isolatedDefaults(),
            discoverLocalModels: { [.init(server: .ollama, baseURL: URL(string: "http://127.0.0.1:11434")!, name: "vision-model")] }
        )
        brain.modelChoice = BrainController.ModelChoice.local.rawValue
        await brain.refresh()
        XCTAssertEqual(brain.localModels.count, 1)
        do {
            _ = try await brain.route(RouteRequirement(capabilities: [.vision]))
            XCTFail("A model name cannot establish image understanding")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error.kind, .notConfigured)
        }
    }

    func testOnlyPassedLocalCapabilitiesRouteAndChangedRevisionInvalidatesThem() async throws {
        var revision = "first-revision"
        let brain = BrainController(
            readCredential: { _ in nil }, transport: CapabilityTestTransport(), defaults: try isolatedDefaults(),
            discoverLocalModels: { [.init(server: .ollama, baseURL: URL(string: "http://127.0.0.1:11434")!, name: "test-model", revision: revision)] }
        )
        brain.modelChoice = BrainController.ModelChoice.local.rawValue
        await brain.refresh()
        let model = try XCTUnwrap(brain.localModels.first)
        brain.checkLocalModel(model)
        let deadline = Date().addingTimeInterval(5)
        while brain.localChecks[model.id] == .checking, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard case .checked(_, let result) = brain.localChecks[model.id] else { return XCTFail("Expected a completed capability check") }
        XCTAssertEqual(result.capabilities, [.streaming, .tools])
        let routed = try await brain.route(RouteRequirement(capabilities: [.tools]))
        XCTAssertEqual(routed.provider.id, model.id)
        do {
            _ = try await brain.route(RouteRequirement(capabilities: [.vision]))
            XCTFail("A failed image check must exclude screen requests")
        } catch let error as ModelProviderError { XCTAssertEqual(error.kind, .notConfigured) }

        revision = "replaced-revision"
        await brain.refresh()
        XCTAssertNil(brain.localChecks[model.id])
        do {
            _ = try await brain.route(RouteRequirement(capabilities: [.tools]))
            XCTFail("New model contents require new checks")
        } catch let error as ModelProviderError { XCTAssertEqual(error.kind, .notConfigured) }
    }

    func testChatGPTIsTheDefaultWithoutReadingOtherCredentials() async throws {
        var credentialReads = 0
        let brain = BrainController(readCredential: { _ in
            credentialReads += 1
            throw CocoaError(.fileReadNoPermission)
        }, defaults: try isolatedDefaults())
        for tier in [ModelTier.fast, .deep] {
            let decision = try await brain.route(RouteRequirement(capabilities: [.vision, .tools], tier: tier))
            XCTAssertEqual(decision.provider.id, .codex)
        }
        XCTAssertEqual(credentialReads, 0)
    }

    func testLocalChoicePersistsAndNeverEscapesToChatGPT() async throws {
        let defaults = try isolatedDefaults()
        let brain = BrainController(readCredential: { _ in
            XCTFail("Local selection must not read remote credentials")
            return "unused-key"
        }, defaults: defaults)
        brain.modelChoice = BrainController.ModelChoice.local.rawValue
        do {
            let decision = try await brain.route(RouteRequirement(capabilities: [.tools, .vision], tier: .deep))
            XCTAssertTrue(decision.provider.capabilities.contains(.local))
        } catch let error as ModelProviderError {
            XCTAssertEqual(error.kind, .notConfigured)
        }
        let restored = BrainController(defaults: defaults)
        XCTAssertEqual(restored.modelChoice, BrainController.ModelChoice.local.rawValue)
        defaults.set("unknown-choice", forKey: PerryPreferences.$modelChoice.key)
        let unreadableChoice = BrainController(defaults: defaults)
        do {
            _ = try await unreadableChoice.route(RouteRequirement())
            XCTFail("An unrecognized setting must not select a remote provider")
        } catch let error as ModelProviderError {
            XCTAssertEqual(error.provider, "settings")
        }
    }

    func testCustomProviderReceivesOnlyItsConfiguredEndpointAndModel() async throws {
        let transport = CapturingBrainTransport()
        let brain = BrainController(
            readCredential: { $0 == RuntimeCatalog.byokVisionKeychainAccount ? "custom-test-key" : nil },
            configuredEndpoint: { .init(baseURL: URL(string: "https://models.example.invalid/v1")!, model: "custom-test-model") },
            transport: transport, defaults: try isolatedDefaults()
        )
        brain.modelChoice = BrainController.ModelChoice.direct.rawValue
        let decision = try await brain.route(RouteRequirement(capabilities: [.vision, .tools]))
        XCTAssertEqual(decision.provider.id, "custom")
        do {
            for try await _ in decision.provider.stream(ModelRequest(messages: [.user([.text("Test")])])) {}
            XCTFail("Expected the recording transport to stop the request")
        } catch CapturingBrainTransport.Recorded.request {}
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://models.example.invalid/v1/chat/completions")
        let payload = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        XCTAssertEqual(payload?["model"] as? String, "custom-test-model")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer custom-test-key")
    }

    func testRepeatedRoutingRetainsHealthUntilCredentialsChange() async throws {
        var credential: String? = "test-key-one"
        let brain = BrainController(readCredential: { account in
            account == BrainController.keychainAccount(for: .openAI) ? credential : nil
        }, configuredEndpoint: { nil })
        let first = try brain.router()
        await first.reportFailure(.openAI)
        await first.reportFailure(.openAI)
        let repeated = try brain.router()
        XCTAssertTrue(first === repeated)
        let healthy = await repeated.isHealthy(.openAI)
        XCTAssertFalse(healthy)

        credential = "test-key-two"
        let replacement = try brain.router()
        XCTAssertFalse(replacement === first)
        let refreshed = try await replacement.route(RouteRequirement(capabilities: [.vision], tier: .fast))
        XCTAssertEqual(refreshed.provider.id, .openAI)
        let replacementHealthy = await replacement.isHealthy(.openAI)
        XCTAssertTrue(replacementHealthy)

        credential = nil
        let removed = try brain.router()
        XCTAssertFalse(removed === replacement)
        let afterRemoval = try await removed.route(RouteRequirement(capabilities: [.vision], tier: .fast))
        XCTAssertNotEqual(afterRemoval.provider.id, .openAI)
    }

    func testConfiguredModelChangesReachTheNextRequest() async throws {
        let transport = CapturingBrainTransport()
        var model = "configured-model-one"
        let brain = BrainController(
            readCredential: { $0 == RuntimeCatalog.byokVisionKeychainAccount ? "test-legacy-key" : nil },
            configuredEndpoint: { .init(baseURL: URL(string: "https://api.openai.com")!, model: model) },
            transport: transport
        )
        let first = try brain.router(preference: [.openAI])
        let firstProvider = try await first.route(RouteRequirement(tier: .deep)).provider
        do {
            for try await _ in firstProvider.stream(ModelRequest(messages: [.user([.text("Test")])], tier: .deep)) {}
            XCTFail("Expected the recording transport to stop the request")
        } catch CapturingBrainTransport.Recorded.request {}
        model = "configured-model-two"
        let second = try brain.router(preference: [.openAI])
        XCTAssertFalse(first === second)
        let secondProvider = try await second.route(RouteRequirement(tier: .fast)).provider
        do {
            for try await _ in secondProvider.stream(ModelRequest(messages: [.user([.text("Test")])], tier: .fast)) {}
            XCTFail("Expected the recording transport to stop the request")
        } catch CapturingBrainTransport.Recorded.request {}
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        let payloads = try requests.map { try JSONSerialization.jsonObject(with: XCTUnwrap($0.httpBody)) as? [String: Any] }
        XCTAssertEqual(payloads.compactMap { $0?["model"] as? String }, ["configured-model-one", "configured-model-two"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer test-legacy-key", "Bearer test-legacy-key"])
    }

    func testUnreadableCredentialDoesNotSilentlySelectAnotherProvider() {
        let brain = BrainController(readCredential: { _ in throw CocoaError(.fileReadNoPermission) })
        XCTAssertThrowsError(try brain.router())
    }
}

private actor CapturingBrainTransport: HTTPLineStreaming {
    enum Recorded: Error { case request }
    private(set) var requests: [URLRequest] = []

    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        requests.append(request)
        throw Recorded.request
    }
}

private struct CapabilityTestTransport: HTTPLineStreaming {
    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let last = try XCTUnwrap(messages.last)
        let delta: [String: Any]
        let finish: String
        if last["role"] as? String == "tool" {
            delta = ["content": try XCTUnwrap(last["content"] as? String)]
            finish = "stop"
        } else if body["tools"] != nil {
            delta = ["tool_calls": [["index": 0, "id": "check", "type": "function", "function": ["name": "perry_capability_check", "arguments": "{\"value\":\"test\"}"]]]]
            finish = "tool_calls"
        } else if let content = last["content"] as? [[String: Any]], content.contains(where: { $0["type"] as? String == "image_url" }) {
            delta = ["content": "Cannot read the image"]
            finish = "stop"
        } else {
            delta = ["content": "PERRY_READY"]
            finish = "stop"
        }
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["delta": delta, "finish_reason": finish]]])
        let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
        return (response, AsyncThrowingStream { continuation in
            continuation.yield("data: " + String(decoding: data, as: UTF8.self))
            continuation.yield("")
            continuation.yield("data: [DONE]")
            continuation.yield("")
            continuation.finish()
        })
    }
}

private actor GuideBrainTransport: HTTPLineStreaming {
    var responses: [(String, String?)]
    private(set) var requests: [URLRequest] = []

    init(responses: [(String, String?)]) { self.responses = responses }

    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        requests.append(request)
        let next = responses.removeFirst()
        let payload: [String: Any] = ["choices": [["delta": ["content": next.0], "finish_reason": next.1 as Any? ?? NSNull()]]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
        return (response, AsyncThrowingStream { continuation in
            continuation.yield("data: " + String(decoding: data, as: UTF8.self))
            continuation.yield("")
            continuation.yield("data: [DONE]")
            continuation.yield("")
            continuation.finish()
        })
    }
}
