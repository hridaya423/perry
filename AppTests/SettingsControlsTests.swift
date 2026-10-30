import PerryGuide
import XCTest
@testable import Perry

@MainActor
final class SettingsControlsTests: XCTestCase {
    private var directory: URL!
    private var controller: AppController!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller = AppController.testing(directory: directory)
    }

    override func tearDown() async throws {
        controller.subsystems.notchPresence.stop()
        controller = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testForgettingOneNoteLeavesTheOthersNewestFirst() async {
        await controller.setMemoryEnabled(true)
        let older = MemoryRecord(category: .preference, summary: "sorts by name", createdAt: Date(timeIntervalSince1970: 1))
        let newer = MemoryRecord(category: .appWorkflow, summary: "exports as PDF", createdAt: Date(timeIntervalSince1970: 2))
        let gone = MemoryRecord(category: .pastSession, summary: "planned the trip", createdAt: Date(timeIntervalSince1970: 3))
        for record in [older, newer, gone] { await controller.subsystems.memoryStore.remember(record) }
        let forgotten = await controller.forgetMemory(gone.id)
        XCTAssertTrue(forgotten)
        let remaining = await controller.memories()
        XCTAssertEqual(remaining.map(\.id), [newer.id, older.id])
    }

    func testErasingWhatPerryKnowsRemovesNotesAndProfileOnly() async throws {
        await controller.setMemoryEnabled(true)
        await controller.subsystems.memoryStore.remember(MemoryRecord(category: .preference, summary: "sorts by name"))
        let memory = directory.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        try "Name: Sam".write(to: memory.appendingPathComponent("PROFILE.md"), atomically: true, encoding: .utf8)
        try "Project: trip".write(to: memory.appendingPathComponent("CONTEXT.md"), atomically: true, encoding: .utf8)
        PerryPreferences.speechRate = 1.3
        defer { PerryPreferences.speechRate = 1.0 }

        let erased = await controller.eraseMemory()

        XCTAssertTrue(erased)
        let remaining = await controller.memories()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: memory.appendingPathComponent("PROFILE.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: memory.appendingPathComponent("CONTEXT.md").path))
        XCTAssertEqual(PerryPreferences.speechRate, 1.3)
    }

    func testTheNotchEyesSwitchSavesTheChoice() {
        let previous = PerryPreferences.notchStatusEnabled
        defer { controller.setNotchEyes(previous) }
        controller.setNotchEyes(false)
        XCTAssertFalse(PerryPreferences.notchStatusEnabled)
        controller.setNotchEyes(true)
        XCTAssertTrue(PerryPreferences.notchStatusEnabled)
    }

    func testTheMeterMapsQuietAndLoudToTheEnds() {
        XCTAssertEqual(MicrophoneLevelMeter.normalized(0), 0)
        XCTAssertEqual(MicrophoneLevelMeter.normalized(1), 1, accuracy: 0.0001)
        XCTAssertEqual(MicrophoneLevelMeter.normalized(0.01), 0.4, accuracy: 0.0001)
    }
}
