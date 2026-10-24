import SwiftUI
import PerryBrain
import PerryCore

struct ModelProfilesSection: View {
    @ObservedObject var brain: BrainController
    @State private var adding = false
    @State private var presetID = ProviderPreset.all[0].id
    @State private var baseURL = ProviderPreset.all[0].baseURL?.absoluteString ?? ""
    @State private var key = ""
    @State private var model = ProviderPreset.all[0].suggested?.deep ?? ""
    @State private var fastModel = ProviderPreset.all[0].suggested?.fast ?? ""
    @State private var availableModels: [String] = []
    @State private var loadingModels = false
    @State private var errorMessage: String?
    @State private var pendingRemoval: ModelProfile?

    private var preset: ProviderPreset { ProviderPreset.preset(id: presetID) ?? .custom }

    var body: some View {
        ForEach(brain.profiles) { profile in
            row(profile)
        }
        .notchDialog("Remove this provider?", item: $pendingRemoval,
                     message: "Perry removes its API key from Keychain.") { profile in
            [NotchDialog.Action("Remove provider", role: .destructive) {
                do { try brain.removeProfile(profile) } catch { errorMessage = error.localizedDescription }
            }]
        }
        DisclosureGroup(brain.profiles.isEmpty ? "Add your first provider" : "Add another provider", isExpanded: $adding) {
            form
        }
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.circle").settingNote()
        }
    }

    private func row(_ profile: ModelProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    brain.setActiveProfile(profile.id)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName).font(.callout.weight(.medium))
                            Text(modelLine(profile)).settingNote()
                        }
                    } icon: {
                        Image(systemName: brain.activeProfile?.id == profile.id ? "largecircle.fill.circle" : "circle")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(brain.activeProfile?.id == profile.id ? .isSelected : [])
                Spacer()
                if brain.profileChecks[profile.id] == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Check") { brain.checkProfile(profile) }
                }
                Button("Remove…", role: .destructive) { pendingRemoval = profile }
            }
            checkSummary(profile)
        }
    }

    private func modelLine(_ profile: ModelProfile) -> String {
        guard let fast = profile.fastModel, !fast.isEmpty, fast != profile.model else { return profile.model }
        return "\(profile.model) · Talk uses \(fast)"
    }

    @ViewBuilder
    private func checkSummary(_ profile: ModelProfile) -> some View {
        switch brain.profileChecks[profile.id] {
        case .checked(let checkedModel, let result) where checkedModel == profile.model:
            Text(summary(result)).settingNote()
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle").settingNote()
        case .checking:
            Text("Checking text, images, and tools with a harmless test.").settingNote()
        default:
            if profile.preset.keyRequired, !brain.hasCredential(profile) {
                Text("No API key saved. Remove and add it again.").settingNote()
            }
        }
    }

    private func summary(_ result: ModelCapabilityProbe.Result) -> String {
        func word(_ check: ModelCapabilityProbe.Check) -> String {
            switch check {
            case .passed: "yes"
            case .failed: "no"
            case .notRun: "not checked"
            }
        }
        return "Text: \(word(result.text)). Images: \(word(result.vision)). Tools: \(word(result.tools))."
    }

    @ViewBuilder
    private var form: some View {
        Picker("Provider", selection: $presetID) {
            ForEach(ProviderPreset.all) { preset in
                Text(preset.name).tag(preset.id)
            }
        }
        .onChange(of: presetID) { _, _ in applyPreset() }
        if preset.baseURL == nil || preset.isLocal {
            TextField(preset.isLocal ? "Server address" : "HTTPS base URL", text: $baseURL)
                .textFieldStyle(.roundedBorder)
        } else {
            LabeledContent("Endpoint") {
                Text(baseURL).font(PerryTheme.Typography.monoSmall).foregroundStyle(PerryTheme.Colors.textSecondary)
            }
        }
        if !preset.isLocal {
            SecureField(preset.keyRequired ? "API key" : "API key (optional)", text: $key)
                .textFieldStyle(.roundedBorder)
        }
        HStack(spacing: PerryTheme.Spacing.inline) {
            Button(loadingModels ? "Loading models…" : "Load models") { loadModels() }
                .disabled(loadingModels || endpointURL == nil)
            if !availableModels.isEmpty {
                Text("\(availableModels.count) models").settingNote()
            }
        }
        if availableModels.isEmpty {
            TextField("Model ID", text: $model).textFieldStyle(.roundedBorder)
            TextField("Faster model for Talk (optional)", text: $fastModel).textFieldStyle(.roundedBorder)
        } else {
            Picker("Model", selection: $model) {
                ForEach(availableModels, id: \.self) { Text($0).tag($0) }
            }
            Picker("Model for Talk", selection: $fastModel) {
                Text("Same as above").tag("")
                ForEach(availableModels, id: \.self) { Text($0).tag($0) }
            }
        }
        Text("Talk uses the faster model so spoken answers start sooner. Tasks use the main model.").settingNote()
        Button("Save and use") { save() }
            .disabled(!canSave)
    }

    private var endpointURL: URL? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil,
              (try? NetworkEndpointPolicy.requireSafe(url)) != nil else { return nil }
        return url
    }

    private var canSave: Bool {
        endpointURL != nil
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!preset.keyRequired || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func applyPreset() {
        key = ""
        baseURL = preset.baseURL?.absoluteString ?? ""
        model = preset.suggested?.deep ?? ""
        fastModel = preset.suggested?.fast ?? ""
        availableModels = []
        errorMessage = nil
    }

    private func loadModels() {
        guard let url = endpointURL else { return }
        loadingModels = true
        errorMessage = nil
        let preset = preset
        let key = key
        Task {
            defer { loadingModels = false }
            do {
                let models = try await preset.listModels(baseURL: url, key: key)
                availableModels = models
                if !models.contains(model) { model = models.first ?? model }
                if !fastModel.isEmpty, !models.contains(fastModel) { fastModel = "" }
                if models.isEmpty { errorMessage = "The provider returned no models. Type a model ID instead." }
            } catch {
                errorMessage = "Couldn’t load models: \(error.localizedDescription) Type a model ID instead."
            }
        }
    }

    private func save() {
        guard let url = endpointURL else { return }
        let profile = ModelProfile(presetID: preset.id, baseURL: url, model: model, fastModel: fastModel.isEmpty ? nil : fastModel)
        do {
            try brain.addProfile(profile, key: key)
            key = ""
            adding = false
            errorMessage = nil
            brain.checkProfile(profile)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
