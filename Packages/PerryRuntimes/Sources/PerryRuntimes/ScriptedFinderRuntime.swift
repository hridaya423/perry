import Foundation
import PerryCore

public struct ScriptedFinderRuntime: AgentRuntime {
    public let id = "scripted.finder"
    public let capabilities = RuntimeCapabilities(guiGrounding: false, fileIO: true, browser: false, latencyClass: .fast)

    private let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    private var fileManager: FileManager { .default }

    public func plan(goal: String, context: ScreenContext) async throws -> Plan {
        let names = Self.demoFileNames
        var steps: [Step] = [
            Step(kind: .highlight, summary: "point at the Finder window showing \(baseURL.lastPathComponent)")
        ]
        for name in names {
            steps.append(
                Step(
                    kind: .createFile,
                    summary: "create \(name)",
                    payload: ["name": name, "contents": "created by perry demo"]
                )
            )
        }
        for name in names {
            steps.append(
                Step(
                    kind: .renameFile,
                    summary: "rename \(name) to \(Self.renamed(name))",
                    payload: ["name": name, "newName": Self.renamed(name)]
                )
            )
        }
        return Plan(goal: goal, runtimeID: id, steps: steps)
    }

    public func execute(_ step: Step, consent: ConsentHandle?) async throws -> StepResult {
        switch step.kind {
        case .highlight, .movePointer:
            return StepResult(stepID: step.id, success: true, message: "annotated target")
        case .createFile:
            let name = step.payload["name"] ?? ""
            let contents = step.payload["contents"] ?? ""
            let url = baseURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                return StepResult(stepID: step.id, success: false, message: "\(name) already exists")
            }
            do {
                try Data(contents.utf8).write(to: url, options: .atomic)
                return StepResult(stepID: step.id, success: true, message: "wrote \(name)")
            } catch {
                throw ExecutionError(message: "could not write \(url.path): \(error.localizedDescription)")
            }
        case .renameFile:
            let name = step.payload["name"] ?? ""
            let newName = step.payload["newName"] ?? ""
            let source = baseURL.appendingPathComponent(name)
            let destination = baseURL.appendingPathComponent(newName)
            guard fileManager.fileExists(atPath: source.path) else {
                return StepResult(stepID: step.id, success: false, message: "\(name) not found")
            }
            do {
                try fileManager.moveItem(at: source, to: destination)
                return StepResult(stepID: step.id, success: true, message: "renamed to \(newName)")
            } catch {
                throw ExecutionError(message: "rename failed: \(error.localizedDescription)")
            }
        case .moveToTrash, .delegate, .typeText, .clickControl:
            throw ExecutionError(message: "runtime \(id) does not implement step kind \(step.kind.rawValue)")
        }
    }

    public static let demoFileNames = ["perry-demo-a.txt", "perry-demo-b.txt", "perry-demo-c.txt"]

    public static func renamed(_ name: String) -> String {
        name.replacingOccurrences(of: ".txt", with: "-renamed.txt")
    }
}
