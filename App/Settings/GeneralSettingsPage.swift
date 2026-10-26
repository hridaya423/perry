import AppKit
import SwiftUI

struct GeneralSettingsPage: View {
    @State private var opensAtLogin = LoginItem.isEnabled
    @State private var error: String?

    var body: some View {
        SettingsScroll {
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
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            opensAtLogin = LoginItem.isEnabled
        }
        .settingsErrorDialog($error)
    }
}
