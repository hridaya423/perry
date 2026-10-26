import AppKit
import PerryRuntimes
import SwiftUI

struct BrainSettingsPage: View {
    let controller: AppController
    @AppStorage(PerryPreferences.$cuaDriverPath.key) private var cuaDriverPath = ""
    @StateObject private var runtimeSettings: RuntimeSettingsState
    @State private var copiedCommand: String?
    @State private var error: String?

    init(controller: AppController) {
        self.controller = controller
        _runtimeSettings = StateObject(wrappedValue: RuntimeSettingsState {
            async let setup = controller.runtimes.currentSetup()
            async let driverStatus = controller.probe.cuaHealth().summary
            return await RuntimeSettingsState.Status(setup: setup, cuaStatus: driverStatus)
        })
    }

    private var setup: RuntimeSetupSnapshot { runtimeSettings.status.setup }

    var body: some View {
        SettingsScroll {
            SettingsCard(title: "Conversation model") {
                VStack(alignment: .leading, spacing: 10) {
                    BrainModelSettingsView(brain: controller.brain)
                }
                .settingsRowPadding()
            }
            SettingsCard(title: "Agents", footer: setup.records.contains(where: { $0.status == setup.summary }) ? nil : setup.summary) {
                ForEach(setup.records) { runtime in
                    HStack(alignment: .firstTextBaseline, spacing: PerryTheme.Spacing.inline) {
                        Image(systemName: runtime.isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(runtime.isReady ? PerryTheme.Colors.success : PerryTheme.Colors.textSecondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(runtime.name)
                                .font(PerryTheme.Scale.body)
                            Text(runtime.status)
                                .settingNote()
                            if runtime.authenticatesInApp, runtime.authentication != .authenticated {
                                Text("Sign in with ChatGPT from Conversation model above.")
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
                    Button("Check again") { runtimeSettings.refresh() }
                }
            }
            SettingsCard(title: "Screen helper", footer: "The screen helper (Cua Driver) lets Perry see the screen and act in other apps.") {
                Text(runtimeSettings.status.cuaStatus)
                    .font(PerryTheme.Scale.body)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsRowPadding()
                    .accessibilityLabel("Computer-use driver status")
                    .accessibilityValue(runtimeSettings.status.cuaStatus)
            }
            SettingsAdvanced {
                SettingsCard {
                    if hasCommands {
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
                        SettingsDivider()
                    }
                    HStack(spacing: PerryTheme.Spacing.inline) {
                        TextField("Cua Driver path (optional)", text: $cuaDriverPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            controller.reloadCuaDriverConfiguration()
                            runtimeSettings.refresh()
                        }
                    }
                    .settingsRowPadding()
                }
            }
        }
        .onAppear { runtimeSettings.refresh() }
        .onDisappear { runtimeSettings.cancel() }
        .settingsErrorDialog($error)
    }

    private var hasCommands: Bool {
        setup.records.contains { $0.signInCommand != nil || $0.signOutCommand != nil }
    }

    private func copy(_ command: RuntimeAuthenticationCommand) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(command.shellText, forType: .string) else {
            error = "Perry could not copy the authentication command. Open Terminal and run the runtime’s official sign-in command manually."
            return
        }
        copiedCommand = command.shellText
    }
}
