import AppKit
import PerryRuntimes
import SwiftUI

struct BrainSettingsPage: View {
    let controller: AppController
    @State private var setup = RuntimeSetupSnapshot(summary: "Looking for coding agents…", records: [])
    @State private var screenStatus = "Checking…"
    @State private var refreshCount = 0
    @State private var copiedCommand: String?
    @State private var error: String?

    var body: some View {
        SettingsScroll {
            BrainChoiceSection(brain: controller.subsystems.brain, local: controller.subsystems.localBrain, catalog: controller.subsystems.runtimes)
            SettingsCard(title: "Coding agents", footer: setup.records.contains(where: { $0.status == setup.summary }) ? nil : setup.summary) {
                ForEach(setup.records) { runtime in
                    HStack(alignment: .firstTextBaseline, spacing: PerryTheme.Spacing.inline) {
                        StatusMark(runtime.isReady ? .ok : .attention)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(runtime.name)
                                .font(PerryTheme.Scale.body)
                            Text(runtime.status)
                                .settingNote()
                            if runtime.authenticatesInApp, runtime.authentication != .authenticated {
                                Text("Sign in with ChatGPT under Brain above.")
                                    .settingNote()
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .settingsRowPadding()
                    .accessibilityElement(children: .combine)
                    SettingsDivider()
                }
                SettingsRow(title: "Status") {
                    Button("Check again") { refreshCount += 1 }
                }
            }
            SettingsCard(title: "Screen control", footer: "Lets Perry see your screen and act in other apps.") {
                Text(screenStatus)
                    .font(PerryTheme.Scale.body)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsRowPadding()
                    .accessibilityLabel("Screen control status")
                    .accessibilityValue(screenStatus)
            }
            if hasCommands {
                SettingsAdvanced {
                    SettingsCard {
                        ForEach(setup.records.filter { $0.signInCommand != nil || $0.signOutCommand != nil }) { runtime in
                            SettingsRow(title: runtime.name) {
                                if let command = runtime.signInCommand {
                                    Button(copiedCommand == command.shellText ? "Copied" : "Copy sign-in") { copy(command) }
                                }
                                if let command = runtime.signOutCommand {
                                    Button(copiedCommand == command.shellText ? "Copied" : "Copy sign-out") { copy(command) }
                                }
                            }
                            SettingsDivider()
                        }
                        SettingsRow(title: "Run the copied command in Terminal, then choose Check again.") {
                            Button("Open Terminal") {
                                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration())
                            }
                        }
                    }
                }
            }
        }
        .task(id: refreshCount) {
            async let latestSetup = controller.subsystems.runtimes.currentSetup()
            async let latestScreenStatus = controller.subsystems.probe.screenHealth().summary
            let (newSetup, newScreenStatus) = await (latestSetup, latestScreenStatus)
            guard !Task.isCancelled else { return }
            setup = newSetup
            screenStatus = newScreenStatus
        }
        .settingsErrorDialog($error)
    }

    private var hasCommands: Bool {
        setup.records.contains { $0.signInCommand != nil || $0.signOutCommand != nil }
    }

    private func copy(_ command: RuntimeAuthenticationCommand) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(command.shellText, forType: .string) else {
            error = "I couldn’t copy the sign-in command. Open Terminal and run it yourself."
            return
        }
        copiedCommand = command.shellText
    }
}
