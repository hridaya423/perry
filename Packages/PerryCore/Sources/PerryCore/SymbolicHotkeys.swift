import Foundation

/// One enabled system shortcut from com.apple.symbolichotkeys.plist.
/// `modifiers` uses Apple's plist encoding: shift = 0x20000,
/// control = 0x40000, option = 0x80000, command = 0x100000.
public struct SymbolicHotkey: Equatable, Sendable {
    public let keyCode: Int
    public let modifiers: Int

    public init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Reads the macOS system shortcut table so Perry can warn when one of its
/// own chords collides (⌥⌘Space is claimed by Spotlight's Finder search).
public enum SymbolicHotkeys {
    public static func entries(from plist: [String: Any]) -> [SymbolicHotkey] {
        guard let hotkeys = plist["AppleSymbolicHotKeys"] as? [String: Any] else { return [] }
        return hotkeys.values.compactMap { raw in
            guard let entry = raw as? [String: Any],
                  let enabled = entry["enabled"] as? Int, enabled != 0,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Int], parameters.count >= 3
            else { return nil }
            return SymbolicHotkey(keyCode: parameters[1], modifiers: parameters[2])
        }
    }

    public static func load(
        url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.symbolichotkeys.plist")
    ) -> [SymbolicHotkey] {
        guard let plist = NSDictionary(contentsOf: url) as? [String: Any] else { return [] }
        return entries(from: plist)
    }

    /// A chord conflicts when an enabled system hotkey uses the same
    /// keyCode + modifier bits — macOS eats the event before Perry sees it.
    public static func conflicts(keyCode: Int, modifiers: Int, in entries: [SymbolicHotkey]) -> Bool {
        entries.contains { $0.keyCode == keyCode && $0.modifiers == modifiers }
    }
}
