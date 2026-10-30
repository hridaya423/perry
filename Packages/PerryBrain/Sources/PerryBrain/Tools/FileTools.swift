import Foundation
import PerryCore

public struct WorkspaceEntry: Sendable, Equatable {
    /// Path relative to the workspace root.
    public var path: String
    public var isDirectory: Bool
    public var byteCount: Int64
    public var modified: Date?

    public init(path: String, isDirectory: Bool, byteCount: Int64, modified: Date?) {
        self.path = path
        self.isDirectory = isDirectory
        self.byteCount = byteCount
        self.modified = modified
    }
}

public struct WorkspaceFileError: Error, Sendable, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Root-confined file backend: resolves `..` and symlinks, refuses anything
/// that lands outside the workspace root. Suitable as the app's default
/// executor backend for un-journaled reads and quick writes.
public struct LocalWorkspaceFiles: Sendable {
    public static let maximumWriteBytes = 8 * 1_024 * 1_024
    public static let maximumReadBytes = 8 * 1_024 * 1_024

    private let rootURL: URL
    private let rootPath: String

    public init(root: URL) throws {
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceFileError("workspace root does not exist: \(root.path)")
        }
        self.rootURL = resolved
        self.rootPath = resolved.path.hasSuffix("/") ? resolved.path : resolved.path + "/"
    }

    /// Resolves a relative path inside the root. For creation targets the
    /// parent directory is resolved instead (it must exist).
    private func resolve(_ relative: String, create: Bool = false) throws -> URL {
        let trimmed = relative.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "/" else { return rootURL }
        guard !trimmed.hasPrefix("/"), !trimmed.contains("\0") else {
            throw WorkspaceFileError("path must be relative to the workspace")
        }
        let candidate = rootURL.appendingPathComponent(trimmed).standardizedFileURL
        guard candidate.path == rootURL.path || candidate.path.hasPrefix(rootPath) else {
            throw WorkspaceFileError("path escapes the workspace: \(trimmed)")
        }
        if create {
            let parent = candidate.deletingLastPathComponent()
            let realParent = parent.resolvingSymlinksInPath().standardizedFileURL
            guard realParent.path == rootURL.path || realParent.path.hasPrefix(rootPath) else {
                throw WorkspaceFileError("path escapes the workspace: \(trimmed)")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: realParent.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw WorkspaceFileError("parent directory does not exist: \(parent.path)")
            }
            return realParent.appendingPathComponent(candidate.lastPathComponent)
        }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == rootURL.path || resolved.path.hasPrefix(rootPath) else {
            throw WorkspaceFileError("path escapes the workspace: \(trimmed)")
        }
        return resolved
    }

    private func relativePath(of url: URL) -> String {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved.hasPrefix(rootPath) ? String(resolved.dropFirst(rootPath.count)) : url.lastPathComponent
    }

    public func list(path: String) async throws -> [WorkspaceEntry] {
        let url = try resolve(path.isEmpty ? "." : path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceFileError("not a directory: \(path)")
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return try children.map { child in
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            return WorkspaceEntry(
                path: relativePath(of: child),
                isDirectory: values.isDirectory ?? false,
                byteCount: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate
            )
        }.sorted { $0.path.localizedCompare($1.path) == .orderedAscending }
    }

    public func read(path: String, maxBytes: Int) async throws -> (text: String, byteCount: Int64, truncated: Bool) {
        let url = try resolve(path)
        let cap = min(max(1, maxBytes), Self.maximumReadBytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw WorkspaceFileError("not a regular file: \(path)")
        }
        let byteCount = (attributes[.size] as? Int64) ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: cap + 1) ?? Data()
        let truncated = data.count > cap
        let slice = truncated ? data.prefix(cap) : data[...]
        guard let text = String(data: slice, encoding: .utf8) else {
            throw WorkspaceFileError("not UTF-8 text: \(path)")
        }
        return (text, byteCount, truncated)
    }

    public func write(path: String, contents: String) async throws {
        let bytes = Data(contents.utf8)
        guard bytes.count <= Self.maximumWriteBytes else {
            throw WorkspaceFileError("contents exceed \(Self.maximumWriteBytes) bytes")
        }
        let url = try resolve(path, create: true)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw WorkspaceFileError("already exists: \(path) — use files.overwrite")
        }
        try bytes.write(to: url, options: .withoutOverwriting)
    }

    public func overwrite(path: String, contents: String) async throws -> String? {
        let bytes = Data(contents.utf8)
        guard bytes.count <= Self.maximumWriteBytes else {
            throw WorkspaceFileError("contents exceed \(Self.maximumWriteBytes) bytes")
        }
        let url = try resolve(path, create: true)
        let exists = FileManager.default.fileExists(atPath: url.path)
        var previous: String? = nil
        if exists,
           let data = try? Data(contentsOf: url),
           data.count <= Self.maximumWriteBytes {
            previous = String(data: data, encoding: .utf8)
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).perry-tmp")
        try bytes.write(to: tmp, options: .atomic)
        if exists {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        return previous
    }

    public func makeDirectory(path: String) async throws {
        var url = try resolve(path)
        var pending: [URL] = []
        var isDirectory: ObjCBool = false
        while !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            pending.append(url)
            url = url.deletingLastPathComponent()
            _ = try resolve(url.path == rootURL.path ? "." : relativePath(of: url), create: false)
        }
        guard isDirectory.boolValue else {
            throw WorkspaceFileError("a file is in the way: \(path)")
        }
        for directory in pending.reversed() {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
    }

    public func move(source: String, destination: String) async throws {
        let sourceURL = try resolve(source)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw WorkspaceFileError("no such file: \(source)")
        }
        let destinationURL = try resolve(destination, create: true)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw WorkspaceFileError("destination exists: \(destination)")
        }
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    public func trash(path: String) async throws -> String {
        let url = try resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkspaceFileError("no such file: \(path)")
        }
        let rel = relativePath(of: url)
        guard rel != ".trash", !rel.hasPrefix(".trash/") else {
            throw WorkspaceFileError("already in trash: \(path)")
        }
        // Workspace-local .trash: FileManager.trashItem blocks on Finder/
        // session UI (hangs on a locked display); a move is instant and
        // restores through files.move.
        let trashDir = rootURL.appendingPathComponent(".trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        var candidate = trashDir.appendingPathComponent("\(stamp)-\(url.lastPathComponent)")
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            counter += 1
            candidate = trashDir.appendingPathComponent("\(stamp)-\(counter)-\(url.lastPathComponent)")
        }
        try FileManager.default.moveItem(at: url, to: candidate)
        return relativePath(of: candidate)
    }
}

/// `files.*` executors: schemas, tiers, and undo hints for the host.
public enum FileToolExecutors {
    public static func make(backend: LocalWorkspaceFiles) -> [any ToolExecutor] {
        [
            ListTool(backend: backend), ReadTool(backend: backend),
            WriteTool(backend: backend), OverwriteTool(backend: backend),
            MkdirTool(backend: backend), MoveTool(backend: backend),
            TrashTool(backend: backend),
        ]
    }

    private static func json(_ call: ToolCall, _ object: [String: JSONValue]) -> ToolResult {
        let data = (try? JSONValue.object(object).data()) ?? Data()
        return .text(call.id, String(data: data, encoding: .utf8) ?? "{}")
    }

    private static func path(_ call: ToolCall, _ key: String = "path") throws -> String {
        guard let value = call.arguments[key]?.stringValue, !value.isEmpty else {
            throw WorkspaceFileError("missing \(key)")
        }
        return value
    }

    private static func undo(_ tool: String, _ arguments: [String: JSONValue]) -> JSONValue {
        .object(["tool": .string(tool), "arguments": .object(arguments)])
    }

    private struct ListTool: ToolExecutor {
        let backend: LocalWorkspaceFiles
        let spec = ToolSpec(
            name: "files.list",
            description: "List files and folders inside the workspace.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["path": .object(["type": .string("string")])]),
            ]),
            surfaces: [.agent], readOnly: true
        )
        func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            let entries = try await backend.list(path: call.arguments["path"]?.stringValue ?? ".")
            return FileToolExecutors.json(call, [
                "entries": .array(entries.map { entry in
                    .object([
                        "path": .string(entry.path),
                        "isDirectory": .bool(entry.isDirectory),
                        "byteCount": .number(Double(entry.byteCount)),
                    ])
                }),
            ])
        }
    }

    private struct ReadTool: ToolExecutor {
        let backend: LocalWorkspaceFiles
        let spec = ToolSpec(
            name: "files.read",
            description: "Read a UTF-8 text file from the workspace.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")]),
                    "maxBytes": .object(["type": .string("integer")]),
                ]),
                "required": .array([.string("path")]),
            ]),
            surfaces: [.agent], readOnly: true
        )
        func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            let maxBytes = Int(call.arguments["maxBytes"]?.doubleValue ?? 256 * 1_024)
            let result = try await backend.read(path: try FileToolExecutors.path(call), maxBytes: maxBytes)
            return FileToolExecutors.json(call, [
                "path": .string(try FileToolExecutors.path(call)),
                "text": .string(result.text),
                "byteCount": .number(Double(result.byteCount)),
                "truncated": .bool(result.truncated),
            ])
        }
    }

    private struct WriteTool: ToolExecutor {
        let backend: LocalWorkspaceFiles
        let spec = ToolSpec(
            name: "files.write",
            description: "Create a new UTF-8 file in the workspace. Fails if it exists.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")]),
                    "contents": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("path"), .string("contents")]),
            ]),
            tier: .yellow, surfaces: [.agent]
        )
        func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            let path = try FileToolExecutors.path(call)
            guard let contents = call.arguments["contents"]?.stringValue else {
                throw WorkspaceFileError("missing contents")
            }
            try await backend.write(path: path, contents: contents)
            return FileToolExecutors.json(call, [
                "path": .string(path),
                "created": .bool(true),
                "undo": FileToolExecutors.undo("files.trash", ["path": .string(path)]),
            ])
        }
    }

    private struct OverwriteTool: ToolExecutor {
        let backend: LocalWorkspaceFiles
        let spec = ToolSpec(
            name: "files.overwrite",
            description: "Replace the contents of a workspace file (or create it).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")]),
                    "contents": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("path"), .string("contents")]),
            ]),
            tier: .yellow, surfaces: [.agent]
        )
        func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            let path = try FileToolExecutors.path(call)
            guard let contents = call.arguments["contents"]?.stringValue else {
                throw WorkspaceFileError("missing contents")
            }
            let previous = try await backend.overwrite(path: path, contents: contents)
            var fields: [String: JSONValue] = ["path": .string(path), "overwritten": .bool(true)]
            if let previous {
                fields["undo"] = FileToolExecutors.undo("files.overwrite", [
                    "path": .string(path), "contents": .string(previous),
                ])
            }
            return FileToolExecutors.json(call, fields)
        }
    }

    private struct MkdirTool: ToolExecutor {
        let backend: LocalWorkspaceFiles
        let spec = ToolSpec(
            name: "files.mkdir",
            description: "Create a directory in the workspace, including intermediates.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["path": .object(["type": .string("string")])]),
                "required": .array([.string("path")]),
            ]),
            tier: .yellow, surfaces: [.agent]
        )
        func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            let path = try FileToolExecutors.path(call)
            try await backend.makeDirectory(path: path)
            return FileToolExecutors.json(call, [
                "path": .string(path),
                "created": .bool(true),
                "undo": FileToolExecutors.undo("files.trash", ["path": .string(path)]),
            ])
        }
    }

    private struct MoveTool: ToolExecutor {
        let backend: LocalWorkspaceFiles
        let spec = ToolSpec(
            name: "files.move",
            description: "Move or rename a file inside the workspace.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "source": .object(["type": .string("string")]),
                    "destination": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("source"), .string("destination")]),
            ]),
            tier: .yellow, surfaces: [.agent]
        )
        func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            let source = try FileToolExecutors.path(call, "source")
            let destination = try FileToolExecutors.path(call, "destination")
            try await backend.move(source: source, destination: destination)
            return FileToolExecutors.json(call, [
                "source": .string(source),
                "destination": .string(destination),
                "undo": FileToolExecutors.undo("files.move", [
                    "source": .string(destination), "destination": .string(source),
                ]),
            ])
        }
    }

    private struct TrashTool: ToolExecutor {
        let backend: LocalWorkspaceFiles
        let spec = ToolSpec(
            name: "files.trash",
            description: "Move a workspace file or folder to the workspace .trash (restorable via files.move).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["path": .object(["type": .string("string")])]),
                "required": .array([.string("path")]),
            ]),
            tier: .yellow, surfaces: [.agent]
        )
        func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            let path = try FileToolExecutors.path(call)
            let trashedTo = try await backend.trash(path: path)
            return FileToolExecutors.json(call, [
                "path": .string(path), "trashedTo": .string(trashedTo),
                "undo": FileToolExecutors.undo("files.move", [
                    "source": .string(trashedTo), "destination": .string(path),
                ]),
            ])
        }
    }
}
