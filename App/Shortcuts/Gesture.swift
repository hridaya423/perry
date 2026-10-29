import AppKit

struct ModifierSet: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let control = ModifierSet(rawValue: 1 << 0)
    static let option = ModifierSet(rawValue: 1 << 1)
    static let command = ModifierSet(rawValue: 1 << 2)
    static let shift = ModifierSet(rawValue: 1 << 3)
    static let function = ModifierSet(rawValue: 1 << 4)
    static let rightOption = ModifierSet(rawValue: 1 << 5)
    static let capsLock = ModifierSet(rawValue: 1 << 6)

    private static let rightOptionDeviceBit: UInt64 = 0x40
    private static let names: [(ModifierSet, String, String)] = [
        (.capsLock, "capsLock", "Caps Lock"),
        (.function, "fn", "fn"),
        (.control, "control", "⌃"),
        (.rightOption, "rightOption", "right ⌥"),
        (.option, "option", "⌥"),
        (.shift, "shift", "⇧"),
        (.command, "command", "⌘"),
    ]

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(_ flags: CGEventFlags) {
        var set: ModifierSet = []
        if flags.contains(.maskControl) { set.insert(.control) }
        if flags.contains(.maskAlternate) { set.insert(.option) }
        if flags.contains(.maskCommand) { set.insert(.command) }
        if flags.contains(.maskShift) { set.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { set.insert(.function) }
        if flags.rawValue & Self.rightOptionDeviceBit != 0 { set.insert(.rightOption) }
        self = set
    }

    init(_ flags: NSEvent.ModifierFlags) {
        self.init(CGEventFlags(rawValue: UInt64(flags.rawValue)))
    }

    var withoutSide: ModifierSet { subtracting(.rightOption) }

    var symbols: String {
        Self.names.filter { contains($0.0) && !($0.0 == .option && contains(.rightOption)) }.map(\.2).joined()
    }

    var token: String {
        Self.names.filter { contains($0.0) }.map(\.1).joined(separator: "+")
    }

    var words: String {
        let said: [(ModifierSet, String)] = [
            (.capsLock, "Caps Lock"), (.function, "Function"), (.control, "Control"), (.rightOption, "right Option"),
            (.option, "Option"), (.shift, "Shift"), (.command, "Command"),
        ]
        return said.filter { contains($0.0) && !($0.0 == .option && contains(.rightOption)) }.map(\.1).joined(separator: " and ")
    }

    init?(token: String) {
        var set: ModifierSet = []
        for part in token.split(separator: "+") {
            guard let match = Self.names.first(where: { $0.1 == part }) else { return nil }
            set.insert(match.0)
        }
        guard !set.isEmpty else { return nil }
        self = set
    }
}

enum Gesture: Equatable, Hashable, Sendable, RawRepresentable {
    case hold(ModifierSet)
    case chord(ModifierSet, keyCode: UInt16)
    case doubleTap(ModifierSet)

    static let defaultTalk = Gesture.hold([.control, .option])
    static let defaultType = Gesture.doubleTap([.control])
    static let defaultDictate = Gesture.hold([.function])
    static let defaultWake = Gesture.chord([.option, .command], keyCode: 35)

    init?(rawValue: String) {
        let parts = rawValue.split(separator: ":").map(String.init)
        switch (parts.first, parts.count) {
        case ("hold", 2):
            guard let set = ModifierSet(token: parts[1]) else { return nil }
            self = .hold(set)
        case ("doubleTap", 2):
            guard let set = ModifierSet(token: parts[1]) else { return nil }
            self = .doubleTap(set)
        case ("chord", 3):
            guard let set = ModifierSet(token: parts[1]), let key = UInt16(parts[2]) else { return nil }
            self = .chord(set, keyCode: key)
        default:
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .hold(let set): "hold:\(set.token)"
        case .doubleTap(let set): "doubleTap:\(set.token)"
        case .chord(let set, let key): "chord:\(set.token):\(key)"
        }
    }

    var holdModifiers: ModifierSet? {
        if case .hold(let set) = self { return set }
        return nil
    }

    var doubleTapModifiers: ModifierSet? {
        if case .doubleTap(let set) = self { return set }
        return nil
    }

    var keys: String {
        switch self {
        case .hold(let set): set.symbols
        case .doubleTap(let set): "2× \(set.symbols)"
        case .chord(let set, let key): set.symbols + KeyName.name(for: key)
        }
    }

    var said: String {
        switch self {
        case .hold(let set): "Hold \(set.words)"
        case .doubleTap(let set): "Double-tap \(set.words)"
        case .chord(let set, let key): "Press \(set.words) \(KeyName.name(for: key))"
        }
    }

    var spoken: String {
        switch self {
        case .hold(let set): "Hold \(set.symbols)"
        case .doubleTap(let set): "Double-tap \(set.symbols)"
        case .chord: "Press \(keys)"
        }
    }

    var releaseHint: String {
        switch self {
        case .hold(let set): "Release \(set.symbols) when you’re done"
        case .chord: "Release \(keys) when you’re done"
        case .doubleTap(let set): "Tap \(set.symbols) when you’re done"
        }
    }
}

enum KeyName {
    private static let names: [UInt16: String] = [
        49: "Space", 36: "Return", 53: "Esc", 48: "Tab",
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
        45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
    ]

    static func name(for keyCode: UInt16) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }
}
