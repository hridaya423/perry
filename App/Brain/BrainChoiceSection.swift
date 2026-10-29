import PerryBrain
import SwiftUI

struct BrainChoiceSection: View {
    @ObservedObject var brain: BrainController
    @ObservedObject var local: LocalBrain
    let catalog: RuntimeCatalog
    @State private var profile = MachineProfile.current()
    @State private var bench: LocalBenchmark.Record?

    private var selection: CloudBrainList.Row? {
        switch brain.modelChoice {
        case .chatGPT: .chatGPT
        case .claudeCode: .claudeCode
        case .acp: brain.acpAgent.map(CloudBrainList.Row.agent)
        case .direct: .apiKey
        case .local: nil
        }
    }

    var body: some View {
        SettingsCard(title: "Brain") {
            CloudBrainList(brain: brain, selection: selection) { row in
                if case .agent(let agent) = row {
                    brain.setAcpAgent(agent)
                } else {
                    brain.modelChoice = row.choice
                }
            }
            SettingsDivider()
            Button { brain.modelChoice = .local } label: {
                HStack(spacing: 10) {
                    RadioMark(selected: brain.modelChoice == .local)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("On this Mac")
                        Text(localCapability)
                            .settingNote()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .settingsRowPadding()
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityAddTraits(brain.modelChoice == .local ? .isSelected : [])
        }
        detail
            .task {
                await brain.refreshSetupStates(using: catalog)
                bench = LocalBenchmark.load(from: local.benchURL)
            }
    }

    private var localCapability: String {
        if local.phase == .ready { return "Works offline. Nothing leaves this Mac." }
        if profile.appleIntelligenceAvailable { return "Works offline. Answers in text until a brain is set up." }
        return "Works offline once a brain is set up."
    }

    @ViewBuilder
    private var detail: some View {
        switch brain.modelChoice {
        case .chatGPT:
            SettingsCard(title: "ChatGPT") {
                HomeConnectionView(brain: brain, openSettings: { brain.modelChoice = .direct })
                    .settingsRowPadding()
                SettingsDivider()
                modelPicker(BrainController.chatGPTModels, selection: Binding(get: { brain.chatGPTModel }, set: { brain.chatGPTModel = $0 }))
            }
        case .claudeCode:
            SettingsCard(title: "Claude Code") {
                Text(brain.claudeCodeAvailable
                    ? "Perry runs Claude Code with your Claude sign-in. It follows the same approval rules as every other brain."
                    : "Claude Code isn’t installed. Install it, sign in with `claude`, then come back.")
                    .fixedSize(horizontal: false, vertical: true)
                    .settingsRowPadding()
                if brain.claudeCodeAvailable {
                    SettingsDivider()
                    modelPicker(BrainController.claudeCodeModels, selection: Binding(get: { brain.claudeCodeModel }, set: { brain.claudeCodeModel = $0 }))
                }
            }
        case .acp:
            SettingsCard(title: "Coding agent") {
                VStack(alignment: .leading, spacing: 10) {
                    AcpAgentSection(brain: brain)
                }
                .settingsRowPadding()
            }
        case .direct:
            SettingsCard(title: "API key") {
                VStack(alignment: .leading, spacing: 10) {
                    ModelProfilesSection(brain: brain)
                }
                .settingsRowPadding()
            }
        case .local:
            LocalBrainView(brain: brain, local: local, profile: profile, bench: bench)
        }
    }

    private func modelPicker(_ options: [BrainController.ModelOption], selection: Binding<String?>) -> some View {
        SettingsPicker(title: "Model", detail: "Automatic answers quick questions with a fast model and bigger tasks with a stronger one.", selection: selection) {
            ForEach(options, id: \.self) { option in
                Text(option.title).tag(option.id)
            }
        }
    }
}
