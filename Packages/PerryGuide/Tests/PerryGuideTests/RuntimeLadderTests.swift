import XCTest
@testable import PerryGuide
import PerryCore

final class HardwareAndKeysTests: XCTestCase {
    func testKeychainRoundTrip() throws {
        let store = KeychainStore(service: "dev.perry.tests")
        defer { store.delete(account: "test-key") }

        try store.save("secret-one", account: "test-key")
        XCTAssertEqual(store.read(account: "test-key"), "secret-one")

        try store.save("secret-two", account: "test-key")
        XCTAssertEqual(store.read(account: "test-key"), "secret-two")

        store.delete(account: "test-key")
        XCTAssertNil(store.read(account: "test-key"))
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

final class BYOKPlannerTests: XCTestCase {
    private func sampleSnapshot() -> AXSnapshot {
        AXSnapshot(
            appBundleID: "com.apple.finder",
            windowTitle: "Desktop",
            elements: [
                AXElement(stableID: "b1", role: .button, label: "Tags", frame: AXElementFrame(x: 0, y: 0, width: 80, height: 24), isActionable: true),
                AXElement(stableID: "s1", role: .slider, label: "Volume", frame: AXElementFrame(x: 0, y: 30, width: 120, height: 16), isActionable: true),
            ]
        )
    }

    func testThrowsWithoutKeyBeforeAnyNetworkCall() async {
        let planner = BYOKPlanner(endpoint: .openAI, apiKeyProvider: { nil })
        do {
            _ = try await planner.plan(goal: "tag files", snapshot: sampleSnapshot())
            XCTFail("expected PlanError")
        } catch {
            XCTAssertTrue("\(error)".contains("no API key"))
        }
    }

    func testParsesStepsFromProviderPayload() async throws {
        let providerBody: [String: Any] = [
            "choices": [[
                "message": [
                    "content": """
                    Sure! Here's my plan:
                    {"steps":[{"id":"b1","instruction":"click Tags"},{"id":"null","instruction":"watch the highlight"}]}
                    """
                ]
            ]]
        ]
        let providerData = try JSONSerialization.data(withJSONObject: providerBody)

        var capturedRequest: URLRequest?
        let planner = BYOKPlanner(
            endpoint: .anthropic,
            apiKeyProvider: { "sk-test" },
            transport: { request in
                capturedRequest = request
                return (providerData, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )

        let plan = try await planner.plan(goal: "tag the file", snapshot: sampleSnapshot())
        XCTAssertEqual(plan.steps.count, 2)
        if case .axElement(let id) = plan.steps[0].target {
            XCTAssertEqual(id, "b1")
        } else {
            XCTFail("expected element target")
        }
        if case .verbalOnly = plan.steps[1].target {} else {
            XCTFail("expected verbal target for null id")
        }

        let sent = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    func testNon200SurfacesProviderStatus() async {
        let planner = BYOKPlanner(
            endpoint: .openRouter,
            apiKeyProvider: { "sk-test" },
            transport: { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
        )
        do {
            _ = try await planner.plan(goal: "g", snapshot: sampleSnapshot())
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue("\(error)".contains("401"))
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
}
