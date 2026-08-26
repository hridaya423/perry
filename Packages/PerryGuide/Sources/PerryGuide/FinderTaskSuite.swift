import Foundation
import PerryCore
import PerryRuntimes

/// The PRD §10 M3 gate: "one real-world task suite green." Each scenario runs
/// against an isolated directory laid out like a mini Finder workspace.
public struct FinderTaskScenario: Sendable {
    public let name: String
    public let setup: @Sendable (URL) throws -> Void
    public let goal: String
    public let verify: @Sendable (URL) throws -> Bool

    public init(
        name: String,
        setup: @escaping @Sendable (URL) throws -> Void,
        goal: String,
        verify: @escaping @Sendable (URL) throws -> Bool
    ) {
        self.name = name
        self.setup = setup
        self.goal = goal
        self.verify = verify
    }
}

public enum FinderTaskSuite {
    /// Runtime that executes common Finder file operations from step payloads.
    public struct FileOpsRuntime: AgentRuntime {
        public let id = "fileops.finder"
        public let capabilities = RuntimeCapabilities(guiGrounding: false, fileIO: true, browser: false, latencyClass: .fast)
        private let baseURL: URL

        public init(baseURL: URL) {
            self.baseURL = baseURL
        }

        private var fm: FileManager { .default }

        public func plan(goal: String, context: ScreenContext) async throws -> Plan {
            // Plans are provided by scenarios; this runtime only executes.
            Plan(goal: goal, runtimeID: id, steps: [])
        }

        public func execute(_ step: Step, consent: ConsentHandle?) async throws -> StepResult {
            switch step.kind {
            case .createFile:
                let url = baseURL.appendingPathComponent(step.payload["name"] ?? "untitled")
                try Data((step.payload["contents"] ?? "").utf8).write(to: url, options: .atomic)
                return StepResult(stepID: step.id, success: true, message: "created")
            case .renameFile:
                try fm.moveItem(
                    at: baseURL.appendingPathComponent(step.payload["name"] ?? ""),
                    to: baseURL.appendingPathComponent(step.payload["newName"] ?? "")
                )
                return StepResult(stepID: step.id, success: true, message: "renamed")
            case .moveToTrash:
                let source = baseURL.appendingPathComponent(step.payload["name"] ?? "")
                var trashURL: NSURL?
                try fm.trashItem(at: source, resultingItemURL: &trashURL)
                return StepResult(stepID: step.id, success: true, message: "trashed")
            default:
                throw ExecutionError(message: "unsupported step \(step.kind.rawValue)")
            }
        }
    }

    public static let all: [FinderTaskScenario] = [
        renameBatch,
        organizeByExtension,
        cleanupOldExports,
    ]

    public static let renameBatch = FinderTaskScenario(
        name: "rename-batch",
        setup: { dir in
            for letter in ["alpha", "beta", "gamma"] {
                try Data("notes".utf8).write(to: dir.appendingPathComponent("\(letter).txt"))
            }
        },
        goal: "append -final to every txt file",
        verify: { dir in
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            return Set(names) == Set(["alpha-final.txt", "beta-final.txt", "gamma-final.txt"])
        }
    )

    public static let organizeByExtension = FinderTaskScenario(
        name: "organize-by-extension",
        setup: { dir in
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("Images"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("photo1.png"))
            try Data("y".utf8).write(to: dir.appendingPathComponent("photo2.png"))
        },
        goal: "move png files into Images folder",
        verify: { dir in
            let fm = FileManager.default
            let images = try fm.contentsOfDirectory(atPath: dir.appendingPathComponent("Images").path)
            let top = try fm.contentsOfDirectory(atPath: dir.path)
            return images.count == 2 && !top.contains { $0.hasSuffix(".png") }
        }
    )

    public static let cleanupOldExports = FinderTaskScenario(
        name: "cleanup-old-exports",
        setup: { dir in
            for index in 0..<3 {
                try Data("old".utf8).write(to: dir.appendingPathComponent("export-\(index).mov"))
            }
        },
        goal: "trash the old export movies after confirmation",
        verify: { dir in
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            return names.isEmpty
        }
    )

    /// Builds the plan a scenario drives through the supervisor. Orange steps
    /// (trash) exercise the confirmation path; yellow steps run autonomously.
    public static func plan(for scenario: FinderTaskScenario) -> Plan {
        switch scenario.name {
        case renameBatch.name:
            return Plan(goal: scenario.goal, runtimeID: FileOpsRuntime(baseURL: URL(fileURLWithPath: "/")).id, steps: [
                Step(kind: .renameFile, summary: "rename alpha.txt", payload: ["name": "alpha.txt", "newName": "alpha-final.txt"]),
                Step(kind: .renameFile, summary: "rename beta.txt", payload: ["name": "beta.txt", "newName": "beta-final.txt"]),
                Step(kind: .renameFile, summary: "rename gamma.txt", payload: ["name": "gamma.txt", "newName": "gamma-final.txt"]),
            ])
        case organizeByExtension.name:
            return Plan(goal: scenario.goal, runtimeID: "", steps: [
                Step(kind: .renameFile, summary: "move photo1.png", payload: ["name": "photo1.png", "newName": "Images/photo1.png"]),
                Step(kind: .renameFile, summary: "move photo2.png", payload: ["name": "photo2.png", "newName": "Images/photo2.png"]),
            ])
        case cleanupOldExports.name:
            return Plan(goal: scenario.goal, runtimeID: "", steps: [
                Step(kind: .moveToTrash, summary: "trash export-0.mov", payload: ["name": "export-0.mov"]),
                Step(kind: .moveToTrash, summary: "trash export-1.mov", payload: ["name": "export-1.mov"]),
                Step(kind: .moveToTrash, summary: "trash export-2.mov", payload: ["name": "export-2.mov"]),
            ])
        default:
            return Plan(goal: scenario.goal, runtimeID: "", steps: [])
        }
    }
}
