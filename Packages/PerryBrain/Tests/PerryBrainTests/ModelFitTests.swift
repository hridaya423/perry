import XCTest
@testable import PerryBrain

final class ModelFitTests: XCTestCase {
    private let gib: UInt64 = 1 << 30

    private func profile(_ chip: String, gb: UInt64, workingSetShare: Double = 0.78, appleIntelligence: Bool = false) -> MachineProfile {
        let memory = gb * gib
        return MachineProfile(
            memoryBytes: memory,
            workingSetBytes: UInt64(Double(memory) * workingSetShare),
            chip: Chip(brandString: "Apple \(chip)"),
            gpuCores: nil,
            powerSource: .ac,
            lowPowerMode: false,
            thermalState: .nominal,
            appleIntelligenceAvailable: appleIntelligence
        )
    }

    private func recommend(_ chip: String, gb: UInt64, workingSetShare: Double = 0.78, budget: MemoryBudget = .nothing, appleIntelligence: Bool = false) -> Recommendation {
        ModelFit.recommend(profile: profile(chip, gb: gb, workingSetShare: workingSetShare, appleIntelligence: appleIntelligence), budget: budget)
    }

    private func offers(gb: UInt64, workingSetShare: Double = 0.75, freeGB: Double) -> [ModelOffer] {
        ModelFit.offers(profile: profile("M4 Pro", gb: gb, workingSetShare: workingSetShare), freeDiskBytes: Int64(freeGB * 1e9))
    }

    func testOffersHoloAsRecommendedAndGuiOwlAsSmall() {
        let result = offers(gb: 48, freeGB: 100)
        XCTAssertEqual(result.map(\.rung.id), ["Holo-3.1-4B-Q4_K_M", "GUI-Owl-1.5-2B-Q4_K_M"])
        XCTAssertEqual(ModelFit.recommended(result)?.size, .recommended)
    }

    func testRecommendationStepsDownWhenTheDiskIsTooSmall() {
        let result = offers(gb: 48, freeGB: 4)
        XCTAssertEqual(result[0].blocker, .disk(neededGB: 5.74))
        XCTAssertEqual(ModelFit.recommended(result)?.size, .small)
    }

    func testEightGigabytesWithASmallWorkingSetBlocksHoloOnMemory() {
        let result = offers(gb: 8, workingSetShare: 0.67, freeGB: 100)
        XCTAssertEqual(result.map(\.blocker), [.memory, nil])
        XCTAssertEqual(ModelFit.recommended(result)?.size, .small)
    }

    func testChipParsing() {
        XCTAssertEqual(Chip(brandString: "Apple M4 Pro"), Chip(generation: 4, kind: .pro))
        XCTAssertEqual(Chip(brandString: "Apple M1"), Chip(generation: 1, kind: .base))
        XCTAssertEqual(Chip(brandString: "Apple M2 Max"), Chip(generation: 2, kind: .max))
        XCTAssertEqual(Chip(brandString: "Apple M3 Ultra"), Chip(generation: 3, kind: .ultra))
        XCTAssertEqual(Chip(brandString: "Apple M5"), Chip(generation: 5, kind: .base))
        XCTAssertEqual(Chip(brandString: "Intel(R) Core(TM) i9"), Chip(generation: 0, kind: .base))
    }

    func testEightGigabytesUsesTheTwoBillionModelWhenFourBillionFailsTheFitRule() {
        let result = recommend("M2", gb: 8, workingSetShare: 0.67)
        XCTAssertEqual(result.interactive.id, "Qwen3.5-2B-UD-Q4_K_XL")
        XCTAssertNil(result.deep)
    }

    func testEightGigabytesUsesTheFourBillionModelOnlyWhenTheFitRulePasses() {
        let result = recommend("M2", gb: 8, workingSetShare: 0.78)
        XCTAssertEqual(result.interactive.id, "Qwen3.5-4B-UD-Q4_K_XL")
        XCTAssertNil(result.deep)
    }

    func testFitRuleIsSeventyFivePercentOfTheWorkingSet() {
        let model = ModelRung.qwen35_9B_UDQ4KXL
        let limit = UInt64(model.activeGB * 1e9 / 0.75)
        var spec = profile("M4 Pro", gb: 16)
        spec.workingSetBytes = limit - 1_000_000
        XCTAssertFalse(ModelFit.fits(model, on: spec))
        spec.workingSetBytes = limit + 1_000_000
        XCTAssertTrue(ModelFit.fits(model, on: spec))
    }

    func testSixteenGigabytesSplitsOlderAndNewerChips() {
        XCTAssertEqual(recommend("M3", gb: 16).interactive.id, "Qwen3.5-9B-UD-Q4_K_XL")
        XCTAssertEqual(recommend("M4", gb: 16).interactive.id, "Qwen3.5-9B-UD-Q4_K_XL")
        XCTAssertEqual(recommend("M5", gb: 16).interactive.id, "Qwen3.5-9B-UD-Q4_K_XL")
        XCTAssertEqual(recommend("M1", gb: 16).interactive.id, "Qwen3.5-4B-UD-Q4_K_XL")
        XCTAssertEqual(recommend("M2", gb: 16).interactive.id, "Qwen3.5-4B-UD-Q4_K_XL")
        XCTAssertNil(recommend("M4", gb: 16).deep)
    }

    func testTwentyFourGigabytesChipClassBeatsRam() {
        let pro = recommend("M4 Pro", gb: 24)
        let base = recommend("M4", gb: 24)
        XCTAssertEqual(pro.interactive.id, "Qwen3.5-9B-UD-Q6_K_XL")
        XCTAssertEqual(base.interactive.id, "Qwen3.5-9B-UD-Q4_K_XL")
        XCTAssertNil(pro.deep)
        XCTAssertNil(base.deep)
        let ladder = ModelFit.interactiveLadder.map(\.id)
        XCTAssertEqual(ladder.firstIndex(of: pro.interactive.id)!, ladder.firstIndex(of: base.interactive.id)! + 1)
    }

    func testThirtyTwoGigabytes() {
        let result = recommend("M2 Max", gb: 32, workingSetShare: 0.85)
        XCTAssertEqual(result.interactive.id, "Qwen3.6-35B-A3B-UD-IQ4_XS")
        XCTAssertEqual(result.deep?.id, "Qwen3.8-27B-UD-IQ4_XS")
    }

    func testThirtyTwoGigabytesAtSeventyEightPercentFailsTheFitRuleForTheMixtureModel() {
        let result = recommend("M2 Max", gb: 32)
        XCTAssertEqual(result.interactive.id, "Qwen3.5-9B-UD-Q6_K_XL")
        XCTAssertEqual(result.deep?.id, "Qwen3.8-27B-UD-IQ4_XS")
    }

    func testThirtyTwoGigabytesOnABaseChipDropsARungAndHasNoDeepLane() {
        let result = recommend("M4", gb: 32, workingSetShare: 0.85)
        XCTAssertEqual(result.interactive.id, "Qwen3.5-9B-UD-Q6_K_XL")
        XCTAssertNil(result.deep)
    }

    func testFortyEightGigabytes() {
        let result = recommend("M4 Pro", gb: 48)
        XCTAssertEqual(result.interactive.id, "Qwen3.6-35B-A3B-UD-Q4_K_XL")
        XCTAssertEqual(result.deep?.id, "Qwen3.8-27B-UD-Q5_K_XL")
    }

    func testSixtyFourGigabytes() {
        let result = recommend("M5 Pro", gb: 64)
        XCTAssertEqual(result.interactive.id, "Qwen3.6-35B-A3B-UD-Q6_K")
        XCTAssertEqual(result.deep?.id, "Qwen3.8-27B-UD-Q6_K")
    }

    func testNinetySixGigabytesAndUp() {
        for gb: UInt64 in [96, 128, 192, 512] {
            let result = recommend("M5 Max", gb: gb)
            XCTAssertEqual(result.interactive.id, "Qwen3.6-35B-A3B-Q8_0")
            XCTAssertEqual(result.deep?.id, "Qwen3.8-27B-Q8_0")
        }
    }

    func testOddMemorySizesRoundDownToTheirTier() {
        XCTAssertEqual(recommend("M3 Pro", gb: 18).interactive.id, "Qwen3.5-9B-UD-Q4_K_XL")
        XCTAssertEqual(recommend("M3 Max", gb: 36, workingSetShare: 0.85).interactive.id, "Qwen3.6-35B-A3B-UD-IQ4_XS")
        XCTAssertEqual(recommend("M4 Max", gb: 128).interactive.id, "Qwen3.6-35B-A3B-Q8_0")
    }

    func testNothingFitsStillReturnsTheSmallestModel() {
        let result = recommend("M1", gb: 8, workingSetShare: 0.2)
        XCTAssertEqual(result.interactive.id, "Qwen3.5-2B-UD-Q4_K_XL")
    }

    func testHelperIsAppleFoundationModelsWhenAvailable() {
        XCTAssertEqual(recommend("M4", gb: 16, appleIntelligence: true).helper, .appleFoundationModels)
    }

    func testHelperFallsBackToTheSmallQwen() {
        guard case .model(let model) = recommend("M4", gb: 16).helper else { return XCTFail("expected a model helper") }
        XCTAssertEqual(model.id, "Qwen3.5-0.8B-Q4_K_M")
    }

    func testNothingBudgetKeepsNothingResident() {
        let result = recommend("M4 Pro", gb: 48, budget: .nothing)
        XCTAssertEqual(result.resident, [])
        XCTAssertEqual(result.idleMemoryGB, 0)
    }

    func testUpToTwoGigabytesKeepsOnlyTheHelperResident() {
        let apple = recommend("M4 Pro", gb: 48, budget: .upTo2GB, appleIntelligence: true)
        XCTAssertEqual(apple.resident, [.helper])
        XCTAssertEqual(apple.idleMemoryGB, 0)
        let qwen = recommend("M4 Pro", gb: 48, budget: .upTo2GB)
        XCTAssertEqual(qwen.resident, [.helper])
        XCTAssertEqual(qwen.idleMemoryGB, 0.73, accuracy: 0.001)
        XCTAssertLessThanOrEqual(qwen.idleMemoryGB, 2)
    }

    func testKeepMainModelReadyKeepsOneLaneResidentBelowNinetySixGigabytes() {
        for gb: UInt64 in [8, 16, 24, 32, 48, 64] {
            let result = recommend("M4 Pro", gb: gb, workingSetShare: 0.85, budget: .keepMainReady)
            XCTAssertEqual(result.resident, [.interactive], "\(gb) GB")
            XCTAssertEqual(result.idleMemoryGB, result.interactive.downloadGB, accuracy: 0.001)
        }
    }

    func testKeepMainModelReadyKeepsBothLanesResidentAtNinetySixGigabytes() {
        let result = recommend("M5 Max", gb: 128, budget: .keepMainReady)
        XCTAssertEqual(result.resident, [.interactive, .deep])
        XCTAssertEqual(result.idleMemoryGB, 37.8 + 30.0, accuracy: 0.001)
    }

    func testBudgetDoesNotChangeTheModels() {
        let nothing = recommend("M4 Pro", gb: 48, budget: .nothing)
        for budget in MemoryBudget.allCases {
            let other = recommend("M4 Pro", gb: 48, budget: budget)
            XCTAssertEqual(other.interactive, nothing.interactive)
            XCTAssertEqual(other.deep, nothing.deep)
            XCTAssertEqual(other.helper, nothing.helper)
        }
    }
}
