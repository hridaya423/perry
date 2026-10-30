import Foundation
import PerryRuntimes

struct RuntimeReadiness {
    let isReady: Bool
    let message: String
    let authentication: RuntimeAuthenticationStatus?

    init(isReady: Bool, message: String, authentication: RuntimeAuthenticationStatus? = nil) {
        self.isReady = isReady
        self.message = message
        self.authentication = authentication
    }

    func commands(
        executable: URL,
        signIn: [String],
        signOut: [String],
        environment: [String: String] = [:]
    ) -> (signIn: RuntimeAuthenticationCommand?, signOut: RuntimeAuthenticationCommand?) {
        guard let authentication else { return (nil, nil) }
        if authentication == .authenticated {
            return (nil, RuntimeAuthenticationCommand(executable: executable, arguments: signOut, environment: environment))
        }
        return (
            RuntimeAuthenticationCommand(executable: executable, arguments: signIn, environment: environment),
            authentication == .configured
                ? RuntimeAuthenticationCommand(executable: executable, arguments: signOut, environment: environment)
                : nil
        )
    }
}

struct RuntimeSetupRecord: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String
    let isReady: Bool
    let authentication: RuntimeAuthenticationStatus?
    let signInCommand: RuntimeAuthenticationCommand?
    let signOutCommand: RuntimeAuthenticationCommand?
    var authenticatesInApp = false

}

struct RuntimeSetupSnapshot: Equatable {
    let summary: String
    let records: [RuntimeSetupRecord]
}

struct RuntimeAuthenticationCommand: Equatable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]

    init(executable: URL, arguments: [String], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    var shellText: String {
        var command = [String]()
        if !environment.isEmpty {
            command.append("/usr/bin/env")
            command.append(contentsOf: environment.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" })
        }
        command.append(executable.path)
        command.append(contentsOf: arguments)
        return command.map(Self.shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum SetupState: Equatable {
    case ready(detail: String)
    case needsSignIn
    case notInstalled
    case unchecked
}

extension RuntimeSetupSnapshot {
    func setupStates(chatGPTEmail: String?, acpInstalled: Bool) -> [BrainController.ModelChoice: SetupState] {
        [
            .chatGPT: state(of: "cli.codex", readyDetail: chatGPTEmail ?? "Signed in with ChatGPT"),
            .claudeCode: state(of: "cli.claude-code", readyDetail: "Signed in with Claude Code"),
            .acp: acpInstalled ? .ready(detail: "Installed") : .notInstalled,
            .direct: .unchecked,
            .local: .unchecked,
        ]
    }

    private func state(of id: String, readyDetail: String) -> SetupState {
        guard !records.isEmpty else { return .unchecked }
        guard let record = records.first(where: { $0.id == id }) else { return .notInstalled }
        switch record.authentication {
        case nil: return .notInstalled
        case .authenticated?: return .ready(detail: readyDetail)
        case .missing?, .invalid?: return .needsSignIn
        case .notRequired?, .configured?, .unknown?: return .unchecked
        }
    }
}
