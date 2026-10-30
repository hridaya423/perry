import XCTest
@testable import Perry

@MainActor
final class RoutineOfferTests: XCTestCase {
    @MainActor private final class Harness {
        var onboarding = false
        var offered = false
        var presentations = 0
        lazy var offer = RoutineOffer(
            isOnboarding: { [unowned self] in onboarding },
            wasOffered: { [unowned self] in offered },
            markOffered: { [unowned self] in offered = true },
            present: { [unowned self] in presentations += 1 }
        )
    }

    func testTheCardAppearsOnceAfterTheFirstGUITask() {
        let harness = Harness()
        harness.offer.taskFinished(usedGUI: true)
        harness.offer.taskFinished(usedGUI: true)
        XCTAssertEqual(harness.presentations, 1)
        XCTAssertTrue(harness.offered)
    }

    func testATaskThatNeverTouchedAnAppDoesNotOffer() {
        let harness = Harness()
        harness.offer.taskFinished(usedGUI: false)
        XCTAssertEqual(harness.presentations, 0)
        XCTAssertFalse(harness.offered)
        harness.offer.taskFinished(usedGUI: true)
        XCTAssertEqual(harness.presentations, 1)
    }

    func testNothingAppearsDuringOnboardingAndTheOfferStaysAvailable() {
        let harness = Harness()
        harness.onboarding = true
        harness.offer.taskFinished(usedGUI: true)
        XCTAssertEqual(harness.presentations, 0)
        XCTAssertFalse(harness.offered)
        harness.onboarding = false
        harness.offer.taskFinished(usedGUI: true)
        XCTAssertEqual(harness.presentations, 1)
    }

    func testAnEarlierOfferIsRemembered() {
        let harness = Harness()
        harness.offered = true
        harness.offer.taskFinished(usedGUI: true)
        XCTAssertEqual(harness.presentations, 0)
    }

    func testOnlyScreenToolsCountAsUsingAnApp() {
        for name in ["ui.click", "ui.type", "ui.hotkey", "ui.drag"] {
            XCTAssertTrue(ForegroundTaskController.isGUITool(name), name)
        }
        for name in ["files.read", "screen.observe", "memory.write", "integrations.write"] {
            XCTAssertFalse(ForegroundTaskController.isGUITool(name), name)
        }
    }

    func testTheOfferedFlagIsAPerryPreference() {
        let key = PerryPreferences.$routineOffered.key
        XCTAssertTrue(key.hasPrefix("perry."))
        let saved = UserDefaults.standard.object(forKey: key)
        addTeardownBlock {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        PerryPreferences.$routineOffered.reset()
        XCTAssertFalse(PerryPreferences.routineOffered)
        PerryPreferences.routineOffered = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
    }
}
