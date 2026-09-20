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

    /// Builds the typed plan a scenario drives through the supervisor. Rename
    /// actions run under one plan approval; trash actions use action-scoped
    /// approval to exercise the per-action confirmation path.
    public static func plan(for scenario: FinderTaskScenario, workspace: URL) throws -> PerryRuntimes.ExecutionPlan {
        let taskID = TaskID(UUID().uuidString)
        switch scenario.name {
        case renameBatch.name:
            return try makePlan(
                taskID: taskID,
                goal: scenario.goal,
                workspace: workspace,
                renames: [
                    ("alpha.txt", "alpha-final.txt"),
                    ("beta.txt", "beta-final.txt"),
                    ("gamma.txt", "gamma-final.txt"),
                ]
            )
        case organizeByExtension.name:
            return try makePlan(
                taskID: taskID,
                goal: scenario.goal,
                workspace: workspace,
                renames: [
                    ("photo1.png", "Images/photo1.png"),
                    ("photo2.png", "Images/photo2.png"),
                ]
            )
        case cleanupOldExports.name:
            let actions = try (0..<3).map { index in
                let name = "export-\(index).mov"
                let (device, inode) = try fileIdentity(at: workspace.appendingPathComponent(name))
                return try ExecutableAction(
                    id: ActionID("trash-\(index)"),
                    summary: "trash \(name)",
                    approvalRequirement: .action,
                    operation: .transform(workspace: workspace, command: .moveToTrash(path: name)),
                    postcondition: .trashedItem(device: device, inode: inode)
                )
            }
            return try PerryRuntimes.ExecutionPlan(
                taskID: taskID,
                goal: scenario.goal,
                actions: actions,
                requestedScopes: [.workspaceWrite]
            )
        default:
            throw ExecutablePlanError.invalid("unknown scenario \(scenario.name)")
        }
    }

    private static func makePlan(
        taskID: TaskID,
        goal: String,
        workspace: URL,
        renames: [(source: String, destination: String)]
    ) throws -> PerryRuntimes.ExecutionPlan {
        let actions = try renames.enumerated().map { index, rename in
            let (device, inode) = try fileIdentity(at: workspace.appendingPathComponent(rename.source))
            return try ExecutableAction(
                id: ActionID("rename-\(index)"),
                summary: "rename \(rename.source) to \(rename.destination)",
                approvalRequirement: .plan,
                operation: .transform(
                    workspace: workspace,
                    command: .rename(path: rename.source, destination: rename.destination)
                ),
                postcondition: .renamedItem(device: device, inode: inode)
            )
        }
        return try PerryRuntimes.ExecutionPlan(
            taskID: taskID,
            goal: goal,
            actions: actions,
            requestedScopes: [.workspaceWrite]
        )
    }

    private static func fileIdentity(at url: URL) throws -> (device: UInt64, inode: UInt64) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              device.uint64Value > 0, inode.uint64Value > 0 else {
            throw ExecutablePlanError.invalid("could not read file identity at \(url.path)")
        }
        return (device.uint64Value, inode.uint64Value)
    }
}
