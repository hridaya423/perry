import CryptoKit
import Foundation

public struct AcpRegistryEntry: Sendable, Equatable, Identifiable {
    public enum Distribution: Sendable, Equatable {
        case package(launcher: String, package: String, arguments: [String], environment: [String: String])
        case binary(archive: URL, sha256: String?, command: String, arguments: [String], environment: [String: String])
    }

    public let id: String
    public let name: String
    public let version: String
    public let summary: String
    public let distributions: [Distribution]

    public enum Availability: Sendable, Equatable {
        case ready(AcpAgent)
        case download(archive: URL, sha256: String, command: String, arguments: [String], environment: [String: String])
        case unavailable(String)
    }

    public func availability(launcher: (String) -> URL?) -> Availability {
        var reasons: [String] = []
        for distribution in distributions {
            switch distribution {
            case .package(let tool, let package, let arguments, let environment):
                guard let executable = launcher(tool) else {
                    reasons.append(tool == "npx" ? "Needs Node.js (npx)." : "Needs uv (uvx).")
                    continue
                }
                let prefix = tool == "npx" ? ["-y", package] : [package]
                return .ready(AcpAgent(id: "registry.\(id)", name: name, command: executable.path, arguments: prefix + arguments, environment: environment))
            case .binary(let archive, let sha256, let command, let arguments, let environment):
                guard let sha256, !sha256.isEmpty else {
                    reasons.append("The registry gives no checksum, so Perry won’t download it.")
                    continue
                }
                return .download(archive: archive, sha256: sha256, command: command, arguments: arguments, environment: environment)
            }
        }
        return .unavailable(reasons.first ?? "No build for this Mac.")
    }
}

public enum AcpRegistry {
    public static let url = URL(string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json")!

    public static func fetch(session: URLSession = .shared) async throws -> [AcpRegistryEntry] {
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 15))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return parse(data)
    }

    public static func parse(_ data: Data) -> [AcpRegistryEntry] {
        guard let payload = try? JSONValue(parsing: data) else { return [] }
        return (payload["agents"]?.arrayValue ?? []).compactMap { agent in
            guard let id = agent["id"]?.stringValue, let name = agent["name"]?.stringValue,
                  let distribution = agent["distribution"] else { return nil }
            var distributions: [AcpRegistryEntry.Distribution] = []
            for tool in ["npx", "uvx"] {
                guard let entry = distribution[tool], let package = entry["package"]?.stringValue else { continue }
                distributions.append(.package(launcher: tool, package: package, arguments: strings(entry["args"]), environment: environment(entry["env"])))
            }
            if let mac = distribution["binary"]?["darwin-aarch64"],
               let archive = mac["archive"]?.stringValue.flatMap(URL.init(string:)), archive.scheme == "https",
               let command = mac["cmd"]?.stringValue {
                distributions.append(.binary(archive: archive, sha256: mac["sha256"]?.stringValue, command: command, arguments: strings(mac["args"]), environment: environment(mac["env"])))
            }
            guard !distributions.isEmpty else { return nil }
            return AcpRegistryEntry(
                id: id, name: name, version: agent["version"]?.stringValue ?? "",
                summary: agent["description"]?.stringValue ?? "", distributions: distributions
            )
        }
    }

    public static func install(
        _ entry: AcpRegistryEntry, archive: URL, sha256: String, command: String, arguments: [String],
        environment: [String: String], into root: URL, session: URLSession = .shared
    ) async throws -> AcpAgent {
        guard isSafeComponent(entry.id), isSafeComponent(entry.version.isEmpty ? "current" : entry.version) else {
            throw AcpInstallError.unsafeName
        }
        let (downloaded, response) = try await session.download(for: URLRequest(url: archive, timeoutInterval: 120))
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let digest = SHA256.hash(data: try Data(contentsOf: downloaded, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256.lowercased() else { throw AcpInstallError.checksumMismatch }

        let directory = root.appendingPathComponent(entry.id, isDirectory: true)
            .appendingPathComponent(entry.version.isEmpty ? "current" : entry.version, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xf", downloaded.path, "-C", directory.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw AcpInstallError.unpackFailed }

        let executable = directory.appendingPathComponent(command).resolvingSymlinksInPath()
        guard executable.path.hasPrefix(directory.resolvingSymlinksInPath().path + "/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw AcpInstallError.missingCommand }
        return AcpAgent(id: "registry.\(entry.id)", name: entry.name, command: executable.path, arguments: arguments, environment: environment)
    }

    static func isSafeComponent(_ value: String) -> Bool {
        value != "." && value != ".." && !value.isEmpty
            && value.range(of: "^[A-Za-z0-9._+-]+$", options: .regularExpression) != nil
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private static func environment(_ value: JSONValue?) -> [String: String] {
        value?.objectValue?.compactMapValues(\.stringValue) ?? [:]
    }
}

public enum AcpInstallError: LocalizedError, Equatable {
    case checksumMismatch, unpackFailed, missingCommand, unsafeName

    public var errorDescription: String? {
        switch self {
        case .checksumMismatch: "The download didn’t match the registry’s checksum, so Perry deleted it."
        case .unpackFailed: "Perry couldn’t unpack the agent."
        case .missingCommand: "The agent’s program wasn’t where the registry said."
        case .unsafeName: "The registry entry has a name Perry can’t use as a folder."
        }
    }
}
