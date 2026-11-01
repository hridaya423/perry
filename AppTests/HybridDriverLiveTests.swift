import AppKit
import ImageIO
import XCTest
import PerryCore
@testable import Perry

final class HybridDriverLiveTests: XCTestCase {
    private var logURL: URL!
    private var fixture: NSRunningApplication?
    private var target: ScreenTargetHint!

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["PERRY_LIVE_AGENT_DESKTOP"] == "1" else {
            throw XCTSkip("Set PERRY_LIVE_AGENT_DESKTOP=1 after building scripts/lab/hybrid-fixture and granting Perry permissions")
        }
        let app = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PERRY_HYBRID_FIXTURE"] ?? "/tmp/PerryHybridFixture.app")
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("perry-hybrid-\(UUID().uuidString).log")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [logURL.path]
        fixture = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        let ready = try await waitForLine { $0.hasPrefix("ready ") }.split(separator: " ")
        target = ScreenTargetHint(bundleID: "dev.perry.hybrid-fixture", processID: pid_t(ready[1])!, windowID: Int64(ready[2])!)
        try await Task.sleep(for: .milliseconds(500))
    }

    override func tearDown() async throws {
        fixture?.forceTerminate()
    }

    func testCanvasPointClickGoesThroughCuaInTheBackground() async throws {
        let (client, session, capture) = try await capturedFixture()
        let scale = try pixelScale(capture)
        let before = Self.observeUser()
        _ = try await client.execute(
            try ComputerAction(actionID: "canvas", command: .click(.windowPixels(x: 260 * scale, y: (titleBar(capture, scale) + 140) * scale))),
            sessionID: session
        )
        let line = try await waitForLine { $0.hasPrefix("canvas-click") }
        let parts = line.split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(parts[0], 240, accuracy: 6)
        XCTAssertEqual(parts[1], 120, accuracy: 6)
        XCTAssertEqual(Self.observeUser(), before)
    }

    func testCanvasDragGoesThroughCuaInTheBackground() async throws {
        let (client, session, capture) = try await capturedFixture()
        let scale = try pixelScale(capture)
        let top = titleBar(capture, scale) + 20
        let before = Self.observeUser()
        _ = try await client.execute(
            try ComputerAction(actionID: "drag", command: .drag(
                from: .windowPixels(x: 120 * scale, y: (top + 60) * scale),
                to: .windowPixels(x: 400 * scale, y: (top + 180) * scale),
                durationMilliseconds: 300,
                steps: 12
            )),
            sessionID: session
        )
        let line = try await waitForLine { $0.hasPrefix("canvas-drag") }
        let parts = line.split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(parts[0], 100, accuracy: 6)
        XCTAssertEqual(parts[1], 60, accuracy: 6)
        XCTAssertEqual(parts[2], 380, accuracy: 6)
        XCTAssertEqual(parts[3], 180, accuracy: 6)
        XCTAssertEqual(Self.observeUser(), before)
    }

    func testPressableButtonIsClickedOnceThroughAccessibility() async throws {
        let (client, session, capture) = try await capturedFixture()
        try await click("Works", client: client, session: session, capture: capture)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(lines(), ["works ax"])
    }

    func testButtonThatIgnoresThePressIsRetriedThroughCua() async throws {
        let (client, session, capture) = try await capturedFixture()
        let before = Self.observeUser()
        try await click("Inert", client: client, session: session, capture: capture)
        _ = try await waitForLine { $0 == "inert mouse" }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(lines().filter { $0.hasPrefix("inert") }, ["inert mouse"])
        XCTAssertEqual(Self.observeUser(), before)
    }

    func testConsequentialButtonThatIgnoresThePressIsNotRetried() async throws {
        let (client, session, capture) = try await capturedFixture()
        try await click("Send", client: client, session: session, capture: capture)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertFalse(lines().contains("send mouse"))
    }

    private func capturedFixture() async throws -> (AgentDesktopClient, String, ScreenCapturedWindow) {
        let fallback = CuaDriverClient()
        let fallbackHealth = await fallback.health()
        _ = try XCTUnwrap(fallbackHealth.ready ? true : nil, fallbackHealth.summary)
        let client = AgentDesktopClient(fallback: fallback)
        addTeardownBlock { await client.shutdown() }
        let health = await client.health()
        _ = try XCTUnwrap(health.ready ? true : nil, health.summary)
        let session = "perry-live-hybrid-\(UUID().uuidString)"
        let capture = try await client.capture(target: target, sessionID: session)
        XCTAssertEqual(capture.target.title, "Perry Hybrid Fixture")
        return (client, session, capture)
    }

    private func click(_ label: String, client: AgentDesktopClient, session: String, capture: ScreenCapturedWindow) async throws {
        let element = try XCTUnwrap(
            capture.accessibilitySnapshotModel?.elements.first { $0.role == .button && $0.label == label },
            "no \(label) button in the snapshot"
        )
        _ = try await client.execute(
            ComputerAction(stepID: label, operation: .click(.element(id: element.stableID, label: label, point: nil))),
            sessionID: session
        )
    }

    private func pixelScale(_ capture: ScreenCapturedWindow) throws -> Double {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(capture.screenshotData as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return Double(image.width) / 520
    }

    private func titleBar(_ capture: ScreenCapturedWindow, _ scale: Double) -> Double {
        let source = CGImageSourceCreateWithData(capture.screenshotData as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        return Double(image.height) / scale - 360
    }

    private static func observeUser() -> String {
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        return "\(Int(cursor.x)),\(Int(cursor.y)) \(front)"
    }

    private func lines() -> [String] {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("ready ") }
    }

    private func waitForLine(_ matches: (String) -> Bool) async throws -> String {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if let line = text.split(separator: "\n").map(String.init).first(where: matches) { return line }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw FixtureTimeout(log: lines())
    }
}

private struct FixtureTimeout: Error {
    let log: [String]
}
