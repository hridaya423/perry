import SwiftUI
import PerryBrain

struct AcpAgentSection: View {
    @ObservedObject var brain: BrainController
    @State private var selection = ""
    @State private var name = ""
    @State private var command = ""
    @State private var registry: [AcpRegistryEntry]?
    @State private var loadingRegistry = false
    @State private var registryError: String?

    private static let custom = "custom"

    var body: some View {
        Picker("Agent", selection: $selection) {
            ForEach(AcpAgent.known) { agent in
                Text(agent.executable() == nil ? "\(agent.name) (not installed)" : agent.name).tag(agent.id)
            }
            Text("Custom command").tag(Self.custom)
        }
        if selection == Self.custom {
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Command, for example /usr/local/bin/my-agent acp", text: $command).textFieldStyle(.roundedBorder)
        }
        HStack {
            if let current = brain.acpAgent {
                Text(brain.acpAgentAvailable ? "Using \(current.name)." : "\(current.name) isn’t installed.").settingNote()
            }
            Spacer()
            Button("Use this agent") { if let agent = chosen { brain.setAcpAgent(agent) } }
                .disabled(chosen?.executable() == nil || chosen == brain.acpAgent)
        }
        Text("Perry starts the agent in its read-only mode when it has one and refuses the agent’s own requests to run commands or edit files. The agent can still read files without asking.")
            .settingNote()
            .onAppear(perform: load)
        DisclosureGroup("More coding agents") {
            if let registry {
                AcpRegistryList(entries: registry, brain: brain, failure: $registryError)
            } else {
                Button(loadingRegistry ? "Loading the list…" : "Load the list") { loadRegistry() }
                    .disabled(loadingRegistry)
                Text("Perry contacts agentclientprotocol.com only when you press this.").settingNote()
            }
            if let registryError {
                StatusLabel(registryError, .attention).settingNote()
            }
        }
    }

    private func loadRegistry() {
        loadingRegistry = true
        registryError = nil
        Task {
            defer { loadingRegistry = false }
            do {
                registry = try await AcpRegistry.fetch()
            } catch {
                registryError = "Couldn’t load the list. Try again."
            }
        }
    }

    private var chosen: AcpAgent? {
        if selection != Self.custom { return AcpAgent.known.first { $0.id == selection } }
        let parts = command.split(separator: " ").map(String.init)
        guard let first = parts.first else { return nil }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return AcpAgent(id: "custom", name: label.isEmpty ? first : label, command: first, arguments: Array(parts.dropFirst()))
    }

    private func load() {
        guard selection.isEmpty else { return }
        guard let current = brain.acpAgent else {
            selection = AcpAgent.known.first { $0.executable() != nil }?.id ?? AcpAgent.known[0].id
            return
        }
        if AcpAgent.known.contains(where: { $0.id == current.id }) {
            selection = current.id
        } else {
            selection = Self.custom
            name = current.name
            command = ([current.command] + current.arguments).joined(separator: " ")
        }
    }
}

struct AcpRegistryList: View {
    let entries: [AcpRegistryEntry]
    @ObservedObject var brain: BrainController
    @Binding var failure: String?
    @State private var installing: String?

    var body: some View {
        ForEach(entries) { entry in row(entry) }
    }

    private func row(_ entry: AcpRegistryEntry) -> some View {
        let availability = entry.availability { tool in AcpAgent(name: tool, command: tool, arguments: []).executable() }
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.callout.weight(.medium))
                Text(entry.summary).settingNote().lineLimit(2)
                if case .unavailable(let reason) = availability {
                    Text(reason).settingNote()
                }
            }
            Spacer()
            switch availability {
            case .ready(let agent):
                Button(brain.acpAgent == agent ? "In use" : "Use") { brain.setAcpAgent(agent) }
                    .disabled(brain.acpAgent == agent)
            case .download(let archive, let sha256, let command, let arguments, let environment):
                if installing == entry.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Download and use") {
                        install(entry, archive: archive, sha256: sha256, command: command, arguments: arguments, environment: environment)
                    }
                    .disabled(installing != nil)
                }
            case .unavailable:
                EmptyView()
            }
        }
    }

    private func install(_ entry: AcpRegistryEntry, archive: URL, sha256: String, command: String, arguments: [String], environment: [String: String]) {
        guard let root = AppController.supportDirectory?.appendingPathComponent("AcpAgents", isDirectory: true) else { return }
        installing = entry.id
        failure = nil
        Task {
            defer { installing = nil }
            do {
                let agent = try await AcpRegistry.install(entry, archive: archive, sha256: sha256, command: command, arguments: arguments, environment: environment, into: root)
                brain.setAcpAgent(agent)
            } catch {
                failure = "Couldn’t install \(entry.name). Try again."
            }
        }
    }

}
