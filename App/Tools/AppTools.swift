import AppKit
import PerryBrain

struct AppTools {
    var executors: [any ToolExecutor] { [LaunchTool()] }

    private struct LaunchTool: ToolExecutor {
        let spec = ToolSpec(
            name: "app.launch",
            description: "Launch or activate an app by name or bundle identifier.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object(["type": .string("string")]),
                    "bundleID": .object(["type": .string("string")]),
                ]),
            ]),
            tier: .yellow,
            surfaces: [.agent]
        )

        func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            let name = call.arguments["name"]?.stringValue
            let bundleID = call.arguments["bundleID"]?.stringValue
            guard name != nil || bundleID != nil else {
                return .text(call.id, "app.launch: pass a name or bundleID", isError: true)
            }
            let resolved = await MainActor.run {
                bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                    ?? name.flatMap(Self.findApp(named:))
            }
            guard let resolved else {
                return .text(call.id, "app.launch: no app matches", isError: true)
            }
            do {
                let app = try await NSWorkspace.shared.openApplication(at: resolved, configuration: .init())
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while !Self.hasWindow(app.processIdentifier), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                return .text(call.id, #"{"launched":"\#(resolved.deletingPathExtension().lastPathComponent)","bundleID":"\#(app.bundleIdentifier ?? "")"}"#)
            } catch {
                return .text(call.id, "app.launch failed: \(error.localizedDescription)", isError: true)
            }
        }

        private static func hasWindow(_ pid: pid_t) -> Bool {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            return windows.contains { $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0 }
        }

        private static func findApp(named name: String) -> URL? {
            let query = name.lowercased()
            let dirs = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
            for dir in dirs {
                guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
                for entry in entries where entry.hasSuffix(".app") {
                    let stem = entry.dropLast(4).lowercased()
                    if stem == query || stem.contains(query) {
                        return URL(fileURLWithPath: dir).appendingPathComponent(entry)
                    }
                }
            }
            return nil
        }
    }
}
