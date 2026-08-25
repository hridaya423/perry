import XCTest
@testable import PerryOverlay

final class ControlBridgeTests: XCTestCase {
    func testScribbleToolCallParsesToGuidanceCommand() throws {
        let command = PerryControlBridge.testCommand(from: [
            "tool": "show_scribble",
            "arguments": [
                "points": [["x": 10, "y": 20], [30, 40], ["x": "50", "y": "60"]],
                "accentHex": "#34D399",
                "durationMs": 1500,
                "lineWidth": 6,
            ],
        ])
        guard case .showVisualGuidanceOverlay(let overlay) = command else {
            return XCTFail("expected guidance overlay command, got \(String(describing: command))")
        }
        XCTAssertEqual(overlay.kind, .scribble)
        XCTAssertEqual(overlay.points.count, 3)
        XCTAssertEqual(overlay.duration, 1.5)
        XCTAssertEqual(overlay.style.lineWidth, 6)
    }

    func testRectangleHighlightParsesWithFillOpacity() throws {
        let command = PerryControlBridge.testCommand(from: [
            "tool": "show_highlight",
            "arguments": ["x1": 100, "y1": 200, "x2": 150, "y2": 260, "fillOpacity": 0.25],
        ])
        guard case .showVisualGuidanceOverlay(let overlay) = command else {
            return XCTFail("expected guidance overlay command")
        }
        XCTAssertEqual(overlay.kind, .rectangle)
        XCTAssertEqual(overlay.rect, PerryGuidanceRect(x: 100, y: 200, width: 50, height: 60))
        XCTAssertEqual(overlay.style.fillOpacity, 0.25)
    }

    func testUnknownToolsReturnNil() {
        XCTAssertNil(PerryControlBridge.testCommand(from: ["tool": "gmail_list_messages", "arguments": [:]]))
        XCTAssertNil(PerryControlBridge.testCommand(from: ["tool": "shell_exec", "arguments": [:]]))
    }

    func testAdvertisedSurfaceIsDrawingAndDisplayOnly() {
        let names = PerryControlBridge.testMCPToolDescriptors.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("show_scribble"))
        XCTAssertTrue(names.contains("show_highlight"))
        XCTAssertFalse(names.contains { $0.hasPrefix("gmail") })

        let capabilityIDs = PerryControlBridge.testCapabilityCompatibilityMetadata.compactMap { $0["id"] as? String }
        XCTAssertEqual(Set(capabilityIDs), Set(["visual_guidance.scribble", "visual_guidance.rectangle"]))
    }

    func testBridgeTokenReadsFromEnvironment() {
        setenv("PERRY_BRIDGE_TOKEN", "test-token-123", 1)
        defer { unsetenv("PERRY_BRIDGE_TOKEN") }
        XCTAssertEqual(PerryControlBridge.bridgeToken(), "test-token-123")
    }

    func testLiveLoopbackServerEnforcesAuthAndRoutesCommands() async throws {
        setenv("PERRY_BRIDGE_TOKEN", "loopback-test", 1)
        defer { unsetenv("PERRY_BRIDGE_TOKEN") }

        let received = ReceivedBox()
        let bridge = PerryControlBridge(port: 39431) { command in
            await received.append(command)
            return PerryControlResponse.ok(["ok": true])
        }
        bridge.start()
        try await Task.sleep(nanoseconds: 400_000_000)
        defer { bridge.stop() }

        let base = URL(string: "http://127.0.0.1:39431")!

        var health = URLRequest(url: base.appendingPathComponent("health"))
        health.httpMethod = "GET"
        let (healthBody, healthResponse) = try await URLSession.shared.data(for: health)
        let healthStatus = try XCTUnwrap(healthResponse as? HTTPURLResponse)
        XCTAssertEqual(healthStatus.statusCode, 200)
        let healthJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: healthBody) as? [String: Any])
        XCTAssertEqual(healthJSON["ok"] as? Bool, true)

        var unauthorized = URLRequest(url: base.appendingPathComponent("clear"))
        unauthorized.httpMethod = "POST"
        let (_, deniedResponse) = try await URLSession.shared.data(for: unauthorized)
        let deniedStatus = try XCTUnwrap(deniedResponse as? HTTPURLResponse)
        XCTAssertEqual(deniedStatus.statusCode, 401)

        var authorized = URLRequest(url: base.appendingPathComponent("clear"))
        authorized.httpMethod = "POST"
        authorized.addValue("loopback-test", forHTTPHeaderField: "x-perry-token")
        let (_, okResponse) = try await URLSession.shared.data(for: authorized)
        let okStatus = try XCTUnwrap(okResponse as? HTTPURLResponse)
        XCTAssertEqual(okStatus.statusCode, 200)

        let commands = await received.snapshot()
        XCTAssertTrue(commands.contains { command in
            if case .clear = command { return true }
            return false
        })
    }
}

private final class ReceivedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PerryControlCommand] = []

    func append(_ command: PerryControlCommand) {
        lock.lock()
        items.append(command)
        lock.unlock()
    }

    func snapshot() -> [PerryControlCommand] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
