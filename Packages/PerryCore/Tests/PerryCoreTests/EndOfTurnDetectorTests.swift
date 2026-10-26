import Foundation
import XCTest
@testable import PerryCore

final class EndOfTurnDetectorTests: XCTestCase {
    struct Fixture: Decodable {
        struct Transcript: Decodable {
            let t: Double
            let text: String
            let lastWordEnd: Double
        }
        let name: String
        let frames: [[Double]]
        let transcripts: [Transcript]
        let speechEnd: Double?
    }

    struct Outcome {
        let fixture: Fixture
        let event: EndOfTurnDetector.Event?
        let at: Double
        var latency: Double? { fixture.speechEnd.map { at - $0 } }
        var cutOff: Bool { (latency ?? 0) < 0 }
    }

    static func fixtures() throws -> [Fixture] {
        let directory = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/turns", withExtension: nil))
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: $0)) }
    }

    static func replay(_ fixture: Fixture) -> Outcome {
        var detector = EndOfTurnDetector(startedAt: 0)
        var transcripts = fixture.transcripts[...]
        for frame in fixture.frames {
            let t = frame[0]
            while let next = transcripts.first, next.t <= t {
                transcripts = transcripts.dropFirst()
                _ = detector.transcript(at: next.t, text: next.text, lastWordEnd: next.lastWordEnd)
            }
            switch detector.frame(at: t, rms: frame[1]) {
            case let event? where event.isTerminal: return Outcome(fixture: fixture, event: event, at: t)
            default: continue
            }
        }
        return Outcome(fixture: fixture, event: nil, at: fixture.frames.last?[0] ?? 0)
    }

    func testEveryFixtureEndsTheWayItShould() throws {
        let outcomes = try Self.fixtures().map(Self.replay)
        XCTAssertEqual(outcomes.count, 14)
        for outcome in outcomes {
            if outcome.fixture.speechEnd == nil {
                XCTAssertEqual(outcome.event, .abort(.noSpeech), outcome.fixture.name)
                XCTAssertEqual(outcome.at, 8, accuracy: 0.03, outcome.fixture.name)
            } else {
                XCTAssertEqual(outcome.event, .commit(.silence), outcome.fixture.name)
                XCTAssertFalse(outcome.cutOff, "\(outcome.fixture.name) committed \(-(outcome.latency ?? 0)) s before the speech ended")
            }
        }
    }

    func testShortQuestionCommitsWithin900msOfTheLastWord() throws {
        let fixture = try XCTUnwrap(Self.fixtures().first { $0.name == "short-question" })
        let latency = try XCTUnwrap(Self.replay(fixture).latency)
        XCTAssertLessThan(latency, 0.9)
    }

    func testFillerPauseDoesNotEndTheTurn() throws {
        let fixture = try XCTUnwrap(Self.fixtures().first { $0.name == "um-pause" })
        let outcome = Self.replay(fixture)
        XCTAssertEqual(outcome.event, .commit(.silence))
        XCTAssertGreaterThan(outcome.at, try XCTUnwrap(fixture.speechEnd))
    }

    func testNoiseBedIsNotSpeech() throws {
        let fixture = try XCTUnwrap(Self.fixtures().first { $0.name == "fan-only" })
        XCTAssertEqual(Self.replay(fixture).event, .abort(.noSpeech))
    }

    func testCutOffRateAndMedianLatencyMeetTheTargets() throws {
        let spoken = try Self.fixtures().map(Self.replay).filter { $0.fixture.speechEnd != nil }
        let cutOffRate = Double(spoken.filter(\.cutOff).count) / Double(spoken.count)
        let latencies = spoken.compactMap(\.latency).sorted()
        let median = latencies[latencies.count / 2]
        print("endofturn cutoff=\(cutOffRate) median=\(median) latencies=\(spoken.map { "\($0.fixture.name):\(String(format: "%.2f", $0.latency ?? -1))" })")
        XCTAssertLessThan(cutOffRate, 0.05)
        XCTAssertLessThan(median, 0.9)
    }

    func testUserActionsEndTheTurnImmediately() {
        var detector = EndOfTurnDetector(startedAt: 0)
        XCTAssertEqual(detector.transcript(at: 0.5, text: "open", lastWordEnd: 0.4), .speechStarted)
        XCTAssertEqual(detector.userAction(.sendNow), .commit(.userSent))
        XCTAssertNil(detector.frame(at: 0.6, rms: 0.1))
        var cancelled = EndOfTurnDetector(startedAt: 0)
        XCTAssertEqual(cancelled.userAction(.cancel), .abort(.cancelled))
    }

    func testTrailingCuesWaitLongerThanClearEnds() {
        var detector = EndOfTurnDetector(startedAt: 0)
        _ = detector.transcript(at: 1, text: "Draft a reply and", lastWordEnd: 0.9)
        XCTAssertEqual(detector.requiredSilence, 1.2)
        _ = detector.transcript(at: 2, text: "Draft a reply and keep it short.", lastWordEnd: 1.9)
        XCTAssertEqual(detector.requiredSilence, 0.5)
        _ = detector.transcript(at: 3, text: "Stop reading.", lastWordEnd: 2.9)
        XCTAssertEqual(detector.requiredSilence, 0.7)
        _ = detector.transcript(at: 4, text: "Stop reading. Remind me to", lastWordEnd: 3.9)
        XCTAssertEqual(detector.requiredSilence, 1.2)
        _ = detector.transcript(at: 5, text: "Stop reading. Remind me to call Maya", lastWordEnd: 4.9)
        XCTAssertEqual(detector.requiredSilence, 1.0)
    }

    func testTurnCapCommits() {
        var detector = EndOfTurnDetector(startedAt: 0)
        var event: EndOfTurnDetector.Event?
        var t = 0.0
        while event == nil || event == .speechStarted {
            t += 0.02
            event = detector.frame(at: t, rms: t < 0.1 ? 0.0004 : 0.05)
        }
        XCTAssertEqual(event, .commit(.turnCap))
        XCTAssertEqual(t, 60, accuracy: 0.03)
    }
}

private extension EndOfTurnDetector.Event {
    var isTerminal: Bool {
        switch self {
        case .commit, .abort: true
        case .speechStarted, .silence: false
        }
    }
}
