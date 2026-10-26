import PerryBrain
import SwiftUI

struct CloudBrainList: View {
    enum Row: Hashable {
        case chatGPT
        case claudeCode
        case agent(AcpAgent)
        case apiKey

        static func == (lhs: Row, rhs: Row) -> Bool {
            switch (lhs, rhs) {
            case (.chatGPT, .chatGPT), (.claudeCode, .claudeCode), (.apiKey, .apiKey): true
            case (.agent(let left), .agent(let right)): left.id == right.id
            default: false
            }
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(title)
            if case .agent(let agent) = self { hasher.combine(agent.id) }
        }

        var choice: BrainController.ModelChoice {
            switch self {
            case .chatGPT: .chatGPT
            case .claudeCode: .claudeCode
            case .agent: .acp
            case .apiKey: .direct
            }
        }

        var title: String {
            switch self {
            case .chatGPT: "ChatGPT"
            case .claudeCode: "Claude Code"
            case .agent(let agent): agent.name
            case .apiKey: "API key"
            }
        }

        var capability: String {
            switch self {
            case .chatGPT: "Needs internet. Uses your ChatGPT plan."
            case .claudeCode: "Needs internet. Uses your Claude plan."
            case .agent(let agent): "Needs internet. Runs through \(agent.name)."
            case .apiKey: "Needs internet. The service behind your key bills you."
            }
        }
    }

    static func rows(claudeCodeInstalled: Bool, agents: [AcpAgent]) -> [Row] {
        [.chatGPT] + (claudeCodeInstalled ? [.claudeCode] : []) + agents.map(Row.agent) + [.apiKey]
    }

    static func installedAgents(saved: AcpAgent?) -> [AcpAgent] {
        let known = AcpAgent.known.filter { $0.executable() != nil }
        guard let saved, saved.executable() != nil, !known.contains(where: { $0.id == saved.id }) else { return known }
        return known + [saved]
    }

    static func preselected(
        saved: BrainController.ModelChoice?,
        savedAgent: AcpAgent?,
        rows: [Row],
        states: [BrainController.ModelChoice: SetupState],
        hasProfile: Bool
    ) -> Row? {
        if let saved {
            switch saved {
            case .acp:
                if let match = rows.first(where: { if case .agent(let agent) = $0 { agent.id == savedAgent?.id } else { false } }) { return match }
            case .local:
                return nil
            default:
                if let match = rows.first(where: { $0.choice == saved }) { return match }
            }
        }
        return rows.first { row in
            if row == .apiKey { return hasProfile }
            if case .ready = states[row.choice] { return true }
            return false
        }
    }

    @ObservedObject var brain: BrainController
    let selection: Row?
    let select: (Row) -> Void

    var body: some View {
        let rows = Self.rows(claudeCodeInstalled: brain.claudeCodeAvailable, agents: Self.installedAgents(saved: brain.acpAgent))
        ForEach(Array(rows.enumerated()), id: \.element) { index, row in
            if index > 0 { SettingsDivider() }
            Button { select(row) } label: {
                HStack(alignment: .center, spacing: 10) {
                    RadioMark(selected: selection == row)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                        Text(row.capability)
                            .settingNote()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(status(row))
                        .settingNote()
                        .lineLimit(1)
                }
                .settingsRowPadding()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection == row ? .isSelected : [])
            .accessibilityValue(status(row))
        }
    }

    private func status(_ row: Row) -> String {
        if row == .apiKey {
            return brain.activeProfile.map { "\($0.displayName) · \($0.model)" } ?? ""
        }
        switch brain.setupStates[row.choice] ?? .unchecked {
        case .ready(let detail): return detail
        case .needsSignIn: return "Sign in"
        case .notInstalled: return "Not installed"
        case .unchecked: return ""
        }
    }
}
