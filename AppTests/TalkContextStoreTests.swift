import AppKit
import XCTest
import PerryBrain
import PerryCore
import PerryGuide
import PerryOverlay
@testable import Perry

@MainActor
final class TalkContextStoreTests: XCTestCase {
    private let key = TalkContextKey(processID: 7, windowID: 9)

    func testThreadPersistsWithinTTL() throws {
        var now: TimeInterval = 1000
        let store = TalkContextStore(now: { now })
        let thread = UUID()
        store.record(key, threadID: thread)
        now += 120
        XCTAssertEqual(store.thread(for: key), thread)
    }

    func testThreadExpiresAfterTTL() throws {
        var now: TimeInterval = 1000
        let store = TalkContextStore(now: { now }, ttl: 600)
        store.record(key, threadID: UUID())
        now += 601
        XCTAssertNil(store.thread(for: key))
    }

    func testReadRefreshesTTL() throws {
        var now: TimeInterval = 1000
        let store = TalkContextStore(now: { now }, ttl: 600)
        let thread = UUID()
        store.record(key, threadID: thread)
        now += 550
        XCTAssertEqual(store.thread(for: key), thread)
        now += 550
        XCTAssertEqual(store.thread(for: key), thread)
    }

    func testResetPhraseClearsContext() throws {
        let store = TalkContextStore()
        store.record(key, threadID: UUID())
        XCTAssertTrue(TalkContextStore.isResetPhrase("new topic: tell me about that"))
        store.reset(key)
        XCTAssertNil(store.thread(for: key))
    }

    func testKeysAreIndependent() throws {
        let store = TalkContextStore()
        let other = TalkContextKey(processID: 8, windowID: 9)
        let thread = UUID()
        store.record(key, threadID: thread)
        XCTAssertNil(store.thread(for: other))
        XCTAssertEqual(store.thread(for: key), thread)
    }

    func testAcceptInputReusesWindowThread() throws {
        let home = HomeController()
        let first = home.acceptInput("what is this", contextKey: key)
        home.homeModel.threads = [PerryThread(id: first.threadID)]
        let followUp = home.acceptInput("and that one", contextKey: key)
        XCTAssertEqual(first.threadID, followUp.threadID)
    }

    func testAcceptInputSeparatesWindows() throws {
        let home = HomeController()
        let editorKey = TalkContextKey(processID: 7, windowID: 9)
        let browserKey = TalkContextKey(processID: 8, windowID: 4)
        let editor = home.acceptInput("what is this", contextKey: editorKey)
        let browser = home.acceptInput("what is this", contextKey: browserKey)
        XCTAssertNotEqual(editor.threadID, browser.threadID)
    }

    func testAcceptInputResetPhraseStartsFreshForWindow() throws {
        let home = HomeController()
        let first = home.acceptInput("what is this", contextKey: key)
        let fresh = home.acceptInput("new topic — what's that", contextKey: key)
        XCTAssertNotEqual(first.threadID, fresh.threadID)
    }

    func testAcceptInputDropsMappedThreadThatNoLongerExists() throws {
        let home = HomeController()
        let first = home.acceptInput("what is this", contextKey: key)
        home.homeModel.threads.removeAll { $0.id == first.threadID }
        let next = home.acceptInput("and this", contextKey: key)
        XCTAssertNotEqual(first.threadID, next.threadID)
    }
}
