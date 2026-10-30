import XCTest
import PerryBrain
@testable import Perry

@MainActor
final class HomePerryRowTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-perry-rows-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPerryRowCreatesItsThreadStampedWithPerryID() async throws {
        let store = ThreadStore(directory: directory)
        let home = HomeController()
        home.threadStore = store
        home.openHome()

        let threadUUID = UUID()
        let perry = Perry(name: "Tidy Desk", job: "tidy", threadID: threadUUID.uuidString)
        home.homeModel.onPerrySelected?(perry)
        await home.joinAll()

        let thread = await store.thread(id: threadUUID)
        XCTAssertEqual(thread?.perryID, perry.id.uuidString)
        XCTAssertEqual(thread?.title, "Tidy Desk")
        XCTAssertEqual(home.homeModel.sidebarSelection, .thread(threadUUID))
    }

    func testPerryRowOpensExistingThreadWithoutRewritingIt() async throws {
        let store = ThreadStore(directory: directory)
        let home = HomeController()
        home.threadStore = store
        home.openHome()

        let threadUUID = UUID()
        var existing = try await store.upsert(PerryThread(id: threadUUID, title: "Original title"))
        existing = try await store.beginTurn(to: threadUUID, question: "earlier work")
        XCTAssertNotNil(existing.pendingTurn)

        let perry = Perry(name: "Different name", job: "tidy", threadID: threadUUID.uuidString)
        home.homeModel.onPerrySelected?(perry)
        await home.joinAll()

        let thread = await store.thread(id: threadUUID)
        XCTAssertEqual(thread?.title, "Original title")
        XCTAssertEqual(thread?.pendingTurn?.question, "earlier work")
        XCTAssertEqual(home.homeModel.sidebarSelection, .thread(threadUUID))
    }

    func testPerryRowIsRejectedWhileAdmissionClosed() async throws {
        let store = ThreadStore(directory: directory)
        let home = HomeController()
        home.threadStore = store
        home.openHome()

        home.closeAdmission()
        let threadUUID = UUID()
        let perry = Perry(name: "Tidy Desk", job: "tidy", threadID: threadUUID.uuidString)
        home.homeModel.onPerrySelected?(perry)
        await home.joinAll()

        let persisted = await store.thread(id: threadUUID)
        XCTAssertNil(persisted)
        XCTAssertNil(home.homeModel.sidebarSelection)
        home.reopenAdmission()
    }
}
