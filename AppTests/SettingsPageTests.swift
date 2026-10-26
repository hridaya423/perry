import XCTest
@testable import Perry

final class SettingsPageTests: XCTestCase {
    func testEveryOldTabOpensItsNewPage() {
        let expected: [String: SettingsPage] = [
            "general": .general,
            "voice": .voice,
            "runtimes": .brain,
            "integrations": .apps,
            "memory": .you,
            "safety": .privacy,
        ]
        for (old, page) in expected {
            XCTAssertEqual(SettingsPage(stored: old), page, old)
        }
        XCTAssertEqual(SettingsPage(stored: "unknown"), .general)
        for page in SettingsPage.allCases {
            XCTAssertEqual(SettingsPage(stored: page.rawValue), page)
        }
    }

    func testPerryToolPagesOpenTheMatchingPage() {
        XCTAssertEqual(SettingsPage(perryPage: "voice"), .voice)
        XCTAssertEqual(SettingsPage(perryPage: "apps"), .apps)
        XCTAssertEqual(SettingsPage(perryPage: "memory"), .you)
        XCTAssertEqual(SettingsPage(perryPage: "brain"), .brain)
        XCTAssertEqual(SettingsPage(perryPage: "perrys"), .brain)
        XCTAssertEqual(SettingsPage(perryPage: nil), .general)
    }

    func testTheSidebarListsEveryPageOnceInPlanOrder() {
        XCTAssertEqual(SettingsPage.groups.flatMap(\.pages), [.general, .you, .voice, .dictation, .shortcuts, .brain, .apps, .privacy])
        XCTAssertEqual(SettingsPage.groups.map(\.title), [nil, "Talk", "Connect", "Trust"])
    }

    func testRecoveryLinksNameTheNewPage() {
        XCTAssertEqual(FailureRecovery.settings(.brain).title, "Open Brain settings")
        XCTAssertEqual(FailureRecovery.settings(.privacy).title, "Open Privacy settings")
    }
}
