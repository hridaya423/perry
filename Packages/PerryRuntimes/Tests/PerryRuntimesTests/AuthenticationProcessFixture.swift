import Foundation

final class AuthenticationProcessFixture: Sendable {
    static let seededSecret = "perry-auth-fixture-secret-7f2a"

    let executable: URL
    let codexHome: URL

    private let directory: URL
    private let launchMarker: URL

    init(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0,
        waitsForCancellation: Bool = false
    ) throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("perry-auth-process-\(UUID().uuidString)", isDirectory: true)
        self.directory = directory
        self.launchMarker = directory.appendingPathComponent("launched")
        self.executable = directory.appendingPathComponent("cli-fixture")
        self.codexHome = directory.appendingPathComponent("codex-home", isDirectory: true)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
            var script = "#!/bin/sh\nset -eu\nprintf '%s\\n' launched > \(Self.shellLiteral(launchMarker.path))\n"
            if !stdout.isEmpty {
                script += "printf '%s\\n' \(Self.shellLiteral(stdout))\n"
            }
            if !stderr.isEmpty {
                script += "printf '%s\\n' \(Self.shellLiteral(stderr)) >&2\n"
            }
            if waitsForCancellation {
                script += "trap 'exit 0' TERM INT\nwhile :; do /bin/sleep 0.01; done\n"
            } else {
                script += "exit \(exitCode)\n"
            }
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        } catch {
            try fileManager.removeItem(at: directory)
            throw error
        }
    }

    var wasLaunched: Bool {
        FileManager.default.fileExists(atPath: launchMarker.path)
    }

    func waitUntilLaunched(timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !wasLaunched && Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: 5_000_000)
            } catch {
                return false
            }
        }
        return wasLaunched
    }

    func cleanup() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private static func shellLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
