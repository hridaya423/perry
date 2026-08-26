import SwiftUI
import PerryCore
import PerryGuide
import PerryRuntimes

/// The real settings surface: runtime status, wake word, memory, voice,
/// data. Backed by the same stores AppController owns; no shadow state.
struct SettingsView: View {
    @AppStorage("perry.wakeWord.enabled") private var wakeWordEnabled = false
    @State private var memoryEnabled = true
    @State private var runtimeStatus = "checking…"
    @State private var voiceName: String?

    var body: some View {
        TabView {
            Form {
                Section("Agent brain") {
                    Text(runtimeStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Section("Invocation") {
                    Toggle("Say \"hey perry\" to wake", isOn: $wakeWordEnabled)
                    Text("Off by default. When on, listening starts only after the phrase.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "switch.2") }
            .onAppear { refreshRuntimeStatus() }

            Form {
                Section("Memory") {
                    Toggle("Remember context between sessions", isOn: $memoryEnabled)
                        .onChange(of: memoryEnabled) { _, newValue in
                            Task {
                                await MemoryStore.sharedForSettings.setConfiguration(
                                    MemoryConfiguration(enabled: newValue)
                                )
                            }
                        }
                    Text("Stored locally, inspectable, never synced.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Wipe memory & activity logs", role: .destructive) {
                        NotificationCenter.default.post(name: .perryWipeDataRequested, object: nil)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Memory & Data", systemImage: "brain") }
            .onAppear { refreshMemory() }

            Form {
                Section("Voice out") {
                    LabeledContent("Voice", value: voiceName ?? "System default")
                    if let next = Self.voiceUpgradeHint(voiceName) {
                        Text(next)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Voice", systemImage: "waveform") }
            .onAppear { voiceName = AppController.speakingVoiceDisplayName() }
        }
        .frame(width: 480, height: 320)
    }

    private func refreshRuntimeStatus() {
        Task {
            let codexInstalled = (try? CodexRuntime.bundledLocator()) != nil
            let claudeInstalled = (try? CLIRuntime.locateExecutable()) != nil
            await MainActor.run {
                switch (codexInstalled, claudeInstalled) {
                case (true, _): runtimeStatus = "Perry's own agent brain is ready."
                case (false, true): runtimeStatus = "Using your installed Claude Code CLI."
                case (false, false): runtimeStatus = "No runtime found yet; first task will offer setup."
                }
            }
        }
    }

    private func refreshMemory() {
        Task {
            let config = await MemoryStore.sharedForSettings.currentConfiguration()
            await MainActor.run { memoryEnabled = config.enabled }
        }
    }

    static func voiceUpgradeHint(_ current: String?) -> String? {
        guard let current, !current.lowercased().contains("enhanced"), !current.lowercased().contains("premium") else { return nil }
        return "For a warmer voice: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices, download an enhanced English voice."
    }
}

extension Notification.Name {
    static let perryWipeDataRequested = Notification.Name("perry.wipeDataRequested")
}

extension MemoryStore {
    static var sharedForSettings: MemoryStore { MemoryStoreShared.shared }
}

/// MemoryStore has no process-wide instance in tests; the Settings surface
/// needs one owner for reads and wipes.
enum MemoryStoreShared {
    static let shared = MemoryStore(storageDirectory: AppControllerSupport.supportDirectory)
}

enum AppControllerSupport {
    static let supportDirectory: URL? = {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Perry", isDirectory: true)
    }()
}
