import SwiftUI
import PerryBrain

struct BrainModelSettingsView: View {
    @ObservedObject var brain: BrainController

    var body: some View {
        Picker("Home and Talk", selection: $brain.modelChoice) {
            ForEach(BrainController.ModelChoice.allCases, id: \.rawValue) { choice in
                Text(choice.title).tag(choice.rawValue)
            }
            if BrainController.ModelChoice(rawValue: brain.modelChoice) == nil {
                Text("Saved model unavailable").tag(brain.modelChoice)
            }
        }
        switch BrainController.ModelChoice(rawValue: brain.modelChoice) {
        case .chatGPT:
            HomeConnectionView(brain: brain, openSettings: {
                brain.modelChoice = BrainController.ModelChoice.direct.rawValue
            })
        case .direct:
            Text("Use the provider, model, and credential in Direct AI provider below. Perry stops if that provider cannot handle the request.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .local:
            Text("Home and Talk use on-device models. Requests that need unavailable image or tool capabilities stop here; Perry won’t send them to a remote model.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Find models on this Mac") { Task { await brain.refresh() } }
                .task { await brain.refresh() }
            if brain.localModels.isEmpty {
                Text("No local server models found. Start Ollama or LM Studio, load a model, then check again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(brain.localModels, id: \.id) { model in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(model.name) (\(model.server.rawValue))").font(.callout.weight(.medium))
                            Spacer()
                            if brain.localChecks[model.id] == .checking {
                                ProgressView().controlSize(.small)
                                Button("Cancel") { brain.cancelLocalCheck(model) }
                            } else {
                                Button("Check capabilities") { brain.checkLocalModel(model) }
                            }
                        }
                        switch brain.localChecks[model.id] {
                        case .checking:
                            Text("Checking with sample text, a generated image, and a harmless test tool. No apps or files are changed.")
                                .font(.callout).foregroundStyle(.secondary)
                        case .checked(_, let result):
                            checkRow("Text", result.text)
                            checkRow("Images", result.vision)
                            checkRow("Tools", result.tools)
                        case .failed(let message):
                            Label(message, systemImage: "exclamationmark.circle").font(.callout)
                        case nil:
                            Text("Not checked yet").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Perry uses only capabilities that passed. Checks apply to this session; run them again after changing the model.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case nil:
            Text("Choose a model to resume conversations. Perry hasn’t switched providers.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func checkRow(_ title: String, _ check: ModelCapabilityProbe.Check) -> some View {
        switch check {
        case .passed:
            Label("\(title): passed", systemImage: "checkmark.circle")
                .font(.callout)
        case .failed(let message):
            Label("\(title): \(message)", systemImage: "exclamationmark.circle")
                .font(.callout).foregroundStyle(.secondary)
        case .notRun:
            Text("\(title): not checked").font(.callout).foregroundStyle(.secondary)
        }
    }
}
