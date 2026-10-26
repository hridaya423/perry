import AppKit
import PerryBrain
import PerryGuide
import SwiftUI

struct YouSettingsPage: View {
    let controller: AppController
    @State private var memoryEnabled = false
    @State private var categories: [MemoryRecord.Category: Bool] = MemoryRecord.Category.allCases.reduce(into: [:]) { $0[$1] = true }
    @State private var records: [MemoryRecord] = []
    @State private var confirmsErase = false
    @State private var error: String?
    @State private var profile: [String: String] = [:]
    @State private var pasted = ""
    @State private var copied = false
    @State private var importing = false
    @State private var importResult: String?

    static let profileFields = ["Name", "Work", "Apps", "Learning goal", "Answer style"]

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
            SettingsCard(title: "Profile", footer: "Perry reads this before every answer.") {
                ForEach(Array(Self.profileFields.enumerated()), id: \.element) { index, field in
                    if index > 0 { SettingsDivider() }
                    HStack(spacing: 12) {
                        Text(field)
                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                            .frame(width: 110, alignment: .leading)
                        TextField(field, text: Binding(get: { profile[field] ?? "" }, set: { profile[field] = $0 }), prompt: Text("Not set").foregroundStyle(PerryTheme.Colors.textTertiary))
                            .textFieldStyle(.plain)
                            .onSubmit { saveProfile(field) }
                    }
                    .settingsRowPadding()
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
                            Text(Self.note(record))
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
                        .buttonStyle(.pressable)
                        .help("Forget this")
                        .accessibilityLabel("Forget: \(record.summary)")
                    }
                    .settingsRowPadding()
                }
            }
            SettingsCard(title: "Bring notes from ChatGPT or Claude", footer: importResult) {
                HStack(spacing: 12) {
                    Text("Ask: \u{201C}\(MemoryExtraction.importRequest)\u{201D}")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(MemoryExtraction.importRequest, forType: .string)
                        copied = true
                    }
                }
                .settingsRowPadding()
                SettingsDivider()
                TextEditor(text: $pasted)
                    .scrollContentBackground(.hidden)
                    .frame(height: 64)
                    .overlay(alignment: .topLeading) {
                        if pasted.isEmpty {
                            Text("Paste the answer").foregroundStyle(PerryTheme.Colors.textTertiary)
                                .padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    .settingsRowPadding()
                SettingsDivider()
                SettingsRow(title: "Add to memory", detail: "Perry keeps the facts about you and drops the rest.") {
                    Button(importing ? "Reading…" : "Add notes") { importNotes() }
                        .disabled(importing || !canImport || pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        records = await controller.memories().sorted { Self.standing($0) && !Self.standing($1) }
        profile = Dictionary(uniqueKeysWithValues: Self.profileFields.map { ($0, controller.memoryFiles?.profileField($0) ?? "") })
    }

    private var canImport: Bool {
        controller.brain.hasSavedChoice || controller.brain.onDeviceRouteAvailable
    }

    private func saveProfile(_ field: String) {
        do {
            try controller.memoryFiles?.setProfileField(field, profile[field] ?? "")
        } catch {
            self.error = "I couldn’t save your \(field.lowercased()). Try again."
        }
    }

    private func importNotes() {
        importing = true
        importResult = nil
        Task {
            defer { importing = false }
            let known = Set(records.map { $0.summary.lowercased() })
            let reply = try? await controller.brain.completeOnDevice(MemoryExtraction.importPrompt(pasted))
            let facts = (reply.map(MemoryExtraction.decodeImport) ?? []).filter { !known.contains($0.text.lowercased()) }
            guard reply != nil else {
                error = "I couldn’t read those notes. Check the brain in Brain settings, then try again."
                return
            }
            await controller.saveImportedFacts(facts)
            pasted = ""
            importResult = facts.isEmpty ? "No new facts about you in that answer." : "Added \(facts.count) \(facts.count == 1 ? "note" : "notes")."
            await reload()
        }
    }

    private static func standing(_ record: MemoryRecord) -> Bool {
        record.category == .aboutYou && record.expiresAt == nil
    }

    private static func note(_ record: MemoryRecord) -> String {
        let when = record.expiresAt.map { "Until \($0.formatted(.dateTime.month(.abbreviated).day()))" }
            ?? record.createdAt.formatted(.relative(presentation: .named))
        return "\(title(record.category)) · \(when)"
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
        case .aboutYou: "About you"
        case .appWorkflow: "App workflows"
        case .preference: "Preferences"
        case .pastSession: "Past conversations"
        }
    }
}
