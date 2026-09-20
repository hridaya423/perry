import Foundation
import ImageIO
import XCTest
import PerryCapture
@testable import Perry

final class CuaLiveTests: XCTestCase {
    private let fixtureTitle = "Perry-Cua-Fixture.txt"
    private let fixtureMarker = "Perry Cua capture fixture 001"

    func testExactWindowCaptureSurvivesDriverRestart() async throws {
        let client = try await readyLiveClient()
        let sessionID = "perry-live-capture-\(UUID().uuidString)"
        let first = try await client.capture(
            target: CuaTargetHint(bundleID: "com.apple.TextEdit", windowTitle: fixtureTitle),
            sessionID: sessionID
        )
        try assertFixtureCapture(first)

        await client.reloadConfiguration()
        let retiredTarget = await client.target(for: sessionID)
        XCTAssertNil(retiredTarget)
        let health = await client.health()
        _ = try XCTUnwrap(health.ready ? true : nil, health.summary)

        let second = try await client.capture(
            target: CuaTargetHint(
                bundleID: first.target.bundleID,
                processID: first.target.processID,
                windowID: first.target.windowID
            ),
            sessionID: sessionID
        )
        try assertFixtureCapture(second)
        XCTAssertEqual(second.target.processID, first.target.processID)
        XCTAssertEqual(second.target.windowID, first.target.windowID)
        XCTAssertGreaterThan(second.target.connectionGeneration, first.target.connectionGeneration)
    }

    func testMissingExactWindowDoesNotCaptureAnotherWindow() async throws {
        let client = try await readyLiveClient()
        let reference = try await client.capture(
            target: CuaTargetHint(bundleID: "com.apple.TextEdit", windowTitle: fixtureTitle),
            sessionID: "perry-live-reference-\(UUID().uuidString)"
        )
        try assertFixtureCapture(reference)
        let sessionID = "perry-live-missing-\(UUID().uuidString)"
        do {
            _ = try await client.capture(
                target: CuaTargetHint(
                    bundleID: reference.target.bundleID,
                    processID: reference.target.processID,
                    windowID: Int64.max
                ),
                sessionID: sessionID
            )
            XCTFail("An absent exact window must not fall back to another window")
        } catch let error as CuaDriverError {
            XCTAssertEqual(error, .noTargetWindow)
        }
        let target = await client.target(for: sessionID)
        XCTAssertNil(target)
    }

    private func readyLiveClient() async throws -> CuaDriverClient {
        guard ProcessInfo.processInfo.environment["PERRY_LIVE_CUA"] == "1" else {
            throw XCTSkip("Set PERRY_LIVE_CUA=1 in the test runner after opening the documented TextEdit fixture and granting Perry permissions")
        }
        let client = CuaDriverClient()
        addTeardownBlock { await client.shutdown() }
        let health = await client.health()
        return try XCTUnwrap(health.ready ? client : nil, health.summary)
    }

    private func assertFixtureCapture(_ capture: CuaCapturedWindow) throws {
        XCTAssertEqual(capture.target.bundleID, "com.apple.TextEdit")
        XCTAssertEqual(capture.target.title, fixtureTitle)
        XCTAssertGreaterThan(capture.target.processID, 0)
        XCTAssertGreaterThan(capture.target.windowID, 0)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(capture.screenshotData as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertGreaterThan(image.width, 100)
        XCTAssertGreaterThan(image.height, 100)
        let text = try PerryVisionTextRecognizer.recognizeText(in: capture.screenshotData)
            .map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains(fixtureMarker), "The exact-window image must contain the seeded fixture marker")
    }
}
