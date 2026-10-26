import PerryGuide
import SwiftUI

struct YouSettingsPage: View {
    let controller: AppController
    @State private var memoryEnabled = false
    @State private var categories: [MemoryRecord.Category: Bool] = MemoryRecord.Category.allCases.reduce(into: [:]) { $0[$1] = true }
    @State private var records: [MemoryRecord] = []
    @State private var confirmsErase = false
    @State private var error: String?

    var body: some View {
        SettingsScroll {
            SettingsCard(title: "Keep notes", footer: "Stored on this Mac, never synced.") {
                Toggle("Remember between conversations", isOn: $memoryEnabled)
                    .settingsRowPadding()
                    .onChange(of: memoryEnabled) { _, value in
                        Task { await controller.setMemoryEnabled(value) }
                    }
                ForEach(MemoryRecord.Category.allCases, id: \.self) { category in
                    SettingsDivider()
                    Toggle(Self.title(category), isOn: Binding(
                        get: { categories[category] ?? true },
                        set: { value in
                            categories[category] = value
                            Task { await controller.setMemoryCategoryEnabled(category, enabled: value) }
                        }
                    ))
                    .settingsRowPadding()
                    .disabled(!memoryEnabled)
                }
            }
            SettingsCard(title: "What Perry remembers") {
                if records.isEmpty {
                    Text(memoryEnabled ? "Nothing yet. Perry adds notes as you use it." : "Nothing. Memory is off.")
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .settingsRowPadding()
                }
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { SettingsDivider() }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.summary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(Self.title(record.category)) · \(record.createdAt.formatted(.relative(presentation: .named)))")
                                .settingNote()
                        }
                        Spacer(minLength: 8)
                        Button {
                            forget(record)
                        } label: {
                            Image(systemName: "xmark")
                                .font(PerryTheme.Icon.utility)
                                .imageScale(.small)
                                .foregroundStyle(PerryTheme.Colors.icon)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Forget this")
                        .accessibilityLabel("Forget: \(record.summary)")
                    }
                    .settingsRowPadding()
                }
            }
            SettingsCard {
                SettingsRow(title: "Erase memory", detail: "Every note above and your profile. Settings, history and connections stay.") {
                    Button("Erase all…", role: .destructive) { confirmsErase = true }
                        .disabled(records.isEmpty && !memoryEnabled)
                }
            }
        }
        .task(reload)
        .notchDialog(
            "Erase memory?",
            isPresented: $confirmsErase,
            message: "I’ll forget every note and your profile. This can’t be undone."
        ) {
            [NotchDialog.Action("Erase memory", role: .destructive) {
                Task {
                    if await controller.eraseMemory() {
                        await reload()
                    } else {
                        error = "I couldn’t erase my memory. Try again, or use Erase all Perry data in Privacy."
                    }
                }
            }]
        }
        .settingsErrorDialog($error)
    }

    @Sendable
    private func reload() async {
        let configuration = await controller.currentMemoryConfiguration()
        memoryEnabled = configuration.enabled
        categories = configuration.categoryToggles
        records = await controller.memories()
    }

    private func forget(_ record: MemoryRecord) {
        Task {
            if await controller.forgetMemory(record.id) {
                records.removeAll { $0.id == record.id }
            } else {
                error = "I couldn’t forget that note. Try again."
            }
        }
    }

    private static func title(_ category: MemoryRecord.Category) -> String {
        switch category {
        case .appWorkflow: "App workflows"
        case .preference: "Preferences"
        case .pastSession: "Past conversations"
        }
    }
}
