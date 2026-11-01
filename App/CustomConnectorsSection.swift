import PerryBrain
import SwiftUI

struct CustomConnectorsSection: View {
    @ObservedObject var connectors: CustomConnectors
    @State private var name = ""
    @State private var kind = Kind.command
    @State private var address = ""
    @State private var secretVariable = ""
    @State private var secret = ""
    @State private var adding = false
    @State private var addError: String?
    @State private var removeError: String?
    @State private var showsForm = false

    private enum Kind: String, CaseIterable, Identifiable {
        case command = "Command"
        case url = "URL"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom connectors")
                        .font(PerryTheme.Scale.body.weight(.semibold))
                    Text("Connect a tool you set up yourself. Perry asks before it changes anything.")
                        .settingNote()
                }
                Spacer(minLength: 8)
                Button(showsForm ? "Cancel" : "Add…") { showsForm.toggle() }
                    .buttonStyle(InkButtonStyle(.secondary))
                    .controlSize(.small)
                    .accessibilityLabel(showsForm ? "Cancel adding a connector" : "Add a custom connector")
            }
            ForEach(connectors.connectors) { connector in
                Divider()
                row(connector)
            }
            if let removeError {
                Text(removeError)
                    .font(PerryTheme.Scale.secondary)
                    .foregroundStyle(PerryTheme.Colors.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsForm {
                Divider()
                form
            }
        }
        .padding(16)
        .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.card, style: .continuous))
    }

    private func row(_ connector: CustomConnector) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(connector.name)
                        .font(PerryTheme.Scale.body)
                    if connector.secret != nil {
                        Image(systemName: "key.fill")
                            .font(PerryTheme.Icon.utility).imageScale(.small)
                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                            .help("Uses a key from your keychain")
                            .accessibilityLabel("Uses a key")
                    }
                }
                Text(connector.summary)
                    .font(PerryTheme.Scale.monoSmall)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            statusLabel(connectors.status[connector.id], signInNotSaved: connectors.signInNotSaved.contains(connector.id))
            if connectors.signInNotSaved.contains(connector.id) || connectors.status[connector.id]?.isFailed == true {
                Button("Reconnect") { connectors.reconnect(connector.id) }
                    .buttonStyle(InkButtonStyle(.secondary))
                    .controlSize(.small)
            }
            Button("Remove", role: .destructive) { removeError = connectors.remove(connector.id) }
                .buttonStyle(.pressable)
                .font(PerryTheme.Scale.secondary)
                .foregroundStyle(PerryTheme.Colors.textSecondary)
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: CustomConnectors.Status?, signInNotSaved: Bool) -> some View {
        switch status {
        case .ready where signInNotSaved:
            StatusLabel("Reconnect soon", .attention)
                .foregroundStyle(PerryTheme.Colors.caution)
                .help(MCPAuthError.credentialNotSaved.localizedDescription)
        case .ready(let count):
            StatusLabel("\(count) \(count == 1 ? "tool" : "tools")", .ok)
                .foregroundStyle(PerryTheme.Colors.success)
        case .failed(let message):
            StatusLabel("Offline", .attention)
                .foregroundStyle(PerryTheme.Colors.caution)
                .help(message)
        case .connecting, nil:
            ProgressView().controlSize(.small)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                Picker("Type", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
            TextField(kind == .command ? "npx -y @modelcontextprotocol/server-memory" : "https://example.com/mcp", text: $address)
                .textFieldStyle(.roundedBorder)
                .font(PerryTheme.Scale.monoSmall)
                .onSubmit(add)
            HStack(spacing: 8) {
                if kind == .command {
                    TextField("API_KEY", text: $secretVariable)
                        .textFieldStyle(.roundedBorder)
                        .font(PerryTheme.Scale.monoSmall)
                        .frame(maxWidth: 180)
                        .accessibilityLabel("Key variable name")
                }
                SecureField(kind == .command ? "Key value (optional)" : "Bearer token (optional)", text: $secret)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button(adding ? "Connecting…" : "Add", action: add)
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.small)
                    .disabled(adding || endpoint == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let addError {
                Text(addError)
                    .font(PerryTheme.Scale.secondary)
                    .foregroundStyle(PerryTheme.Colors.caution)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(kind == .command
                     ? "Runs in your login shell, the same way Terminal would run it. A key is passed as that variable and kept in your keychain."
                     : "Streamable HTTP servers. A token is sent as a Bearer header and kept in your keychain.")
                    .settingNote()
            }
        }
    }

    private var endpoint: CustomConnector.Endpoint? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch kind {
        case .command:
            return .command(trimmed)
        case .url:
            guard let url = URL(string: trimmed), url.scheme == "https" || url.scheme == "http", url.host != nil else { return nil }
            return .url(url)
        }
    }

    private func add() {
        guard let endpoint, !adding else { return }
        adding = true
        addError = nil
        removeError = nil
        Task {
            let connector = CustomConnector(name: name, endpoint: endpoint, secret: kind == .command ? .environment(secretVariable.trimmingCharacters(in: .whitespaces)) : nil)
            let status = await connectors.add(connector, secret: secret)
            adding = false
            if case .failed(let message) = status {
                addError = message
            } else {
                name = ""
                address = ""
                secretVariable = ""
                secret = ""
                showsForm = false
            }
        }
    }
}
