import Foundation
import XCTest
import PerryCore
@testable import Perry

final class CuaCapabilityManifestTests: XCTestCase {
    private var testDirectory: URL!

    override func setUpWithError() throws {
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CuaCapabilityManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDirectory)
    }

    func testMaterializeGeneratesAllowlistMinusBlocklist() throws {
        let appsDirectory = testDirectory.appendingPathComponent("Applications", isDirectory: true)
        try makeApp("Browser.app", bundleID: "com.example.Browser", in: appsDirectory)
        try makeApp("OnePassword.app", bundleID: "com.agilebits.onepassword7", in: appsDirectory)

        let url = try XCTUnwrap(CuaCapabilityManifest.materialize(
            into: testDirectory.appendingPathComponent("CuaDriver", isDirectory: true),
            hostBundleID: "dev.perry.Perry",
            applicationDirectories: [appsDirectory],
            extraBundleIDs: ["com.example.RunningOnly", "dev.perry.Perry"],
            fileManager: .default
        ))
        let yaml = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(yaml.contains("display: true"))
        XCTAssertTrue(yaml.contains("bundle_id: \"com.example.Browser\""))
        XCTAssertTrue(yaml.contains("bundle_id: \"com.example.RunningOnly\""))
        XCTAssertFalse(yaml.contains("onepassword"), "blocked bundle IDs must not reach the manifest")
        XCTAssertFalse(yaml.contains("dev.perry.Perry"), "Perry must not be able to drive itself")
        XCTAssertTrue(yaml.contains("- get_desktop_state"))
        XCTAssertTrue(yaml.contains("- list_windows"))
        XCTAssertTrue(yaml.contains("- set_value"))
        XCTAssertTrue(yaml.contains("launch: true"))
        XCTAssertTrue(yaml.contains("terminate: deny"))
    }

    func testMaterializeRecursesOneLevelIntoApplicationFolders() throws {
        let appsDirectory = testDirectory.appendingPathComponent("Applications", isDirectory: true)
        try makeApp("Top.app", bundleID: "com.example.Top", in: appsDirectory)
        let utilities = appsDirectory.appendingPathComponent("Utilities", isDirectory: true)
        try makeApp("Nested.app", bundleID: "com.example.Nested", in: utilities)
        let deep = utilities.appendingPathComponent("Deep", isDirectory: true)
        try makeApp("TooDeep.app", bundleID: "com.example.TooDeep", in: deep)

        let url = try XCTUnwrap(CuaCapabilityManifest.materialize(
            into: testDirectory.appendingPathComponent("CuaDriver", isDirectory: true),
            hostBundleID: "dev.perry.Perry",
            applicationDirectories: [appsDirectory],
            extraBundleIDs: [],
            fileManager: .default
        ))
        let yaml = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(yaml.contains("bundle_id: \"com.example.Top\""))
        XCTAssertTrue(yaml.contains("bundle_id: \"com.example.Nested\""))
        XCTAssertFalse(yaml.contains("TooDeep"), "folders are scanned one level only")
    }

    func testMaterializeReturnsNilWhenNoAppsAllowed() {
        let emptyDirectory = testDirectory.appendingPathComponent("Empty", isDirectory: true)
        XCTAssertNil(CuaCapabilityManifest.materialize(
            into: testDirectory.appendingPathComponent("CuaDriver", isDirectory: true),
            hostBundleID: "dev.perry.Perry",
            applicationDirectories: [emptyDirectory],
            extraBundleIDs: ["com.bitwarden.desktop"],
            fileManager: .default
        ))
    }

    func testMaterializeEscapesBundleIDQuotes() throws {
        let url = try XCTUnwrap(CuaCapabilityManifest.materialize(
            into: testDirectory.appendingPathComponent("CuaDriver", isDirectory: true),
            hostBundleID: "dev.perry.Perry",
            applicationDirectories: [],
            extraBundleIDs: ["com.example.odd\"id"],
            fileManager: .default
        ))
        let yaml = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(yaml.contains("bundle_id: \"com.example.odd\\\"id\""))
    }

    private func makeApp(_ name: String, bundleID: String, in directory: URL) throws {
        let contents = directory.appendingPathComponent(name).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID]
        try (plist as NSDictionary).write(
            to: contents.appendingPathComponent("Info.plist"),
            atomically: true
        )
    }
}

@MainActor
final class CuaManifestRefresherTests: XCTestCase {
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var _scanned: Set<String> = []
        private var _writes = 0
        var scanned: Set<String> {
            get { lock.withLock { _scanned } }
            set { lock.withLock { _scanned = newValue } }
        }
        var writes: Int { lock.withLock { _writes } }
        func noteWrite() { lock.withLock { _writes += 1 } }
    }

    private func makeRefresher(_ probe: Probe) -> CuaCapabilityManifest.Refresher {
        CuaCapabilityManifest.Refresher(
            directory: URL(fileURLWithPath: "/tmp"),
            hostBundleID: "dev.perry.Perry",
            notificationCenter: NotificationCenter(),
            coveredBundleIDs: { probe.scanned },
            materialize: { _, _ in
                probe.noteWrite()
                return nil
            }
        )
    }

    private func settle(_ refresher: CuaCapabilityManifest.Refresher) async {
        while let pending = refresher.pending { await pending.value }
    }

    func testStartOnlyLearnsCoverage() async {
        let probe = Probe()
        probe.scanned = ["com.example.known"]
        let refresher = makeRefresher(probe)

        refresher.start()
        await settle(refresher)
        XCTAssertEqual(probe.writes, 0, "the worker spawn already wrote the manifest")

        refresher.noteLaunch(of: "com.example.known")
        await settle(refresher)
        XCTAssertEqual(probe.writes, 0, "a covered launch must not rewrite the manifest")
    }

    func testUncoveredLaunchRewritesOnce() async {
        let probe = Probe()
        probe.scanned = ["com.example.known"]
        let refresher = makeRefresher(probe)
        refresher.start()
        await settle(refresher)

        probe.scanned.insert("com.example.new")  // running by the time the note arrives
        refresher.noteLaunch(of: "com.example.new")
        await settle(refresher)
        XCTAssertEqual(probe.writes, 1)

        refresher.noteLaunch(of: "com.example.new")
        await settle(refresher)
        XCTAssertEqual(probe.writes, 1, "the refreshed scan covers the new bundle")
    }

    func testLaunchDuringScanOnlyPassRewritesAfterIt() async {
        let probe = Probe()
        let refresher = makeRefresher(probe)
        refresher.start()
        probe.scanned = ["com.example.new"]
        refresher.noteLaunch(of: "com.example.new")
        refresher.noteLaunch(of: "com.example.other")
        await settle(refresher)
        XCTAssertEqual(probe.writes, 1, "queued launches coalesce into one rewrite")
    }
}
