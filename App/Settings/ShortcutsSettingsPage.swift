import PerryCore
import SwiftUI

struct ShortcutsSettingsPage: View {
    let controller: AppController
    @AppStorage(PerryPreferences.$wakeWordEnabled.key) private var wakeWordEnabled = false
    @State private var hotkeys: [SymbolicHotkey] = []
    @State private var captures = Dictionary(uniqueKeysWithValues: ShortcutRole.allCases.map {
        ($0, $0.capture(gestures: ShortcutRole.current, hotkeys: []))
    })
    @State private var error: String?

    var body: some View {
        SettingsScroll {
            SettingsCard {
                ForEach(ShortcutRole.allCases) { role in
                    if role != .talk {
                        SettingsDivider()
                    }
                    ShortcutRecorder(
                        title: role.title,
                        capture: binding(for: role),
                        presets: role.presets,
                        presetLabel: role.label(for:),
                        onSave: { save(role, $0) }
                    )
                    .settingsRowPadding()
                    if role == .talk {
                        SettingsDivider()
                        ShortcutCheckRow(check: controller.shortcutCheck, gesture: captures[.talk]?.saved ?? .defaultTalk) {
                            controller.shortcutCheck.begin(captureMode: controller.modifierHoldMonitor.captureMode)
                            if controller.shortcutCheck.result == .needsInputMonitoring {
                                Task { await PermissionGuideCoordinator.guide(.inputMonitoring) }
                            }
                        }
                        .settingsRowPadding()
                    }
                }
            }
            SettingsCard(title: "Wake word") {
                Toggle(isOn: $wakeWordEnabled) {
                    Text("Say “hey Perry” to wake")
                    Text("Listens on this Mac for the phrase and keeps no transcript.").settingNote()
                }
                .settingsRowPadding()
                .onChange(of: wakeWordEnabled) { _, value in
                    controller.voice.updateWakeWordEnabled(value)
                }
            }
        }
        .onAppear {
            hotkeys = SymbolicHotkeys.load()
            refreshConflicts()
        }
        .settingsErrorDialog($error)
    }

    private func binding(for role: ShortcutRole) -> Binding<ShortcutCapture> {
        Binding(
            get: { captures[role] ?? role.capture(gestures: ShortcutRole.current, hotkeys: hotkeys) },
            set: { captures[role] = $0 }
        )
    }

    private func save(_ role: ShortcutRole, _ gesture: Gesture) {
        switch role {
        case .wake:
            do {
                try controller.updateWakeShortcut(gesture)
            } catch {
                captures[.wake] = ShortcutRole.wake.capture(gestures: ShortcutRole.current, hotkeys: hotkeys)
                self.error = error.localizedDescription
            }
        case .dictate:
            role.saved = gesture
            controller.voice.updatePushToTalkGesture(gesture)
        case .talk, .type:
            role.saved = gesture
        }
        refreshConflicts()
    }

    private func refreshConflicts() {
        let gestures = ShortcutRole.current
        for role in ShortcutRole.allCases {
            captures[role]?.perryOwners = role.owners(gestures: gestures)
            captures[role]?.systemHotkeys = hotkeys
        }
    }
}
