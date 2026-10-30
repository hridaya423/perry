import Darwin
import Foundation
import PerryCore
import PerryRuntimes

public enum WorkspaceUndoError: Error, Equatable, Sendable, LocalizedError {
    case notUndoable(String)
    case conflicted(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notUndoable(let reason), .conflicted(let reason), .failed(let reason): reason
        }
    }
}

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

    public func inversePlan(
        receipts: [WorkspaceFileExecutionReceipt],
        goal: String,
        taskID: TaskID = TaskID(UUID().uuidString)
    ) throws -> ExecutionPlan {
        let workspace = URL(fileURLWithPath: workspacePath, isDirectory: true)
        var state = PlannedState()
        let actions = try receipts.reversed().map { try inverseAction(for: $0, workspace: workspace, state: &state) }
        return try ExecutionPlan(
            taskID: taskID,
            goal: goal,
            actions: actions,
            requestedScopes: [.workspaceWrite]
        )
    }

    private struct PlannedState {
        var vacated: Set<String> = []
        var moved: [String: URL] = [:]

        func stat(_ url: URL) -> Darwin.stat? {
            let real: URL
            if let moved = moved[url.path] {
                real = moved
            } else if vacated.contains(url.path) {
                return nil
            } else {
                real = url
            }
            var info = Darwin.stat()
            return Darwin.lstat(real.path, &info) == 0 ? info : nil
        }

        func children(of url: URL) -> [String] {
            let real = moved[url.path] ?? url
            let onDisk = ((try? FileManager.default.contentsOfDirectory(atPath: real.path)) ?? [])
                .map { url.appendingPathComponent($0).path }
                .filter { !vacated.contains($0) }
            let arriving = moved.keys.filter { ($0 as NSString).deletingLastPathComponent == url.path }
            return Array(Set(onDisk + arriving))
        }

        mutating func vacate(_ url: URL) {
            vacated.insert(url.path)
            moved[url.path] = nil
        }

        mutating func move(_ real: URL, to url: URL) {
            vacated.remove(url.path)
            moved[url.path] = real
        }
    }

    private func inverseAction(
        for receipt: WorkspaceFileExecutionReceipt,
        workspace: URL,
        state: inout PlannedState
    ) throws -> ExecutableAction {
        guard let summary = inverseDescription(for: receipt) else {
            throw WorkspaceUndoError.notUndoable("receipts without verified identity cannot be undone")
        }
        let command: ExecutableAction.FileTransform
        let postcondition: ExecutableAction.Postcondition
        switch receipt.effect {
        case .createdFile(let path, let byteCount):
            let url = try resolveWorkspace(path)
            guard let info = state.stat(url) else {
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
            state.vacate(url)
        case .createdDirectory(let path):
            let url = try resolveWorkspace(path)
            guard let info = state.stat(url), info.st_mode & S_IFMT == S_IFDIR else {
                throw WorkspaceUndoError.conflicted("the created directory is no longer there")
            }
            guard state.children(of: url).isEmpty else {
                throw WorkspaceUndoError.conflicted("“\(path)” is no longer empty")
            }
            command = .moveToTrash(path: path)
            postcondition = .trashedItem(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
            state.vacate(url)
        case .renamed(let source, let destination, let device, let inode):
            let destinationURL = try resolveWorkspace(destination)
            let sourceURL = try resolveWorkspace(source)
            try requireIdentity(destinationURL, device: device, inode: inode, what: "The renamed item", state: state)
            try requireAbsent(sourceURL, what: "The original name", state: state)
            command = .rename(path: destination, destination: source)
            postcondition = .renamedItem(device: device, inode: inode)
            let real = state.moved[destinationURL.path] ?? destinationURL
            state.vacate(destinationURL)
            state.move(real, to: sourceURL)
        case .trashed(let source, let entryName, let device, let inode):
            let entryURL = try resolveTrashEntry(entryName)
            let sourceURL = try resolveWorkspace(source)
            try requireIdentity(entryURL, device: device, inode: inode, what: "The Trash entry", state: state)
            try requireAbsent(sourceURL, what: "The restore location", state: state)
            command = .restoreFromTrash(entryName: entryName, destination: source)
            postcondition = .renamedItem(device: device, inode: inode)
            state.vacate(entryURL)
            state.move(entryURL, to: sourceURL)
        case .restored(let source, _, let device, let inode):
            let sourceURL = try resolveWorkspace(source)
            try requireIdentity(sourceURL, device: device, inode: inode, what: "The restored item", state: state)
            command = .moveToTrash(path: source)
            postcondition = .trashedItem(device: device, inode: inode)
            state.vacate(sourceURL)
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

    private func requireIdentity(_ url: URL, device: UInt64, inode: UInt64, what: String, state: PlannedState) throws {
        guard let info = state.stat(url) else {
            throw WorkspaceUndoError.conflicted("\(what.lowercased()) is no longer where Perry left it")
        }
        guard info.st_mode & S_IFMT != S_IFLNK,
              UInt64(info.st_dev) == device,
              UInt64(info.st_ino) == inode else {
            throw WorkspaceUndoError.conflicted("\(what.lowercased()) changed identity since Perry acted")
        }
    }

    private func requireAbsent(_ url: URL, what: String, state: PlannedState) throws {
        if state.stat(url) != nil {
            throw WorkspaceUndoError.conflicted("\(what.lowercased()) is now occupied by something else")
        }
    }
}
