import XCTest
import PerryCapture
@testable import Perry

@MainActor
final class OnboardingDirectorTests: XCTestCase {
    private let granted = PerryPermissionSnapshot(
        accessibility: true, screenRecording: .granted, microphone: .granted
    )
    private let denied = PerryPermissionSnapshot(
        accessibility: false, screenRecording: .denied, microphone: .denied
    )

    private func makeDirector(
        snapshot: PerryPermissionSnapshot? = nil,
        spoken: NSMutableArray? = nil
    ) -> (OnboardingDirector, NSMutableArray) {
        let speech = spoken ?? NSMutableArray()
        var effects = OnboardingDirector.Effects()
        effects.permissionProbe = { snapshot ?? self.denied }
        effects.speak = { speech.add($0) }
        return (OnboardingDirector(effects: effects), speech)
    }

    func testTalkTurnDrivesGreetThenFirstTalk() {
        let (director, speech) = makeDirector()
        director.start()

        XCTAssertEqual(director.beat, .greet)
        XCTAssertEqual(speech.firstObject as? String, OnboardingDirector.scriptGreet)

        director.noteTalkTurnCompleted()
        XCTAssertEqual(director.beat, .firstTalk)
        XCTAssertEqual(speech.lastObject as? String, OnboardingDirector.scriptTalk)
        director.noteTalkTurnCompleted()
        XCTAssertEqual(director.beat, .screenAccess)
        director.stop()
    }

    func testSkipWalksEveryBeat() {
        let (director, _) = makeDirector()
        var beats: [OnboardingDirector.Beat?] = []
        director.onBeatChanged = { beats.append(($0, $1).0) }
        director.start()
        // Greet → firstTalk → screenAccess → brainChoice → practice steps → finale.
        director.skip() // greet → firstTalk
        director.skip() // firstTalk → screenAccess
        XCTAssertEqual(director.beat, .screenAccess)
        director.skip() // screenAccess → brainChoice
        director.skip() // brainChoice → practice
        XCTAssertEqual(director.beat, .practice)
        XCTAssertEqual(director.practiceStep, .pointAsk)
        director.skip() // pointAsk → guide
        XCTAssertEqual(director.practiceStep, .guide)
        director.skip() // guide → renameUndo
        director.skip() // renameUndo → dictate
        director.skip() // dictate → finale
        XCTAssertEqual(director.beat, .finale)
        director.skip() // finale → done
        XCTAssertNil(director.beat)
        // onBeatChanged fires once per practice sub-step too.
        XCTAssertEqual(beats, [
            .greet, .firstTalk, .screenAccess, .brainChoice,
            .practice, .practice, .practice, .practice,
            .finale,
        ])
    }

    func testDeniedMicSpeaksKeyboardVariant() {
        let (director, speech) = makeDirector()
        director.start()
        director.skip() // greet → firstTalk
        director.noteMicrophoneDenied()
        XCTAssertTrue(director.micDenied)
        XCTAssertEqual(speech.lastObject as? String, OnboardingDirector.scriptNoMicTalk)
    }

    func testDeniedMicBeforeFirstTalkSpeaksVariantOnEntry() {
        let (director, speech) = makeDirector()
        director.noteMicrophoneDenied() // denied before reaching the beat
        director.start()
        director.skip() // greet → firstTalk
        XCTAssertEqual(speech.lastObject as? String, OnboardingDirector.scriptNoMicTalk)
    }

    func testPermissionGrantAutoAdvances() async {
        let (director, _) = makeDirector(snapshot: granted)
        director.start()
        director.skip() // greet → firstTalk
        director.skip() // firstTalk → screenAccess (starts polling)
        XCTAssertEqual(director.beat, .screenAccess)

        // The 500 ms poll should detect the grant and advance.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(director.beat, .brainChoice)
        director.stop()
    }

    func testDeniedPermissionsKeepBeatWaiting() async {
        let (director, _) = makeDirector(snapshot: denied)
        director.start()
        director.skip()
        director.skip()
        XCTAssertEqual(director.beat, .screenAccess)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(director.beat, .screenAccess) // still waiting — no dead-end, but no advance
        director.stop()
    }

    func testPracticeStepsCompleteToFinale() {
        let (director, _) = makeDirector()
        director.start()
        while director.beat != .practice && director.beat != nil {
            director.skip()
        }
        XCTAssertEqual(director.practiceStep, .pointAsk)
        director.notePracticeStepCompleted()
        XCTAssertEqual(director.practiceStep, .guide)
        director.notePracticeStepCompleted()
        XCTAssertEqual(director.practiceStep, .renameUndo)
        director.notePracticeStepCompleted()
        XCTAssertEqual(director.practiceStep, .dictate)
        director.notePracticeStepCompleted()
        XCTAssertEqual(director.beat, .finale)
    }

    func testEventsIgnoredOutsideTheirBeat() {
        let (director, _) = makeDirector()
        director.start()
        director.notePracticeStepCompleted() // not in practice — no-op
        director.noteBrainChoiceMade()       // not in brainChoice — no-op
        XCTAssertEqual(director.beat, .greet)
    }
}
