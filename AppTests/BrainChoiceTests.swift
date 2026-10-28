import PerryBrain
import XCTest
@testable import Perry

private final class FakeProcess: LocalEngineProcess {
    var isRunning = true
    let processIdentifier: Int32 = 0
    var terminations = 0
    func terminate() {
        terminations += 1
        isRunning = false
    }
}

@MainActor
final class BrainChoiceTests: XCTestCase {
    private let cursor = AcpAgent(id: "cursor", name: "Cursor", command: "cursor-agent", arguments: ["acp"])

    func testTheCloudRowsComeInPlanOrder() {
        XCTAssertEqual(CloudBrainList.rows(claudeCodeInstalled: true, agents: [cursor]), [.chatGPT, .claudeCode, .agent(cursor), .apiKey])
        XCTAssertEqual(CloudBrainList.rows(claudeCodeInstalled: false, agents: []), [.chatGPT, .apiKey])
    }

    func testTheSavedChoiceWinsThenTheFirstReadyRow() {
        let rows = CloudBrainList.rows(claudeCodeInstalled: true, agents: [cursor])
        var states: [BrainController.ModelChoice: SetupState] = [.chatGPT: .needsSignIn, .claudeCode: .ready(detail: "Signed in"), .acp: .ready(detail: "Installed")]
        XCTAssertEqual(CloudBrainList.preselected(saved: .chatGPT, savedAgent: nil, rows: rows, states: states, hasProfile: false), .chatGPT)
        XCTAssertEqual(CloudBrainList.preselected(saved: .acp, savedAgent: cursor, rows: rows, states: states, hasProfile: false), .agent(cursor))
        XCTAssertNil(CloudBrainList.preselected(saved: .local, savedAgent: nil, rows: rows, states: states, hasProfile: false))
        XCTAssertEqual(CloudBrainList.preselected(saved: nil, savedAgent: nil, rows: rows, states: states, hasProfile: false), .claudeCode)
        states = [.chatGPT: .needsSignIn, .claudeCode: .needsSignIn, .acp: .notInstalled]
        XCTAssertEqual(CloudBrainList.preselected(saved: nil, savedAgent: nil, rows: rows, states: states, hasProfile: true), .apiKey)
        XCTAssertNil(CloudBrainList.preselected(saved: nil, savedAgent: nil, rows: rows, states: states, hasProfile: false))
    }

    func testOnboardingHighlightsTheRouteThatIsReadyNow() {
        XCTAssertEqual(BrainBeat.initialRoute(saved: nil, cloudReady: false, localReady: false), .cloud)
        XCTAssertEqual(BrainBeat.initialRoute(saved: nil, cloudReady: false, localReady: true), .local)
        XCTAssertEqual(BrainBeat.initialRoute(saved: nil, cloudReady: true, localReady: true), .cloud)
        XCTAssertEqual(BrainBeat.initialRoute(saved: .local, cloudReady: true, localReady: true), .local)
        XCTAssertEqual(BrainBeat.initialRoute(saved: .local, cloudReady: false, localReady: false), .cloud)
    }

    func testAnAPIKeyCountsAsReadyOnlyWithASavedProfile() {
        XCTAssertFalse(BrainBeat.isReady(.apiKey, states: [:], hasProfile: false))
        XCTAssertTrue(BrainBeat.isReady(.apiKey, states: [:], hasProfile: true))
        XCTAssertFalse(BrainBeat.isReady(.chatGPT, states: [.chatGPT: .needsSignIn], hasProfile: true))
        XCTAssertTrue(BrainBeat.isReady(.chatGPT, states: [.chatGPT: .ready(detail: "a@b.c")], hasProfile: false))
    }

    func testNoCloudRowSellsVoice() {
        for row in CloudBrainList.rows(claudeCodeInstalled: true, agents: [cursor]) {
            XCTAssertFalse(row.capability.lowercased().contains("voice"), row.title)
            XCTAssertFalse(row.capability.lowercased().contains("speak"), row.title)
        }
    }

    func testEachMemoryChoiceSetsTheServerIdleRules() {
        XCTAssertEqual(LocalBrain.idlePolicy(.nothing), .init(sleepIdleSeconds: 300, exitAfterIdle: .seconds(1800)))
        XCTAssertEqual(LocalBrain.idlePolicy(.upTo2GB), .init(sleepIdleSeconds: 300, exitAfterIdle: .seconds(1800)))
        XCTAssertEqual(LocalBrain.idlePolicy(.keepMainReady), .init(sleepIdleSeconds: nil, exitAfterIdle: nil))
        let model = LocalEngine.Model(weights: URL(fileURLWithPath: "/m.gguf"), projector: nil)
        let key = URL(fileURLWithPath: "/k")
        XCTAssertTrue(LocalEngine.arguments(lane: .interactive, model: model, port: 1, keyFile: key, sleepIdleSeconds: LocalBrain.idlePolicy(.nothing).sleepIdleSeconds).contains("--sleep-idle-seconds"))
        XCTAssertFalse(LocalEngine.arguments(lane: .interactive, model: model, port: 1, keyFile: key, sleepIdleSeconds: LocalBrain.idlePolicy(.keepMainReady).sleepIdleSeconds).contains("--sleep-idle-seconds"))
    }

    func testAPressureWarningStopsTheServerAndNormalDoesNot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = FakeProcess()
        let engine = LocalEngine(binary: URL(fileURLWithPath: "/bin/llama-server"), directory: directory, launch: { _, _ in process }, health: { _ in true }, freePort: { 4000 })
        let local = LocalBrain(engine: engine, modelsDirectory: directory, benchURL: directory.appendingPathComponent("bench.json"))
        _ = try await engine.start(lane: .interactive, model: .init(weights: URL(fileURLWithPath: "/m.gguf"), projector: nil), sleepIdleSeconds: nil, exitAfterIdle: nil)
        local.memoryPressure(.normal)
        XCTAssertEqual(process.terminations, 0)
        local.memoryPressure(.warning)
        XCTAssertEqual(process.terminations, 1)
        XCTAssertNil(engine.endpoint)
    }

    func testEachRungNamesItsHuggingFaceFiles() {
        XCTAssertEqual(ModelRung.qwen36_35B_UDQ4KXL.repo, "unsloth/Qwen3.6-35B-A3B-GGUF")
        XCTAssertEqual(ModelRung.qwen36_35B_UDQ4KXL.files, ["Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf", "mmproj-F16.gguf"])
        XCTAssertEqual(ModelRung.holo31_4B_Q4KM.repo, "mradermacher/Holo-3.1-4B-GGUF")
        XCTAssertEqual(ModelRung.holo31_4B_Q4KM.files, ["Holo-3.1-4B.Q4_K_M.gguf", "Holo-3.1-4B.mmproj-f16.gguf"])
    }

    func testADownloadedLineupModelIsReadyAtLaunchAndServesTheLocalRoute() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = LocalEngine(binary: URL(fileURLWithPath: "/bin/llama-server"), directory: directory, launch: { _, _ in FakeProcess() }, health: { _ in true }, freePort: { 4000 })
        let empty = LocalBrain(engine: engine, modelsDirectory: directory, benchURL: directory.appendingPathComponent("bench.json"))
        XCTAssertEqual(empty.phase, .notSetUp)
        XCTAssertNil(empty.provider)

        let rung = ModelRung.guiOwl15_2B_Q4KM
        let folder = directory.appendingPathComponent(rung.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in rung.files { try Data([1]).write(to: folder.appendingPathComponent(file)) }

        let local = LocalBrain(engine: engine, modelsDirectory: directory, benchURL: directory.appendingPathComponent("bench.json"))
        XCTAssertEqual(local.phase, .ready)
        XCTAssertEqual(local.installed, rung)
        XCTAssertEqual(local.model(for: rung)?.weights.lastPathComponent, "GUI-Owl-1.5-2B-Instruct.Q4_K_M.gguf")
        XCTAssertEqual(local.provider?.id.rawValue, "local.perry.GUI-Owl-1.5-2B-Q4_K_M")
        XCTAssertTrue(local.provider?.capabilities.isSuperset(of: [.tools, .vision, .local]) == true)
    }

    func testWithoutTheEngineNothingDownloads() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = LocalBrain(engine: nil, modelsDirectory: directory, benchURL: directory.appendingPathComponent("bench.json"))
        await local.setUp(.qwen35_2B_UDQ4KXL)
        guard case .failed(let message) = local.phase else { return XCTFail("Expected a failure") }
        XCTAssertTrue(message.contains("nothing was downloaded"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testTheMachineLineNamesChipAndMemory() {
        XCTAssertEqual(LocalBrainView.machineLine(Self.profile(gb: 48, chip: "Apple M4 Pro")), "This Mac: M4 Pro, 48 GB")
        XCTAssertEqual(LocalBrainView.machineLine(Self.profile(gb: 8, chip: "Apple M2")), "This Mac: M2, 8 GB")
        XCTAssertTrue(LocalBrainView.isSmall(Self.profile(gb: 8, chip: "Apple M2")))
        XCTAssertFalse(LocalBrainView.isSmall(Self.profile(gb: 16, chip: "Apple M2")))
    }

    static func profile(gb: UInt64, chip: String, appleIntelligence: Bool = true) -> MachineProfile {
        MachineProfile(
            memoryBytes: gb << 30, workingSetBytes: (gb << 30) * 3 / 4, chip: Chip(brandString: chip), gpuCores: 20,
            powerSource: .ac, lowPowerMode: false, thermalState: .nominal, appleIntelligenceAvailable: appleIntelligence
        )
    }
}
