import XCTest
import PerryCapture
@testable import Perry

@MainActor
final class OnboardingDirectorTests: XCTestCase {
    private let granted = PerryPermissionSnapshot(accessibility: true, screenRecording: .granted, microphone: .denied)
    private let denied = PerryPermissionSnapshot(accessibility: false, screenRecording: .denied, microphone: .denied)

    func testProviderReadinessPrecedesTheFirstConversation() {
        let director = OnboardingDirector()
        director.start()
        XCTAssertEqual(director.beat, .greet)
        director.skip()
        XCTAssertEqual(director.beat, .brainChoice)
        director.noteTalkTurnCompleted()
        XCTAssertEqual(director.beat, .brainChoice)
        director.noteBrainChoiceMade()
        XCTAssertEqual(director.beat, .firstTalk)
        director.noteTalkTurnCompleted()
        XCTAssertEqual(director.beat, .screenAccess)
        director.stop()
    }

    func testPermissionsDoNotOpenSettingsUntilRequested() async {
        var opened = 0
        var requested = 0
        var effects = OnboardingDirector.Effects()
        effects.permissionProbe = { self.denied }
        effects.requestScreenAccess = { requested += 1 }
        effects.openScreenAccessSettings = { opened += 1 }
        let director = OnboardingDirector(effects: effects)
        director.start()
        director.skip()
        director.skip()
        director.skip()
        await director.refreshPermissions()
        XCTAssertEqual(director.beat, .screenAccess)
        XCTAssertEqual(requested, 1)
        XCTAssertEqual(opened, 0)
        director.openAccessibilitySettings()
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(director.beat, .screenAccess)
        director.stop()
    }

    func testScreenPermissionsAdvanceWithoutMicrophonePermission() async {
        var effects = OnboardingDirector.Effects()
        effects.permissionProbe = { self.granted }
        let director = OnboardingDirector(effects: effects)
        director.start()
        director.skip()
        director.skip()
        director.skip()
        await director.refreshPermissions()
        XCTAssertEqual(director.beat, .practice)
        XCTAssertFalse(director.practiceStarted)
        director.stop()
    }

    func testPracticeRequiresAnExplicitStartAndActualCompletionEvents() {
        var starts = 0
        var effects = OnboardingDirector.Effects()
        effects.beginPractice = { starts += 1 }
        let director = OnboardingDirector(effects: effects)
        director.start()
        for _ in 0..<4 { director.skip() }
        XCTAssertEqual(director.beat, .practice)
        XCTAssertEqual(starts, 0)
        director.notePracticeStepCompleted()
        XCTAssertEqual(director.practiceStep, .pointAsk)
        director.startPractice()
        XCTAssertEqual(starts, 1)
        for expected in [OnboardingDirector.PracticeStep.guide, .renameUndo, .dictate] {
            director.notePracticeStepCompleted()
            XCTAssertEqual(director.practiceStep, expected)
        }
        director.notePracticeStepCompleted()
        XCTAssertEqual(director.beat, .finale)
        director.stop()
    }

    func testInterruptedSetupResumesAndCompletionClearsCheckpoint() throws {
        let name = "perry.onboarding.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = OnboardingDirector(defaults: defaults)
        first.start()
        first.skip()
        first.noteBrainChoiceMade()
        first.stop()
        let resumed = OnboardingDirector(defaults: defaults)
        resumed.start()
        XCTAssertEqual(resumed.beat, .firstTalk)
        resumed.skip()
        resumed.skip()
        resumed.skip()
        XCTAssertEqual(resumed.beat, .finale)
        resumed.skip()
        XCTAssertNil(resumed.beat)
        let fresh = OnboardingDirector(defaults: defaults)
        fresh.start()
        XCTAssertEqual(fresh.beat, .greet)
        fresh.stop()
    }

    func testSkippedPermissionPollCannotAdvanceAReplacementBeat() async {
        let entered = expectation(description: "Permission probe entered")
        var release: CheckedContinuation<PerryPermissionSnapshot, Never>?
        var effects = OnboardingDirector.Effects()
        effects.permissionProbe = { await withCheckedContinuation { release = $0; entered.fulfill() } }
        let director = OnboardingDirector(effects: effects)
        director.start()
        director.skip()
        director.skip()
        director.skip()
        let poll = Task { await director.refreshPermissions() }
        await fulfillment(of: [entered], timeout: 1)
        director.skip()
        release?.resume(returning: granted)
        await poll.value
        XCTAssertEqual(director.beat, .practice)
        director.stop()
    }
}
