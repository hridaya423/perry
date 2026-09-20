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
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var connected = false
    @State private var writesEnabled = false
    @State private var operationState = IntegrationOperationState.idle
    @State private var showDisconnectConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(definition.displayName)
                    .font(PerryTheme.Typography.panelBody.weight(.semibold))
                Spacer()
                if connected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(PerryTheme.Typography.note)
                        .foregroundStyle(PerryTheme.Colors.success)
                    Button("Test") {
                        testConnection()
                    }
                    .controlSize(.small)
                    .disabled(operationState.isWorking)
                    if !definition.quickActions.isEmpty {
                        Menu("Preview") {
                            ForEach(definition.quickActions) { action in
                                Button(action.title) {
                                    preview(action)
                                }
                            }
                        }
                        .controlSize(.small)
                        .disabled(operationState.isWorking)
                    }
                    Button("Disconnect…") {
                        showDisconnectConfirmation = true
                    }
                    .controlSize(.small)
                    .disabled(operationState.isWorking)
                }
            }
            if !connected {
                HStack {
                    TextField("OAuth client ID", text: $clientID)
                        .textFieldStyle(.roundedBorder)
                    if definition.requiresClientSecret {
                        SecureField("Client secret", text: $clientSecret)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button("Connect") {
                        connect()
                    }
                    .controlSize(.small)
                    .disabled(!canConnect || operationState.isWorking)
                }
            }
            if connected && !definition.allowedWritePathPrefixes.isEmpty {
                Toggle("Allow agent writes", isOn: Binding(
                    get: { writesEnabled },
                    set: { value in
                        writesEnabled = value
                        RemoteIntegrationPermissionStore().setWritesEnabled(value, for: definition)
                    }
                ))
                .toggleStyle(.switch)
                .font(PerryTheme.Typography.note)
            }
            Text("\(definition.connectionHint). \(definition.writesEnabledByDefault ? "Read and write access is available." : "Read-only by default; every write still needs explicit approval.")")
                .font(PerryTheme.Typography.monoSmall)
                .foregroundStyle(.secondary)
            if let message = operationState.message {
                HStack(spacing: 6) {
                    operationStatusIcon
                    Text(message)
                }
                .font(PerryTheme.Typography.monoSmall)
                .foregroundStyle(operationStatusColor)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(operationState.accessibilityLabel ?? message)
            }
        }
        .confirmationDialog(
            "Disconnect \(definition.displayName)?",
            isPresented: $showDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect \(definition.displayName)", role: .destructive) {
                disconnect()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Perry removes the saved credential and write permission. You’ll need to authorize this integration again to reconnect.")
        }
        .task {
            do {
                connected = try await AppController.shared.integrationIsConnected(definition)
            } catch {
                connected = false
                setOperationState(.failed(error.localizedDescription))
            }
            writesEnabled = RemoteIntegrationPermissionStore().writesEnabled(for: definition)
        }
    }

    private func connect() {
        setOperationState(.working("Opening secure authorization…"))
        AppController.shared.connectIntegration(definition, clientID: clientID, clientSecret: clientSecret) { result in
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
        AppController.shared.testIntegration(definition) { result in
            switch result {
            case .success(let summary): setOperationState(.succeeded(summary))
            case .failure(let error): setOperationState(.failed(error.localizedDescription))
            }
        }
    }

    private func preview(_ action: RemoteIntegrationQuickAction) {
        setOperationState(.working("Reading \(action.title.lowercased())…"))
        AppController.shared.previewIntegration(definition, action: action) { result in
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
                try await AppController.shared.disconnectIntegration(definition)
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
