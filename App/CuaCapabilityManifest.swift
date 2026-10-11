import AppKit
import Foundation
import PerryCore

/// Plan §6.5: driver 0.22.1 has no `any` app mode, so the capability ceiling is
/// generated at each worker spawn from installed and running apps minus the
/// TrustGuard blocklist, and `Refresher` rewrites it when an app the last scan
/// didn't cover launches. TrustGuard still gates every capture at runtime; this
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

    /// Installed (each application directory plus one level of folders, e.g.
    /// /Applications/Utilities) and running bundle IDs, before the blocklist.
    static func scannedBundleIDs(
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

    /// Rewrites the manifest when an app the last scan didn't cover launches,
    /// so the next worker spawn can reach it (plan Phase 2 item 9).
    /// Scans and rewrites run off the main actor, one at a time; the worker
    /// spawn already materializes, so starting only learns what is covered.
    @MainActor
    final class Refresher {
        private let directory: URL
        private let hostBundleID: String
        private let coveredBundleIDs: @Sendable () -> Set<String>
        private let materialize: @Sendable (URL, String) -> URL?
        private let notificationCenter: NotificationCenter
        private var covered: Set<String>?
        private var observer: NSObjectProtocol?
        private var queuedLaunches: Set<String> = []
        /// The scan or rewrite in flight, if any.
        private(set) var pending: Task<Void, Never>?

        init(
            directory: URL,
            hostBundleID: String,
            notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
            coveredBundleIDs: @escaping @Sendable () -> Set<String> = { CuaCapabilityManifest.scannedBundleIDs() },
            materialize: @escaping @Sendable (URL, String) -> URL? = {
                CuaCapabilityManifest.materialize(into: $0, hostBundleID: $1)
            }
        ) {
            self.directory = directory
            self.hostBundleID = hostBundleID
            self.notificationCenter = notificationCenter
            self.coveredBundleIDs = coveredBundleIDs
            self.materialize = materialize
        }

        deinit {
            if let observer { notificationCenter.removeObserver(observer) }
        }

        func start() {
            guard observer == nil else { return }
            observer = notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                Task { @MainActor in
                    guard let self, let bundleID else { return }
                    self.noteLaunch(of: bundleID)
                }
            }
            run(rewrite: false)
        }

        /// Skips launches the last scan already covered — blocked apps were
        /// scanned and stay denied, allowed apps are already in the manifest.
        func noteLaunch(of bundleID: String) {
            guard covered?.contains(bundleID) != true else { return }
            guard pending == nil else {
                queuedLaunches.insert(bundleID)
                return
            }
            run(rewrite: true)
        }

        private func run(rewrite: Bool) {
            let scan = coveredBundleIDs, write = materialize
            let directory = directory, hostBundleID = hostBundleID
            pending = Task { [weak self] in
                let scanned = await Task.detached {
                    let scanned = scan()
                    if rewrite { _ = write(directory, hostBundleID) }
                    return scanned
                }.value
                guard let self else { return }
                covered = scanned
                pending = nil
                // A launch during a scan-only pass may postdate the manifest
                // on disk; after a rewrite only what that scan missed counts.
                let missed = rewrite ? queuedLaunches.subtracting(scanned) : queuedLaunches
                queuedLaunches = []
                if !missed.isEmpty { run(rewrite: true) }
            }
        }
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
