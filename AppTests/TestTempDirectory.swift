import Foundation

enum TestTempDirectory {
    static func remove(_ url: URL) throws {
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
