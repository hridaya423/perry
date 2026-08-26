import SwiftUI
import PerryOverlay
import PerryGuide

@main
struct PerryApp: App {
    @NSApplicationDelegateAdaptor(AppController.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
