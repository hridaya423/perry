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

    static let setup = PeekRow(id: "perry.setup", kind: .setup, title: "Finish setup", status: "Pick up where you left off")

    static func rows(needsYou: PeekRow?, setup: PeekRow? = nil, tasks: [PeekRow], perrys: [PeekRow], suggestions: [PeekRow]) -> [PeekRow] {
        let urgent = Array(([needsYou, setup].compactMap { $0 } + tasks).prefix(2))
        return urgent.isEmpty ? Array((perrys + suggestions).prefix(2)) : urgent
    }

    @MainActor
    static func rows(model: HomeModel, presentation: NotchPresentation, setupParked: Bool = OnboardingCoordinator.isParked, now: Date = .now) -> [PeekRow] {
        let waiting = presentation.current.flatMap { entry -> PeekRow? in
            guard entry.priority != .activity, !presentation.showsInteraction else { return nil }
            let title = switch entry.priority {
            case .voice: "Listening"
            case .approval: entry.title ?? "Needs your OK"
            case .guide: "Guide needs you"
            case .routine: "Routine needs you"
            case .activity: ""
            }
            let status = entry.priority == .approval ? (entry.title == nil ? "Open to review" : "Needs your OK") : "Open to continue"
            return PeekRow(id: entry.id.uuidString, kind: .needsYou, title: title, status: status)
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

    static func helperTint(_ id: String) -> Color {
        let palette = [Color(red: 0.55, green: 0.71, blue: 1.0), Color(red: 1.0, green: 0.76, blue: 0.48),
                       Color(red: 0.79, green: 0.65, blue: 1.0), Color(red: 1.0, green: 0.62, blue: 0.72),
                       Color(red: 0.44, green: 0.84, blue: 0.88)]
        return palette[Int(id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }) % palette.count]
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
        VStack(spacing: 10) {
            if rows.isEmpty {
                PeekWelcome()
            } else {
                VStack(spacing: 2) {
                    ForEach(rows) { row in
                        PeekRowView(row: row) { onOpen(row) }
                    }
                }
            }
            HStack {
                if !rows.isEmpty {
                    Text(TalkGesture.talk)
                        .font(PerryTheme.Scale.secondary)
                        .foregroundStyle(PerryTheme.Colors.textTertiary)
                }
                Spacer()
                WindowControlButton(systemImage: "arrow.up.left.and.arrow.down.right", label: "Open Perry", action: onExpand)
            }
            .padding(.leading, PeekRowMetrics.inset)
        }
        .padding(.horizontal, NotchLayout.peekInset)
        .padding(.bottom, NotchLayout.peekInset - NotchLayout.bottomInset - 6)
        .foregroundStyle(PerryTheme.Colors.text)
    }
}

private enum PeekRowMetrics {
    static let inset = CGFloat(6)
    static let leadSpacing = CGFloat(12)
    static let tile = CGFloat(38)
}

private struct PeekRowView: View {
    let row: PeekRow
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: PeekRowMetrics.leadSpacing) {
                lead
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
                if row.kind == .task(working: true) {
                    TypingDots()
                } else if row.kind == .needsYou {
                    Text("Review")
                        .font(PerryTheme.Scale.chip)
                        .foregroundStyle(PerryTheme.Colors.onPrimaryAction)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(PerryTheme.Colors.primaryAction, in: Capsule())
                }
            }
            .padding(.vertical, 8)
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
        case .needsYou: face(PerryTheme.Colors.caution, face: .wide)
        case .task(working: true): face(PerryCharacterView.fern, face: .focused)
        case .task(working: false), .setup: face(PerryCharacterView.fern, face: .happy)
        case .perry: face(PeekRow.helperTint(row.id), face: .open)
        case .suggestion: face(PerryTheme.Colors.icon, face: .open)
        }
    }

    private func face(_ tint: Color, face: PerryCharacterPose.Face) -> some View {
        var pose = PerryCharacterPose()
        pose.face = face
        return PerryCharacterView(pose: pose, size: 24, tint: tint)
            .frame(width: PeekRowMetrics.tile, height: PeekRowMetrics.tile)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct PeekWelcome: View {
    var body: some View {
        VStack(spacing: 6) {
            PerryCharacterView(pose: PerryCharacterPose(), size: 30)
                .padding(.bottom, 4)
            Text("\(PerryPreferences.talkGesture.spoken) and ask me anything")
                .font(PerryTheme.Scale.heading)
            Text(TalkGesture.type)
                .font(PerryTheme.Scale.secondary)
                .foregroundStyle(PerryTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}

private struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = reduceMotion ? 0.3 : context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(PerryTheme.Colors.accent)
                        .frame(width: 5, height: 5)
                        .opacity(0.35 + 0.65 * max(0, sin((time * 2.4 - Double(index) * 0.35) * .pi)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
