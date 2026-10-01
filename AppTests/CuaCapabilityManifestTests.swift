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
