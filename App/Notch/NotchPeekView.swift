import AppKit
import PerryBrain
import PerryOverlay
import SwiftUI

struct PeekRow: Equatable, Identifiable {
    enum Kind: Equatable {
        case needsYou
        case setup
        case task(working: Bool)
        case perry
        case suggestion
    }

    let id: String
    let kind: Kind
    let title: String
    let status: String

    static let setup = PeekRow(id: "perry.setup", kind: .setup, title: "Finish setting up", status: "Pick up where you left off")

    static func rows(needsYou: PeekRow?, setup: PeekRow? = nil, tasks: [PeekRow], perrys: [PeekRow], suggestions: [PeekRow]) -> [PeekRow] {
        let urgent = Array(([needsYou, setup].compactMap { $0 } + tasks).prefix(2))
        return urgent.isEmpty ? Array((perrys + suggestions).prefix(2)) : urgent
    }

    @MainActor
    static func rows(model: HomeModel, presentation: NotchPresentation, setupParked: Bool = OnboardingCoordinator.isParked, now: Date = .now) -> [PeekRow] {
        let waiting = presentation.current.flatMap { entry -> PeekRow? in
            guard entry.priority != .activity, !presentation.showsInteraction else { return nil }
            let title = switch entry.priority {
            case .voice: "Perry is listening"
            case .approval: "Perry needs your OK"
            case .guide: "A guide is waiting for you"
            case .routine: "A routine is waiting for you"
            case .activity: ""
            }
            return PeekRow(id: entry.id.uuidString, kind: .needsYou, title: title, status: "Open it to continue")
        }
        let running = (model.deps.backgroundTasks?.records ?? []).filter { !$0.isTerminal }.map {
            PeekRow(id: "\($0.id)", kind: .task(working: true), title: $0.goal, status: "Working in the background")
        }
        let threads = model.threads
            .filter { model.workingThreads.contains($0.id) || now.timeIntervalSince($0.updatedAt) < 86_400 }
            .sorted { (model.workingThreads.contains($0.id) ? 1 : 0, $0.updatedAt) > (model.workingThreads.contains($1.id) ? 1 : 0, $1.updatedAt) }
            .map { thread in
                let working = model.workingThreads.contains(thread.id)
                let last = thread.turns.last
                let status = working
                    ? model.streamingAnswers[thread.id].flatMap(Self.lastLine) ?? "Working…"
                    : last?.failureReason ?? last.flatMap { Self.lastLine($0.answer) } ?? "No answer yet"
                return PeekRow(id: thread.id.uuidString, kind: .task(working: working),
                               title: thread.title.isEmpty ? last?.question ?? "Conversation" : thread.title, status: status)
            }
        return rows(
            needsYou: waiting,
            setup: setupParked ? setup : nil,
            tasks: running + threads,
            perrys: model.perrys.map { PeekRow(id: $0.id.uuidString, kind: .perry, title: $0.name, status: $0.job) },
            suggestions: model.suggestions.map { PeekRow(id: $0.id.uuidString, kind: .suggestion, title: $0.title, status: $0.body) }
        )
    }

    private static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init)
    }
}

struct NotchPeekView: View {
    @ObservedObject var model: HomeModel
    @ObservedObject var presentation: NotchPresentation
    let onOpen: (PeekRow) -> Void
    let onExpand: () -> Void

    var body: some View {
        let rows = PeekRow.rows(model: model, presentation: presentation)
        VStack(spacing: 16) {
            if rows.isEmpty {
                PeekGestureLine()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.leading, PeekRowMetrics.textInset)
                        }
                        PeekRowView(row: row) { onOpen(row) }
                    }
                }
            }
            WorkspaceComposer(
                text: Binding(get: { model.newConversationDraft }, set: { model.updateNewDraft($0) }),
                placeholder: "Ask Perry…",
                canSend: !model.isCreatingConversation,
                focusOnAppear: false,
                onVoice: model.deps.controller.map { controller in { controller.talkSession.startClick() } },
                onExpand: onExpand
            ) {
                model.onStartConversation?(model.newConversationDraft)
            }
        }
        .padding(.horizontal, NotchLayout.peekInset)
        .padding(.bottom, NotchLayout.peekInset - NotchLayout.bottomInset)
        .foregroundStyle(PerryTheme.Colors.text)
    }
}

private enum PeekRowMetrics {
    static let inset = CGFloat(6)
    static let leadSpacing = CGFloat(12)
    static let textInset = inset + PerryTheme.Icon.slot + leadSpacing
}

private struct PeekRowView: View {
    let row: PeekRow
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: PeekRowMetrics.leadSpacing) {
                lead.frame(width: PerryTheme.Icon.slot, height: PerryTheme.Icon.slot)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(PerryTheme.Scale.rowTitle)
                        .lineLimit(1)
                    Text(row.status)
                        .font(PerryTheme.Scale.secondary)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if row.kind == .needsYou {
                    Text("Review")
                        .font(PerryTheme.Scale.chip)
                        .foregroundStyle(PerryTheme.Colors.onPrimaryAction)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(PerryTheme.Colors.primaryAction, in: Capsule())
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, PeekRowMetrics.inset)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(hovered ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .padding(.horizontal, -6)
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(row.title). \(row.status)")
    }

    @ViewBuilder
    private var lead: some View {
        switch row.kind {
        case .needsYou:
            LeadDisc(systemImage: "exclamationmark", tint: PerryTheme.Colors.caution)
        case .task(working: true):
            LeadSpinner()
        case .task(working: false):
            LeadDisc(systemImage: "checkmark", tint: PerryTheme.Colors.success)
        case .perry:
            PerryCharacterView(pose: PerryCharacterPose(), size: PerryTheme.Icon.slot)
        case .setup:
            LeadDisc(systemImage: "arrow.right", tint: PerryTheme.Colors.accent)
        case .suggestion:
            LeadDisc(systemImage: "lightbulb", tint: PerryTheme.Colors.icon)
        }
    }
}

private struct PeekGestureLine: View {
    var body: some View {
        Text("\(TalkGesture.talk), or type below.")
            .font(PerryTheme.Scale.secondary)
            .foregroundStyle(PerryTheme.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
