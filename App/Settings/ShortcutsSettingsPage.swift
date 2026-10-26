import PerryCore
import SwiftUI

struct ShortcutsSettingsPage: View {
    let controller: AppController
    @AppStorage(PerryPreferences.$wakeWordEnabled.key) private var wakeWordEnabled = false
    @AppStorage(PerryPreferences.$wakeShortcut.key) private var wakeShortcut = WakeShortcut.optionCommandP
    @AppStorage(PerryPreferences.$pttShortcut.key) private var pttShortcut = PushToTalkShortcut.functionHold
    @State private var talkCapture = ShortcutCapture(saved: PerryPreferences.talkGesture, defaultGesture: .defaultTalk)
    @State private var pttSystemConflict = false
    @State private var error: String?

    var body: some View {
        SettingsScroll {
            SettingsCard(footer: pttSystemConflict ? "macOS already uses the dictation shortcut, so it may not reach Perry. Pick another, or change it in System Settings › Keyboard › Keyboard Shortcuts." : nil) {
                ShortcutRecorder(
                    title: "Talk",
                    capture: $talkCapture,
                    presets: [.hold([.function]), .hold([.option, .rightOption]), .defaultTalk],
                    onSave: { PerryPreferences.talkGesture = $0 }
                )
                .settingsRowPadding()
                SettingsDivider()
                ShortcutCheckRow(check: controller.shortcutCheck, gesture: talkCapture.saved) {
                    controller.shortcutCheck.begin(captureMode: controller.modifierHoldMonitor.captureMode)
                    if controller.shortcutCheck.result == .needsInputMonitoring {
                        Task { await PermissionGuideCoordinator.guide(.inputMonitoring) }
                    }
                }
                .settingsRowPadding()
                SettingsDivider()
                SettingsPicker(title: "Dictate", detail: "Hold it in any app to type by voice. Double-tap Caps Lock for hands-free.", selection: $pttShortcut) {
                    ForEach(PushToTalkShortcut.allCases) { shortcut in
                        Text(shortcut.title).tag(shortcut)
                    }
                }
                .onChange(of: pttShortcut) { _, shortcut in
                    controller.voice.updatePushToTalkShortcut(shortcut)
                    refreshConflicts()
                }
                SettingsDivider()
                SettingsPicker(title: "Wake shortcut", selection: $wakeShortcut) {
                    ForEach(WakeShortcut.allCases) { shortcut in
                        Text(shortcut.title).tag(shortcut)
                    }
                }
                .onChange(of: wakeShortcut) { _, shortcut in
                    do {
                        try controller.updateWakeShortcut(shortcut)
                    } catch {
                        wakeShortcut = PerryPreferences.wakeShortcut
                        self.error = error.localizedDescription
                    }
                    refreshConflicts()
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
        .onAppear(perform: refreshConflicts)
        .settingsErrorDialog($error)
    }

    private func refreshConflicts() {
        let hotkeys = SymbolicHotkeys.load()
        talkCapture.allowsChords = false
        talkCapture.perryOwners = [
            .init(gesture: .doubleTap([.control]), name: "typing gesture"),
            .init(gesture: wakeShortcut.gesture, name: "wake shortcut"),
        ] + (pttShortcut.gesture.map { [.init(gesture: $0, name: "dictation shortcut")] } ?? [])
        talkCapture.systemHotkeys = hotkeys
        if let chord = pttShortcut.symbolicChord {
            pttSystemConflict = SymbolicHotkeys.conflicts(keyCode: chord.keyCode, modifiers: chord.modifiers, in: hotkeys)
        } else {
            pttSystemConflict = false
        }
    }
}
