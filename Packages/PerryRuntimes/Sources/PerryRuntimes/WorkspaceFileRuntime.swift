import Darwin
import Foundation
import PerryCore

public enum WorkspaceFileExecutionEffect: Codable, Equatable, Sendable {
    case createdFile(path: String, byteCount: Int)
    case createdDirectory(path: String)
    case renamed(source: String, destination: String, device: UInt64, inode: UInt64)
    case trashed(source: String, entryName: String, device: UInt64, inode: UInt64)
    case restored(source: String, entryName: String, device: UInt64, inode: UInt64)
    case legacy(path: String, byteCount: Int)

    private enum CodingKeys: String, CodingKey {
        case createdFile, createdDirectory, renamed, trashed, restored
    }

    private enum PayloadKeys: String, CodingKey {
        case path, byteCount, source, destination, entryName, device, inode
    }

    public init(from decoder: Decoder) throws {
        let payload = try PlanDecodingFields.enumPayload(decoder, cases: [
            CodingKeys.createdFile.rawValue: [PayloadKeys.path.rawValue, PayloadKeys.byteCount.rawValue],
            CodingKeys.createdDirectory.rawValue: [PayloadKeys.path.rawValue],
            CodingKeys.renamed.rawValue: [
                PayloadKeys.source.rawValue, PayloadKeys.destination.rawValue,
                PayloadKeys.device.rawValue, PayloadKeys.inode.rawValue,
            ],
            CodingKeys.trashed.rawValue: [
                PayloadKeys.source.rawValue, PayloadKeys.entryName.rawValue,
                PayloadKeys.device.rawValue, PayloadKeys.inode.rawValue,
            ],
            CodingKeys.restored.rawValue: [
                PayloadKeys.source.rawValue, PayloadKeys.entryName.rawValue,
                PayloadKeys.device.rawValue, PayloadKeys.inode.rawValue,
            ],
        ])
        switch payload.name {
        case CodingKeys.createdFile.rawValue:
            self = .createdFile(
                path: try payload.fields.decode(String.self, PayloadKeys.path.rawValue),
                byteCount: try payload.fields.decode(Int.self, PayloadKeys.byteCount.rawValue)
            )
        case CodingKeys.createdDirectory.rawValue:
            self = .createdDirectory(
                path: try payload.fields.decode(String.self, PayloadKeys.path.rawValue)
            )
        case CodingKeys.renamed.rawValue:
            self = .renamed(
                source: try payload.fields.decode(String.self, PayloadKeys.source.rawValue),
                destination: try payload.fields.decode(String.self, PayloadKeys.destination.rawValue),
                device: try payload.fields.decode(UInt64.self, PayloadKeys.device.rawValue),
                inode: try payload.fields.decode(UInt64.self, PayloadKeys.inode.rawValue)
            )
        case CodingKeys.trashed.rawValue:
            self = .trashed(
                source: try payload.fields.decode(String.self, PayloadKeys.source.rawValue),
                entryName: try payload.fields.decode(String.self, PayloadKeys.entryName.rawValue),
                device: try payload.fields.decode(UInt64.self, PayloadKeys.device.rawValue),
                inode: try payload.fields.decode(UInt64.self, PayloadKeys.inode.rawValue)
            )
        case CodingKeys.restored.rawValue:
            self = .restored(
                source: try payload.fields.decode(String.self, PayloadKeys.source.rawValue),
                entryName: try payload.fields.decode(String.self, PayloadKeys.entryName.rawValue),
                device: try payload.fields.decode(UInt64.self, PayloadKeys.device.rawValue),
                inode: try payload.fields.decode(UInt64.self, PayloadKeys.inode.rawValue)
            )
        default:
            throw ExecutablePlanError.invalid("unknown workspace receipt effect")
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var root = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .createdFile(let path, let byteCount):
            var payload = root.nestedContainer(keyedBy: PayloadKeys.self, forKey: .createdFile)
            try payload.encode(path, forKey: .path)
            try payload.encode(byteCount, forKey: .byteCount)
        case .createdDirectory(let path):
            var payload = root.nestedContainer(keyedBy: PayloadKeys.self, forKey: .createdDirectory)
            try payload.encode(path, forKey: .path)
        case .renamed(let source, let destination, let device, let inode):
            var payload = root.nestedContainer(keyedBy: PayloadKeys.self, forKey: .renamed)
            try payload.encode(source, forKey: .source)
            try payload.encode(destination, forKey: .destination)
            try payload.encode(device, forKey: .device)
            try payload.encode(inode, forKey: .inode)
        case .trashed(let source, let entryName, let device, let inode):
            var payload = root.nestedContainer(keyedBy: PayloadKeys.self, forKey: .trashed)
            try payload.encode(source, forKey: .source)
            try payload.encode(entryName, forKey: .entryName)
            try payload.encode(device, forKey: .device)
            try payload.encode(inode, forKey: .inode)
        case .restored(let source, let entryName, let device, let inode):
            var payload = root.nestedContainer(keyedBy: PayloadKeys.self, forKey: .restored)
            try payload.encode(source, forKey: .source)
            try payload.encode(entryName, forKey: .entryName)
            try payload.encode(device, forKey: .device)
            try payload.encode(inode, forKey: .inode)
        case .legacy:
            throw ExecutablePlanError.invalid("legacy workspace receipt effects use the legacy receipt wire format")
        }
    }

    fileprivate func validate() throws {
        switch self {
        case .createdFile(let path, let byteCount), .legacy(let path, let byteCount):
            guard !path.isEmpty, byteCount >= 0 else {
                throw ExecutablePlanError.invalid("workspace receipt file effect is invalid")
            }
        case .createdDirectory(let path):
            guard !path.isEmpty else {
                throw ExecutablePlanError.invalid("workspace receipt directory effect is invalid")
            }
        case .renamed(let source, let destination, let device, let inode):
            guard !source.isEmpty, !destination.isEmpty, source != destination, device > 0, inode > 0 else {
                throw ExecutablePlanError.invalid("workspace receipt rename effect is invalid")
            }
        case .trashed(let source, let entryName, let device, let inode):
            guard !source.isEmpty, !entryName.isEmpty, device > 0, inode > 0 else {
                throw ExecutablePlanError.invalid("workspace receipt trash effect is invalid")
            }
        case .restored(let source, let entryName, let device, let inode):
            guard !source.isEmpty, !entryName.isEmpty, device > 0, inode > 0 else {
                throw ExecutablePlanError.invalid("workspace receipt restore effect is invalid")
            }
        }
    }
}

public struct WorkspaceFileExecutionReceipt: Codable, Equatable, Sendable {
    public let planID: UUID
    public let actionID: ActionID
    public let planDigest: String
    public let effect: WorkspaceFileExecutionEffect

    public var path: String {
        switch effect {
        case .createdFile(let path, _), .createdDirectory(let path), .legacy(let path, _): path
        case .renamed(_, let destination, _, _): destination
        case .trashed(let source, _, _, _), .restored(let source, _, _, _): source
        }
    }

    public var byteCount: Int {
        switch effect {
        case .createdFile(_, let byteCount), .legacy(_, let byteCount): byteCount
        case .createdDirectory, .renamed, .trashed, .restored: 0
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case planID, actionID, planDigest, effect, path, byteCount
    }

    init(planID: UUID, actionID: ActionID, planDigest: String, effect: WorkspaceFileExecutionEffect) {
        self.planID = planID
        self.actionID = actionID
        self.planDigest = planDigest
        self.effect = effect
    }

    public init(from decoder: Decoder) throws {
        let fields = try PlanDecodingFields(
            decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue))
        )
        let effect = try fields.optional(WorkspaceFileExecutionEffect.self, "effect")
        let legacyPath = try fields.optional(String.self, "path")
        let legacyByteCount = try fields.optional(Int.self, "byteCount")
        let decodedEffect: WorkspaceFileExecutionEffect
        if let effect {
            guard legacyPath == nil, legacyByteCount == nil else {
                throw ExecutablePlanError.invalid("workspace receipt mixes effect representations")
            }
            decodedEffect = effect
        } else {
            guard let legacyPath, let legacyByteCount else {
                throw ExecutablePlanError.invalid("workspace receipt is missing its effect")
            }
            decodedEffect = .legacy(path: legacyPath, byteCount: legacyByteCount)
        }
        try decodedEffect.validate()
        self.init(
            planID: try fields.decode(UUID.self, "planID"),
            actionID: try fields.decode(ActionID.self, "actionID"),
            planDigest: try fields.decode(String.self, "planDigest"),
            effect: decodedEffect
        )
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(planID, forKey: .planID)
        try fields.encode(actionID, forKey: .actionID)
        try fields.encode(planDigest, forKey: .planDigest)
        switch effect {
        case .legacy(let path, let byteCount):
            try fields.encode(path, forKey: .path)
            try fields.encode(byteCount, forKey: .byteCount)
        default:
            try fields.encode(effect, forKey: .effect)
        }
    }
}

public struct WorkspaceFileRuntime: ExecutableActionExecutor {
    public static let maximumFileCreationBytes = 8 * 1_024 * 1_024
    public let id = "local.workspace-files"

    private let baseURL: URL
    private let typedRoot: (path: String, device: dev_t, inode: ino_t)?
    private let trashURL: URL

    public init(baseURL: URL) {
        self.init(
            baseURL: baseURL,
            trashURL: baseURL.appendingPathComponent(".trash", isDirectory: true)
        )
    }

    public init(baseURL: URL, trashURL: URL) {
        self.baseURL = baseURL.resolvingSymlinksInPath().standardizedFileURL
        self.trashURL = trashURL.resolvingSymlinksInPath().standardizedFileURL
        typedRoot = Self.bindDirectory(baseURL)
    }

    private static func bindDirectory(_ url: URL) -> (path: String, device: dev_t, inode: ino_t)? {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = Darwin.realpath(path, nil) else { return nil }
            defer { free(resolved) }
            var identity = stat()
            guard Darwin.lstat(resolved, &identity) == 0,
                  identity.st_mode & S_IFMT == S_IFDIR else { return nil }
            return (String(cString: resolved), identity.st_dev, identity.st_ino)
        }
    }

    public func execute(_ approvedAction: ApprovedExecutableAction) async throws -> ActionExecutionResult {
        try Task.checkCancellation()
        let action = try approvedAction.validatedAction()
        let effect = try executeTypedAction(action)
        try Task.checkCancellation()
        let receipt = WorkspaceFileExecutionReceipt(
            planID: approvedAction.planID,
            actionID: action.id,
            planDigest: approvedAction.planDigest,
            effect: effect
        )
        return ActionExecutionResult(action: action, evidence: .workspaceFile(receipt))
    }

    public func execute(_ action: ExecutableAction) async throws -> ActionExecutionResult {
        throw ExecutionApprovalError.grantRequired
    }

    public func execute(
        plan: ExecutionPlan,
        actionID: ActionID,
        grantID: UUID,
        registry: ExecutionApprovalRegistry
    ) async throws -> WorkspaceFileExecutionReceipt {
        try Task.checkCancellation()
        let action = try await registry.authorize(grantID: grantID, plan: plan, actionID: actionID)
        try Task.checkCancellation()

        let planDigest = try plan.approvalDigest()
        try Task.checkCancellation()
        let effect = try executeTypedAction(action)
        try Task.checkCancellation()
        return WorkspaceFileExecutionReceipt(
            planID: plan.planID,
            actionID: action.id,
            planDigest: planDigest,
            effect: effect
        )
    }

    private func executeTypedAction(_ action: ExecutableAction) throws -> WorkspaceFileExecutionEffect {
        guard case .transform(let workspace, let command) = action.operation else {
            throw ExecutionError(message: "workspace file runtime only executes typed file transforms")
        }
        guard Array(workspace.standardizedFileURL.path.utf8) == Array(baseURL.path.utf8) else {
            throw ExecutionError(message: "typed workspace does not match runtime binding")
        }
        let effect: WorkspaceFileExecutionEffect
        switch command {
        case .createUTF8File(let requestedPath, let contents):
            guard contents.utf8.count <= Self.maximumFileCreationBytes else {
                throw ExecutionError(message: "typed file creation supports at most 8 MiB of UTF-8 contents")
            }
            try createTypedFile(path: requestedPath, contents: contents)
            effect = .createdFile(path: requestedPath, byteCount: contents.utf8.count)
        case .createDirectory(let requestedPath):
            try createTypedDirectory(path: requestedPath)
            effect = .createdDirectory(path: requestedPath)
        case .rename(let source, let destination):
            guard case .renamedItem(let device, let inode) = action.postcondition else {
                throw ExecutionError(message: "typed rename requires source identity")
            }
            try renameTypedItem(
                source: source,
                destination: destination,
                expectedDevice: device,
                expectedInode: inode
            )
            effect = .renamed(
                source: source,
                destination: destination,
                device: device,
                inode: inode
            )
        case .moveToTrash(let requestedPath):
            guard case .trashedItem(let device, let inode) = action.postcondition else {
                throw ExecutionError(message: "typed trash requires source identity")
            }
            let entryName = try moveTypedItemToTrash(
                path: requestedPath,
                expectedDevice: device,
                expectedInode: inode
            )
            effect = .trashed(
                source: requestedPath,
                entryName: entryName,
                device: device,
                inode: inode
            )
        case .restoreFromTrash(let entryName, let destination):
            guard case .renamedItem(let device, let inode) = action.postcondition else {
                throw ExecutionError(message: "typed restore requires entry identity")
            }
            try restoreTypedItemFromTrash(
                entryName: entryName,
                destination: destination,
                expectedDevice: device,
                expectedInode: inode
            )
            effect = .restored(
                source: destination,
                entryName: entryName,
                device: device,
                inode: inode
            )
        }
        return effect
    }

    private func createTypedFile(path: String, contents: String) throws {
        let components = try relativeComponents(for: path)
        let bytes = Data(contents.utf8)
        let root = try openRootDirectory()
        var directories = [root]
        defer {
            for descriptor in directories.reversed() {
                close(descriptor)
            }
        }

        var parent = root
        for component in components.dropLast() {
            let descriptor = try openDirectory(component: component, relativeTo: parent)
            directories.append(descriptor)
            parent = descriptor
        }

        var openError: Int32 = 0
        let descriptor = components[components.count - 1].withCString { component in
            let descriptor = Darwin.openat(
                parent,
                component,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
            if descriptor < 0 {
                openError = errno
            }
            return descriptor
        }
        guard descriptor >= 0 else {
            if openError == EEXIST {
                throw ExecutionError(message: "typed workspace file already exists")
            }
            throw ExecutionError(message: "could not create typed workspace file")
        }
        defer { close(descriptor) }

        try requireRegularFile(descriptor)
        try writeAll(bytes, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw ExecutionError(message: "could not flush typed workspace file")
        }
        try requireRegularFile(descriptor, expectedByteCount: bytes.count)
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw ExecutionError(message: "could not read back typed workspace file")
        }
        let readBack = try readExactly(bytes.count, from: descriptor)
        try requireRegularFile(descriptor, expectedByteCount: bytes.count)
        guard readBack == bytes else {
            throw ExecutionError(message: "typed workspace file read-back did not match requested bytes")
        }
        var created = stat()
        var current = stat()
        let lookup = components[components.count - 1].withCString {
            Darwin.fstatat(parent, $0, &current, AT_SYMLINK_NOFOLLOW)
        }
        guard Darwin.fstat(descriptor, &created) == 0, lookup == 0,
              created.st_dev == current.st_dev, created.st_ino == current.st_ino,
              current.st_mode & S_IFMT == S_IFREG else {
            throw ExecutionError(message: "typed workspace file changed identity during verification")
        }
        guard Darwin.fsync(parent) == 0 else {
            throw ExecutionError(message: "could not flush typed workspace directory")
        }
    }

    private func createTypedDirectory(path: String) throws {
        let components = try relativeComponents(for: path)
        let root = try openRootDirectory()
        var directories = [root]
        defer {
            for descriptor in directories.reversed() {
                close(descriptor)
            }
        }

        var parent = root
        for component in components.dropLast() {
            let descriptor = try openDirectory(component: component, relativeTo: parent)
            directories.append(descriptor)
            parent = descriptor
        }

        var creationError: Int32 = 0
        let name = components[components.count - 1]
        let created = name.withCString { component in
            let result = Darwin.mkdirat(parent, component, mode_t(S_IRWXU))
            if result != 0 {
                creationError = errno
            }
            return result
        }
        guard created == 0 else {
            if creationError == EEXIST {
                throw ExecutionError(message: "typed workspace directory already exists")
            }
            throw ExecutionError(message: "could not create typed workspace directory")
        }

        let descriptor = try openDirectory(component: name, relativeTo: parent)
        defer { close(descriptor) }
        var opened = stat()
        var current = stat()
        let lookup = name.withCString {
            Darwin.fstatat(parent, $0, &current, AT_SYMLINK_NOFOLLOW)
        }
        guard Darwin.fstat(descriptor, &opened) == 0, lookup == 0,
              opened.st_dev == current.st_dev, opened.st_ino == current.st_ino,
              current.st_mode & S_IFMT == S_IFDIR else {
            throw ExecutionError(message: "typed workspace directory changed identity during verification")
        }
        guard Darwin.fsync(descriptor) == 0, Darwin.fsync(parent) == 0 else {
            throw ExecutionError(message: "could not flush typed workspace directory")
        }
    }

    private func renameTypedItem(
        source: String,
        destination: String,
        expectedDevice: UInt64,
        expectedInode: UInt64
    ) throws {
        try withOpenParent(of: source) { sourceParent, sourceName in
            try withOpenParent(of: destination) { destinationParent, destinationName in
                var original = stat()
                let sourceLookup = sourceName.withCString {
                    Darwin.fstatat(sourceParent, $0, &original, AT_SYMLINK_NOFOLLOW)
                }
                guard sourceLookup == 0,
                      original.st_mode & S_IFMT != S_IFLNK,
                      UInt64(original.st_dev) == expectedDevice,
                      UInt64(original.st_ino) == expectedInode else {
                    throw ExecutionError(message: "typed rename source identity does not match approval")
                }

                var renameError: Int32 = 0
                let renamed = sourceName.withCString { sourceComponent in
                    destinationName.withCString { destinationComponent in
                        let result = Darwin.renameatx_np(
                            sourceParent,
                            sourceComponent,
                            destinationParent,
                            destinationComponent,
                            UInt32(RENAME_EXCL)
                        )
                        if result != 0 {
                            renameError = errno
                        }
                        return result
                    }
                }
                guard renamed == 0 else {
                    if renameError == EEXIST {
                        throw ExecutionError(message: "typed rename destination already exists")
                    }
                    throw ExecutionError(message: "could not rename typed workspace item")
                }

                var moved = stat()
                let destinationLookup = destinationName.withCString {
                    Darwin.fstatat(destinationParent, $0, &moved, AT_SYMLINK_NOFOLLOW)
                }
                var staleSource = stat()
                let staleLookup = sourceName.withCString {
                    Darwin.fstatat(sourceParent, $0, &staleSource, AT_SYMLINK_NOFOLLOW)
                }
                guard destinationLookup == 0,
                      moved.st_dev == original.st_dev, moved.st_ino == original.st_ino,
                      staleLookup != 0, errno == ENOENT else {
                    throw ExecutionError(message: "typed rename result did not match approved source")
                }
                guard Darwin.fsync(destinationParent) == 0,
                      sourceParent == destinationParent || Darwin.fsync(sourceParent) == 0 else {
                    throw ExecutionError(message: "could not flush typed rename directories")
                }
            }
        }
    }

    private func openTrashDirectory() throws -> (descriptor: Int32, device: dev_t) {
        try? FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
        guard let root = Self.bindDirectory(trashURL) else {
            throw ExecutionError(message: "Trash directory binding is unavailable")
        }
        return (try openBoundDirectory(root), root.device)
    }

    private func moveTypedItemToTrash(
        path: String,
        expectedDevice: UInt64,
        expectedInode: UInt64
    ) throws -> String {
        let (trash, trashDevice) = try openTrashDirectory()
        defer { close(trash) }
        return try withOpenParent(of: path) { sourceParent, sourceName in
            var original = stat()
            let sourceLookup = sourceName.withCString {
                Darwin.fstatat(sourceParent, $0, &original, AT_SYMLINK_NOFOLLOW)
            }
            guard sourceLookup == 0,
                  original.st_mode & S_IFMT != S_IFLNK,
                  UInt64(original.st_dev) == expectedDevice,
                  UInt64(original.st_ino) == expectedInode else {
                throw ExecutionError(message: "typed trash source identity does not match approval")
            }
            guard original.st_dev == trashDevice else {
                throw ExecutionError(message: "typed trash cannot move an item across filesystems")
            }

            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            var destinationName = "\(stamp)-\(sourceName)"
            var counter = 0
            while true {
                let candidate = destinationName
                let moved = sourceName.withCString { sourceComponent in
                    candidate.withCString { destinationComponent in
                        Darwin.renameatx_np(
                            sourceParent,
                            sourceComponent,
                            trash,
                            destinationComponent,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                if moved == 0 { break }
                guard errno == EEXIST, counter < 100 else {
                    throw ExecutionError(message: "could not move typed workspace item to Trash")
                }
                counter += 1
                destinationName = "\(stamp)-\(counter)-\(sourceName)"
            }

            var trashed = stat()
            let trashLookup = destinationName.withCString {
                Darwin.fstatat(trash, $0, &trashed, AT_SYMLINK_NOFOLLOW)
            }
            var staleSource = stat()
            let staleLookup = sourceName.withCString {
                Darwin.fstatat(sourceParent, $0, &staleSource, AT_SYMLINK_NOFOLLOW)
            }
            guard trashLookup == 0,
                  trashed.st_dev == original.st_dev, trashed.st_ino == original.st_ino,
                  staleLookup != 0, errno == ENOENT else {
                throw ExecutionError(message: "typed trash result did not match approved source")
            }
            guard Darwin.fsync(trash) == 0, Darwin.fsync(sourceParent) == 0 else {
                throw ExecutionError(message: "could not flush typed trash directories")
            }
            return destinationName
        }
    }

    private func restoreTypedItemFromTrash(
        entryName: String,
        destination: String,
        expectedDevice: UInt64,
        expectedInode: UInt64
    ) throws {
        guard !entryName.isEmpty,
              entryName != ".", entryName != "..",
              !entryName.hasPrefix("/"),
              !entryName.contains("/"), !entryName.contains("\\"),
              !entryName.contains("\0") else {
            throw ExecutionError(message: "typed restore entry name is unsafe")
        }
        let (trash, trashDevice) = try openTrashDirectory()
        defer { close(trash) }
        try withOpenParent(of: destination) { destinationParent, destinationName in
            var parentInfo = stat()
            guard Darwin.fstat(destinationParent, &parentInfo) == 0,
                  parentInfo.st_dev == trashDevice else {
                throw ExecutionError(message: "typed restore cannot move an item across filesystems")
            }
            var original = stat()
            let entryLookup = entryName.withCString {
                Darwin.fstatat(trash, $0, &original, AT_SYMLINK_NOFOLLOW)
            }
            guard entryLookup == 0,
                  original.st_mode & S_IFMT != S_IFLNK,
                  UInt64(original.st_dev) == expectedDevice,
                  UInt64(original.st_ino) == expectedInode else {
                throw ExecutionError(message: "typed restore entry identity does not match approval")
            }

            var restoreError: Int32 = 0
            let restored = entryName.withCString { entryComponent in
                destinationName.withCString { destinationComponent in
                    let result = Darwin.renameatx_np(
                        trash,
                        entryComponent,
                        destinationParent,
                        destinationComponent,
                        UInt32(RENAME_EXCL)
                    )
                    if result != 0 {
                        restoreError = errno
                    }
                    return result
                }
            }
            guard restored == 0 else {
                if restoreError == EEXIST {
                    throw ExecutionError(message: "typed restore destination already exists")
                }
                throw ExecutionError(message: "could not restore typed workspace item")
            }

            var moved = stat()
            let destinationLookup = destinationName.withCString {
                Darwin.fstatat(destinationParent, $0, &moved, AT_SYMLINK_NOFOLLOW)
            }
            var staleEntry = stat()
            let staleLookup = entryName.withCString {
                Darwin.fstatat(trash, $0, &staleEntry, AT_SYMLINK_NOFOLLOW)
            }
            guard destinationLookup == 0,
                  moved.st_dev == original.st_dev, moved.st_ino == original.st_ino,
                  staleLookup != 0, errno == ENOENT else {
                throw ExecutionError(message: "typed restore result did not match approved entry")
            }
            guard Darwin.fsync(destinationParent) == 0, Darwin.fsync(trash) == 0 else {
                throw ExecutionError(message: "could not flush typed restore directories")
            }
        }
    }

    private func withOpenParent<T>(
        of path: String,
        _ operation: (Int32, String) throws -> T
    ) throws -> T {
        let components = try relativeComponents(for: path)
        let root = try openRootDirectory()
        var directories = [root]
        defer {
            for descriptor in directories.reversed() {
                close(descriptor)
            }
        }
        var parent = root
        for component in components.dropLast() {
            let descriptor = try openDirectory(component: component, relativeTo: parent)
            directories.append(descriptor)
            parent = descriptor
        }
        return try operation(parent, components[components.count - 1])
    }

    private func relativeComponents(for path: String) throws -> [String] {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw ExecutionError(message: "typed workspace file path must be relative without traversal")
        }
        return components
    }

    private func openRootDirectory() throws -> Int32 {
        guard let typedRoot else {
            throw ExecutionError(message: "workspace runtime binding is unavailable")
        }
        return try openBoundDirectory(typedRoot)
    }

    private func openBoundDirectory(
        _ root: (path: String, device: dev_t, inode: ino_t)
    ) throws -> Int32 {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ExecutionError(message: "workspace runtime binding is unavailable")
        }
        do {
            for component in root.path.split(separator: "/") {
                try Task.checkCancellation()
                let child = try openDirectory(component: String(component), relativeTo: descriptor)
                close(descriptor)
                descriptor = child
            }
            var identity = stat()
            guard Darwin.fstat(descriptor, &identity) == 0,
                  identity.st_dev == root.device, identity.st_ino == root.inode else {
                throw ExecutionError(message: "workspace runtime binding changed identity")
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func openDirectory(component: String, relativeTo parent: Int32) throws -> Int32 {
        let descriptor = component.withCString { name in
            Darwin.openat(parent, name, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw ExecutionError(message: "typed workspace path contains an unavailable directory")
        }
        do {
            try requireDirectory(descriptor)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func requireDirectory(_ descriptor: Int32) throws {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else {
            throw ExecutionError(message: "typed workspace path requires directories")
        }
    }

    private func requireRegularFile(_ descriptor: Int32, expectedByteCount: Int? = nil) throws {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ExecutionError(message: "typed workspace file is not the requested regular file")
        }
        if let expectedByteCount, info.st_size != off_t(expectedByteCount) {
            throw ExecutionError(message: "typed workspace file size does not match requested bytes")
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            while offset < data.count {
                try Task.checkCancellation()
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    min(data.count - offset, 65_536)
                )
                if count > 0 {
                    offset += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    throw ExecutionError(message: "could not write typed workspace file")
                }
            }
        }
    }

    private func readExactly(_ byteCount: Int, from descriptor: Int32) throws -> Data {
        var data = Data()
        data.reserveCapacity(byteCount)
        var buffer = [UInt8](repeating: 0, count: min(max(byteCount, 1), 65_536))
        while data.count < byteCount {
            try Task.checkCancellation()
            let requested = min(buffer.count, byteCount - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            if count > 0 {
                data.append(buffer, count: count)
            } else if count == 0 {
                throw ExecutionError(message: "typed workspace file read-back ended early")
            } else if errno != EINTR {
                throw ExecutionError(message: "could not read back typed workspace file")
            }
        }

        var extraByte: UInt8 = 0
        while true {
            try Task.checkCancellation()
            let count = withUnsafeMutableBytes(of: &extraByte) { bytes in
                Darwin.read(descriptor, bytes.baseAddress, 1)
            }
            if count == 0 { break }
            if count > 0 {
                throw ExecutionError(message: "typed workspace file contains unexpected bytes")
            }
            if errno != EINTR {
                throw ExecutionError(message: "could not finish typed workspace file read-back")
            }
        }
        return data
    }
}
public struct WorkspaceFileVerifier: TypedActionVerifier {
    private let baseURL: URL
    private let trashURL: URL

    public init(
        baseURL: URL,
        trashURL: URL? = nil
    ) {
        self.baseURL = baseURL.resolvingSymlinksInPath().standardizedFileURL
        self.trashURL = (trashURL ?? self.baseURL.appendingPathComponent(".trash", isDirectory: true))
            .resolvingSymlinksInPath().standardizedFileURL
    }

    public func verify(
        approvedAction: ApprovedExecutableAction,
        result: ActionExecutionResult,
        context: ScreenContext
    ) async -> VerificationStatus {
        let action = approvedAction.action
        guard result.actionID == action.id, result.operation == action.operation else {
            return .unverified(reason: "the typed executor returned a mismatched action")
        }
        guard case .workspaceFile(let receipt) = result.evidence,
              receipt.actionID == action.id,
              receiptMatches(receipt.effect, action: action) else {
            return .unverified(reason: "the typed executor returned a receipt for another approved action")
        }
        if !result.journaled {
            guard receipt.planID == approvedAction.planID,
                  receipt.planDigest == approvedAction.planDigest,
                  receipt.planDigest == approvedAction.grant.planDigest else {
                return .unverified(reason: "the typed executor returned a receipt for another approved action")
            }
        }
        guard case .transform(let workspace, let command) = action.operation,
              workspace.resolvingSymlinksInPath().standardizedFileURL.path == baseURL.path else {
            return .unverified(reason: "the typed action is not bound to the verified workspace")
        }
        switch command {
        case .createUTF8File(let path, _):
            guard case .fileContents(let expected) = action.postcondition, let url = safeURL(for: path) else {
                return .unverified(reason: "the typed file action has no matching file postcondition")
            }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      try Data(contentsOf: url) == Data(expected.utf8) else {
                    return .unverified(reason: "the created file does not contain the requested contents")
                }
                return .verified(evidence: "the created file was read back with the requested contents")
            } catch {
                return .unverified(reason: "the created file could not be read back")
            }
        case .createDirectory(let path):
            guard action.postcondition == .directoryExists, let url = safeURL(for: path) else {
                return .unverified(reason: "the typed directory action has no matching postcondition")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return .unverified(reason: "the created path is not a directory")
            }
            return .verified(evidence: "the created directory was read back")
        case .rename(let source, let destination):
            guard case .renamedItem(let expectedDevice, let expectedInode) = action.postcondition,
                  let sourceURL = safeURL(for: source), let destinationURL = safeURL(for: destination),
                  !FileManager.default.fileExists(atPath: sourceURL.path) else {
                return .unverified(reason: "the rename postcondition was not satisfied")
            }
            var identity = stat()
            guard Darwin.lstat(destinationURL.path, &identity) == 0,
                  UInt64(identity.st_dev) == expectedDevice,
                  UInt64(identity.st_ino) == expectedInode else {
                return .unverified(reason: "the renamed path does not match the approved source")
            }
            return .verified(evidence: "the renamed path was read back with its approved identity")
        case .moveToTrash(let path):
            guard case .trashedItem(let expectedDevice, let expectedInode) = action.postcondition,
                  let url = safeURL(for: path),
                  case .workspaceFile(let receipt) = result.evidence,
                  case .trashed(let source, let entryName, let device, let inode) = receipt.effect,
                  source == path, device == expectedDevice, inode == expectedInode,
                  let trashItem = safeTrashURL(for: entryName),
                  !FileManager.default.fileExists(atPath: url.path) else {
                return .unverified(reason: "the typed Trash receipt does not match the approved item")
            }
            var trashed = stat()
            guard Darwin.lstat(trashItem.path, &trashed) == 0,
                  UInt64(trashed.st_dev) == expectedDevice,
                  UInt64(trashed.st_ino) == expectedInode else {
                return .unverified(reason: "the Trash destination does not match the approved item")
            }
            return .verified(evidence: "the trashed item was read back with its approved identity")
        case .restoreFromTrash(let entryName, let destination):
            guard case .renamedItem(let expectedDevice, let expectedInode) = action.postcondition,
                  let destinationURL = safeURL(for: destination),
                  case .workspaceFile(let receipt) = result.evidence,
                  case .restored(let source, let receiptEntry, let device, let inode) = receipt.effect,
                  source == destination, receiptEntry == entryName,
                  device == expectedDevice, inode == expectedInode else {
                return .unverified(reason: "the typed restore receipt does not match the approved entry")
            }
            var restored = stat()
            guard Darwin.lstat(destinationURL.path, &restored) == 0,
                  UInt64(restored.st_dev) == expectedDevice,
                  UInt64(restored.st_ino) == expectedInode else {
                return .unverified(reason: "the restored path does not match the approved entry")
            }
            if let trashItem = safeTrashURL(for: entryName),
               FileManager.default.fileExists(atPath: trashItem.path) {
                return .unverified(reason: "the Trash entry was not consumed by the restore")
            }
            return .verified(evidence: "the restored item was read back with its approved identity")
        }
    }

    private func receiptMatches(_ effect: WorkspaceFileExecutionEffect, action: ExecutableAction) -> Bool {
        switch (action.operation, action.postcondition, effect) {
        case (
            .transform(_, .createUTF8File(let path, let contents)),
            .fileContents,
            .createdFile(let receiptPath, let byteCount)
        ):
            return path == receiptPath && contents.utf8.count == byteCount
        case (
            .transform(_, .createDirectory(let path)),
            .directoryExists,
            .createdDirectory(let receiptPath)
        ):
            return path == receiptPath
        case (
            .transform(_, .rename(let source, let destination)),
            .renamedItem(let device, let inode),
            .renamed(let receiptSource, let receiptDestination, let receiptDevice, let receiptInode)
        ):
            return source == receiptSource && destination == receiptDestination
                && device == receiptDevice && inode == receiptInode
        case (
            .transform(_, .moveToTrash(let path)),
            .trashedItem(let device, let inode),
            .trashed(let receiptSource, let entryName, let receiptDevice, let receiptInode)
        ):
            return path == receiptSource && device == receiptDevice && inode == receiptInode
                && Self.isSafeTrashEntryName(entryName)
        case (
            .transform(_, .restoreFromTrash(let entryName, let destination)),
            .renamedItem(let device, let inode),
            .restored(let receiptSource, let receiptEntry, let receiptDevice, let receiptInode)
        ):
            return destination == receiptSource && entryName == receiptEntry
                && device == receiptDevice && inode == receiptInode
        default:
            return false
        }
    }

    private func safeURL(for path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.contains("\0") else { return nil }
        let candidate = baseURL.appendingPathComponent(trimmed).standardizedFileURL
        guard candidate.path.hasPrefix(baseURL.path + "/"),
              candidate.resolvingSymlinksInPath().standardizedFileURL.path == candidate.path else { return nil }
        return candidate
    }

    private func safeTrashURL(for entryName: String) -> URL? {
        guard Self.isSafeTrashEntryName(entryName) else { return nil }
        let candidate = trashURL.appendingPathComponent(entryName, isDirectory: false).standardizedFileURL
        guard candidate.path.hasPrefix(trashURL.path + "/"),
              candidate.resolvingSymlinksInPath().standardizedFileURL.path == candidate.path else { return nil }
        return candidate
    }

    private static func isSafeTrashEntryName(_ entryName: String) -> Bool {
        !entryName.isEmpty
            && entryName != "."
            && entryName != ".."
            && !entryName.hasPrefix("/")
            && !entryName.contains("/")
            && !entryName.contains("\\")
            && !entryName.contains("\0")
    }
}
