import AppKit
import SwiftUI
import PerryCore
import PerryGuide
import PerryRuntimes

struct BackgroundTasksView: View {
    @ObservedObject var backgroundTasks: BackgroundTaskController
    var askPerry: (() -> Void)?
    @State private var hasLoaded = false

    private var isEmpty: Bool {
        hasLoaded && backgroundTasks.records.isEmpty && backgroundTasks.persistenceError == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isEmpty {
                WorkspaceEmptyState(
                    title: "No tasks running",
                    message: "Tasks you start run here while you work.",
                    actionTitle: askPerry == nil ? nil : "Start a task",
                    action: askPerry
                )
            } else {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tasks are saved on this Mac. Perry resumes them only between steps.")
                            .font(PerryTheme.Scale.secondary)
                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                        if hasLoaded, backgroundTasks.persistenceError == nil {
                            Text("\(backgroundTasks.runningCount) active · \(backgroundTasks.records.count) saved")
                                .font(PerryTheme.Scale.secondary)
                                .monospacedDigit()
                                .foregroundStyle(PerryTheme.Colors.textSecondary)
                        }
                    }
                    Spacer()
                    Button("Resume all") {
                        backgroundTasks.resumeAll()
                    }
                    .disabled(!hasLoaded || backgroundTasks.persistenceError != nil || !backgroundTasks.records.contains(where: backgroundTasks.canResume))
                }

                if !hasLoaded {
                    ProgressView("Loading saved tasks")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            if let issue = backgroundTasks.persistenceError {
                                VStack(alignment: .leading, spacing: PerryTheme.Spacing.inline) {
                                    StatusLabel("Couldn’t read saved tasks", .attention)
                                        .font(PerryTheme.Scale.rowTitle)
                                        .accessibilityAddTraits(.isHeader)
                                    Text("Reopen Perry. Don’t delete the task files.")
                                        .font(PerryTheme.Scale.secondary)
                                    Text(issue.localizedDescription)
                                        .font(PerryTheme.Scale.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, PerryTheme.Spacing.section)
                                .accessibilityIdentifier("background-task-storage-error")
                            }
                            ForEach(backgroundTasks.records) { record in
                                BackgroundTaskRow(record: record, backgroundTasks: backgroundTasks)
                                if record.id != backgroundTasks.records.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                }

                Text("Paused tasks may need your approval or their original app before they can continue.")
                    .font(PerryTheme.Scale.secondary)
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
    @State private var showDeleteConfirmation = false
    @State private var showUndoConfirmation = false
    @State private var approvalPresentationID = UUID()
    @State private var workspaceApproval: TaskRecord?

    private var recoveryNotice: BackgroundTaskRecoveryNotice? {
        BackgroundTaskRecoveryNotice(record: record, isRunning: backgroundTasks.isRunning(record.id))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            lead
            VStack(alignment: .leading, spacing: 4) {
                Text(record.goal)
                    .font(PerryTheme.Scale.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    if case .agent = record.plan {
                        Text(record.state.rawValue.capitalized)
                    } else {
                        Text("\(record.state.rawValue.capitalized) · step \(min(record.checkpoint.nextStepIndex + 1, max(record.plan.actionCount, 1))) of \(record.plan.actionCount)")
                    }
                }
                .font(PerryTheme.Scale.secondary)
                .monospacedDigit()
                .foregroundStyle(PerryTheme.Colors.textSecondary)
                if let recoveryNotice {
                    BackgroundTaskRecoveryNoticeView(notice: recoveryNotice)
                } else if record.checkpoint.isAwaitingApproval,
                   record.plan.actionSummaries.indices.contains(record.checkpoint.nextStepIndex) {
                    Text("Needs your OK: \(record.plan.actionSummaries[record.checkpoint.nextStepIndex])")
                        .font(PerryTheme.Scale.meta)
                        .foregroundStyle(PerryTheme.Colors.caution)
                }
                if recoveryNotice == nil, let message = backgroundTasks.message(for: record.id) {
                    Text(message)
                        .font(PerryTheme.Scale.secondary)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            controls
        }
        .padding(.vertical, 9)
        .notchDialog(
            "Delete this task and its files?",
            isPresented: $showDeleteConfirmation,
            message: "I’ll delete the saved task and every file it made."
        ) {
            [NotchDialog.Action("Delete task", role: .destructive) {
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
            "Undo my changes?",
            isPresented: $showUndoConfirmation,
            message: "I’ll reverse these, in order:\n" + undoDescriptions.joined(separator: "\n") + "\n\nAnything you changed since stays as it’s. I stop at the first conflict."
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
                    Button("Delete…", role: .destructive) { showDeleteConfirmation = true }
                        .controlSize(.small)
                        .accessibilityLabel("Delete task \(record.goal)")
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
            } else if backgroundTasks.canResume(record) {
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
                        .accessibilityLabel("Undo my changes for \(record.goal)")
                }
                Button("Delete…", role: .destructive) { showDeleteConfirmation = true }
                    .controlSize(.small)
                    .accessibilityLabel("Delete task \(record.goal)")
            }
        }
    }

    private var undoDescriptions: [String] {
        backgroundTasks.undoableDescriptions(for: record)
    }

    @ViewBuilder
    private var lead: some View {
        if recoveryNotice != nil {
            LeadDisc(systemImage: "exclamationmark", tint: PerryTheme.Colors.caution)
        } else {
            switch record.state {
            case .queued, .ready: LeadDisc(systemImage: "clock", tint: PerryTheme.Colors.icon)
            case .running: LeadSpinner()
            case .paused: LeadDisc(systemImage: "pause", tint: PerryTheme.Colors.caution)
            case .completed: LeadDisc(systemImage: "checkmark", tint: PerryTheme.Colors.success)
            case .blocked: LeadDisc(systemImage: "hand.raised", tint: PerryTheme.Colors.caution)
            case .failed: LeadDisc(systemImage: "xmark", tint: PerryTheme.Colors.danger)
            }
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
                .font(PerryTheme.Scale.title)
            if let action = record.workspaceActionToApprove,
               case .transform(let workspace, .createUTF8File(let path, let contents)) = action.operation {
                Text("I’ll create one file in this task’s folder. I’ll not overwrite an existing file.")
                    .font(PerryTheme.Scale.body)
                Text(workspace.appendingPathComponent(path).path)
                    .font(PerryTheme.Scale.code)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("File contents · \(contents.utf8.count) bytes")
                    .font(PerryTheme.Scale.meta)
                ScrollView {
                    Text(contents.isEmpty ? "This file will be empty." : contents)
                        .font(PerryTheme.Scale.code)
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
                Text("This request is gone. Go back and review the current task.")
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
                .font(PerryTheme.Scale.section)
            Text(notice.message)
                .font(PerryTheme.Scale.secondary)
        }
        .foregroundStyle(PerryTheme.Colors.text)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
