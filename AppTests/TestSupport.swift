import Foundation
import PerryGuide
import XCTest
@testable import Perry

enum TestTempDirectory {
    static func remove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var lastError: Error = CocoaError(.fileNoSuchFile)
        for _ in 0..<40 {
            do {
                try FileManager.default.removeItem(at: url)
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.025)
            }
        }
        throw lastError
    }
}

extension XCTestCase {
    func restoreDefaultsAfterTest(_ keys: [String], clearing: Bool = true) {
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        if clearing { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        addTeardownBlock {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor
    func pollUntil(_ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try TestTempDirectory.remove(directory) }
        return directory
    }
}

extension AppController {
    static func testing(
        directory: URL,
        session: SessionController? = nil,
        overrides configure: (inout LaunchOverrides) -> Void = { _ in }
    ) -> AppController {
        var overrides = LaunchOverrides()
        overrides.storageDirectory = directory
        overrides.guidePlanner = AXGuidePlanner()
        configure(&overrides)
        return AppController(sessionController: session ?? SessionController(), overrides: overrides)
    }
}

@MainActor
extension SessionController {
    private func invokingAttemptID() throws -> UUID {
        guard case .invoking(let invocation) = state else {
            throw IllegalSessionTransitionError(state: state, operation: "start invocation")
        }
        return invocation.id
    }

    func startGuide(_ guide: GuideSessionState) throws {
        try startGuide(guide, attemptID: try invokingAttemptID())
    }

    func startExecution(_ execution: ExecutionSessionState) throws {
        try startExecution(execution, attemptID: try invokingAttemptID())
    }

    func startAsk(_ ask: AskSessionState) throws {
        try startAsk(ask, attemptID: try invokingAttemptID())
    }
}
