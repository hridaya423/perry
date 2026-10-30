import AppKit
import SwiftUI

enum IntegrationOperationState: Equatable {
    case idle
    case working(String)
    case succeeded(String)
    case failed(String)

    var message: String? {
        switch self {
        case .idle:
            nil
        case .working(let message), .succeeded(let message), .failed(let message):
            message
        }
    }

    var isWorking: Bool {
        guard case .working = self else { return false }
        return true
    }

    var accessibilityLabel: String? {
        switch self {
        case .idle:
            nil
        case .working(let message):
            "In progress: \(message)"
        case .succeeded(let message):
            "Succeeded: \(message)"
        case .failed(let message):
            "Failed: \(message)"
        }
    }
}

struct IntegrationRow: View {
    let definition: RemoteIntegrationDefinition
    let connections: IntegrationConnections
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var connected = false
    @State private var writesEnabled = false
    @State private var operationState = IntegrationOperationState.idle
    @State private var showDisconnectConfirmation = false
    @State private var settingUp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                BrandMark(id: definition.id, name: definition.displayName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(definition.displayName)
                        .font(PerryTheme.Scale.body.weight(.semibold))
                    Text(definition.connectionHint)
                        .font(PerryTheme.Scale.secondary)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                }
                Spacer(minLength: 8)
                if connected {
                    StatusLabel("Connected", .ok)
                        .font(PerryTheme.Scale.secondary)
                        .foregroundStyle(PerryTheme.Colors.success)
                    Menu {
                        Button("Test connection") { testConnection() }
                        if !definition.quickActions.isEmpty {
                            Menu("Preview") {
                                ForEach(definition.quickActions) { action in
                                    Button(action.title) { preview(action) }
                                }
                            }
                        }
                        Divider()
                        Button("Disconnect…") { showDisconnectConfirmation = true }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(PerryTheme.Icon.utility)
                            .foregroundStyle(PerryTheme.Colors.icon)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("\(definition.displayName) options")
                    .disabled(operationState.isWorking)
                } else if hasBundledClient {
                    Button("Connect") { connect() }
                        .buttonStyle(InkButtonStyle())
                        .controlSize(.small)
                        .disabled(operationState.isWorking)
                        .accessibilityLabel("Connect \(definition.displayName)")
                } else {
                    Button(settingUp ? "Cancel" : "Connect") { settingUp.toggle() }
                        .buttonStyle(InkButtonStyle(.secondary))
                        .controlSize(.small)
                        .accessibilityLabel(settingUp ? "Cancel \(definition.displayName) setup" : "Connect \(definition.displayName)")
                }
            }
            if !connected && hasBundledClient {
                Button(settingUp ? "Cancel own setup" : "Use your own setup") { settingUp.toggle() }
                    .buttonStyle(.pressable)
                    .font(PerryTheme.Scale.secondary)
                    .underline()
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .accessibilityLabel(settingUp ? "Cancel own setup for \(definition.displayName)" : "Use your own setup for \(definition.displayName)")
            }
            if !connected && settingUp {
                VStack(alignment: .leading, spacing: 12) {
                    Text((hasBundledClient ? "Sign in with your own setup for \(definition.displayName) instead of Perry’s. " : "\(definition.displayName) needs your own sign-in setup. ") + definition.redirectInstructions)
                        .font(PerryTheme.Scale.secondary)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if definition.showsCallbackURL {
                        Text(OAuthConfiguration.defaultRedirectURI.absoluteString)
                            .font(PerryTheme.Scale.monoSmall)
                            .textSelection(.enabled)
                    }
                    TextField("OAuth client ID", text: $clientID)
                        .textFieldStyle(.roundedBorder)
                    if definition.requiresClientSecret {
                        SecureField("Client secret", text: $clientSecret)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 12) {
                        Button("Connect \(definition.displayName)") {
                            connect()
                        }
                        .buttonStyle(InkButtonStyle())
                        .controlSize(.small)
                        .disabled(!canConnect || operationState.isWorking)
                        Text(definition.writesEnabledByDefault ? "Read and write access." : "Read-only until you allow writes.")
                            .font(PerryTheme.Scale.secondary)
                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                    }
                }
                .padding(.top, 4)
            }
            if connected && !definition.allowedWritePathPrefixes.isEmpty {
                Toggle("Let Perry make changes", isOn: Binding(
                    get: { writesEnabled },
                    set: { value in setWrites(value) }
                ))
                .toggleStyle(InkSwitchStyle())
                .font(PerryTheme.Scale.secondary)
            }
            if connected {
                Text(definition.writesEnabledByDefault ? "Perry can read and make changes." : "Read-only to start. Perry asks before it makes changes.")
                    .font(PerryTheme.Scale.secondary)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
            }
            if let message = operationState.message {
                HStack(spacing: 6) {
                    operationStatusIcon
                    Text(message)
                }
                .font(PerryTheme.Scale.secondary)
                .foregroundStyle(operationStatusColor)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(operationState.accessibilityLabel ?? message)
            }
        }
        .notchDialog(
            "Disconnect \(definition.displayName)?",
            isPresented: $showDisconnectConfirmation,
            message: "I’ll remove the saved sign-in and permission to make changes. To reconnect, sign in again."
        ) {
            [NotchDialog.Action("Disconnect \(definition.displayName)", role: .destructive) {
                disconnect()
            }]
        }
        .task {
            do {
                connected = try await connections.isConnected(definition)
            } catch {
                connected = false
                setOperationState(.failed(error.localizedDescription))
            }
            writesEnabled = RemoteIntegrationPermissionStore().writesEnabled(for: definition)
        }
    }

    private func connect() {
        setOperationState(.working("Opening sign-in…"))
        connections.connect(definition, clientID: clientID, clientSecret: clientSecret, deviceCodePrompt: showDeviceCode) { result in
            switch result {
            case .success:
                connected = true
                settingUp = false
                clientID = ""
                clientSecret = ""
                setOperationState(.succeeded("Connected on this Mac."))
            case .failure(let error):
                setOperationState(.failed(error.localizedDescription))
            }
        }
    }

    private var hasBundledClient: Bool {
        connections.hasBundledClient(definition)
    }

    private func showDeviceCode(_ prompt: DeviceCodePrompt) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt.userCode, forType: .string)
        setOperationState(.working("Enter code \(prompt.userCode) at \(prompt.verificationURL.host ?? "the sign-in page"). I copied it to your clipboard."))
    }

    private func setWrites(_ value: Bool) {
        if value { setOperationState(.working("Checking \(definition.displayName) access…")) }
        connections.setWrites(value, for: definition, deviceCodePrompt: showDeviceCode) { result in
            switch result {
            case .success(let enabled):
                writesEnabled = enabled
                setOperationState(.idle)
            case .failure(let error):
                writesEnabled = false
                setOperationState(.failed(error.localizedDescription))
            }
        }
    }

    private var canConnect: Bool {
        let hasClientID = !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSecret = !definition.requiresClientSecret || !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasClientID && hasSecret
    }

    private func testConnection() {
        setOperationState(.working("Testing the connection…"))
        connections.test(definition) { result in
            switch result {
            case .success(let summary): setOperationState(.succeeded(summary))
            case .failure(let error): setOperationState(.failed(error.localizedDescription))
            }
        }
    }

    private func preview(_ action: RemoteIntegrationQuickAction) {
        setOperationState(.working("Reading \(action.title.lowercased())…"))
        connections.preview(definition, action: action) { result in
            switch result {
            case .success(let summary): setOperationState(.succeeded(summary))
            case .failure(let error): setOperationState(.failed(error.localizedDescription))
            }
        }
    }

    private func disconnect() {
        setOperationState(.working("Disconnecting…"))
        Task {
            do {
                let revoked = try await connections.disconnect(definition)
                connected = false
                writesEnabled = false
                setOperationState(.succeeded(revoked ? "Disconnected, and \(definition.displayName) revoked Perry’s access." : "Disconnected on this Mac."))
            } catch {
                setOperationState(.failed(error.localizedDescription))
            }
        }
    }

    @ViewBuilder
    private var operationStatusIcon: some View {
        switch operationState {
        case .idle:
            EmptyView()
        case .working:
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        case .succeeded:
            StatusMark(.ok)
                .accessibilityHidden(true)
        case .failed:
            StatusMark(.failed)
                .accessibilityHidden(true)
        }
    }

    private var operationStatusColor: Color {
        switch operationState {
        case .failed:
            PerryTheme.Colors.danger
        case .succeeded:
            PerryTheme.Colors.success
        case .idle, .working:
            .secondary
        }
    }

    private func setOperationState(_ state: IntegrationOperationState) {
        operationState = state
        guard let announcement = state.accessibilityLabel else { return }
        guard let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}
