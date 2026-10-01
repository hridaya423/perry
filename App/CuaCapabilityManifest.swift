import AppKit
import Foundation
import PerryCore

/// Plan §6.5: driver 0.22.1 has no `any` app mode, so the capability ceiling is
/// generated at each worker spawn from installed and running apps minus the
/// TrustGuard blocklist. TrustGuard still gates every capture at runtime; this
/// manifest is only the driver's deny-by-default ceiling.
enum CuaCapabilityManifest {
    static let toolAllowList: [String] = [
        "check_permissions",
        "start_session", "get_session_state", "end_session",
        "list_apps", "list_windows", "get_window_state", "get_desktop_state",
        "get_cursor_position", "zoom",
        "click", "right_click", "double_click", "scroll",
        "type_text", "press_key", "hotkey", "drag", "set_value",
        "invoke_menu", "verify_state", "launch_app",
        "clipboard_read", "clipboard_write",
        "get_browser_state",
        "browser_click", "browser_dialog", "browser_download", "browser_navigate",
        "browser_pointer", "browser_prepare",
        "browser_set_input_files", "browser_type",
    ]

    static func materialize(
        into directory: URL,
        hostBundleID: String,
        blockedBundleIDs: Set<String> = TrustGuard.defaultBlockedBundleIDs,
        applicationDirectories: [URL] = Self.applicationDirectories(),
        extraBundleIDs: Set<String> = Self.runningBundleIDs(),
        fileManager: FileManager = .default
    ) -> URL? {
        var bundleIDs = extraBundleIDs
        for directory in applicationDirectories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries where entry.pathExtension == "app" {
                if let bundleID = Bundle(url: entry)?.bundleIdentifier {
                    bundleIDs.insert(bundleID)
                }
            }
        }
        bundleIDs.remove(hostBundleID)
        let blocked = Set(blockedBundleIDs.map { $0.lowercased() })
        let allowed = bundleIDs.filter { !blocked.contains($0.lowercased()) }.sorted()
        guard !allowed.isEmpty else { return nil }

        var yaml = "version: 3\nexpires_after: 8h\nidle_timeout: 30m\n\nallow:\n  tools:\n"
        for tool in toolAllowList {
            yaml += "    - \(tool)\n"
        }
        yaml += "\nresources:\n  desktop:\n    display: true\n\n  apps:\n"
        for bundleID in allowed {
            yaml += "    - bundle_id: \(escaped(bundleID))\n      launch: true\n      windows: all\n      terminate: deny\n"
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("capabilities.yaml")
            try yaml.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func applicationDirectories() -> [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications"),
        ]
    }

    private static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    private static func escaped(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
