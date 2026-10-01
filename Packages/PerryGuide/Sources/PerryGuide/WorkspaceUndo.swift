import Darwin
import Foundation
import PerryCore
import PerryRuntimes

public enum WorkspaceUndoError: Error, Equatable, Sendable, LocalizedError {
    /// The receipt does not carry enough verified identity to undo safely
    /// (legacy effects), or the path itself is unsafe.
    case notUndoable(String)
    /// The world changed since the receipt: the item moved, was replaced,
    /// grew content, or something else now occupies the restore location.
    /// Undo stops rather than touch intervening work.
    case conflicted(String)
    /// The conflict check passed but the filesystem operation failed.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notUndoable(let reason), .conflicted(let reason), .failed(let reason): reason
        }
    }
}

/// Reverses completed workspace actions from their durable receipts. Every
/// inverse is conflict-checked first: the identity recorded at execution time
/// (device + inode, or byte count for created files) must still match, and the
/// restore location must be free. Anything else stops the undo without
/// touching the file system.
public struct WorkspaceUndoEngine: Sendable {
    private let workspacePath: String
    private let trashPath: String

    public init(
        workspace: URL,
        trashURL: URL? = nil
    ) {
        let trashURL = trashURL ?? workspace
            .resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(".trash", isDirectory: true)
        workspacePath = workspace.resolvingSymlinksInPath().standardizedFileURL.path
        trashPath = trashURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// One-line description of the inverse, or nil when the effect cannot be
    /// undone safely. Used to show the user exactly what Undo will do.
    public func inverseDescription(for receipt: WorkspaceFileExecutionReceipt) -> String? {
        switch receipt.effect {
        case .createdFile(let path, _):
            return "Move the created file “\(path)” to the workspace trash"
        case .createdDirectory(let path):
            return "Move the empty directory “\(path)” to the workspace trash"
        case .renamed(let source, let destination, _, _):
            return "Rename “\(destination)” back to “\(source)”"
        case .trashed(let source, _, _, _):
            return "Restore “\(source)” from the workspace trash"
        case .restored(let source, _, _, _):
            return "Move the restored item “\(source)” back to the workspace trash"
        case .legacy:
            return nil
        }
    }

    /// The typed inverse plan for a run's completed receipts, last change
    /// first. Every postcondition binds the identity observed right now, so
    /// execution re-verifies it — and the same conflict checks the
    /// synchronous path applies run here at build time, so a changed world
    /// stops Undo before it touches anything.
    public func inversePlan(
        receipts: [WorkspaceFileExecutionReceipt],
        goal: String,
        taskID: TaskID = TaskID(UUID().uuidString)
    ) throws -> ExecutionPlan {
        let workspace = URL(fileURLWithPath: workspacePath, isDirectory: true)
        let actions = try receipts.reversed().map { try inverseAction(for: $0, workspace: workspace) }
        return try ExecutionPlan(
            taskID: taskID,
            goal: goal,
            actions: actions,
            requestedScopes: [.workspaceWrite]
        )
    }

    private func inverseAction(
        for receipt: WorkspaceFileExecutionReceipt,
        workspace: URL
    ) throws -> ExecutableAction {
        guard let summary = inverseDescription(for: receipt) else {
            throw WorkspaceUndoError.notUndoable("receipts without verified identity cannot be undone")
        }
        let command: ExecutableAction.FileTransform
        let postcondition: ExecutableAction.Postcondition
        switch receipt.effect {
        case .createdFile(let path, let byteCount):
            let url = try resolveWorkspace(path)
            var info = stat()
            guard Darwin.lstat(url.path, &info) == 0 else {
                throw WorkspaceUndoError.conflicted("the created file is no longer there")
            }
            guard info.st_mode & S_IFMT == S_IFREG else {
                throw WorkspaceUndoError.conflicted("“\(path)” is no longer a regular file")
            }
            guard info.st_size == off_t(byteCount) else {
                throw WorkspaceUndoError.conflicted("“\(path)” changed since Perry created it")
            }
            command = .moveToTrash(path: path)
            postcondition = .trashedItem(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        case .createdDirectory(let path):
            let url = try resolveWorkspace(path)
            var info = stat()
            guard Darwin.lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                throw WorkspaceUndoError.conflicted("the created directory is no longer there")
            }
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            guard contents.isEmpty else {
                throw WorkspaceUndoError.conflicted("“\(path)” is no longer empty")
            }
            command = .moveToTrash(path: path)
            postcondition = .trashedItem(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        case .renamed(let source, let destination, let device, let inode):
            try requireIdentity(try resolveWorkspace(destination), device: device, inode: inode, what: "The renamed item")
            try requireAbsent(try resolveWorkspace(source), what: "The original name")
            command = .rename(path: destination, destination: source)
            postcondition = .renamedItem(device: device, inode: inode)
        case .trashed(let source, let entryName, let device, let inode):
            try requireIdentity(try resolveTrashEntry(entryName), device: device, inode: inode, what: "The Trash entry")
            try requireAbsent(try resolveWorkspace(source), what: "The restore location")
            command = .restoreFromTrash(entryName: entryName, destination: source)
            postcondition = .renamedItem(device: device, inode: inode)
        case .restored(let source, _, let device, let inode):
            try requireIdentity(try resolveWorkspace(source), device: device, inode: inode, what: "The restored item")
            command = .moveToTrash(path: source)
            postcondition = .trashedItem(device: device, inode: inode)
        case .legacy:
            throw WorkspaceUndoError.notUndoable("receipts without verified identity cannot be undone")
        }
        return try ExecutableAction(
            id: ActionID(UUID().uuidString),
            summary: summary,
            approvalRequirement: .action,
            operation: .transform(workspace: workspace, command: command),
            postcondition: postcondition
        )
    }

    /// Same lexical rules as the runtime and verifier: workspace-relative,
    /// no traversal, no symlinked ancestors (a swapped parent would resolve
    /// outside the workspace and is treated as a conflict).
    private func resolveWorkspace(_ relative: String) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty,
              !relative.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw WorkspaceUndoError.notUndoable("the receipt path is not a safe workspace-relative path")
        }
        let candidate = URL(fileURLWithPath: workspacePath, isDirectory: true)
            .appendingPathComponent(relative)
            .standardizedFileURL
        guard candidate.path.hasPrefix(workspacePath + "/"),
              candidate.resolvingSymlinksInPath().standardizedFileURL.path == candidate.path else {
            throw WorkspaceUndoError.conflicted("the receipt path no longer resolves inside the task workspace")
        }
        return candidate
    }

    private func resolveTrashEntry(_ entryName: String) throws -> URL {
        guard !entryName.isEmpty,
              entryName != ".", entryName != "..",
              !entryName.hasPrefix("/"),
              !entryName.contains("/"), !entryName.contains("\\"),
              !entryName.contains("\0") else {
            throw WorkspaceUndoError.notUndoable("the receipt's Trash entry name is unsafe")
        }
        let candidate = URL(fileURLWithPath: trashPath, isDirectory: true)
            .appendingPathComponent(entryName, isDirectory: false)
            .standardizedFileURL
        guard candidate.path.hasPrefix(trashPath + "/"),
              candidate.resolvingSymlinksInPath().standardizedFileURL.path == candidate.path else {
            throw WorkspaceUndoError.conflicted("the Trash entry no longer resolves inside the Trash")
        }
        return candidate
    }

    private func requireIdentity(_ url: URL, device: UInt64, inode: UInt64, what: String) throws {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            throw WorkspaceUndoError.conflicted("\(what.lowercased()) is no longer where Perry left it")
        }
        guard info.st_mode & S_IFMT != S_IFLNK,
              UInt64(info.st_dev) == device,
              UInt64(info.st_ino) == inode else {
            throw WorkspaceUndoError.conflicted("\(what.lowercased()) changed identity since Perry acted")
        }
    }

    private func requireAbsent(_ url: URL, what: String) throws {
        var info = stat()
        if Darwin.lstat(url.path, &info) == 0 {
            throw WorkspaceUndoError.conflicted("\(what.lowercased()) is now occupied by something else")
        }
    }

}
