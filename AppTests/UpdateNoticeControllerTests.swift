import XCTest
@testable import Perry

@MainActor
final class UpdateNoticeControllerTests: XCTestCase {
    func testUpdaterConfigurationRequiresHTTPSAndAnEdDSAPublicKey() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let configuration = PerryUpdaterConfiguration(info: [
            "SUFeedURL": "https://updates.perry.example/appcast.xml",
            "SUPublicEDKey": key,
        ])

        XCTAssertEqual(configuration?.feedURL.absoluteString, "https://updates.perry.example/appcast.xml")
        XCTAssertEqual(configuration?.publicKey, Data(repeating: 7, count: 32))
        XCTAssertNil(PerryUpdaterConfiguration(info: [
            "SUFeedURL": "http://updates.perry.example/appcast.xml",
            "SUPublicEDKey": key,
        ]))
        XCTAssertNil(PerryUpdaterConfiguration(info: [
            "SUFeedURL": "https://updates.perry.example/appcast.xml",
            "SUPublicEDKey": Data(repeating: 7, count: 31).base64EncodedString(),
        ]))
    }

    func testSparkleNotificationsDoNotPresentWhenUpdaterIsUnavailable() {
        let suiteName = "dev.perry.tests.update-notice.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var presentCount = 0
        var spoken: [String] = []
        let controller = UpdateNoticeController(
            defaults: defaults,
            onPresent: { presentCount += 1 },
            onSpeak: { spoken.append($0) }
        )

        guard case .unavailable = controller.availability else {
            return XCTFail("The test bundle must not configure a production update feed")
        }
        controller.start()
        NotificationCenter.default.post(name: Notification.Name("SPUUpdaterDidFinishUpdateCycleNotification"), object: nil)

        XCTAssertEqual(presentCount, 0)
        XCTAssertTrue(spoken.isEmpty)
    }

    func testVersionNoticePresentsOnce() async {
        let suiteName = "dev.perry.tests.update-notice.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("0.9.0", forKey: "perry.lastSeenVersion")
        let presented = expectation(description: "version notice presented")
        var presentCount = 0
        let controller = UpdateNoticeController(
            defaults: defaults,
            onPresent: {
                presentCount += 1
                presented.fulfill()
            },
            onSpeak: { _ in }
        )

        controller.start()
        controller.start()
        await fulfillment(of: [presented], timeout: 1)
        XCTAssertEqual(presentCount, 1)
    }
}
