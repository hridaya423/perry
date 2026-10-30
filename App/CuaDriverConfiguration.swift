import Foundation
import Security

enum CuaCodeIdentity: Sendable, Equatable {
    case appleDeveloperID(identifier: String, teamIdentifier: String)
    case unsignedOrAdHoc
}

struct CuaDriverConfiguration: Sendable {
    let executableURL: URL
    var capabilityManifestURL: URL
    let hostBundleID: String

    private static let driverRequirement = "identifier \"cua-driver\" and anchor apple generic and certificate leaf[subject.OU] = \"YCK386LBJ7\""
    private static let developerIDRequirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    static func discover(
        environment _: [String: String] = [:],
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        userDefaults: UserDefaults = .standard,
        identityVerifier: (URL) -> Bool = { verifyIdentity(at: $0) },
        codeIdentityReader: (URL) -> CuaCodeIdentity? = { readDeveloperIDIdentity(at: $0) }
    ) -> CuaDriverConfiguration? {
        let registeredURL = userDefaults.string(forKey: PerryPreferences.$cuaDriverPath.key).flatMap { value -> URL? in
            let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path)
        }
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
        guard isResolvedBundledPath(capabilityManifestURL, inside: hostBundleURL),
              fileManager.isReadableFile(atPath: capabilityManifestURL.path) else {
            return nil
        }
        let hostBundleID = bundle.bundleIdentifier ?? "dev.perry.Perry"

        if let registeredURL {
            let executableURL = registeredURL.resolvingSymlinksInPath().standardizedFileURL
            if fileManager.isExecutableFile(atPath: executableURL.path), identityVerifier(executableURL) {
                return CuaDriverConfiguration(
                    executableURL: executableURL,
                    capabilityManifestURL: capabilityManifestURL,
                    hostBundleID: hostBundleID
                )
            }
        }

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

    private static func readDeveloperIDIdentity(at url: URL) -> CuaCodeIdentity? {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(resolvedURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(developerIDRequirement as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(
                  staticCode,
                  SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate),
                  requirement
              ) == errSecSuccess else {
            return nil
        }
        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        ) == errSecSuccess,
              let signingInfo else {
            return nil
        }
        let values = signingInfo as NSDictionary
        guard let identifier = values[kSecCodeInfoIdentifier] as? String,
              !identifier.isEmpty,
              let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String,
              !teamIdentifier.isEmpty else {
            return nil
        }
        return .appleDeveloperID(identifier: identifier, teamIdentifier: teamIdentifier)
    }

    static func bundledDriverIsAllowed(
        driverURL: URL,
        hostBundleURL: URL,
        upstreamIdentityVerified: Bool,
        hostIdentity: CuaCodeIdentity?,
        driverIdentity: CuaCodeIdentity?
    ) -> Bool {
        guard isResolvedBundledPath(driverURL, inside: hostBundleURL) else { return false }
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
        codeIdentityReader: (URL) -> CuaCodeIdentity?
    ) -> CuaDriverConfiguration? {
        guard let bundledURL else { return nil }
        let executableURL = bundledURL.resolvingSymlinksInPath().standardizedFileURL
        guard fileManager.isExecutableFile(atPath: executableURL.path),
              isResolvedBundledPath(executableURL, inside: hostBundleURL) else {
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

    private static func isResolvedBundledPath(_ driverURL: URL, inside hostBundleURL: URL) -> Bool {
        let resolvedDriverURL = driverURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedHostBundleURL = hostBundleURL.resolvingSymlinksInPath().standardizedFileURL
        let hostComponents = resolvedHostBundleURL.pathComponents
        return resolvedDriverURL.pathComponents.count > hostComponents.count
            && resolvedDriverURL.pathComponents.starts(with: hostComponents)
    }
}
