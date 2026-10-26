import XCTest
@testable import PerryBrain

final class ToolConsentStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testGrantPersistsAcrossInstances() async throws {
        let store = ToolConsentStore(directory: dir)
        let granted = await store.isGranted(tool: "files.trash", threadID: "t1")
        XCTAssertFalse(granted)

        try await store.grantAlways(tool: "files.trash", threadID: "t1")
        let now = await store.isGranted(tool: "files.trash", threadID: "t1")
        XCTAssertTrue(now)

        // A fresh instance reads the persisted grant.
        let reloaded = ToolConsentStore(directory: dir)
        let persisted = await reloaded.isGranted(tool: "files.trash", threadID: "t1")
        XCTAssertTrue(persisted)
        // Other tools and other threads still need asking.
        let otherTool = await reloaded.isGranted(tool: "integrations.write", threadID: "t1")
        let otherThread = await reloaded.isGranted(tool: "files.trash", threadID: "t2")
        XCTAssertFalse(otherTool)
        XCTAssertFalse(otherThread)
    }

    func testRevoke() async throws {
        let store = ToolConsentStore(directory: dir)
        try await store.grantAlways(tool: "a", threadID: "t")
        try await store.grantAlways(tool: "b", threadID: "t")
        try await store.revoke(threadID: "t", tool: "a")
        let a = await store.isGranted(tool: "a", threadID: "t")
        let b = await store.isGranted(tool: "b", threadID: "t")
        XCTAssertFalse(a)
        XCTAssertTrue(b)
        try await store.revoke(threadID: "t")
        let bAfter = await store.isGranted(tool: "b", threadID: "t")
        XCTAssertFalse(bAfter)
    }

    func testApprovingWrapperAutoApprovesGranted() async throws {
        let store = ToolConsentStore(directory: nil)
        try await store.grantAlways(tool: "files.move", threadID: "t1")
        var asked = 0
        let approve = await store.approving(threadID: "t1") { _, _ in
            asked += 1
            return .approvedOnce
        }
        let granted = await approve(
            ToolCall(id: "1", name: "files.move", arguments: .object([:])),
            ToolSpec(name: "files.move", description: "", inputSchema: .object([:]))
        )
        XCTAssertEqual(granted, .approvedOnce)
        XCTAssertEqual(asked, 0)

        let ungranted = await approve(
            ToolCall(id: "2", name: "files.trash", arguments: .object([:])),
            ToolSpec(name: "files.trash", description: "", inputSchema: .object([:]))
        )
        XCTAssertEqual(ungranted, .approvedOnce)
        XCTAssertEqual(asked, 1)
    }

    func testNoThreadIDNeverAutoApproves() async throws {
        let store = ToolConsentStore(directory: nil)
        var asked = false
        let approve = await store.approving(threadID: nil) { _, _ in
            asked = true
            return .denied
        }
        let result = await approve(
            ToolCall(id: "1", name: "x", arguments: .object([:])),
            ToolSpec(name: "x", description: "", inputSchema: .object([:]))
        )
        XCTAssertEqual(result, .denied)
        XCTAssertTrue(asked)
    }
}
