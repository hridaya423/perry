import AppKit
import Foundation
import PerryCore

enum CuaCapabilityManifest {
    static let toolAllowList: [String] = [
        "check_permissions", "start_session", "end_session",
        "list_windows", "get_window_state",
        "click", "right_click", "double_click", "scroll",
        "type_text", "press_key", "hotkey", "drag", "set_value", "run_steps",
    ]

    static func materialize(
        into directory: URL,
        hostBundleID: String,
        blockedBundleIDs: Set<String> = TrustGuard.defaultBlockedBundleIDs,
        applicationDirectories: [URL] = Self.applicationDirectories(),
        extraBundleIDs: Set<String> = Self.runningBundleIDs(),
        fileManager: FileManager = .default
    ) -> URL? {
        var bundleIDs = scannedBundleIDs(
            applicationDirectories: applicationDirectories,
            extraBundleIDs: extraBundleIDs,
            fileManager: fileManager
        )
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

    private static func scannedBundleIDs(
        applicationDirectories: [URL] = Self.applicationDirectories(),
        extraBundleIDs: Set<String> = Self.runningBundleIDs(),
        fileManager: FileManager = .default
    ) -> Set<String> {
        var bundleIDs = extraBundleIDs
        for directory in applicationDirectories {
            for bundleURL in appBundles(under: directory, fileManager: fileManager) {
                if let bundleID = Bundle(url: bundleURL)?.bundleIdentifier {
                    bundleIDs.insert(bundleID)
                }
            }
        }
        return bundleIDs
    }

    private static func appBundles(under directory: URL, fileManager: FileManager) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var bundles = entries.filter { $0.pathExtension == "app" }
        for entry in entries where entry.pathExtension != "app" {
            guard let children = try? fileManager.contentsOfDirectory(
                at: entry,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            bundles.append(contentsOf: children.filter { $0.pathExtension == "app" })
        }
        return bundles
    }

    private static func applicationDirectories() -> [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
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
