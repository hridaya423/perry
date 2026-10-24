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
                VStack(alignment: .leading, spacing: 2) {
                    Text(definition.displayName)
                        .font(PerryTheme.Typography.panelBody.weight(.semibold))
                    Text(definition.connectionHint)
                        .font(PerryTheme.Typography.note)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                }
                Spacer(minLength: 8)
                if connected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(PerryTheme.Typography.note)
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
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("\(definition.displayName) options")
                    .disabled(operationState.isWorking)
                } else {
                    Button(settingUp ? "Cancel" : "Set up") { settingUp.toggle() }
                        .buttonStyle(InkButtonStyle(.secondary))
                        .controlSize(.small)
                        .accessibilityLabel(settingUp ? "Cancel \(definition.displayName) setup" : "Set up \(definition.displayName)")
                }
            }
            if !connected && settingUp {
                VStack(alignment: .leading, spacing: 12) {
                    Text("This build needs your own OAuth app for \(definition.displayName). Add this callback URL in the provider’s developer settings, then enter its credentials.")
                        .font(PerryTheme.Typography.note)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("dev.perry.perry:/oauth/callback")
                        .font(PerryTheme.Typography.monoSmall)
                        .textSelection(.enabled)
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
                            .font(PerryTheme.Typography.note)
                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                    }
                }
                .padding(.top, 4)
            }
            if connected && !definition.allowedWritePathPrefixes.isEmpty {
                Toggle("Allow agent writes", isOn: Binding(
                    get: { writesEnabled },
                    set: { value in
                        writesEnabled = value
                        RemoteIntegrationPermissionStore().setWritesEnabled(value, for: definition)
                    }
                ))
                .toggleStyle(InkSwitchStyle())
                .font(PerryTheme.Typography.note)
            }
            if connected {
                Text(definition.writesEnabledByDefault ? "Read and write access is available." : "Read-only by default. Writes require your approval.")
                    .font(PerryTheme.Typography.note)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
            }
            if let message = operationState.message {
                HStack(spacing: 6) {
                    operationStatusIcon
                    Text(message)
                }
                .font(PerryTheme.Typography.note)
                .foregroundStyle(operationStatusColor)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(operationState.accessibilityLabel ?? message)
            }
        }
        .notchDialog(
            "Disconnect \(definition.displayName)?",
            isPresented: $showDisconnectConfirmation,
            message: "Perry removes the saved credential and write permission. You’ll need to authorize this integration again to reconnect."
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
        setOperationState(.working("Opening secure authorization…"))
        connections.connect(definition, clientID: clientID, clientSecret: clientSecret) { result in
            switch result {
            case .success:
                connected = true
                clientID = ""
                clientSecret = ""
                setOperationState(.succeeded("Connected on this Mac."))
            case .failure(let error):
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
        setOperationState(.working("Testing provider access…"))
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
                try await connections.disconnect(definition)
                connected = false
                writesEnabled = false
                setOperationState(.succeeded("Disconnected."))
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
            Image(systemName: "checkmark.circle.fill")
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
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
