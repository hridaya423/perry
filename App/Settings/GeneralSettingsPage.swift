import AppKit
import SwiftUI

struct GeneralSettingsPage: View {
    let controller: AppController
    @State private var opensAtLogin = LoginItem.isEnabled
    @AppStorage(PerryPreferences.$notchStatusEnabled.key) private var notchEyes = true
    @AppStorage(PerryPreferences.$notchHoverPeek.key) private var hoverPeek = true
    @State private var updateNote: String?
    @State private var error: String?

    var body: some View {
        SettingsScroll {
            SettingsCard(title: "Notch") {
                Toggle(isOn: Binding(get: { notchEyes }, set: { controller.setNotchEyes($0) })) {
                    Text("Show Perry in the notch")
                    Text("Perry’s eyes rest beside the camera and show when Perry is busy.").settingNote()
                }
                .settingsRowPadding()
                SettingsDivider()
                Toggle(isOn: $hoverPeek) {
                    Text("Quick peek on hover")
                    Text("Point at the notch to see what Perry is doing.").settingNote()
                }
                .settingsRowPadding()
            }
            SettingsCard(title: "Startup", footer: LoginItem.needsApproval ? "Approve Perry in System Settings › General › Login Items." : nil) {
                Toggle("Open Perry when you log in", isOn: $opensAtLogin)
                    .settingsRowPadding()
                    .onChange(of: opensAtLogin) { _, value in
                        guard value != LoginItem.isEnabled else { return }
                        do {
                            try LoginItem.setEnabled(value)
                        } catch {
                            opensAtLogin = LoginItem.isEnabled
                            self.error = error.localizedDescription
                        }
                    }
                SettingsDivider()
                SettingsRow(title: "Replay the intro", detail: "Walk through setup again. Your settings stay as they are.") {
                    Button("Replay") { controller.runOnboarding(force: true) }
                }
            }
            SettingsCard(title: "Perry \(Self.version)", footer: updateNote) {
                SettingsRow(title: "Updates") {
                    Button("Check for Updates") {
                        if case .unavailable = controller.updateNoticeController.availability {
                            updateNote = "This build can’t check for updates. Download the latest Perry from its website."
                        } else {
                            controller.updateNoticeController.checkForUpdates()
                        }
                    }
                }
                SettingsDivider()
                SettingsRow(title: "What’s New") {
                    Button("Show") { controller.showWhatsNew() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            opensAtLogin = LoginItem.isEnabled
        }
        .settingsErrorDialog($error)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}
