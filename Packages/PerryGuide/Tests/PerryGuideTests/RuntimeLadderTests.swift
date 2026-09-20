import XCTest
@testable import PerryGuide
import PerryCore
import PerryRuntimes

private actor RequestCapture {
    private var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }

    func snapshot() -> URLRequest? {
        request
    }
}

final class HardwareAndKeysTests: XCTestCase {
    func testKeychainRoundTrip() throws {
        let store = KeychainStore(service: "dev.perry.tests")
        defer { try? store.deleteChecked(account: "test-key") }

        try store.save("secret-one", account: "test-key")
        XCTAssertEqual(try store.readChecked(account: "test-key"), "secret-one")

        try store.save("secret-two", account: "test-key")
        XCTAssertEqual(try store.readChecked(account: "test-key"), "secret-two")

        try store.deleteChecked(account: "test-key")
        XCTAssertNil(try store.readChecked(account: "test-key"))
    }

    func testHardwareProbePassesOnQualifyingMachine() {
        let probe = HardwareProbe()
        let report = probe.evaluate(chipName: "Apple M3 Pro", physicalMemoryBytes: 18 * 1024 * 1024 * 1024)
        XCTAssertTrue(report.passesFloor)
        XCTAssertNil(report.reasonIfBelow)
    }

    func testHardwareProbeFailsUnderMemoryFloorWithSpecifics() {
        let probe = HardwareProbe()
        let report = probe.evaluate(chipName: "Apple M2", physicalMemoryBytes: 8 * 1024 * 1024 * 1024)
        XCTAssertFalse(report.passesFloor)
        XCTAssertEqual(report.reasonIfBelow, "8 GB of unified memory is under the 16 GB floor for usable 4–7B quantized models.")
    }

    func testHardwareProbeFailsOnIntel() {
        let probe = HardwareProbe()
        let report = probe.evaluate(chipName: "Intel Core i9", physicalMemoryBytes: 32 * 1024 * 1024 * 1024)
        XCTAssertFalse(report.passesFloor)
        XCTAssertTrue(report.reasonIfBelow?.contains("Apple silicon") == true)
    }
}

final class RuntimeGuidePlannerTests: XCTestCase {
    private func button(_ id: String, label: String) -> AXElement {
        AXElement(
            stableID: id,
            role: .button,
            label: label,
            frame: AXElementFrame(x: 0, y: 0, width: 80, height: 24),
            isActionable: true
        )
    }

    private func observation() -> GuideObservation {
        GuideObservation(
            snapshot: AXSnapshot(
                appBundleID: "com.apple.finder",
                windowTitle: "Desktop",
                elements: [button("b1", label: "Tags"), button("s1", label: "Share")]
            ),
            windowBounds: AXElementFrame(x: 0, y: 0, width: 800, height: 600)
        )
    }

    private func openAIBody(_ text: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": text]]],
        ])
    }

    private func planner(
        body: @escaping @Sendable () throws -> Data,
        status: Int = 200,
        capture: RequestCapture? = nil
    ) -> RuntimeGuidePlanner {
        RuntimeGuidePlanner(
            configuration: DirectProviderConfiguration(provider: .openAI, model: "gpt-test"),
            apiKeyProvider: { "sk-test" },
            transport: { request in
                if let capture { await capture.record(request) }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (try body(), response)
            }
        )
    }

    func testThrowsWithoutKeyBeforeAnyNetworkCall() async {
        let capture = RequestCapture()
        let planner = RuntimeGuidePlanner(
            configuration: DirectProviderConfiguration(provider: .openAI, model: "gpt-test"),
            apiKeyProvider: { nil },
            transport: { request in
                await capture.record(request)
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        do {
            _ = try await planner.nextStep(goal: "tag files", observation: observation(), context: .empty)
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue("\(error)".contains("authentication is missing"))
            let sent = await capture.snapshot()
            XCTAssertNil(sent)
        }
    }

    func testParsesAStepAndSendsTheKey() async throws {
        let capture = RequestCapture()
        let planner = planner(
            body: { try self.openAIBody(#"{"step":{"instruction":"click Tags","target":"b1"}}"#) },
            capture: capture
        )

        let step = try await planner.nextStep(goal: "tag the file", observation: observation(), context: .empty)

        XCTAssertEqual(step?.instruction, "click Tags")
        if case .axElement(let id)? = step?.target {
            XCTAssertEqual(id, "b1")
        } else {
            XCTFail("expected element target")
        }
        let request = await capture.snapshot()
        let sent = try XCTUnwrap(request)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    func testScreenContextReachesThePlannerRequest() async throws {
        let capture = RequestCapture()
        let planner = planner(
            body: { try self.openAIBody(#"{"step":{"instruction":"click Tags","target":"b1"}}"#) },
            capture: capture
        )
        let context = GuideContext(
            spatialRegionDescription: "the toolbar area",
            memoryContext: "Prefers archive folders"
        )

        _ = try await planner.nextStep(goal: "tag the file", observation: observation(), context: context)

        let captured = await capture.snapshot()
        let request = try XCTUnwrap(captured)
        let body = try XCTUnwrap(request.httpBody)
        let sent = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(sent.contains("the toolbar area"), "spatial region missing from planner request")
        XCTAssertTrue(sent.contains("Prefers archive folders"), "memory context missing from planner request")
        XCTAssertTrue(sent.contains("com.apple.finder"), "app identity missing from planner request")
        XCTAssertTrue(sent.contains("Tags"), "visible controls missing from planner request")
    }

    func testDoneSignalEndsTheSession() async throws {
        let planner = planner(body: { try self.openAIBody(#"{"done":true}"#) })
        let step = try await planner.nextStep(goal: "g", observation: observation(), context: .empty)
        XCTAssertNil(step)
    }

    func testInventedElementIDIsRejected() async throws {
        let planner = planner(body: { try self.openAIBody(#"{"step":{"instruction":"ghost","target":"invented"}}"#) })
        do {
            _ = try await planner.nextStep(goal: "g", observation: observation(), context: .empty)
            XCTFail("expected invalidTarget")
        } catch GuidePlannerError.invalidTarget {}
    }

    func testOutOfWindowPointIsRejected() async throws {
        let planner = planner(body: { try self.openAIBody(#"{"step":{"instruction":"far","target":[5000,5000]}}"#) })
        do {
            _ = try await planner.nextStep(goal: "g", observation: observation(), context: .empty)
            XCTFail("expected invalidTarget")
        } catch GuidePlannerError.invalidTarget {}
    }

    func testMalformedResponseSurfacesHonestly() async throws {
        let planner = planner(body: { try self.openAIBody("not json at all") })
        do {
            _ = try await planner.nextStep(goal: "g", observation: observation(), context: .empty)
            XCTFail("expected malformedResponse")
        } catch GuidePlannerError.malformedResponse {}
    }

    func testNon200SurfacesProviderStatus() async throws {
        let planner = planner(body: { Data() }, status: 401)
        do {
            _ = try await planner.nextStep(goal: "g", observation: observation(), context: .empty)
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue("\(error)".contains("401"))
        }
    }

    func testVisiblePathKeepsOnlyGroundedSteps() async throws {
        let planner = planner(body: {
            try self.openAIBody(#"{"steps":[{"instruction":"click Tags","target":"b1"},{"instruction":"ghost","target":"invented"},{"instruction":"click Share","target":"s1"}]}"#)
        })

        let steps = try await planner.visiblePath(goal: "tag a file", observation: observation(), context: .empty)

        XCTAssertEqual(steps.count, 2)
        for step in steps {
            guard case .axElement(let id) = step.target else {
                return XCTFail("visible path must only contain grounded targets")
            }
            XCTAssertNotNil(observation().snapshot.element(withStableID: id))
        }
    }
}

final class RuntimeRouterTests: XCTestCase {
    func testFileTasksPreferCLI() {
        let router = RuntimeRouter(cliAvailable: true, byokAvailable: true, localPassesFloor: false)
        XCTAssertEqual(router.route(task: .fileOrDev).runtimeID, "cli.claude-code")
    }

    func testGUITasksRouteToVisionCapableCloud() {
        let router = RuntimeRouter(cliAvailable: true, byokAvailable: true, localPassesFloor: false)
        XCTAssertEqual(router.route(task: .guiGrounding).runtimeID, "byok.cloud")
    }

    func testNothingAvailableExplainsPath() {
        let router = RuntimeRouter(cliAvailable: false, byokAvailable: false, localPassesFloor: false)
        XCTAssertTrue(router.route(task: .fileOrDev).reason.contains("install a coding-agent CLI"))
    }

    func testLocalTierRequiresFloorAndFlag() {
        let offFloor = RuntimeRouter(cliAvailable: false, byokAvailable: false, localPassesFloor: false, localExperimentalFlagOn: true)
        let noFlag = RuntimeRouter(cliAvailable: false, byokAvailable: false, localPassesFloor: true, localExperimentalFlagOn: false)
        let offered = RuntimeRouter(cliAvailable: false, byokAvailable: false, localPassesFloor: true, localExperimentalFlagOn: true)

        XCTAssertFalse(offFloor.isLocalTierOffered())
        XCTAssertFalse(noFlag.isLocalTierOffered())
        XCTAssertTrue(offered.isLocalTierOffered())
    }

    func testLocalPlannerIsSelectedWhenExplicitlyEnabled() {
        let router = RuntimeRouter(
            cliAvailable: false,
            byokAvailable: false,
            localPassesFloor: true,
            localExperimentalFlagOn: true
        )

        XCTAssertEqual(router.route(task: .fileOrDev).runtimeID, "local.task-planner")
        XCTAssertEqual(router.route(task: .guiGrounding).runtimeID, "local.task-planner")
    }
}
