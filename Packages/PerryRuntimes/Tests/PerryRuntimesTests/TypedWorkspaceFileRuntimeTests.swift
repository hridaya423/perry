import Darwin
import Foundation
import XCTest
import PerryCore
@testable import PerryRuntimes

final class TypedWorkspaceFileRuntimeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-typed-workspace-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defer { directory = nil }
        if let directory {
            try FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testCreateUTF8FileReturnsActionBoundReceiptAndExactBytes() async throws {
        let contents = "  e\u{301}\r\n\t🍐\n  "
        let plan = try makePlan(workspace: directory, path: "reports/report.txt", contents: contents)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("reports"), withIntermediateDirectories: false)
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("write"))

        let receipt = try await WorkspaceFileRuntime(baseURL: directory).execute(
            plan: plan,
            actionID: "write",
            grantID: grant.id,
            registry: registry
        )

        let expected = Data(contents.utf8)
        let file = directory.appendingPathComponent("reports/report.txt")
        XCTAssertEqual(receipt.planID, plan.planID)
        XCTAssertEqual(receipt.actionID, "write")
        XCTAssertEqual(receipt.planDigest, try plan.approvalDigest())
        XCTAssertEqual(receipt.path, "reports/report.txt")
        XCTAssertEqual(receipt.byteCount, expected.count)
        XCTAssertEqual(receipt.effect, .createdFile(path: "reports/report.txt", byteCount: expected.count))
        XCTAssertEqual(try JSONDecoder().decode(
            WorkspaceFileExecutionReceipt.self,
            from: JSONEncoder().encode(receipt)
        ), receipt)
        XCTAssertEqual(try Data(contentsOf: file), expected)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
    }

    func testTypedExecutorRejectsUnapprovedActionBeforeSideEffect() async throws {
        let plan = try makePlan(workspace: directory, path: "unapproved.txt", contents: "blocked")
        let action = try XCTUnwrap(plan.actions.first)

        do {
            _ = try await WorkspaceFileRuntime(baseURL: directory).execute(action)
            XCTFail("unapproved typed execution must fail")
        } catch let error as ExecutionApprovalError {
            XCTAssertEqual(error, .grantRequired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("unapproved.txt").path))
    }

    func testTypedExecutorReturnsTrashReceiptAndVerifierChecksDestinationIdentity() async throws {
        let trash = directory.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("report.txt")
        try Data("report".utf8).write(to: source)
        var sourceIdentity = stat()
        XCTAssertEqual(lstat(source.path, &sourceIdentity), 0)
        let action = try ExecutableAction(
            id: "trash",
            summary: "Move report to Trash",
            approvalRequirement: .action,
            operation: .transform(workspace: directory, command: .moveToTrash(path: "report.txt")),
            postcondition: .trashedItem(device: UInt64(sourceIdentity.st_dev), inode: UInt64(sourceIdentity.st_ino))
        )
        let plan = try PerryRuntimes.ExecutionPlan(
            taskID: "trash-task",
            goal: "Move report to Trash",
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
        let grant = try ExecutionApprovalGrant(plan: plan, scope: .action(action.id))
        let approved = try ApprovedExecutableAction(plan: plan, actionID: action.id, grant: grant)
        let runtime = WorkspaceFileRuntime(baseURL: directory, trashURL: trash)
        let result = try await runtime.execute(approved)
        let verifier = WorkspaceFileVerifier(baseURL: directory, trashURL: trash)

        guard case .workspaceFile(let receipt) = result.evidence,
              case .trashed(_, let entryName, let device, let inode) = receipt.effect else {
            return XCTFail("typed execution must return a trash receipt")
        }
        XCTAssertEqual(device, UInt64(sourceIdentity.st_dev))
        XCTAssertEqual(inode, UInt64(sourceIdentity.st_ino))
        let verified = await verifier.verify(approvedAction: approved, result: result, context: ScreenContext.empty)
        XCTAssertEqual(verified, .verified(evidence: "the trashed item was read back with its approved identity"))

        let unrelated = trash.appendingPathComponent("unrelated")
        try Data("unrelated".utf8).write(to: unrelated)
        try FileManager.default.removeItem(at: trash.appendingPathComponent(entryName))
        try FileManager.default.moveItem(at: unrelated, to: trash.appendingPathComponent(entryName))
        let swapped = await verifier.verify(approvedAction: approved, result: result, context: ScreenContext.empty)
        guard case .unverified = swapped else {
            return XCTFail("an unrelated Trash entry must not satisfy the receipt")
        }
    }

    func testVerifierRejectsReceiptFromAnotherExecutionPlan() async throws {
        let plan = try makePlan(workspace: directory, path: "cross-execution.txt", contents: "receipt")
        let action = try XCTUnwrap(plan.actions.first)
        let grant = try ExecutionApprovalGrant(plan: plan, scope: .action(action.id))
        let approved = try ApprovedExecutableAction(plan: plan, actionID: action.id, grant: grant)
        let result = try await WorkspaceFileRuntime(baseURL: directory).execute(approved)
        let otherPlan = try PerryRuntimes.ExecutionPlan(
            taskID: "other-task",
            goal: "Different execution",
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
        let otherGrant = try ExecutionApprovalGrant(plan: otherPlan, scope: .action(action.id))
        let otherApproved = try ApprovedExecutableAction(plan: otherPlan, actionID: action.id, grant: otherGrant)
        let status = await WorkspaceFileVerifier(baseURL: directory).verify(
            approvedAction: otherApproved,
            result: result,
            context: ScreenContext.empty
        )

        guard case .unverified = status else {
            return XCTFail("a receipt from another execution plan must not verify")
        }
    }

    func testVerifierRejectsUnsafeTrashReceiptEntryNames() async throws {
        let trash = directory.appendingPathComponent("Trash", isDirectory: true)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let outsideItem = outside.appendingPathComponent("item")
        try Data("outside".utf8).write(to: outsideItem)
        try FileManager.default.createSymbolicLink(
            at: trash.appendingPathComponent("redirect"),
            withDestinationURL: outside
        )
        var identity = stat()
        XCTAssertEqual(lstat(outsideItem.path, &identity), 0)

        let action = try ExecutableAction(
            id: "trash",
            summary: "Move report to Trash",
            approvalRequirement: .action,
            operation: .transform(workspace: directory, command: .moveToTrash(path: "report.txt")),
            postcondition: .trashedItem(device: UInt64(identity.st_dev), inode: UInt64(identity.st_ino))
        )
        let plan = try PerryRuntimes.ExecutionPlan(
            taskID: "unsafe-trash-task",
            goal: "Move report to Trash",
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
        let grant = try ExecutionApprovalGrant(plan: plan, scope: .action(action.id))
        let approved = try ApprovedExecutableAction(plan: plan, actionID: action.id, grant: grant)
        let digest = try plan.approvalDigest()
        let verifier = WorkspaceFileVerifier(baseURL: directory, trashURL: trash)
        let entryNames = [
            "../outside/item",
            outsideItem.path,
            "",
            ".",
            "..",
            "nested/item",
            "redirect/item",
        ]

        for entryName in entryNames {
            let receipt = WorkspaceFileExecutionReceipt(
                planID: plan.planID,
                actionID: action.id,
                planDigest: digest,
                effect: .trashed(
                    source: "report.txt",
                    entryName: entryName,
                    device: UInt64(identity.st_dev),
                    inode: UInt64(identity.st_ino)
                )
            )
            let result = ActionExecutionResult(action: action, evidence: .workspaceFile(receipt))
            let status = await verifier.verify(approvedAction: approved, result: result, context: .empty)
            guard case .unverified = status else {
                return XCTFail("unsafe Trash entry name was verified: \(entryName)")
            }
        }
    }

    func testCreateDirectoryReturnsActionBoundReceiptAndDurableDirectory() async throws {
        let action = try ExecutableAction(
            id: "mkdir",
            summary: "Create reports directory",
            approvalRequirement: .action,
            operation: .transform(workspace: directory, command: .createDirectory(path: "reports/2026")),
            postcondition: .directoryExists
        )
        let plan = try PerryRuntimes.ExecutionPlan(
            taskID: "mkdir-task",
            goal: "Create reports directory",
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("reports"),
            withIntermediateDirectories: false
        )
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("mkdir"))

        let receipt = try await WorkspaceFileRuntime(baseURL: directory).execute(
            plan: plan,
            actionID: "mkdir",
            grantID: grant.id,
            registry: registry
        )

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("reports/2026").path,
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(receipt.planID, plan.planID)
        XCTAssertEqual(receipt.actionID, "mkdir")
        XCTAssertEqual(receipt.planDigest, try plan.approvalDigest())
        XCTAssertEqual(receipt.path, "reports/2026")
        XCTAssertEqual(receipt.byteCount, 0)
        XCTAssertEqual(receipt.effect, .createdDirectory(path: "reports/2026"))
        XCTAssertEqual(try JSONDecoder().decode(
            WorkspaceFileExecutionReceipt.self,
            from: JSONEncoder().encode(receipt)
        ), receipt)
    }

    func testCreateDirectoryRejectsSymlinkParentWithoutWritingOutsideWorkspace() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-typed-directory-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link"),
            withDestinationURL: outside
        )
        let action = try ExecutableAction(
            id: "mkdir",
            summary: "Create escaped directory",
            approvalRequirement: .action,
            operation: .transform(workspace: directory, command: .createDirectory(path: "link/escaped")),
            postcondition: .directoryExists
        )
        let plan = try PerryRuntimes.ExecutionPlan(
            taskID: "mkdir-symlink-task",
            goal: "Create escaped directory",
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("mkdir"))

        do {
            _ = try await WorkspaceFileRuntime(baseURL: directory).execute(
                plan: plan,
                actionID: "mkdir",
                grantID: grant.id,
                registry: registry
            )
            XCTFail("A symlink parent must not redirect directory creation")
        } catch is ExecutionError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("escaped").path))
    }

    func testRenameRequiresSourceIdentityAndDoesNotOverwriteDestination() async throws {
        let source = directory.appendingPathComponent("source.txt")
        let destination = directory.appendingPathComponent("destination.txt")
        try Data("source".utf8).write(to: source)
        var sourceInfo = stat()
        XCTAssertEqual(Darwin.lstat(source.path, &sourceInfo), 0)
        let plan = try makeRenamePlan(
            source: "source.txt",
            destination: "destination.txt",
            device: UInt64(sourceInfo.st_dev),
            inode: UInt64(sourceInfo.st_ino)
        )
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("rename"))

        let receipt = try await WorkspaceFileRuntime(baseURL: directory).execute(
            plan: plan,
            actionID: "rename",
            grantID: grant.id,
            registry: registry
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("source".utf8))
        XCTAssertEqual(receipt.path, "destination.txt")
        XCTAssertEqual(receipt.byteCount, 0)
        XCTAssertEqual(
            receipt.effect,
            .renamed(
                source: "source.txt",
                destination: "destination.txt",
                device: UInt64(sourceInfo.st_dev),
                inode: UInt64(sourceInfo.st_ino)
            )
        )

        try Data("replacement".utf8).write(to: source)
        var replacementInfo = stat()
        XCTAssertEqual(Darwin.lstat(source.path, &replacementInfo), 0)
        let collisionPlan = try makeRenamePlan(
            source: "source.txt",
            destination: "destination.txt",
            device: UInt64(replacementInfo.st_dev),
            inode: UInt64(replacementInfo.st_ino)
        )
        let collisionGrant = try await registry.issue(plan: collisionPlan, scope: .action("rename"))
        do {
            _ = try await WorkspaceFileRuntime(baseURL: directory).execute(
                plan: collisionPlan,
                actionID: "rename",
                grantID: collisionGrant.id,
                registry: registry
            )
            XCTFail("Rename must not overwrite an existing destination")
        } catch is ExecutionError {
        }
        XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("source".utf8))
    }

    func testRenameRejectsChangedSourceIdentity() async throws {
        let source = directory.appendingPathComponent("source.txt")
        try Data("source".utf8).write(to: source)
        var sourceInfo = stat()
        XCTAssertEqual(Darwin.lstat(source.path, &sourceInfo), 0)
        let plan = try makeRenamePlan(
            source: "source.txt",
            destination: "destination.txt",
            device: UInt64(sourceInfo.st_dev),
            inode: UInt64(sourceInfo.st_ino)
        )
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("rename"))
        try FileManager.default.removeItem(at: source)
        try Data("replacement".utf8).write(to: source)

        do {
            _ = try await WorkspaceFileRuntime(baseURL: directory).execute(
                plan: plan,
                actionID: "rename",
                grantID: grant.id,
                registry: registry
            )
            XCTFail("A replacement source must not inherit rename approval")
        } catch is ExecutionError {
        }
        XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("destination.txt").path))
    }

    func testMoveToTrashRequiresSourceIdentityAndMovesExactItem() async throws {
        let trash = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-typed-trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: trash) }
        let source = directory.appendingPathComponent("obsolete.txt")
        try Data("obsolete".utf8).write(to: source)
        var sourceInfo = stat()
        XCTAssertEqual(Darwin.lstat(source.path, &sourceInfo), 0)
        let plan = try makeTrashPlan(
            path: "obsolete.txt",
            device: UInt64(sourceInfo.st_dev),
            inode: UInt64(sourceInfo.st_ino)
        )
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("trash"))

        let receipt = try await WorkspaceFileRuntime(baseURL: directory, trashURL: trash).execute(
            plan: plan,
            actionID: "trash",
            grantID: grant.id,
            registry: registry
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let trashedItems = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        XCTAssertEqual(trashedItems.count, 1)
        let trashed = try XCTUnwrap(trashedItems.first)
        XCTAssertEqual(try Data(contentsOf: trashed), Data("obsolete".utf8))
        var trashedInfo = stat()
        XCTAssertEqual(Darwin.lstat(trashed.path, &trashedInfo), 0)
        XCTAssertEqual(trashedInfo.st_dev, sourceInfo.st_dev)
        XCTAssertEqual(trashedInfo.st_ino, sourceInfo.st_ino)
        XCTAssertEqual(receipt.path, "obsolete.txt")
        XCTAssertEqual(receipt.byteCount, 0)
        guard case .trashed(let receiptSource, let entryName, let device, let inode) = receipt.effect else {
            return XCTFail("Trash receipt did not retain its typed effect")
        }
        XCTAssertEqual(receiptSource, "obsolete.txt")
        XCTAssertEqual(entryName, trashed.lastPathComponent)
        XCTAssertEqual(device, UInt64(sourceInfo.st_dev))
        XCTAssertEqual(inode, UInt64(sourceInfo.st_ino))
    }

    func testMoveToTrashRejectsReplacedSourceIdentity() async throws {
        let trash = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-typed-trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: trash) }
        let source = directory.appendingPathComponent("obsolete.txt")
        try Data("obsolete".utf8).write(to: source)
        var sourceInfo = stat()
        XCTAssertEqual(Darwin.lstat(source.path, &sourceInfo), 0)
        let plan = try makeTrashPlan(
            path: "obsolete.txt",
            device: UInt64(sourceInfo.st_dev),
            inode: UInt64(sourceInfo.st_ino)
        )
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("trash"))
        try FileManager.default.removeItem(at: source)
        try Data("replacement".utf8).write(to: source)

        do {
            _ = try await WorkspaceFileRuntime(baseURL: directory, trashURL: trash).execute(
                plan: plan,
                actionID: "trash",
                grantID: grant.id,
                registry: registry
            )
            XCTFail("A replacement source must not inherit trash approval")
        } catch is ExecutionError {
        }
        XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
    }

    func testAuthorizationDenialDoesNotWrite() async throws {
        let plan = try makePlan(workspace: directory, path: "denied.txt", contents: "denied")
        let registry = ExecutionApprovalRegistry()

        do {
            _ = try await WorkspaceFileRuntime(baseURL: directory).execute(
                plan: plan,
                actionID: "write",
                grantID: UUID(),
                registry: registry
            )
            XCTFail("an unknown grant must not authorize a write")
        } catch {
            XCTAssertEqual(error as? ExecutionApprovalError, .malformedGrant)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("denied.txt").path))
    }

    func testCancellationAfterAuthorizationDoesNotWrite() async throws {
        let plan = try makePlan(workspace: directory, path: "cancelled.txt", contents: "cancelled")
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("write"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WorkspaceFileRuntime(baseURL: directory).execute(
                plan: plan,
                actionID: "write",
                grantID: grant.id,
                registry: registry
            )
        }

        do {
            _ = try await task.value
            XCTFail("cancellation after authorization must prevent the write")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancelled.txt").path))
    }

    func testChangedWorkspaceIsRejectedBeforeAnyWrite() async throws {
        let changedWorkspace = directory.appendingPathComponent("other-workspace", isDirectory: true)
        let plan = try makePlan(workspace: changedWorkspace, path: "changed.txt", contents: "changed")
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("write"))

        do {
            _ = try await WorkspaceFileRuntime(baseURL: directory).execute(
                plan: plan,
                actionID: "write",
                grantID: grant.id,
                registry: registry
            )
            XCTFail("a plan for another workspace must be rejected")
        } catch is ExecutionError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("changed.txt").path))
    }

    func testExistingFileRemainsUnchanged() async throws {
        let file = directory.appendingPathComponent("existing.txt")
        try Data("original".utf8).write(to: file)
        let plan = try makePlan(workspace: directory, path: "existing.txt", contents: "replacement")
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("write"))

        do {
            _ = try await WorkspaceFileRuntime(baseURL: directory).execute(
                plan: plan,
                actionID: "write",
                grantID: grant.id,
                registry: registry
            )
            XCTFail("an existing file must not be overwritten")
        } catch is ExecutionError {
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
    }

    func testSymlinkEscapeIsRejectedWithoutWritingOutsideWorkspace() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-typed-workspace-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link"),
            withDestinationURL: outside
        )
        let plan = try makePlan(workspace: directory, path: "link/escaped.txt", contents: "escape")
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("write"))

        do {
            _ = try await WorkspaceFileRuntime(baseURL: directory).execute(
                plan: plan,
                actionID: "write",
                grantID: grant.id,
                registry: registry
            )
            XCTFail("a symlink path must not escape the workspace")
        } catch is ExecutionError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("escaped.txt").path))
    }

    func testReplacedWorkspaceAncestorCannotRedirectWrite() async throws {
        let ancestor = directory.appendingPathComponent("ancestor", isDirectory: true)
        let workspace = ancestor.appendingPathComponent("workspace", isDirectory: true)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("workspace"), withIntermediateDirectories: true)
        let runtime = WorkspaceFileRuntime(baseURL: workspace)
        let plan = try makePlan(workspace: workspace, path: "redirected.txt", contents: "private")
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("write"))
        try FileManager.default.moveItem(at: ancestor, to: directory.appendingPathComponent("original"))
        try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: outside)

        do {
            _ = try await runtime.execute(plan: plan, actionID: "write", grantID: grant.id, registry: registry)
            XCTFail("A replaced ancestor must not redirect the workspace binding")
        } catch is ExecutionError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("workspace/redirected.txt").path))
    }

    func testReplacementRootDirectoryCannotInheritApproval() async throws {
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let runtime = WorkspaceFileRuntime(baseURL: workspace)
        let plan = try makePlan(workspace: workspace, path: "report.txt", contents: "private")
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("write"))
        try FileManager.default.moveItem(at: workspace, to: directory.appendingPathComponent("original"))
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)

        do {
            _ = try await runtime.execute(plan: plan, actionID: "write", grantID: grant.id, registry: registry)
            XCTFail("A new directory must not inherit the original workspace binding")
        } catch is ExecutionError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("report.txt").path))
    }

    func testOversizedContentsAreRejectedBeforeFileCreation() async throws {
        let plan = try makePlan(workspace: directory, path: "large.txt", contents: String(repeating: "x", count: 8 * 1_024 * 1_024 + 1))
        let registry = ExecutionApprovalRegistry()
        let grant = try await registry.issue(plan: plan, scope: .action("write"))
        do {
            _ = try await WorkspaceFileRuntime(baseURL: directory).execute(plan: plan, actionID: "write", grantID: grant.id, registry: registry)
            XCTFail("Oversized contents must not create a file")
        } catch is ExecutionError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("large.txt").path))
    }

    private func makePlan(workspace: URL, path: String, contents: String) throws -> PerryRuntimes.ExecutionPlan {
        let action = try ExecutableAction(
            id: "write",
            summary: "Create a UTF-8 file",
            approvalRequirement: .action,
            operation: .transform(
                workspace: workspace,
                command: .createUTF8File(path: path, contents: contents)
            ),
            postcondition: .fileContents(contents)
        )
        return try PerryRuntimes.ExecutionPlan(
            taskID: "task",
            goal: "Create a UTF-8 file",
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
    }

    private func makeRenamePlan(
        source: String,
        destination: String,
        device: UInt64,
        inode: UInt64
    ) throws -> PerryRuntimes.ExecutionPlan {
        let action = try ExecutableAction(
            id: "rename",
            summary: "Rename a workspace item",
            approvalRequirement: .action,
            operation: .transform(
                workspace: directory,
                command: .rename(path: source, destination: destination)
            ),
            postcondition: .renamedItem(device: device, inode: inode)
        )
        return try PerryRuntimes.ExecutionPlan(
            taskID: TaskID("rename-task-\(UUID().uuidString)"),
            goal: "Rename a workspace item",
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
    }

    private func makeTrashPlan(path: String, device: UInt64, inode: UInt64) throws -> PerryRuntimes.ExecutionPlan {
        let action = try ExecutableAction(
            id: "trash",
            summary: "Move a workspace item to Trash",
            approvalRequirement: .action,
            operation: .transform(workspace: directory, command: .moveToTrash(path: path)),
            postcondition: .trashedItem(device: device, inode: inode)
        )
        return try PerryRuntimes.ExecutionPlan(
            taskID: TaskID("trash-task-\(UUID().uuidString)"),
            goal: "Move a workspace item to Trash",
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
    }
}
