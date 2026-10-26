import XCTest
@testable import Perry

private final class FakeProcess: LocalEngineProcess {
    var isRunning = true
    var terminations = 0
    func terminate() {
        terminations += 1
        isRunning = false
    }
}

@MainActor
final class LocalEngineTests: XCTestCase {
    private let model = LocalEngine.Model(
        weights: URL(fileURLWithPath: "/models/main.gguf"),
        projector: URL(fileURLWithPath: "/models/mmproj.gguf"),
        draft: URL(fileURLWithPath: "/models/mtp.gguf")
    )
    private var directory: URL!
    private var launches: [[String]] = []
    private var processes: [FakeProcess] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func engine(healthy: Bool = true) -> LocalEngine {
        LocalEngine(
            binary: URL(fileURLWithPath: "/bin/llama-server"),
            directory: directory,
            launch: { [unowned self] _, arguments in
                launches.append(arguments)
                let process = FakeProcess()
                processes.append(process)
                return process
            },
            health: { _ in healthy },
            healthBudget: .milliseconds(300),
            freePort: { 51234 }
        )
    }

    func testEachLaneGetsItsOwnSamplingAndThinkingFlagsOnLoopbackOnly() {
        let key = URL(fileURLWithPath: "/tmp/key")
        let interactive = LocalEngine.arguments(lane: .interactive, model: model, port: 9, keyFile: key, sleepIdleSeconds: 300)
        XCTAssertTrue(interactive.joined(separator: " ").contains("--host 127.0.0.1 --port 9 --api-key-file /tmp/key"))
        XCTAssertTrue(interactive.joined(separator: " ").contains(#"--chat-template-kwargs {"enable_thinking":false} --temp 0.7 --top-p 0.8 --top-k 20 --min-p 0"#))
        XCTAssertTrue(interactive.joined(separator: " ").contains("--sleep-idle-seconds 300"))
        XCTAssertFalse(interactive.contains("--reasoning-effort"))

        let deep = LocalEngine.arguments(lane: .deep(useMTP: false), model: model, port: 9, keyFile: key, sleepIdleSeconds: nil)
        XCTAssertTrue(deep.joined(separator: " ").contains("--reasoning-effort medium --reasoning-budget 4096"))
        XCTAssertTrue(deep.joined(separator: " ").contains("--temp 1.0 --top-p 0.95"))
        XCTAssertFalse(deep.contains("--sleep-idle-seconds"))
        XCTAssertFalse(deep.contains("--spec-type"))
        let mtp = LocalEngine.arguments(lane: .deep(useMTP: true), model: model, port: 9, keyFile: key, sleepIdleSeconds: nil)
        XCTAssertTrue(mtp.joined(separator: " ").contains("--model-draft /models/mtp.gguf --spec-type draft-mtp --spec-draft-n-max 2"))
    }

    func testTheKeyFileIsPrivateAndMatchesTheEndpointKey() async throws {
        let engine = engine()
        let endpoint = try await engine.start(lane: .interactive, model: model, sleepIdleSeconds: 300, exitAfterIdle: nil)
        let keyFile = directory.appendingPathComponent("api-key")
        let attributes = try FileManager.default.attributesOfItem(atPath: keyFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try String(contentsOf: keyFile, encoding: .utf8), endpoint.apiKey)
        XCTAssertEqual(endpoint.apiKey.count, 64)
        XCTAssertEqual(endpoint.baseURL.absoluteString, "http://127.0.0.1:51234/v1")
        engine.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyFile.path))
        XCTAssertEqual(processes.first?.terminations, 1)
    }

    func testAServerThatNeverGetsHealthyIsStoppedAndReported() async {
        let engine = engine(healthy: false)
        do {
            _ = try await engine.start(lane: .interactive, model: model, sleepIdleSeconds: nil, exitAfterIdle: nil)
            XCTFail("An unhealthy server was accepted")
        } catch {
            XCTAssertEqual(error as? LocalEngine.EngineError, .unhealthy)
        }
        XCTAssertEqual(processes.first?.terminations, 1)
        XCTAssertNil(engine.endpoint)
    }

    func testTheSameLaneIsReusedAndAnotherLaneReplacesIt() async throws {
        let engine = engine()
        _ = try await engine.start(lane: .interactive, model: model, sleepIdleSeconds: nil, exitAfterIdle: nil)
        _ = try await engine.start(lane: .interactive, model: model, sleepIdleSeconds: nil, exitAfterIdle: nil)
        XCTAssertEqual(launches.count, 1)
        _ = try await engine.start(lane: .deep(useMTP: false), model: model, sleepIdleSeconds: nil, exitAfterIdle: nil)
        XCTAssertEqual(launches.count, 2)
        XCTAssertEqual(processes.first?.terminations, 1)
        engine.stop()
    }

    func testMemoryPressureAndIdleBothStopTheServer() async throws {
        let engine = engine()
        _ = try await engine.start(lane: .interactive, model: model, sleepIdleSeconds: nil, exitAfterIdle: nil)
        engine.memoryPressure()
        XCTAssertEqual(processes[0].terminations, 1)
        _ = try await engine.start(lane: .interactive, model: model, sleepIdleSeconds: nil, exitAfterIdle: .milliseconds(100))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(processes[1].terminations, 1)
        XCTAssertNil(engine.endpoint)
    }

    func testAFreeLoopbackPortIsFound() {
        let port = LocalEngine.findFreePort()
        XCTAssertNotNil(port)
        XCTAssertGreaterThan(port ?? 0, 1023)
    }
}
