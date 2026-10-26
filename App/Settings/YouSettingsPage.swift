import PerryGuide
import SwiftUI

struct YouSettingsPage: View {
    let controller: AppController
    @State private var memoryEnabled = false
    @State private var categories: [MemoryRecord.Category: Bool] = MemoryRecord.Category.allCases.reduce(into: [:]) { $0[$1] = true }

    var body: some View {
        SettingsScroll {
            SettingsCard(title: "Memory", footer: "Stored on this Mac, never synced. You can read or erase it any time.") {
                Toggle("Remember context between conversations", isOn: $memoryEnabled)
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
        }
        .task {
            let configuration = await controller.currentMemoryConfiguration()
            memoryEnabled = configuration.enabled
            categories = configuration.categoryToggles
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
