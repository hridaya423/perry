import AppKit
import Foundation

struct AgentDesktopConfiguration: Sendable {
    let executableURL: URL
    let hostBundleID: String
    let stateDirectoryURL: URL
    var bundleIdentifier: @Sendable (Int32) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }

    var environment: [String: String] {
        AgentDesktopCommand.environment(stateDirectory: stateDirectoryURL)
    }

    static func discover(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        supportDirectory: URL? = AppController.supportDirectory,
        codeIdentityReader: (URL) -> ScreenCodeIdentity = { ScreenCodeIdentity.read(at: $0) ?? .unsignedOrAdHoc }
    ) -> AgentDesktopConfiguration? {
        guard let bundledURL = bundle.url(forResource: "agent-desktop", withExtension: nil, subdirectory: "AgentDesktop/bin"),
              let supportDirectory else {
            return nil
        }
        let hostBundleURL = bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let executableURL = bundledURL.resolvingSymlinksInPath().standardizedFileURL
        guard fileManager.isExecutableFile(atPath: executableURL.path),
              bundledDriverIsAllowed(
                  driverURL: executableURL,
                  hostBundleURL: hostBundleURL,
                  hostIdentity: codeIdentityReader(hostBundleURL),
                  driverIdentity: codeIdentityReader(executableURL)
              ) else {
            return nil
        }
        return AgentDesktopConfiguration(
            executableURL: executableURL,
            hostBundleID: bundle.bundleIdentifier ?? "dev.perry.Perry",
            stateDirectoryURL: supportDirectory.appendingPathComponent("AgentDesktop", isDirectory: true)
        )
    }

    static func bundledDriverIsAllowed(
        driverURL: URL,
        hostBundleURL: URL,
        hostIdentity: ScreenCodeIdentity,
        driverIdentity: ScreenCodeIdentity
    ) -> Bool {
        guard ScreenCodeIdentity.isBundled(driverURL, inside: hostBundleURL) else { return false }
        switch hostIdentity {
        case .unsignedOrAdHoc:
            return true
        case let .appleDeveloperID(_, hostTeam):
            guard case let .appleDeveloperID(identifier, driverTeam) = driverIdentity else { return false }
            return !hostTeam.isEmpty && driverTeam == hostTeam && identifier == "agent-desktop"
        }
    }
}
