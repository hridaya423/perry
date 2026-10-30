#if DEBUG
import AppKit
import Foundation
import XCTest
import SwiftUI
import PerryBrain
import PerryCore
import PerryGuide
import PerryRuntimes
@testable import Perry

@MainActor
final class BackgroundTaskLifecycleOrderingTests: XCTestCase {
    func testErasurePromptDeduplicatesAndCollapseCancelsBeforeMaintenance() async throws {
        let directory = try makeTemporaryDirectory()
        let controller = AppController.testing(directory: directory)
        let presentation = NotchPresentation.shared
        let originalOnPresent = presentation.onPresent
        presentation.onPresent = nil
        var enteredErasure = false
        controller.debugSetMaintenanceFixture(skipEraseConfirmation: false) {
            enteredErasure = true
            throw FixtureError.release
        }
        defer {
            presentation.onPresent = originalOnPresent
            controller.subsystems.notchPresence.stop()
        }
        let previousIDs = Set(presentation.entries.map(\.id))
        controller.debugInvokeWipeDataAction()
        let shown = await waitUntil { presentation.entries.contains { !previousIDs.contains($0.id) } }
        XCTAssertTrue(shown)
        let pendingIDs = Set(presentation.entries.map(\.id))
        controller.debugInvokeWipeDataAction()
        XCTAssertEqual(Set(presentation.entries.map(\.id)), pendingIDs)
        controller.collapseNotch()
        let dismissed = await waitUntil { Set(presentation.entries.map(\.id)) == previousIDs }
        XCTAssertTrue(dismissed)
        XCTAssertFalse(controller.debugMaintenanceOwnerHeld)
        XCTAssertFalse(enteredErasure)
    }

    func testCollapsingUnsavedQuitConfirmationRestoresAdmissionAndRequest() async throws {
        let directory = try makeTemporaryDirectory()
        let controller = AppController.testing(directory: directory)
        let presentation = NotchPresentation.shared
        let originalOnPresent = presentation.onPresent
        presentation.onPresent = nil
        defer {
            presentation.onPresent = originalOnPresent
            controller.subsystems.notchPresence.stop()
            controller.subsystems.homeController.closeHome()
        }
        controller.subsystems.homeController.threadStore = nil
        let input = controller.subsystems.homeController.acceptInput("Preserve this request when quitting is cancelled")
        let previousIDs = Set(presentation.entries.map(\.id))
        XCTAssertEqual(controller.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        let shown = await waitUntil { presentation.entries.contains { !previousIDs.contains($0.id) } }
        XCTAssertTrue(shown)
        controller.collapseNotch()
        let reopened = await waitUntil { !controller.debugMaintenanceOwnerHeld }
        XCTAssertTrue(reopened)
        XCTAssertTrue(controller.subsystems.backgroundTasks.acceptsControls)
        XCTAssertEqual(controller.subsystems.homeController.homeModel.unsavedInputs.first?.request.id, input.request.id)
        XCTAssertEqual(Set(presentation.entries.map(\.id)), previousIDs)
    }

    func testQuitChecksFailedAcceptedWritesBeforeDiscardingInput() async throws {
        let directory = try makeTemporaryDirectory()
        let controller = AppController.testing(directory: directory)
        controller.subsystems.homeController.threadStore = nil
        let input = controller.subsystems.homeController.acceptInput("Keep this unsaved request")
        var asked = false
        controller.debugUnsavedQuitDecision = {
            asked = true
            XCTAssertEqual(controller.subsystems.homeController.homeModel.unsavedInputs.map(\.request.text), [input.request.text])
            XCTAssertTrue(controller.debugMaintenanceOwnerHeld)
            return false
        }
        XCTAssertEqual(controller.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        let reopened = await waitUntil { asked && !controller.debugMaintenanceOwnerHeld }
        XCTAssertTrue(reopened)
        XCTAssertTrue(controller.subsystems.backgroundTasks.acceptsControls)
        XCTAssertEqual(controller.subsystems.homeController.homeModel.unsavedInputs.first?.request.id, input.request.id)
        XCTAssertTrue(NSApp.windows.contains { $0.identifier == SessionPanelPresenter.panelIdentifier })
        controller.subsystems.notchPresence.stop()
        controller.subsystems.homeController.closeHome()
    }

    func testRenderUnsavedQuitConfirmation() async throws {
        let directory = try makeTemporaryDirectory()
        let controller = AppController.testing(directory: directory)
        let presentation = NotchPresentation.shared
        let originalOnPresent = presentation.onPresent
        presentation.onPresent = nil
        let confirmation = controller.unsavedRequestQuitConfirmation()
        defer {
            confirmation.cancel()
            presentation.onPresent = originalOnPresent
            controller.subsystems.notchPresence.stop()
        }
        let waiting = Task { await confirmation.confirm() }
        for _ in 0..<100 where !presentation.contains(confirmation.requestID) { await Task.yield() }
        let entry = try XCTUnwrap(presentation.current)
        XCTAssertEqual(entry.id, confirmation.requestID)
        let content = NSHostingView(rootView: entry.content)
        content.frame = NSRect(x: 0, y: 0, width: 512, height: 280)
        content.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/dependable-evidence/unsaved-quit-notch.png")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination)
        confirmation.cancel()
        let confirmed = await waiting.value
        XCTAssertFalse(confirmed)
        XCTAssertFalse(presentation.contains(confirmation.requestID))
    }

    func testNotificationCannotApproveNewRevisionBehindStaleTaskList() async throws {
        let directory = try makeTemporaryDirectory()
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let taskID = TaskID("stale-notification")
        let actions = try ["first", "second"].map { name in
            try ExecutableAction(
                id: ActionID(name), summary: "Create \(name).txt", approvalRequirement: .action,
                operation: .transform(
                    workspace: workspace,
                    command: .createUTF8File(path: "\(name).txt", contents: name)
                ),
                postcondition: .fileContents(name)
            )
        }
        let plan = try ExecutionPlan(
            taskID: taskID, goal: "Create two files", actions: actions, requestedScopes: [.workspaceWrite]
        )
        let queued = try await coordinator.enqueue(executablePlan: plan)
        let controller = AppController.testing(directory: directory) { $0.taskCoordinator = coordinator }
        await controller.subsystems.backgroundTasks.reloadRecords()
        let visible = try XCTUnwrap(controller.subsystems.backgroundTasks.records.first)
        XCTAssertEqual(visible.revision, queued.revision)
        XCTAssertEqual(visible.workspaceActionToApprove?.id, actions[0].id)

        // Advance the task past the visible revision before the stale notification lands.
        let prepared = try await coordinator.approveWorkspaceAction(
            id: taskID, expectedRevision: queued.revision
        )
        _ = try await coordinator.executeWorkspaceAction(
            id: taskID, expectedRevision: prepared.revision,
            runtime: WorkspaceFileRuntime(baseURL: workspace)
        )
        let newerRecord = await coordinator.record(id: taskID)
        let newer = try XCTUnwrap(newerRecord)
        XCTAssertNotEqual(newer.revision, visible.revision)
        XCTAssertEqual(newer.workspaceActionToApprove?.id, actions[1].id)

        controller.subsystems.backgroundTasks.approve(
            taskID,
            expectedActionID: actions[0].id.rawValue,
            expectedRevision: visible.revision
        )
        let settled = await waitUntil {
            controller.subsystems.backgroundTasks.message(for: taskID) == "That approval request is no longer current"
        }
        XCTAssertTrue(settled)
        let retained = await coordinator.record(id: taskID)
        XCTAssertEqual(retained, newer)
        XCTAssertFalse(controller.subsystems.backgroundTasks.isRunning(taskID))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("second.txt").path
        ))
        let metadata = await controller.subsystems.backgroundTasks.debugMetadata(taskID)
        XCTAssertNil(metadata)
    }

    func testMultiActionTaskRetainsMetadataUntilSecondApprovalAndReport() async throws {
        let directory = try makeTemporaryDirectory()
        let workspace = directory.appendingPathComponent("BackgroundWorkspaces/two-file-app-task", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let actions = try ["first", "second"].map { name in
            try ExecutableAction(
                id: ActionID(name), summary: "Create \(name).txt", approvalRequirement: .action,
                operation: .transform(workspace: workspace, command: .createUTF8File(path: "\(name).txt", contents: name)),
                postcondition: .fileContents(name)
            )
        }
        let plan = try PerryRuntimes.ExecutionPlan(taskID: "two-file-app-task", goal: "Create two files", actions: actions, requestedScopes: [.workspaceWrite])
        let metadata = BackgroundTaskMetadata(workspacePath: workspace.path)
        let controller = AppController.testing(directory: directory)
        try await controller.subsystems.backgroundTasks.debugSeed(record: TaskRecord(executablePlan: plan), metadata: metadata)
        let initial = await controller.subsystems.backgroundTasks.debugRecord(plan.taskID)
        controller.subsystems.backgroundTasks.approveWorkspace(try XCTUnwrap(initial))
        let awaitingSecond = await waitUntil {
            let current = await controller.subsystems.backgroundTasks.debugRecord(plan.taskID)
            return current?.workspaceActionToApprove?.id == actions[1].id
                && !controller.subsystems.backgroundTasks.isRunning(plan.taskID)
                && controller.subsystems.backgroundTasks.awaitingApprovalCount == 1
        }
        XCTAssertTrue(awaitingSecond)
        XCTAssertEqual(controller.subsystems.backgroundTasks.awaitingApprovalCount, 1)
        let retainedMetadata = await controller.subsystems.backgroundTasks.debugMetadata(plan.taskID)
        XCTAssertEqual(retainedMetadata, metadata)
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("first.txt"), encoding: .utf8), "first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("second.txt").path))
        let partialHistory = await TranscriptStore(directory: directory).snapshot()
        XCTAssertTrue(partialHistory.isEmpty)

        let pending = await controller.subsystems.backgroundTasks.debugRecord(plan.taskID)
        let secondApproval = try XCTUnwrap(pending)
        let staleRevision = try XCTUnwrap(initial).revision
        controller.subsystems.backgroundTasks.approve(plan.taskID, expectedActionID: actions[1].id.rawValue, expectedRevision: staleRevision)
        controller.subsystems.backgroundTasks.deny(plan.taskID, expectedRevision: staleRevision)
        let afterStaleNotifications = await controller.subsystems.backgroundTasks.debugRecord(plan.taskID)
        XCTAssertEqual(afterStaleNotifications, secondApproval)
        XCTAssertFalse(controller.subsystems.backgroundTasks.isRunning(plan.taskID))
        XCTAssertEqual(controller.subsystems.backgroundTasks.message(for: plan.taskID), "That approval request is no longer current")
        controller.subsystems.backgroundTasks.approve(plan.taskID, expectedActionID: actions[1].id.rawValue, expectedRevision: secondApproval.revision)
        let reported = await waitUntil {
            let current = await controller.subsystems.backgroundTasks.debugRecord(plan.taskID)
            let context = await controller.subsystems.backgroundTasks.debugMetadata(plan.taskID)
            // A retained terminal row is the durable receipt — the task is done.
            return (current?.isTerminal ?? true) && context == nil && !controller.subsystems.backgroundTasks.isRunning(plan.taskID)
                && controller.subsystems.backgroundTasks.awaitingApprovalCount == 0
        }
        XCTAssertTrue(reported)
        XCTAssertEqual(controller.subsystems.backgroundTasks.awaitingApprovalCount, 0)
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("second.txt"), encoding: .utf8), "second")
        let history = await TranscriptStore(directory: directory).snapshot()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.id, plan.planID)
        XCTAssertEqual(history.first?.outcome, .completed)
        XCTAssertEqual(history.first?.steps, actions.map(\.summary))
    }

    func testCancellationReportsPartialWorkWithoutRunningPreparedSecondAction() async throws {
        let directory = try makeTemporaryDirectory()
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let actions = try ["first", "second"].map { name in
            try ExecutableAction(
                id: ActionID(name), summary: "Create \(name).txt", approvalRequirement: .action,
                operation: .transform(workspace: workspace, command: .createUTF8File(path: "\(name).txt", contents: name)),
                postcondition: .fileContents(name)
            )
        }
        let plan = try PerryRuntimes.ExecutionPlan(taskID: "cancel-partial-app-task", goal: "Create two files", actions: actions, requestedScopes: [.workspaceWrite])
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: plan)
        let firstApproval = try await coordinator.approveWorkspaceAction(id: plan.taskID, expectedRevision: queued.revision)
        let partial = try await coordinator.executeWorkspaceAction(id: plan.taskID, expectedRevision: firstApproval.revision, runtime: WorkspaceFileRuntime(baseURL: workspace))
        _ = try await coordinator.approveWorkspaceAction(id: plan.taskID, expectedRevision: partial.revision)
        try await BackgroundTaskContextStore(storageDirectory: directory).save(BackgroundTaskMetadata(workspacePath: workspace.path), for: plan.taskID)
        let moved = directory.appendingPathComponent("moved-workspace", isDirectory: true)
        try FileManager.default.moveItem(at: workspace, to: moved)

        let controller = AppController.testing(directory: directory)
        await controller.subsystems.backgroundTasks.reloadRecords()
        controller.subsystems.backgroundTasks.cancel(plan.taskID)
        let reported = await waitUntil {
            let record = await controller.subsystems.backgroundTasks.debugRecord(plan.taskID)
            let metadata = await controller.subsystems.backgroundTasks.debugMetadata(plan.taskID)
            // Terminal retention keeps the cancelled run's receipts on record.
            return (record?.isTerminal ?? true) && metadata == nil && !controller.subsystems.backgroundTasks.isRunning(plan.taskID)
        }
        XCTAssertTrue(reported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent("second.txt").path))
        XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("first.txt"), encoding: .utf8), "first")
        let history = await TranscriptStore(directory: directory).snapshot()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.id, plan.planID)
        XCTAssertEqual(history.first?.outcome, .stopped)
        XCTAssertEqual(history.first?.steps, [actions[0].summary])
    }

    func testCancelledVerifiedReportPausesOnHistoryFailureWithoutRecreatingWorkspace() async throws {
        let directory = try makeTemporaryDirectory()
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let proposed = try await WorkspaceFilePlanFabricator().workspaceExecutionPlan(
            goal: #"create file "report.txt" with "saved report""#,
            workspace: workspace,
            taskID: "cancelled-report"
        )
        let executionPlan = try XCTUnwrap(proposed)
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let queued = try await coordinator.enqueue(executablePlan: executionPlan)
        let approved = try await coordinator.approveWorkspaceAction(id: queued.id, expectedRevision: queued.revision)
        _ = try await coordinator.executeWorkspaceAction(
            id: queued.id, expectedRevision: approved.revision, runtime: WorkspaceFileRuntime(baseURL: workspace)
        )
        let cancelled = try await coordinator.requestCancellation(id: queued.id)
        let ready = try await coordinator.queueWorkspaceReport(id: queued.id, expectedRevision: cancelled.revision)
        let movedWorkspace = directory.appendingPathComponent("moved-workspace", isDirectory: true)
        try FileManager.default.moveItem(at: workspace, to: movedWorkspace)
        let historyObstruction = directory.appendingPathComponent("Transcripts")
        let obstruction = Data("history cannot create a directory here".utf8)
        try obstruction.write(to: historyObstruction)
        let metadata = BackgroundTaskMetadata(workspacePath: workspace.path)
        try await BackgroundTaskContextStore(storageDirectory: directory).save(metadata, for: queued.id)

        let controller = AppController.testing(directory: directory)
        await controller.subsystems.backgroundTasks.reloadRecords()
        controller.subsystems.backgroundTasks.resume(queued.id)
        let paused = await waitUntil {
            let current = await controller.subsystems.backgroundTasks.debugRecord(queued.id)
            return current?.state == .paused && !controller.subsystems.backgroundTasks.isRunning(queued.id)
        }
        XCTAssertTrue(paused)
        let message = try XCTUnwrap(controller.subsystems.backgroundTasks.message(for: queued.id))
        XCTAssertTrue(message.contains(historyObstruction.path))
        let retained = await controller.subsystems.backgroundTasks.debugRecord(queued.id)
        XCTAssertEqual(retained?.intent, .cancel)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(retained?.workspaceJournal), try encoder.encode(ready.workspaceJournal))
        let retainedMetadata = await controller.subsystems.backgroundTasks.debugMetadata(queued.id)
        XCTAssertEqual(retainedMetadata, metadata)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        XCTAssertEqual(try String(contentsOf: movedWorkspace.appendingPathComponent("report.txt"), encoding: .utf8), "saved report")
        XCTAssertEqual(try Data(contentsOf: historyObstruction), obstruction)
    }

    func testUnsupportedTaskStoreSurfacesRecoveryErrorWithoutChangingData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perry-future-store-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        let fileURL = directory.appendingPathComponent("tasks.json")
        let future = Data(#"{"version":9001,"tasks":[]}"#.utf8)
        try future.write(to: fileURL)
        let controller = AppController.testing(directory: directory)
        await controller.subsystems.backgroundTasks.reloadRecords()
        XCTAssertTrue(controller.sessionStatus.contains("9001"))
        XCTAssertTrue(controller.sessionStatus.contains("compatible Perry version"))
        XCTAssertNotNil(controller.subsystems.backgroundTasks.persistenceError)
        XCTAssertEqual(try Data(contentsOf: fileURL), future)
        XCTAssertTrue(controller.subsystems.backgroundTasks.records.isEmpty)
    }

    func testCancelWaitsForSetupWriterBeforeFinalization() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock {
            try self.removeFixture(directory)
        }
        let controller = AppController.testing(directory: directory)
        let id = TaskID("cancel-waits-for-writer")
        let record = TaskRecord(executablePlan: try executablePlan(taskID: id, workspace: directory))
        let initialMetadata = BackgroundTaskMetadata(targetWindowTitle: "before writer")
        try await controller.subsystems.backgroundTasks.debugSeed(record: record, metadata: initialMetadata)

        let gate = AsyncGate()
        let probe = FixtureProbe()
        let writer = controller.subsystems.backgroundTasks.debugInstallSetupTask(for: id) {
            await gate.wait()
            do {
                try await controller.subsystems.backgroundTasks.debugSaveMetadata(
                    BackgroundTaskMetadata(targetWindowTitle: "after writer"),
                    for: id
                )
                await probe.markFinished()
            } catch {
                await probe.markFailure(String(describing: error))
            }
            await probe.markFinished()
        }
        addTeardownBlock {
            await gate.release()
            try await self.finishFixtureTask(writer, probe: probe)
            _ = await self.waitUntil {
                let record = await controller.subsystems.backgroundTasks.debugRecord(id)
                let metadata = await controller.subsystems.backgroundTasks.debugMetadata(id)
                return record == nil && metadata == nil
            }
        }

        controller.subsystems.backgroundTasks.cancel(id)
        let cancellationPersisted = await waitUntil {
            await controller.subsystems.backgroundTasks.debugRecord(id)?.intent == .cancel
        }
        XCTAssertTrue(cancellationPersisted)
        let metadataBeforeWriter = await controller.subsystems.backgroundTasks.debugMetadata(id)
        XCTAssertEqual(metadataBeforeWriter, initialMetadata)
        let probeBeforeWriter = await probe.snapshot()
        XCTAssertFalse(probeBeforeWriter.finished)

        await gate.release()
        try await finishFixtureTask(writer, probe: probe)
        let probeAfterWriter = await probe.snapshot()
        XCTAssertTrue(probeAfterWriter.finished)
        XCTAssertNil(probeAfterWriter.failure)
        let finalized = await waitUntil {
            let record = await controller.subsystems.backgroundTasks.debugRecord(id)
            let metadata = await controller.subsystems.backgroundTasks.debugMetadata(id)
            return record == nil && metadata == nil
        }
        XCTAssertTrue(finalized)
    }

    func testUncooperativeSetupWriterRefusesFinalizationAtDeadline() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock {
            try self.removeFixture(directory)
        }
        let controller = AppController.testing(directory: directory)
        let id = TaskID("uncooperative-writer")
        let record = TaskRecord(executablePlan: try executablePlan(taskID: id, workspace: directory))
        let initialMetadata = BackgroundTaskMetadata(targetWindowTitle: "retained")
        try await controller.subsystems.backgroundTasks.debugSeed(record: record, metadata: initialMetadata)

        let gate = AsyncGate()
        let probe = FixtureProbe()
        let writer = controller.subsystems.backgroundTasks.debugInstallSetupTask(for: id) {
            await gate.wait()
            do {
                try await controller.subsystems.backgroundTasks.debugSaveMetadata(
                    BackgroundTaskMetadata(targetWindowTitle: "late writer"),
                    for: id
                )
                await probe.markFinished()
            } catch {
                await probe.markFailure(String(describing: error))
            }
            await probe.markFinished()
        }
        addTeardownBlock {
            await gate.release()
            try await self.finishFixtureTask(writer, probe: probe)
            _ = await self.waitUntil {
                let record = await controller.subsystems.backgroundTasks.debugRecord(id)
                let metadata = await controller.subsystems.backgroundTasks.debugMetadata(id)
                return record == nil && metadata == nil
            }
        }

        controller.subsystems.backgroundTasks.cancel(id)
        let cancellationPersisted = await waitUntil {
            await controller.subsystems.backgroundTasks.debugRecord(id)?.intent == .cancel
        }
        XCTAssertTrue(cancellationPersisted)
        try await Task.sleep(for: .milliseconds(750))

        let retainedRecord = await controller.subsystems.backgroundTasks.debugRecord(id)
        let retainedMetadata = await controller.subsystems.backgroundTasks.debugMetadata(id)
        let probeBeforeRelease = await probe.snapshot()
        XCTAssertEqual(retainedRecord?.intent, .cancel)
        XCTAssertEqual(retainedMetadata, initialMetadata)
        XCTAssertFalse(probeBeforeRelease.finished)
        XCTAssertTrue(controller.subsystems.backgroundTasks.isRunning(id))

        await gate.release()
        try await finishFixtureTask(writer, probe: probe)
        let probeAfterRelease = await probe.snapshot()
        XCTAssertTrue(probeAfterRelease.finished)
        XCTAssertNil(probeAfterRelease.failure)
        controller.subsystems.backgroundTasks.cancel(id)
        let finalized = await waitUntil {
            let record = await controller.subsystems.backgroundTasks.debugRecord(id)
            let metadata = await controller.subsystems.backgroundTasks.debugMetadata(id)
            return record == nil && metadata == nil
        }
        XCTAssertTrue(finalized)
    }

    func testPauseInvalidatesQueuedColdResumeBeforeWorkerAdmission() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock {
            try self.removeFixture(directory)
        }
        let coordinator = TaskCoordinator(storageDirectory: directory)
        let controller = AppController.testing(directory: directory) { $0.taskCoordinator = coordinator }
        let id = TaskID("pause-invalidates-launch")
        let plan = try executablePlan(taskID: id, workspace: directory)
        let queued = try await coordinator.enqueue(executablePlan: plan)
        _ = try await coordinator.approveWorkspaceAction(id: id, expectedRevision: queued.revision)
        try await controller.subsystems.backgroundTasks.debugSaveMetadata(
            BackgroundTaskMetadata(targetWindowTitle: "queued"), for: id
        )
        await controller.subsystems.backgroundTasks.reloadRecords()

        let launchGate = AsyncGate()
        let probe = FixtureProbe()
        controller.subsystems.backgroundTasks.debugSetLaunchBarrier {
            await probe.markEntered()
            await launchGate.wait()
        }
        addTeardownBlock {
            await MainActor.run {
                controller.subsystems.backgroundTasks.debugSetLaunchBarrier(nil)
            }
            await launchGate.release()
            _ = await self.waitUntil {
                !controller.subsystems.backgroundTasks.isRunning(id)
            }
        }

        controller.subsystems.backgroundTasks.resume(id)
        let launchEntered = await waitUntil {
            let snapshot = await probe.snapshot()
            return snapshot.entered
        }
        XCTAssertTrue(launchEntered)
        controller.subsystems.backgroundTasks.pause(id)
        let paused = await waitUntil {
            let current = await controller.subsystems.backgroundTasks.debugRecord(id)
            return current?.state == .paused && current?.intent == .pause
        }
        XCTAssertTrue(paused)

        await launchGate.release()
        let launchStopped = await waitUntil {
            !controller.subsystems.backgroundTasks.isRunning(id)
        }
        XCTAssertTrue(launchStopped)
        let finalRecord = await controller.subsystems.backgroundTasks.debugRecord(id)
        XCTAssertEqual(finalRecord?.state, .paused)
        XCTAssertEqual(finalRecord?.intent, .pause)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("fixture.txt").path
        ))
    }

    func testErasureOwnerRejectsConcurrentQuitWithoutReopeningControls() async throws {
        let directory = try makeTemporaryDirectory()
        addTeardownBlock {
            try self.removeFixture(directory)
        }
        let controller = AppController.testing(directory: directory)
        let gate = AsyncGate()
        let probe = FixtureProbe()
        controller.debugSetMaintenanceFixture(skipEraseConfirmation: true) {
            await probe.markEntered()
            await gate.wait()
            throw FixtureError.release
        }
        addTeardownBlock {
            await gate.release()
            _ = await self.waitUntil {
                !controller.debugMaintenanceOwnerHeld
                    && controller.subsystems.backgroundTasks.acceptsControls
            }
            await MainActor.run {
                controller.debugSetMaintenanceFixture(skipEraseConfirmation: false, barrier: nil)
            }
        }

        controller.debugInvokeWipeDataAction()
        let eraseEntered = await waitUntil {
            let snapshot = await probe.snapshot()
            return snapshot.entered
        }
        XCTAssertTrue(eraseEntered)
        XCTAssertTrue(controller.debugMaintenanceOwnerHeld)
        XCTAssertFalse(controller.subsystems.backgroundTasks.acceptsControls)
        let blockedInput = controller.subsystems.homeController.acceptInput("Do not save during erasure")
        do { try await blockedInput.saved.value; XCTFail("Maintenance accepted new input") }
        catch is CancellationError {}
        var blockedRun: AgentFinish?
        for await event in controller.subsystems.agentCoordinator.run(threadID: UUID(), goal: "Do not execute during erasure") {
            if case .finished(let finish) = event { blockedRun = finish }
        }
        guard case .failed = blockedRun else { return XCTFail("Maintenance accepted a new run") }

        let reply = controller.applicationShouldTerminate(NSApplication.shared)
        XCTAssertEqual(reply, .terminateLater)
        XCTAssertEqual(controller.sessionStatus, "I’m finishing a data erase.")
        XCTAssertFalse(controller.subsystems.backgroundTasks.acceptsControls)

        await gate.release()
        let recovered = await waitUntil {
            !controller.debugMaintenanceOwnerHeld
                && controller.subsystems.backgroundTasks.acceptsControls
        }
        XCTAssertTrue(recovered)
        let reopened = controller.subsystems.homeController.acceptInput("Keep this after maintenance failed")
        try await reopened.saved.value
        let saved = await controller.subsystems.homeController.threadStore?.thread(id: reopened.threadID)
        XCTAssertEqual(saved?.waitingInputs?.first?.text, "Keep this after maintenance failed")
    }

    private func executablePlan(taskID: TaskID, workspace: URL) throws -> ExecutionPlan {
        let action = try ExecutableAction(
            id: ActionID("fixture-step"),
            summary: "Create fixture.txt",
            approvalRequirement: .action,
            operation: .transform(
                workspace: workspace,
                command: .createUTF8File(path: "fixture.txt", contents: "fixture")
            ),
            postcondition: .fileContents("fixture")
        )
        return try ExecutionPlan(
            taskID: taskID,
            goal: "fixture background task",
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            do {
                try await Task.sleep(
                    until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(5))),
                    clock: .continuous
                )
            } catch {
                return false
            }
        }
        return await condition()
    }

    private func removeFixture(_ directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try TestTempDirectory.remove(directory)
    }

    private func finishFixtureTask(
        _ task: Task<Void, Never>,
        probe: FixtureProbe
    ) async throws {
        let finished = await waitUntil(timeout: .seconds(2)) {
            let snapshot = await probe.snapshot()
            return snapshot.finished
        }
        guard finished else {
            task.cancel()
            throw FixtureJoinError.timeout
        }
        await task.value
    }
}

private actor AsyncGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                waiter = continuation
            }
        }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private actor FixtureProbe {
    private var entered = false
    private var finished = false
    private var failure: String?

    func markEntered() {
        entered = true
    }

    func markFinished() {
        finished = true
    }

    func markFailure(_ message: String) {
        failure = message
    }

    func snapshot() -> (entered: Bool, finished: Bool, failure: String?) {
        (entered, finished, failure)
    }
}

private enum FixtureError: Error {
    case release
}

private enum FixtureJoinError: Error {
    case timeout
}
#endif
