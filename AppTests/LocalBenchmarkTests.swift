import XCTest
@testable import Perry

final class LocalBenchmarkTests: XCTestCase {
    private let rungs = [
        LocalBenchmark.Rung(model: "Qwen3.6-35B-A3B UD-Q6_K", activeGB: 32.3),
        LocalBenchmark.Rung(model: "Qwen3.6-35B-A3B UD-Q4_K_XL", activeGB: 25.4),
        LocalBenchmark.Rung(model: "Qwen3.6-35B-A3B UD-IQ4_XS", activeGB: 20.8),
        LocalBenchmark.Rung(model: "Qwen3.5-9B UD-Q6_K_XL", activeGB: 12.0),
        LocalBenchmark.Rung(model: "Qwen3.5-4B UD-Q4_K_XL", activeGB: 5.9),
        LocalBenchmark.Rung(model: "Qwen3.5-2B UD-Q4_K_XL", activeGB: 3.0),
    ]

    private func passing(_ change: (inout LocalBenchmark.Measurement) -> Void = { _ in }) -> LocalBenchmark.Measurement {
        var measurement = LocalBenchmark.Measurement(
            loadSeconds: 8, coldTurnSeconds: 6, referenceTurnSeconds: 3.6,
            decodeTokensPerSecond: 40, peakMemoryGB: 20, toolCallsPassed: 5, newPageOuts: 0
        )
        change(&measurement)
        return measurement
    }

    func testTheBenchmarkWaitsForPowerCoolAndFullSpeed() {
        let ready = LocalBenchmark.Conditions(onBattery: false, lowPowerMode: false, thermalState: .fair)
        XCTAssertNil(LocalBenchmark.postponement(ready))
        var conditions = ready
        conditions.onBattery = true
        XCTAssertEqual(LocalBenchmark.postponement(conditions), .onBattery)
        conditions = ready
        conditions.lowPowerMode = true
        XCTAssertEqual(LocalBenchmark.postponement(conditions), .lowPowerMode)
        conditions = ready
        conditions.thermalState = .serious
        XCTAssertEqual(LocalBenchmark.postponement(conditions), .tooHot)
    }

    func testTheStartRungSkipsModelsThatDoNotFit() {
        XCTAssertEqual(LocalBenchmark.startIndex(rungs: rungs, preferred: 0, workingSetGB: 36), 1)
        XCTAssertEqual(LocalBenchmark.startIndex(rungs: rungs, preferred: 2, workingSetGB: 36), 2)
        XCTAssertEqual(LocalBenchmark.startIndex(rungs: rungs, preferred: 0, workingSetGB: 5.3), 5)
        XCTAssertNil(LocalBenchmark.startIndex(rungs: rungs, preferred: 0, workingSetGB: 3))
    }

    func testEachConditionCanRejectARung() {
        let limits = LocalBenchmark.Limits.interactive
        XCTAssertTrue(LocalBenchmark.accepts(passing(), limits: limits, workingSetGB: 36))
        XCTAssertFalse(LocalBenchmark.accepts(passing { $0.referenceTurnSeconds = 6.1 }, limits: limits, workingSetGB: 36))
        XCTAssertFalse(LocalBenchmark.accepts(passing { $0.decodeTokensPerSecond = 14.9 }, limits: limits, workingSetGB: 36))
        XCTAssertFalse(LocalBenchmark.accepts(passing { $0.peakMemoryGB = 27.1 }, limits: limits, workingSetGB: 36))
        XCTAssertFalse(LocalBenchmark.accepts(passing { $0.newPageOuts = 1 }, limits: limits, workingSetGB: 36))
        XCTAssertFalse(LocalBenchmark.accepts(passing { $0.toolCallsPassed = 4 }, limits: limits, workingSetGB: 36))
        XCTAssertTrue(LocalBenchmark.accepts(passing { $0.referenceTurnSeconds = 18; $0.decodeTokensPerSecond = 9 }, limits: .deep, workingSetGB: 36))
    }

    func testTheRunStepsDownUntilARungPasses() async {
        let recorded = [
            rungs[1].model: passing { $0.referenceTurnSeconds = 9 },
            rungs[2].model: passing { $0.decodeTokensPerSecond = 12 },
            rungs[3].model: passing(),
        ]
        var measured: [String] = []
        let outcome = await LocalBenchmark.run(rungs: rungs, preferred: 1, limits: .interactive, workingSetGB: 36) { rung in
            measured.append(rung.model)
            return recorded[rung.model]!
        }
        XCTAssertEqual(outcome.chosen, rungs[3])
        XCTAssertEqual(measured, [rungs[1].model, rungs[2].model, rungs[3].model])
        XCTAssertEqual(outcome.attempts.map(\.accepted), [false, false, true])
        XCTAssertEqual(LocalBenchmark.summary(outcome), "Perry answers screen questions in about 4 seconds on this Mac.")
    }

    func testTheRunGivesUpAfterThreeStepDowns() async {
        var measured = 0
        let outcome = await LocalBenchmark.run(rungs: rungs, preferred: 0, limits: .interactive, workingSetGB: 64) { _ in
            measured += 1
            return passing { $0.toolCallsPassed = 3 }
        }
        XCTAssertNil(outcome.chosen)
        XCTAssertEqual(measured, 4)
        XCTAssertNil(LocalBenchmark.summary(outcome))
    }

    func testThePrefixCacheAndMTPRules() {
        XCTAssertTrue(passing { $0.coldTurnSeconds = 10; $0.referenceTurnSeconds = 7 }.prefixCacheWorks)
        XCTAssertFalse(passing { $0.coldTurnSeconds = 10; $0.referenceTurnSeconds = 7.1 }.prefixCacheWorks)
        XCTAssertTrue(LocalBenchmark.keepsMTP(answerSeconds: 20, withMTP: 17))
        XCTAssertFalse(LocalBenchmark.keepsMTP(answerSeconds: 20, withMTP: 17.1))
    }

    func testTheRecordRoundTripsAndReRunsOnlyWhenSomethingChanged() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let fingerprint = ["chip": "Apple M4 Pro", "osBuild": "27A100"]
        let record = LocalBenchmark.Record(
            fingerprint: fingerprint, engineVersion: "b11871", modelHash: "abc",
            interactive: LocalBenchmark.Outcome(chosen: rungs[1], attempts: [.init(rung: rungs[1], measurement: passing(), accepted: true)])
        )
        try LocalBenchmark.save(record, to: url)
        let loaded = LocalBenchmark.load(from: url)
        XCTAssertEqual(loaded, record)
        XCTAssertFalse(LocalBenchmark.needsRerun(loaded, fingerprint: fingerprint, engineVersion: "b11871", modelHash: "abc"))
        XCTAssertTrue(LocalBenchmark.needsRerun(loaded, fingerprint: ["osBuild": "27A200"], engineVersion: "b11871", modelHash: "abc"))
        XCTAssertTrue(LocalBenchmark.needsRerun(loaded, fingerprint: fingerprint, engineVersion: "b11900", modelHash: "abc"))
        XCTAssertTrue(LocalBenchmark.needsRerun(loaded, fingerprint: fingerprint, engineVersion: "b11871", modelHash: "def"))
        XCTAssertTrue(LocalBenchmark.needsRerun(nil, fingerprint: fingerprint, engineVersion: "b11871", modelHash: "abc"))
    }
}
