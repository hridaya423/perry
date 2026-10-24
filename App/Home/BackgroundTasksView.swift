import AppKit
import SwiftUI
import PerryCore
import PerryGuide
import PerryRuntimes

struct BackgroundTasksView: View {
    @ObservedObject var backgroundTasks: BackgroundTaskController
    let runtimes: RuntimeCatalog
    var askPerry: (() -> Void)?
    @State private var hasLoaded = false

    private var isEmpty: Bool {
        hasLoaded && backgroundTasks.records.isEmpty && backgroundTasks.persistenceError == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isEmpty {
                WorkspaceEmptyState(
                    title: "Nothing in the background",
                    message: "Long jobs you hand to Perry keep running here while you work.",
                    actionTitle: askPerry == nil ? nil : "Give Perry a job",
                    action: askPerry
                )
            } else {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tasks are saved on this Mac. Perry resumes them only between steps.")
                            .font(PerryTheme.Typography.note)
                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                        if hasLoaded, backgroundTasks.persistenceError == nil {
                            Text("\(backgroundTasks.runningCount) active · \(backgroundTasks.records.count) saved")
                                .font(PerryTheme.Typography.note)
                                .monospacedDigit()
                                .foregroundStyle(PerryTheme.Colors.textSecondary)
                        }
                    }
                    Spacer()
                    Button("Resume all") {
                        backgroundTasks.resumeAll()
                    }
                    .disabled(!hasLoaded || backgroundTasks.persistenceError != nil || backgroundTasks.records.allSatisfy {
                        !($0.canResumeWorkspaceTask && !$0.checkpoint.isAwaitingApproval && !backgroundTasks.isRunning($0.id))
                    })
                }

                if !hasLoaded {
                    ProgressView("Loading saved tasks")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            if let issue = backgroundTasks.persistenceError {
                                VStack(alignment: .leading, spacing: PerryTheme.Spacing.inline) {
                                    Label("Task storage needs attention", systemImage: "exclamationmark.triangle")
                                        .font(.headline)
                                        .accessibilityAddTraits(.isHeader)
                                    Text("Resolve the storage issue shown below, then reopen Perry. Keep the task files for recovery.")
                                        .font(PerryTheme.Typography.note)
                                    Text(issue.localizedDescription)
                                        .font(PerryTheme.Typography.note)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, PerryTheme.Spacing.section)
                                .accessibilityIdentifier("background-task-storage-error")
                            }
                            ForEach(backgroundTasks.records) { record in
                                BackgroundTaskRow(record: record, backgroundTasks: backgroundTasks, runtimes: runtimes)
                                if record.id != backgroundTasks.records.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                }

                Text("Paused tasks may need your approval or their original app before they can continue.")
                    .font(PerryTheme.Typography.note)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
            }
        }
        .padding(20)
        .task {
            while !Task.isCancelled {
                await backgroundTasks.reloadRecords()
                hasLoaded = true
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }
}

private struct BackgroundTaskRow: View {
    let record: TaskRecord
    @ObservedObject var backgroundTasks: BackgroundTaskController
    let runtimes: RuntimeCatalog
    @State private var showDeleteConfirmation = false
    @State private var showUndoConfirmation = false
    @State private var approvalPresentationID = UUID()
    @State private var workspaceApproval: TaskRecord?

    private var recoveryNotice: BackgroundTaskRecoveryNotice? {
        BackgroundTaskRecoveryNotice(record: record, isRunning: backgroundTasks.isRunning(record.id))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.goal)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    if case .agent = record.plan {
                        Text(record.state.rawValue.capitalized)
                    } else {
                        Text("\(record.state.rawValue.capitalized) · step \(min(record.checkpoint.nextStepIndex + 1, max(record.plan.actionCount, 1))) of \(record.plan.actionCount)")
                    }
                }
                .font(PerryTheme.Typography.note)
                .monospacedDigit()
                .foregroundStyle(PerryTheme.Colors.textSecondary)
                if case .legacy(let plan) = record.plan {
                    Text("Agent: \(runtimes.name(for: plan.runtimeID))")
                        .font(PerryTheme.Typography.note)
                        .monospacedDigit()
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                }
                if let recoveryNotice {
                    BackgroundTaskRecoveryNoticeView(notice: recoveryNotice)
                } else if record.checkpoint.isAwaitingApproval,
                   record.plan.actionSummaries.indices.contains(record.checkpoint.nextStepIndex) {
                    Text("Approval required: \(record.plan.actionSummaries[record.checkpoint.nextStepIndex])")
                        .font(PerryTheme.Typography.note.weight(.medium))
                        .foregroundStyle(PerryTheme.Colors.warning)
                }
                if recoveryNotice == nil, let message = backgroundTasks.message(for: record.id) {
                    Text(message)
                        .font(PerryTheme.Typography.note)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            controls
        }
        .padding(.vertical, 9)
        .notchDialog(
            "Delete this task and its workspace?",
            isPresented: $showDeleteConfirmation,
            message: "This removes the saved task and every file in its private Perry workspace."
        ) {
            [NotchDialog.Action("Delete task and workspace", role: .destructive) {
                backgroundTasks.discard(record.id)
            }]
        }
        .onChange(of: workspaceApproval?.id) { _, _ in
            guard let presented = workspaceApproval else { return }
            NotchPresentation.shared.present(id: approvalPresentationID, priority: .approval,
                content: WorkspaceTaskApprovalView(record: presented, approve: {
                    backgroundTasks.approveWorkspace(presented)
                }, dismiss: {
                    NotchPresentation.shared.remove(approvalPresentationID)
                    workspaceApproval = nil
                }))
        }
        .notchDialog(
            "Undo Perry’s changes?",
            isPresented: $showUndoConfirmation,
            message: "Perry will reverse, in order:\n" + undoDescriptions.joined(separator: "\n") + "\n\nAnything you changed since stays untouched. Undo stops at the first conflict."
        ) {
            [NotchDialog.Action("Undo \(undoDescriptions.count) change\(undoDescriptions.count == 1 ? "" : "s")") {
                backgroundTasks.undoWorkspaceChanges(record)
            }]
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 6) {
            if recoveryNotice != nil {
                if backgroundTasks.isRunning(record.id) {
                    Button("Stop", role: .destructive) { backgroundTasks.cancel(record.id) }
                        .controlSize(.small)
                        .accessibilityLabel("Stop task \(record.goal)")
                } else {
                    if recoveryNotice == .legacyPlan {
                        Button("Replan") { backgroundTasks.replan(record.id) }
                            .buttonStyle(InkButtonStyle())
                            .controlSize(.small)
                            .accessibilityLabel("Replan task \(record.goal)")
                    }
                    Button("Delete…", role: .destructive) { showDeleteConfirmation = true }
                        .controlSize(.small)
                        .accessibilityLabel("Delete task and workspace \(record.goal)")
                }
            } else if record.workspaceActionToApprove != nil {
                Button("Review file") { workspaceApproval = record }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.small)
                    .accessibilityLabel("Review file creation for \(record.goal)")
                Button("Deny", role: .destructive) { backgroundTasks.cancel(record.id) }
                    .controlSize(.small)
            } else if backgroundTasks.isRunning(record.id), case .executable = record.plan {
                Button("Stop", role: .destructive) { backgroundTasks.cancel(record.id) }
                    .controlSize(.small)
                    .accessibilityLabel("Stop task \(record.goal)")
            } else if backgroundTasks.isRunning(record.id), record.state != .paused {
                Button("Pause") { backgroundTasks.pause(record.id) }
                    .controlSize(.small)
                    .accessibilityLabel("Pause task \(record.goal)")
                Button("Stop", role: .destructive) { backgroundTasks.cancel(record.id) }
                    .controlSize(.small)
                    .accessibilityLabel("Stop task \(record.goal)")
            } else if backgroundTasks.isRunning(record.id), record.state == .paused {
                Button("Resume") { backgroundTasks.resume(record.id) }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.small)
                    .accessibilityLabel("Resume task \(record.goal)")
                Button("Stop", role: .destructive) { backgroundTasks.cancel(record.id) }
                    .controlSize(.small)
                    .accessibilityLabel("Stop task \(record.goal)")
            } else if record.canResumeWorkspaceTask {
                Button("Resume") { backgroundTasks.resume(record.id) }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.small)
                    .accessibilityLabel("Resume task \(record.goal)")
                Button("Stop", role: .destructive) { backgroundTasks.cancel(record.id) }
                    .controlSize(.small)
                    .accessibilityLabel("Stop task \(record.goal)")
            } else {
                if backgroundTasks.isUndoing(record.id) {
                    Button("Undoing…") {}
                        .controlSize(.small)
                        .disabled(true)
                } else if !undoDescriptions.isEmpty {
                    Button("Undo…") { showUndoConfirmation = true }
                        .controlSize(.small)
                        .accessibilityLabel("Undo Perry's changes for \(record.goal)")
                }
                Button("Delete…", role: .destructive) { showDeleteConfirmation = true }
                    .controlSize(.small)
                    .accessibilityLabel("Delete task and workspace \(record.goal)")
            }
        }
    }

    private var undoDescriptions: [String] {
        backgroundTasks.undoableDescriptions(for: record)
    }

    private var iconName: String {
        if recoveryNotice != nil { return "exclamationmark.triangle" }
        switch record.state {
        case .queued, .ready: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle"
        case .blocked: return "hand.raised.circle"
        case .failed: return "xmark.circle"
        }
    }

    private var iconColor: Color {
        if recoveryNotice != nil { return PerryTheme.Colors.warning }
        switch record.state {
        case .queued, .ready: return .secondary
        case .running: return PerryTheme.Colors.active
        case .paused: return PerryTheme.Colors.warning
        case .completed: return PerryTheme.Colors.success
        case .blocked: return PerryTheme.Colors.warning
        case .failed: return PerryTheme.Colors.danger
        }
    }
}

private struct WorkspaceTaskApprovalView: View {
    let record: TaskRecord
    let approve: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.section) {
            Text("Create this file?")
                .font(PerryTheme.Typography.panelTitle)
            if let action = record.workspaceActionToApprove,
               case .transform(let workspace, .createUTF8File(let path, let contents)) = action.operation {
                Text("Perry will create one file in this task’s workspace. An existing file will not be overwritten.")
                    .font(PerryTheme.Typography.panelBody)
                Text(workspace.appendingPathComponent(path).path)
                    .font(PerryTheme.Typography.mono)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("File contents · \(contents.utf8.count) bytes")
                    .font(PerryTheme.Typography.panelMetadata)
                ScrollView {
                    Text(contents.isEmpty ? "This file will be empty." : contents)
                        .font(PerryTheme.Typography.mono)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: PerryTheme.Sizing.filePreviewMinimumHeight)
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Create file") {
                        approve()
                        dismiss()
                    }
                    .buttonStyle(InkButtonStyle())
                }
            } else {
                Text("This approval is no longer available. Go back and review the current task.")
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(PerryTheme.Spacing.panelInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BackgroundTaskRecoveryNoticeView: View {
    let notice: BackgroundTaskRecoveryNotice

    var body: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.tight) {
            Text(notice.title)
                .font(PerryTheme.Typography.note.weight(.semibold))
            Text(notice.message)
                .font(PerryTheme.Typography.note)
        }
        .foregroundStyle(PerryTheme.Colors.text)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
