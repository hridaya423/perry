import Foundation

public struct SymbolicHotkey: Equatable, Sendable {
    public let keyCode: Int
    public let modifiers: Int

    public init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

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

    public static func conflicts(keyCode: Int, modifiers: Int, in entries: [SymbolicHotkey]) -> Bool {
        entries.contains { $0.keyCode == keyCode && $0.modifiers == modifiers }
    }
}
