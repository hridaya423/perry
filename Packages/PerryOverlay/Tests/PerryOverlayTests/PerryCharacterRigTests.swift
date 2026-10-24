import XCTest
@testable import PerryOverlay

final class PerryCharacterRigTests: XCTestCase {
    func testOnlyARestingCharacterFallsAsleep() {
        let still = PerryCharacterRig.sleepAfter + 1
        XCTAssertEqual(PerryCharacterRig(mood: .resting, moodAge: 0, time: 0, stillFor: still).pose.face, .asleep)
        XCTAssertNotEqual(PerryCharacterRig(mood: .needsYou, moodAge: 0, time: 0, stillFor: still).pose.face, .asleep)
        XCTAssertNotEqual(PerryCharacterRig(mood: .resting, moodAge: 0, time: 0, stillFor: still - 2).pose.face, .asleep)
    }

    func testReducedMotionRemovesTravelBounceAndStretch() {
        for mood in PerryMood.allCases {
            let pose = PerryCharacterRig(
                mood: mood, previousMood: .resting, moodAge: 0.1, time: 7.3,
                velocity: CGVector(dx: 3000, dy: -900), acceleration: CGVector(dx: -40_000, dy: 0),
                micLevel: 0.8, reduceMotion: true
            ).pose
            XCTAssertEqual(pose.lean, 0, "\(mood)")
            XCTAssertEqual(pose.hop, 0, "\(mood)")
            XCTAssertEqual(pose.stretch, 1, "\(mood)")
            XCTAssertEqual(pose.trail, .zero, "\(mood)")
            XCTAssertEqual(pose.statusScale, 1, "\(mood)")
        }
    }

    func testLeanAndStretchStayBoundedAtAnySpeed() {
        let pose = PerryCharacterRig(
            mood: .resting, moodAge: 0, time: 0,
            velocity: CGVector(dx: 90_000, dy: 0), acceleration: CGVector(dx: -900_000, dy: 0)
        ).pose
        XCTAssertLessThanOrEqual(abs(pose.lean), PerryCharacterRig.maxLean)
        XCTAssertLessThan(pose.stretch, 1.2)
    }

    func testCelebrationHopLandsWhenItEnds() {
        let mid = PerryCharacterRig(mood: .celebrating, moodAge: PerryCharacterRig.celebrationLength / 2, time: 1).pose
        let done = PerryCharacterRig(mood: .celebrating, moodAge: PerryCharacterRig.celebrationLength * 3, time: 9).pose
        XCTAssertGreaterThan(mid.hop, 0.5)
        XCTAssertEqual(done.hop, 0, accuracy: 0.0001)
    }

    func testEyesAreOpenAlmostAllTheTime() {
        let samples = stride(from: 0.0, to: 120, by: 1.0 / 60).map(PerryCharacterRig.blinkOpenness(at:))
        let closedShare = Double(samples.filter { $0 < 0.5 }.count) / Double(samples.count)
        XCTAssertGreaterThan(closedShare, 0)
        XCTAssertLessThan(closedShare, 0.05)
    }

    func testVoiceStateOutranksTaskState() {
        XCTAssertEqual(PerryMood(voice: .listening, buddy: .acting), .listening)
        XCTAssertEqual(PerryMood(voice: .responding, buddy: .success), .speaking)
        XCTAssertEqual(PerryMood(voice: .idle, buddy: .awaitingApproval), .needsYou)
        XCTAssertEqual(PerryMood(voice: .idle, buddy: .blocked), .needsYou)
    }

    func testMoodChangesBlendInsteadOfCutting() {
        func eye(at age: TimeInterval) -> PerryStroke {
            PerryCharacterRig(mood: .celebrating, previousMood: .resting, moodAge: age, time: 1).pose.eye
        }
        XCTAssertEqual(eye(at: 0), PerryCharacterPose.Face.open.eye)
        XCTAssertEqual(eye(at: PerryCharacterRig.blendLength), PerryCharacterPose.Face.happy.eye)
        let halfway = eye(at: PerryCharacterRig.blendLength / 2)
        XCTAssertNotEqual(halfway, PerryCharacterPose.Face.open.eye)
        XCTAssertNotEqual(halfway, PerryCharacterPose.Face.happy.eye)
    }

    func testEveryMoodHasItsOwnStillSignature() {
        let signatures = PerryMood.allCases.map { mood -> String in
            let pose = PerryCharacterRig(mood: mood, moodAge: 5, time: 5, stillFor: mood == .sleeping ? 60 : 0, reduceMotion: true).pose
            return "\(pose.eye) \(pose.mouth.width > 0) \(pose.status.kind)"
        }
        XCTAssertEqual(Set(signatures).count, PerryMood.allCases.count, signatures.joined(separator: "\n"))
    }

    func testIdleRestingIsStill() {
        let times = stride(from: 0.0, to: 30, by: 0.37).filter { PerryCharacterRig.blinkOpenness(at: $0) == 1 }
        let poses = times.map { PerryCharacterRig(mood: .resting, moodAge: 10, time: $0, stillFor: 10).pose }
        XCTAssertGreaterThan(poses.count, 40)
        XCTAssertEqual(Set(poses.map { "\($0)" }).count, 1)
    }
}
