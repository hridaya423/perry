import AppKit
import PerryBrain

/// `app.launch` — opens an installed app by name or bundle id. Orange tier:
/// it foregrounds another app, which the user should see coming.
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
            tier: .orange,
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
                _ = try await NSWorkspace.shared.openApplication(at: resolved, configuration: .init())
                return .text(call.id, #"{"launched":"\#(resolved.deletingPathExtension().lastPathComponent)"}"#)
            } catch {
                return .text(call.id, "app.launch failed: \(error.localizedDescription)", isError: true)
            }
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
