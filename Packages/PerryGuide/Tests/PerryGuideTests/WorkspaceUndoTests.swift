import XCTest
import PerryCore
@testable import PerryGuide
@testable import PerryRuntimes

final class WorkspaceUndoTests: XCTestCase {
    private var workspace: URL!
    private var trash: URL!
    private var store: URL!
    private var engine: WorkspaceUndoEngine!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-undo-ws-\(UUID().uuidString)", isDirectory: true)
        trash = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-undo-trash-\(UUID().uuidString)", isDirectory: true)
        store = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-undo-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        engine = WorkspaceUndoEngine(workspace: workspace, trashURL: trash)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
        try? FileManager.default.removeItem(at: trash)
        try? FileManager.default.removeItem(at: store)
    }

    private func receipt(_ effect: WorkspaceFileExecutionEffect) -> WorkspaceFileExecutionReceipt {
        WorkspaceFileExecutionReceipt(planID: UUID(), actionID: ActionID("a1"), planDigest: "d", effect: effect)
    }

    private func identity(of url: URL) throws -> (UInt64, UInt64) {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { throw NSError(domain: "test", code: 1) }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }

    private func write(_ name: String, _ contents: String = "hello") throws -> URL {
        let url = workspace.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Runs the typed inverse plan through the shared write-ahead performer —
    /// the same journaled path the Undo button drives.
    private func runInversePlan(receipts: [WorkspaceFileExecutionReceipt]) async throws {
        let plan = try engine.inversePlan(receipts: receipts, goal: "Undo the task")
        let journal = WorkspaceRunJournal(
            plan: plan,
            workspace: workspace,
            coordinator: TaskCoordinator(storageDirectory: store),
            trashURL: trash
        )
        for action in plan.actions {
            _ = try await journal.perform(action)
        }
    }

    // MARK: - Rename

    func testRenameInverseRestoresOriginalName() async throws {
        let original = try write("a.txt")
        let moved = workspace.appendingPathComponent("b.txt")
        let (device, inode) = try identity(of: original)
        try FileManager.default.moveItem(at: original, to: moved)

        try await runInversePlan(receipts: [receipt(.renamed(
            source: "a.txt", destination: "b.txt", device: device, inode: inode
        ))])

        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
        let restored = try identity(of: workspace.appendingPathComponent("a.txt"))
        XCTAssertEqual(restored.0, device)
        XCTAssertEqual(restored.1, inode)
    }

    func testRenameInverseConflictsWhenItemWasReplaced() throws {
        let original = try write("a.txt")
        let moved = workspace.appendingPathComponent("b.txt")
        let (device, inode) = try identity(of: original)
        try FileManager.default.moveItem(at: original, to: moved)
        // Intervening work: replace the renamed file with different content.
        try FileManager.default.removeItem(at: moved)
        _ = try write("b.txt", "user edits")

        XCTAssertThrowsError(try engine.inversePlan(receipts: [receipt(.renamed(
            source: "a.txt", destination: "b.txt", device: device, inode: inode
        ))], goal: "undo")) { error in
            guard case WorkspaceUndoError.conflicted = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path), "undo must not touch the replacement")
    }

    func testRenameInverseConflictsWhenOriginalNameOccupied() throws {
        let original = try write("a.txt")
        let moved = workspace.appendingPathComponent("b.txt")
        let (device, inode) = try identity(of: original)
        try FileManager.default.moveItem(at: original, to: moved)
        _ = try write("a.txt", "new file using the old name")

        XCTAssertThrowsError(try engine.inversePlan(receipts: [receipt(.renamed(
            source: "a.txt", destination: "b.txt", device: device, inode: inode
        ))], goal: "undo")) { error in
            guard case WorkspaceUndoError.conflicted = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }

    // MARK: - Trash restore

    func testTrashInverseRestoresEntry() async throws {
        let file = try write("gone.txt")
        let (device, inode) = try identity(of: file)
        let entryURL = trash.appendingPathComponent("Perry-entry")
        try FileManager.default.moveItem(at: file, to: entryURL)

        try await runInversePlan(receipts: [receipt(.trashed(
            source: "gone.txt", entryName: "Perry-entry", device: device, inode: inode
        ))])

        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("gone.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: entryURL.path))
        let restored = try identity(of: workspace.appendingPathComponent("gone.txt"))
        XCTAssertEqual(restored.0, device)
        XCTAssertEqual(restored.1, inode)
    }

    func testTrashInverseConflictsWhenEntryIsGone() throws {
        XCTAssertThrowsError(try engine.inversePlan(receipts: [receipt(.trashed(
            source: "gone.txt", entryName: "Perry-missing", device: 1, inode: 2
        ))], goal: "undo")) { error in
            guard case WorkspaceUndoError.conflicted = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
    }

    // MARK: - Created file

    func testCreatedFileInverseMovesUnchangedFileToTrash() async throws {
        let file = try write("made.txt")

        try await runInversePlan(receipts: [receipt(.createdFile(path: "made.txt", byteCount: 5))])

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testCreatedFileInverseConflictsWhenFileChanged() throws {
        _ = try write("made.txt", "the user edited this")

        XCTAssertThrowsError(try engine.inversePlan(receipts: [receipt(.createdFile(path: "made.txt", byteCount: 5))], goal: "undo")) { error in
            guard case WorkspaceUndoError.conflicted = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("made.txt").path))
    }

    // MARK: - Created directory

    func testCreatedDirectoryInverseRemovesEmptyDirectory() async throws {
        let dir = workspace.appendingPathComponent("newdir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)

        try await runInversePlan(receipts: [receipt(.createdDirectory(path: "newdir"))])

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testCreatedDirectoryInverseConflictsWhenNoLongerEmpty() throws {
        let dir = workspace.appendingPathComponent("newdir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try "user file".write(to: dir.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try engine.inversePlan(receipts: [receipt(.createdDirectory(path: "newdir"))], goal: "undo")) { error in
            guard case WorkspaceUndoError.conflicted = error else {
                return XCTFail("expected conflict, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: - Not undoable / unsafe paths

    func testUndoRemovesAFolderAndTheFileMadeInsideIt() async throws {
        let folder = workspace.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = try write("reports/q3.txt")

        try await runInversePlan(receipts: [
            receipt(.createdDirectory(path: "reports")),
            receipt(.createdFile(path: "reports/q3.txt", byteCount: 5)),
        ])

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testUndoReversesARenameOfARename() async throws {
        let final = try write("c.txt")
        let (device, inode) = try identity(of: final)

        try await runInversePlan(receipts: [
            receipt(.renamed(source: "a.txt", destination: "b.txt", device: device, inode: inode)),
            receipt(.renamed(source: "b.txt", destination: "c.txt", device: device, inode: inode)),
        ])

        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
    }

    func testLegacyEffectIsNotUndoable() {
        XCTAssertNil(engine.inverseDescription(for: receipt(.legacy(path: "x", byteCount: 1))))
        XCTAssertThrowsError(try engine.inversePlan(receipts: [receipt(.legacy(path: "x", byteCount: 1))], goal: "undo")) { error in
            guard case WorkspaceUndoError.notUndoable = error else {
                return XCTFail("expected notUndoable, got \(error)")
            }
        }
    }

    func testTraversalPathIsRejectedBeforeAnyFilesystemTouch() throws {
        let outside = workspace.deletingLastPathComponent().appendingPathComponent("escape.txt")
        try "x".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertThrowsError(try engine.inversePlan(receipts: [receipt(.createdFile(path: "../escape.txt", byteCount: 1))], goal: "undo")) { error in
            guard case WorkspaceUndoError.notUndoable = error else {
                return XCTFail("expected notUndoable, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testUndoableDescriptionsOnlyListRealInverses() {
        XCTAssertNotNil(engine.inverseDescription(for: receipt(.createdFile(path: "a", byteCount: 1))))
        XCTAssertNotNil(engine.inverseDescription(for: receipt(.createdDirectory(path: "d"))))
        XCTAssertNotNil(engine.inverseDescription(for: receipt(.renamed(source: "a", destination: "b", device: 1, inode: 2))))
        XCTAssertNotNil(engine.inverseDescription(for: receipt(.trashed(source: "a", entryName: "e", device: 1, inode: 2))))
        XCTAssertNil(engine.inverseDescription(for: receipt(.legacy(path: "a", byteCount: 1))))
    }
}
