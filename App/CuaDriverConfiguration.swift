import Foundation
import Security

struct CuaDriverConfiguration: Sendable {
    let executableURL: URL
    var capabilityManifestURL: URL
    let hostBundleID: String

    private static let driverRequirement = "identifier \"cua-driver\" and anchor apple generic and certificate leaf[subject.OU] = \"YCK386LBJ7\""

    static func discover(
        environment _: [String: String] = [:],
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        identityVerifier: (URL) -> Bool = { verifyIdentity(at: $0) },
        codeIdentityReader: (URL) -> ScreenCodeIdentity? = { ScreenCodeIdentity.read(at: $0) }
    ) -> CuaDriverConfiguration? {
        let bundledURL = bundle.url(forResource: "cua-driver", withExtension: nil, subdirectory: "CuaDriver/bin")
        guard let manifestURL = bundle.url(
            forResource: "capabilities",
            withExtension: "yaml",
            subdirectory: "CuaDriver"
        ) else {
            return nil
        }

        let hostBundleURL = bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let capabilityManifestURL = manifestURL.resolvingSymlinksInPath().standardizedFileURL
        guard ScreenCodeIdentity.isBundled(capabilityManifestURL, inside: hostBundleURL),
              fileManager.isReadableFile(atPath: capabilityManifestURL.path) else {
            return nil
        }
        let hostBundleID = bundle.bundleIdentifier ?? "dev.perry.Perry"

        return bundledConfiguration(
            bundledURL,
            hostBundleURL: hostBundleURL,
            hostBundleID: hostBundleID,
            capabilityManifestURL: capabilityManifestURL,
            fileManager: fileManager,
            identityVerifier: identityVerifier,
            codeIdentityReader: codeIdentityReader
        )
    }

    private static func verifyIdentity(at url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(driverRequirement as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(), requirement) == errSecSuccess
    }

    static func bundledDriverIsAllowed(
        driverURL: URL,
        hostBundleURL: URL,
        upstreamIdentityVerified: Bool,
        hostIdentity: ScreenCodeIdentity?,
        driverIdentity: ScreenCodeIdentity?
    ) -> Bool {
        guard ScreenCodeIdentity.isBundled(driverURL, inside: hostBundleURL) else { return false }
        if upstreamIdentityVerified {
            return true
        }
        guard case let .appleDeveloperID(_, hostTeam) = hostIdentity,
              case let .appleDeveloperID(identifier, driverTeam) = driverIdentity,
              !hostTeam.isEmpty,
              identifier == "cua-driver",
              !driverTeam.isEmpty,
              driverTeam == hostTeam else {
            return false
        }
        return true
    }

    private static func bundledConfiguration(
        _ bundledURL: URL?,
        hostBundleURL: URL,
        hostBundleID: String,
        capabilityManifestURL: URL,
        fileManager: FileManager,
        identityVerifier: (URL) -> Bool,
        codeIdentityReader: (URL) -> ScreenCodeIdentity?
    ) -> CuaDriverConfiguration? {
        guard let bundledURL else { return nil }
        let executableURL = bundledURL.resolvingSymlinksInPath().standardizedFileURL
        guard fileManager.isExecutableFile(atPath: executableURL.path),
              ScreenCodeIdentity.isBundled(executableURL, inside: hostBundleURL) else {
            return nil
        }
        let upstreamIdentityVerified = identityVerifier(executableURL)
        let hostIdentity = upstreamIdentityVerified ? nil : codeIdentityReader(hostBundleURL)
        let driverIdentity = upstreamIdentityVerified ? nil : codeIdentityReader(executableURL)
        guard bundledDriverIsAllowed(
            driverURL: executableURL,
            hostBundleURL: hostBundleURL,
            upstreamIdentityVerified: upstreamIdentityVerified,
            hostIdentity: hostIdentity,
            driverIdentity: driverIdentity
        ) else {
            return nil
        }
        return CuaDriverConfiguration(
            executableURL: executableURL,
            capabilityManifestURL: capabilityManifestURL,
            hostBundleID: hostBundleID
        )
    }
}
