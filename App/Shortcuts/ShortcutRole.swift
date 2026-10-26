import PerryCore

enum ShortcutRole: String, CaseIterable, Identifiable {
    case talk
    case type
    case dictate
    case wake

    var id: String { rawValue }

    var title: String {
        switch self {
        case .talk: "Talk"
        case .type: "Type"
        case .dictate: "Dictate"
        case .wake: "Wake"
        }
    }

    var ownerName: String {
        switch self {
        case .talk: "talk shortcut"
        case .type: "typing shortcut"
        case .dictate: "dictation shortcut"
        case .wake: "wake shortcut"
        }
    }

    var defaultGesture: Gesture {
        switch self {
        case .talk: .defaultTalk
        case .type: .defaultType
        case .dictate: .defaultDictate
        case .wake: .defaultWake
        }
    }

    var presets: [Gesture] {
        switch self {
        case .talk:
            [.hold([.function]), .hold([.option, .rightOption]), .defaultTalk]
        case .type:
            [.defaultType, .doubleTap([.option]), .doubleTap([.command])]
        case .dictate:
            [.defaultDictate, .chord([.option, .command], keyCode: 49), .doubleTap([.capsLock]), .hold([.control, .option, .command])]
        case .wake:
            [.defaultWake, .chord([.option, .command], keyCode: 31), .chord([.control, .command], keyCode: 35), .chord([.control, .command], keyCode: 31)]
        }
    }

    var saved: Gesture {
        get {
            switch self {
            case .talk: PerryPreferences.talkGesture
            case .type: PerryPreferences.typeGesture
            case .dictate: PerryPreferences.dictateGesture
            case .wake: PerryPreferences.wakeGesture
            }
        }
        nonmutating set {
            switch self {
            case .talk: PerryPreferences.talkGesture = newValue
            case .type: PerryPreferences.typeGesture = newValue
            case .dictate: PerryPreferences.dictateGesture = newValue
            case .wake: PerryPreferences.wakeGesture = newValue
            }
        }
    }

    static var current: [ShortcutRole: Gesture] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.saved) })
    }

    func label(for gesture: Gesture) -> String {
        if self == .dictate, case .chord = gesture { return "Hold \(gesture.keys)" }
        return gesture.spoken
    }

    func owners(gestures: [ShortcutRole: Gesture]) -> [ShortcutCapture.Owner] {
        Self.allCases.filter { $0 != self }.compactMap { other in
            gestures[other].map { .init(gesture: $0, name: other.ownerName) }
        }
    }

    func capture(gestures: [ShortcutRole: Gesture], hotkeys: [SymbolicHotkey]) -> ShortcutCapture {
        var capture = ShortcutCapture(saved: gestures[self] ?? defaultGesture, defaultGesture: defaultGesture)
        switch self {
        case .talk:
            capture.allowsChords = false
        case .type:
            capture.allowsChords = false
            capture.modifierKind = .doubleTap
        case .dictate:
            break
        case .wake:
            capture.modifierKind = .unsupported
        }
        capture.perryOwners = owners(gestures: gestures)
        capture.systemHotkeys = hotkeys
        return capture
    }
}
