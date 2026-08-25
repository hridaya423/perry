import XCTest
@testable import PerryRuntimes
import PerryCore

final class ScriptedFinderRuntimeTests: XCTestCase {
    private var workDirectory: URL!

    override func setUp() {
        super.setUp()
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-scripted-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        super.tearDown()
    }

    func testPlanProducesSevenSteps() async throws {
        let runtime = ScriptedFinderRuntime(baseURL: workDirectory)
        let plan = try await runtime.plan(goal: "demo rename", context: .empty)
        XCTAssertEqual(plan.steps.count, 7)
        XCTAssertEqual(plan.steps.first?.kind, .highlight)
        XCTAssertEqual(plan.steps.filter { $0.kind == .createFile }.count, 3)
        XCTAssertEqual(plan.steps.filter { $0.kind == .renameFile }.count, 3)
    }

    func testFullExecutionRenamesAllFilesOnDisk() async throws {
        let runtime = ScriptedFinderRuntime(baseURL: workDirectory)
        let plan = try await runtime.plan(goal: "demo rename", context: .empty)

        var results: [StepResult] = []
        for step in plan.steps {
            results.append(try await runtime.execute(step, consent: nil))
        }

        XCTAssertTrue(results.allSatisfy(\.success))
        let contents = try FileManager.default.contentsOfDirectory(atPath: workDirectory.path).sorted()
        XCTAssertEqual(
            contents,
            [
                "perry-demo-a-renamed.txt",
                "perry-demo-b-renamed.txt",
                "perry-demo-c-renamed.txt",
            ]
        )
    }

    func testCreateFailsGracefullyWhenFileExists() async throws {
        let runtime = ScriptedFinderRuntime(baseURL: workDirectory)
        let existing = Step(kind: .createFile, summary: "create dup", payload: ["name": "dup.txt", "contents": "one"])
        _ = try await runtime.execute(existing, consent: nil)
        let duplicate = try await runtime.execute(existing, consent: nil)
        XCTAssertFalse(duplicate.success)
        XCTAssertTrue(duplicate.message.contains("already exists"))
    }
}
