import AppKit
import PerryGuide
import SwiftUI

struct AppsSettingsPage: View {
    let controller: AppController
    @State private var skills: [AppSkill] = []
    @State private var skillEnabled: [String: Bool] = [:]
    @State private var error: String?

    var body: some View {
        SettingsScroll {
            SettingsCard(title: "Apps", footer: "Connections stay in this Mac’s Keychain. Each app starts read-only. Perry asks before it changes anything.") {
                SystemCalendarRow()
                    .settingsRowPadding()
                SettingsDivider()
                ForEach(RemoteIntegrationDefinition.catalog) { definition in
                    IntegrationRow(definition: definition, connections: controller.subsystems.integrationConnections)
                        .settingsRowPadding()
                    if definition.id != RemoteIntegrationDefinition.catalog.last?.id {
                        SettingsDivider()
                    }
                }
            }
            CustomConnectorsSection(connectors: controller.subsystems.customConnectors)
            SettingsCard(title: "App skills", footer: "Skills are notes Perry reads when you use the matching app.") {
                SettingsRow(title: "Skills folder") {
                    Button("Open", action: openSkillsFolder)
                }
                if skills.isEmpty {
                    SettingsDivider()
                    Text("No app skills are installed yet.")
                        .font(PerryTheme.Scale.body)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .settingsRowPadding()
                }
            }
            if !skills.isEmpty {
                SettingsAdvanced(title: "Installed skills (\(skills.count))") {
                    SettingsCard {
                        skillList
                    }
                }
            }
        }
        .onAppear(perform: refreshSkills)
        .settingsErrorDialog($error)
    }

    @ViewBuilder
    private var skillList: some View {
        ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
            if index > 0 { SettingsDivider() }
            Toggle(isOn: Binding(
                get: { skillEnabled[skill.id] ?? true },
                set: { value in
                    skillEnabled[skill.id] = value
                    AppSkillLibrary(storageDirectory: AppController.supportDirectory).setEnabled(value, for: skill.bundleID)
                }
            )) {
                Text(skill.displayName)
                Text("\(skill.bundleID) · \(skill.source.rawValue)")
                    .font(PerryTheme.Scale.monoSmall)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
            }
            .settingsRowPadding()
            .accessibilityLabel("\(skill.displayName), \(skill.source.rawValue) skill")
        }
    }

    private func refreshSkills() {
        let library = AppSkillLibrary(storageDirectory: AppController.supportDirectory)
        skills = library.allSkills()
        skillEnabled = skills.reduce(into: [:]) { $0[$1.id] = library.isEnabled($1.bundleID) }
    }

    private func openSkillsFolder() {
        guard let directory = AppController.supportDirectory?.appendingPathComponent("AppSkills", isDirectory: true) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard NSWorkspace.shared.open(directory) else {
                error = "Perry couldn’t open the skills folder."
                return
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
