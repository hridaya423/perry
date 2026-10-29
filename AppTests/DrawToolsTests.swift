import AppKit
import PerryBrain
import PerryGuide
import PerryOverlay
import XCTest
@testable import Perry

@MainActor
final class DrawToolsTests: XCTestCase {
    func testMarksAtPointsLandWhereTheScreenshotShowsThem() async throws {
        let overlay = PerryCursorState()
        let observations = AgentObservationStore()
        let context = ToolContext(surface: .agent, runID: UUID())
        observations.store(AgentObservationStore.Snapshot(
            index: ElementIndex(elements: []), window: nil, screenshotData: nil,
            windowBoundsAX: CGRect(x: 100, y: 200, width: 400, height: 300),
            imageSize: CGSize(width: 800, height: 600)
        ), runID: context.runID)
        let tools = DrawTools(overlayState: overlay, observations: observations).executors
        func run(_ name: String, _ arguments: [String: JSONValue]) async throws {
            let tool = try XCTUnwrap(tools.first { $0.spec.name == name })
            _ = try await tool.run(ToolCall(id: name, name: name, arguments: .object(arguments)), context: context)
        }
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0

        try await run("ring", ["x": .number(200), "y": .number(100)])
        let ring = try XCTUnwrap(overlay.visualGuidanceOverlays.last).geometry
        let rect = try XCTUnwrap(ring["rect"] as? [String: Double])
        XCTAssertEqual(rect["x"]! + rect["width"]! / 2, 200, accuracy: 0.5)
        XCTAssertEqual(rect["y"]! + rect["height"]! / 2, primaryMaxY - 250, accuracy: 0.5)

        try await run("path", ["points": .array([
            .object(["x": .number(0), "y": .number(0)]),
            .object(["x": .number(800), "y": .number(600)]),
        ])])
        let stroke = try XCTUnwrap(overlay.visualGuidanceOverlays.last?.geometry["points"] as? [[String: Double]])
        XCTAssertEqual(stroke.map { $0["x"] }, [100, 500])
        XCTAssertEqual(stroke.map { $0["y"] }, [primaryMaxY - 200, primaryMaxY - 500])
    }
}

private extension PerryGuidanceOverlay {
    var geometry: [String: Any] {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any] ?? [:]
    }
}
