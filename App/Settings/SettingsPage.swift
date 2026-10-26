import PerryBrain
import PerryCore
import PerryGuide
import SwiftUI

enum SettingsPage: String, CaseIterable {
    case general
    case you
    case voice
    case dictation
    case shortcuts
    case brain
    case apps
    case privacy

    init(stored: String) {
        switch stored {
        case "runtimes": self = .brain
        case "integrations": self = .apps
        case "memory": self = .you
        case "safety": self = .privacy
        default: self = SettingsPage(rawValue: stored) ?? .general
        }
    }

    init(perryPage page: String?) {
        switch page {
        case "perrys": self = .brain
        default: self = SettingsPage(stored: page ?? "")
        }
    }

    var title: String {
        switch self {
        case .general: "General"
        case .you: "Memory"
        case .voice: "Voice"
        case .dictation: "Dictation"
        case .shortcuts: "Shortcuts"
        case .brain: "Brain"
        case .apps: "Apps"
        case .privacy: "Privacy"
        }
    }

    var sidebarTitle: String {
        self == .privacy ? "Privacy" : title
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .you: "person.crop.circle.fill"
        case .voice: "waveform"
        case .dictation: "mic.fill"
        case .shortcuts: "command"
        case .brain: "sparkles"
        case .apps: "square.grid.2x2.fill"
        case .privacy: "lock.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: TileTint.blue
        case .you: TileTint.peach
        case .voice: TileTint.pink
        case .dictation: TileTint.teal
        case .shortcuts: TileTint.blue
        case .brain: TileTint.lilac
        case .apps: TileTint.pink
        case .privacy: TileTint.teal
        }
    }

    static let groups: [(title: String?, pages: [SettingsPage])] = [
        (nil, [.general, .you]),
        ("Talk", [.voice, .dictation, .shortcuts]),
        ("Connect", [.brain, .apps]),
        ("Trust", [.privacy]),
    ]
}

struct SettingsView: View {
    let controller: AppController
    @AppStorage(PerryPreferences.$settingsTab.key) private var stored = SettingsPage.general.rawValue

    var body: some View {
        Group {
            switch SettingsPage(stored: stored) {
            case .general: GeneralSettingsPage(controller: controller)
            case .you: YouSettingsPage(controller: controller)
            case .voice: VoiceSettingsPage(controller: controller)
            case .dictation: DictationSettingsPage(controller: controller)
            case .shortcuts: ShortcutsSettingsPage(controller: controller)
            case .brain: BrainSettingsPage(controller: controller)
            case .apps: AppsSettingsPage(controller: controller)
            case .privacy: PrivacySettingsPage(controller: controller)
            }
        }
        .id(stored)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PerryTheme.Colors.canvas)
        .tint(PerryTheme.Colors.accent)
        .buttonStyle(InkButtonStyle(.secondary))
        .toggleStyle(InkSwitchStyle())
        .controlSize(.small)
        .font(PerryTheme.Scale.body)
        .foregroundStyle(PerryTheme.Colors.text)
    }
}

struct SettingsSidebar: View {
    let onBack: () -> Void
    @AppStorage(PerryPreferences.$settingsTab.key) private var stored = SettingsPage.general.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .imageScale(.small)
                    Text("Back")
                        .font(PerryTheme.Scale.body)
                }
                .foregroundStyle(PerryTheme.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .help("Back (⌘[)")
            .padding(.horizontal, 6)
            .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(SettingsPage.groups.indices, id: \.self) { index in
                        let group = SettingsPage.groups[index]
                        VStack(alignment: .leading, spacing: 1) {
                            if let title = group.title {
                                Text(title.uppercased())
                                    .font(PerryTheme.Scale.section)
                                    .kerning(0.4)
                                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                                    .padding(.horizontal, 8)
                                    .padding(.bottom, 2)
                            }
                            ForEach(group.pages, id: \.self) { page in
                                link(page)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, NotchLayout.bottomInset)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
    }

    private func link(_ page: SettingsPage) -> some View {
        let selected = SettingsPage(stored: stored) == page
        return Button {
            stored = page.rawValue
        } label: {
            HStack(spacing: 10) {
                SymbolTile(systemImage: page.systemImage, tint: page.tint)
                Text(page.sidebarTitle)
                    .font(PerryTheme.Scale.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: PerryTheme.Radius.control, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.1 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: PerryTheme.Radius.control, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SettingsScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }
}

struct SettingsCard<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(PerryTheme.Scale.section)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PerryTheme.Radius.card, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
            )
            if let footer {
                Text(footer)
                    .settingNote()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(PerryTheme.Colors.subtleSeparator)
            .frame(height: 1)
            .padding(.leading, PerryTheme.Spacing.panelInset)
    }
}

struct SettingsRow<Accessory: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(PerryTheme.Scale.body)
                if let detail {
                    Text(detail)
                        .settingNote()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .settingsRowPadding()
    }
}

struct SettingsPicker<Value: Hashable, Options: View>: View {
    let title: String
    var detail: String?
    @Binding var selection: Value
    @ViewBuilder let options: Options

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            Picker(title, selection: $selection) { options }
                .labelsHidden()
                .fixedSize()
        }
    }
}

struct SettingsAdvanced<Content: View>: View {
    var title = "Advanced"
    @ViewBuilder let content: Content
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : PerryTheme.Motion.snap) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title)
                        .font(PerryTheme.Scale.section)
                }
                .foregroundStyle(PerryTheme.Colors.textSecondary)
                .padding(.leading, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                content
            }
        }
    }
}

extension View {
    func settingsRowPadding() -> some View {
        padding(.horizontal, PerryTheme.Spacing.panelInset).padding(.vertical, PerryTheme.Spacing.section)
    }

    func settingsErrorDialog(_ error: Binding<String?>) -> some View {
        notchDialog(
            "Perry couldn’t save that setting",
            item: error,
            message: error.wrappedValue ?? "Perry couldn’t do that. Try again.",
            cancelTitle: "Close"
        ) { _ in [] }
    }
}

extension View {
    func settingNote() -> some View {
        font(PerryTheme.Typography.note)
            .foregroundStyle(PerryTheme.Colors.textSecondary)
    }
}

extension Notification.Name {
    static let perryWipeDataRequested = Notification.Name("perry.wipeDataRequested")
}

extension AppController {
    func openSettings(_ page: SettingsPage) {
        PerryPreferences.settingsTab = page.rawValue
        showSettings()
    }

    func setNotchEyes(_ enabled: Bool) {
        notchStatus.setEnabled(enabled)
        if enabled {
            notchStatus.update(
                isRecording: routineLibrary.isRecording,
                backgroundCount: lastBackgroundCount,
                awaitingApproval: lastAwaitingApprovalCount
            )
        }
        notchPresence.screenLayoutChanged()
    }

    var memoryFiles: MemoryFiles? {
        storageDirectory.map { MemoryFiles(directory: $0.appendingPathComponent("memory", isDirectory: true)) }
    }

    func memories() async -> [MemoryRecord] {
        await memoryStore.snapshot().sorted { $0.createdAt > $1.createdAt }
    }

    func forgetMemory(_ id: UUID) async -> Bool {
        guard !maintenance.isErasureInProgress else { return false }
        return await memoryStore.forget(id)
    }

    func eraseMemory() async -> Bool {
        guard !maintenance.isErasureInProgress, await memoryStore.wipe() else { return false }
        guard let memory = storageDirectory?.appendingPathComponent("memory", isDirectory: true) else { return true }
        for name in ["PROFILE.md", "CONTEXT.md"] {
            try? FileManager.default.removeItem(at: memory.appendingPathComponent(name))
        }
        return true
    }

    func currentMemoryConfiguration() async -> MemoryConfiguration {
        await memoryStore.currentConfiguration()
    }

    func setMemoryEnabled(_ enabled: Bool) async {
        guard !maintenance.isErasureInProgress else { return }
        let current = await memoryStore.currentConfiguration()
        await memoryStore.setConfiguration(
            MemoryConfiguration(enabled: enabled, categoryToggles: current.categoryToggles)
        )
    }

    func setMemoryCategoryEnabled(_ category: MemoryRecord.Category, enabled: Bool) async {
        guard !maintenance.isErasureInProgress else { return }
        let current = await memoryStore.currentConfiguration()
        var toggles = current.categoryToggles
        toggles[category] = enabled
        await memoryStore.setConfiguration(
            MemoryConfiguration(enabled: current.enabled, categoryToggles: toggles)
        )
    }
}
