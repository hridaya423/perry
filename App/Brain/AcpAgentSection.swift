import SwiftUI
import PerryBrain

struct AcpAgentSection: View {
    @ObservedObject var brain: BrainController
    @State private var selection = ""
    @State private var name = ""
    @State private var command = ""

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
                Text(brain.acpAgentAvailable ? "Using \(current.name)." : "\(current.name) is not installed.").settingNote()
            }
            Spacer()
            Button("Use this agent") { if let agent = chosen { brain.setAcpAgent(agent) } }
                .disabled(chosen?.executable() == nil || chosen == brain.acpAgent)
        }
        Text("Perry starts the agent in its read-only mode when it has one and refuses the agent’s own requests to run commands or edit files. The agent can still read files without asking.")
            .settingNote()
            .onAppear(perform: load)
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
