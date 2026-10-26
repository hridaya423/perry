import PerryBrain
import SwiftUI

struct LocalBrainView: View {
    @ObservedObject var brain: BrainController
    @ObservedObject var local: LocalBrain
    let profile: MachineProfile
    var bench: LocalBenchmark.Record?
    @AppStorage(PerryPreferences.$localMemoryBudget.key) private var budgetRaw = LocalBrain.Budget.nothing.rawValue
    @AppStorage(PerryPreferences.$localCloudFallback.key) private var fallbackRaw = LocalBrain.CloudFallback.ask.rawValue

    static func machineLine(_ profile: MachineProfile) -> String {
        let memory = Int((Double(profile.memoryBytes) / Double(1 << 30)).rounded())
        guard profile.chip.generation > 0 else { return "This Mac: \(memory) GB" }
        let kind = switch profile.chip.kind {
        case .base: ""
        case .pro: " Pro"
        case .max: " Max"
        case .ultra: " Ultra"
        }
        return "This Mac: M\(profile.chip.generation)\(kind), \(memory) GB"
    }

    static func isSmall(_ profile: MachineProfile) -> Bool {
        profile.memoryBytes <= 8 << 30
    }

    private var recommendation: Recommendation {
        ModelFit.recommend(profile: profile, budget: (LocalBrain.Budget(rawValue: budgetRaw) ?? .nothing).memoryBudget)
    }

    var body: some View {
        let rung = recommendation.interactive
        SettingsCard(title: Self.machineLine(profile), footer: footer(rung)) {
            setupRow(rung)
            if profile.appleIntelligenceAvailable {
                SettingsDivider()
                SettingsRow(title: "Apple Intelligence", detail: "Answers in text. Reads windows as text. Can’t click or type.") {
                    StatusMark(.ok)
                        .accessibilityLabel("Available")
                }
            }
        }
        SettingsCard(title: "Keep the brain loaded", footer: "Perry also unloads the brain when macOS runs low on memory.") {
            ForEach(Array(LocalBrain.Budget.allCases.enumerated()), id: \.element) { index, budget in
                if index > 0 { SettingsDivider() }
                choiceRow(budget.title, detail: detail(budget), selected: budgetRaw == budget.rawValue) { budgetRaw = budget.rawValue }
            }
        }
        SettingsCard(title: "When this Mac’s brain can’t do a task") {
            ForEach(Array(LocalBrain.CloudFallback.allCases.enumerated()), id: \.element) { index, fallback in
                if index > 0 { SettingsDivider() }
                choiceRow(fallback.title, detail: nil, selected: fallbackRaw == fallback.rawValue) { fallbackRaw = fallback.rawValue }
            }
        }
        SettingsCard(title: "Use a brain you already have", footer: brain.localModels.isEmpty ? "Start Ollama or LM Studio and load one, then look again." : "Perry uses only what passed the check. Check again after you change it.") {
            ForEach(brain.localModels, id: \.id) { model in
                existingModelRow(model)
                SettingsDivider()
            }
            SettingsRow(title: brain.localModels.isEmpty ? "No brains found" : "Look again") {
                Button("Find brains") { Task { await brain.refresh() } }
            }
        }
        .task { await brain.refresh() }
    }

    private func footer(_ rung: ModelRung) -> String {
        let model = "Model: \(rung.name) \(rung.quant)."
        return Self.isSmall(profile) ? "Answers on a Mac with 8 GB are limited, so a cloud brain is better here. \(model)" : model
    }

    private var abilityLine: String {
        guard case .ready = local.phase else { return "Perry checks what it can do after setup." }
        return brain.localTaskCapable ? "It can use your apps." : "It chats privately but can’t use your apps yet."
    }

    @ViewBuilder
    private func setupRow(_ rung: ModelRung) -> some View {
        switch local.phase {
        case .notSetUp:
            SettingsRow(title: "Private brain", detail: String(format: "Runs on this Mac, even offline. %.1f GB download. %@", rung.downloadGB, abilityLine)) {
                Button("Download") { Task { await local.setUp(rung) } }
                    .buttonStyle(InkButtonStyle(.primary))
            }
        case .downloading(let received, let total):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                    .tint(PerryTheme.Colors.accent)
                Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                    .settingNote()
                    .monospacedDigit()
            }
            .settingsRowPadding()
        case .ready:
            SettingsRow(title: "Private brain", detail: [bench.flatMap { LocalBenchmark.summary($0.interactive) }, abilityLine].compactMap { $0 }.joined(separator: " ")) {
                StatusMark(.ok)
                    .accessibilityLabel("Ready")
            }
        case .failed(let message):
            SettingsRow(title: "Setup stopped", detail: message) {
                Button("Try again") { Task { await local.setUp(rung) } }
            }
        }
    }

    private func detail(_ budget: LocalBrain.Budget) -> String {
        switch budget {
        case .nothing: "Perry unloads it after 30 idle minutes. The next answer takes a few seconds longer."
        case .upTo2GB: "Only the small brain stays ready."
        case .keepMainReady: String(format: "The main brain stays loaded, about %.0f GB.", recommendation.interactive.warmGB)
        }
    }

    private func choiceRow(_ title: String, detail: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RadioMark(selected: selected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail {
                        Text(detail)
                            .settingNote()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .settingsRowPadding()
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func existingModelRow(_ model: LocalModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(model.name) · \(model.server.rawValue)")
                Spacer()
                if brain.localChecks[model.id] == .checking {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { brain.cancelLocalCheck(model) }
                } else {
                    Button("Check") { brain.checkLocalModel(model) }
                }
            }
            switch brain.localChecks[model.id] {
            case .checking:
                Text("Checking with sample text, a generated image and a harmless test. No apps or files change.").settingNote()
            case .checked(_, let result):
                Text([("Text", result.text), ("Images", result.vision), ("Actions", result.tools)].map { "\($0.0) \(Self.mark($0.1))" }.joined(separator: " · "))
                    .settingNote()
            case .failed(let message):
                Text(message).settingNote()
            case nil:
                Text("Not checked yet").settingNote()
            }
        }
        .settingsRowPadding()
    }

    private static func mark(_ check: ModelCapabilityProbe.Check) -> String {
        switch check {
        case .passed: "passed"
        case .failed: "failed"
        case .notRun: "not checked"
        }
    }
}
