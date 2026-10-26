import AppKit
import PerryCore
import SwiftUI

struct ShortcutCapture: Equatable {
    enum State: Equatable {
        case idle
        case recording
        case captured(Gesture)
        case conflict(Gesture, owner: String)
        case rejected(Gesture, owner: String)
    }

    struct Owner: Equatable {
        let gesture: Gesture
        let name: String
    }

    static let reserved: [Owner] = [
        Owner(gesture: .chord([.command], keyCode: 49), name: "Spotlight"),
        Owner(gesture: .chord([.command, .control], keyCode: 3), name: "macOS full screen"),
    ]

    static let knownApps: [Owner] = [
        Owner(gesture: .chord([.option], keyCode: 49), name: "Raycast and Alfred"),
        Owner(gesture: .chord([.command, .shift], keyCode: 49), name: "many launchers"),
        Owner(gesture: .hold([.function]), name: "the macOS fn key setting (Dictation or emoji)"),
    ]

    private(set) var state: State = .idle
    private(set) var saved: Gesture
    let defaultGesture: Gesture
    var allowsChords = true
    var perryOwners: [Owner] = []
    var systemHotkeys: [SymbolicHotkey] = []
    private var held: ModifierSet = []

    init(saved: Gesture, defaultGesture: Gesture) {
        self.saved = saved
        self.defaultGesture = defaultGesture
    }

    mutating func begin() {
        state = .recording
        held = []
    }

    mutating func flagsChanged(_ modifiers: ModifierSet) {
        guard state == .recording else { return }
        if modifiers.isEmpty {
            guard !held.isEmpty else { return }
            let gesture = Gesture.hold(held)
            held = []
            evaluate(gesture)
        } else {
            held.formUnion(modifiers)
        }
    }

    mutating func keyDown(_ keyCode: UInt16, modifiers: ModifierSet) {
        guard state == .recording else { return }
        held = []
        switch keyCode {
        case 53 where modifiers.isEmpty:
            state = .idle
        case 51 where modifiers.isEmpty:
            saved = defaultGesture
            state = .captured(defaultGesture)
        default:
            guard allowsChords, !modifiers.isEmpty else { return }
            evaluate(.chord(modifiers, keyCode: keyCode))
        }
    }

    mutating func cancel() {
        state = .idle
        held = []
    }

    mutating func useAnyway() {
        guard case .conflict(let gesture, _) = state else { return }
        saved = gesture
        state = .captured(gesture)
    }

    mutating func pickAnother() {
        begin()
    }

    mutating func choose(_ gesture: Gesture) {
        state = .recording
        evaluate(gesture)
    }

    private mutating func evaluate(_ gesture: Gesture) {
        if case .hold(let set) = gesture, !(1...3).contains(set.subtracting(set.contains(.rightOption) ? .option : []).count) {
            state = .recording
            return
        }
        if let owner = Self.reserved.first(where: { $0.gesture == gesture }) {
            state = .rejected(gesture, owner: owner.name)
            return
        }
        if let owner = conflictOwner(for: gesture) {
            state = .conflict(gesture, owner: owner)
            return
        }
        saved = gesture
        state = .captured(gesture)
    }

    private func conflictOwner(for gesture: Gesture) -> String? {
        if let owner = perryOwners.first(where: { $0.gesture == gesture }) { return "Perry’s \(owner.name)" }
        if case .chord(let set, let key) = gesture,
           SymbolicHotkeys.conflicts(keyCode: Int(key), modifiers: set.symbolicBits, in: systemHotkeys) {
            return "a macOS keyboard shortcut"
        }
        return Self.knownApps.first { $0.gesture == gesture }?.name
    }
}

private extension ModifierSet {
    var count: Int { [ModifierSet.control, .option, .command, .shift, .function, .rightOption].filter(contains).count }

    var symbolicBits: Int {
        (contains(.shift) ? 0x20000 : 0) | (contains(.control) ? 0x40000 : 0)
            | (contains(.option) ? 0x80000 : 0) | (contains(.command) ? 0x100000 : 0)
    }
}

struct ShortcutRecorder: View {
    let title: String
    @Binding var capture: ShortcutCapture
    var presets: [Gesture] = []
    var onSave: (Gesture) -> Void = { _ in }
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(title)
                    .font(PerryTheme.Scale.rowTitle)
                    .foregroundStyle(PerryTheme.Colors.text)
                Spacer(minLength: 8)
                Button(action: toggle) {
                    Text(pillText)
                        .font(PerryTheme.Scale.keycap)
                        .foregroundStyle(capture.state == .recording ? PerryTheme.Colors.textSecondary : PerryTheme.Colors.text)
                        .padding(.horizontal, 14)
                        .frame(minWidth: 120, minHeight: 30)
                        .background(PerryTheme.Colors.chip, in: Capsule())
                        .overlay(Capsule().strokeBorder(capture.state == .recording ? PerryTheme.Colors.accent : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title) shortcut, \(pillText)")
                .accessibilityHint(capture.state == .recording ? "Press the keys. Escape cancels, Delete resets." : "Records a new shortcut")
            }
            switch capture.state {
            case .conflict(_, let owner):
                HStack(spacing: 8) {
                    Text("\(owner) already uses this.")
                        .foregroundStyle(PerryTheme.Colors.caution)
                    Spacer(minLength: 8)
                    Button("Pick another") { capture.pickAnother() }
                    Button("Use anyway") {
                        capture.useAnyway()
                        onSave(capture.saved)
                    }
                }
                .font(PerryTheme.Scale.secondary)
                .buttonStyle(.plain)
                .foregroundStyle(PerryTheme.Colors.accent)
            case .rejected(let gesture, let owner):
                Text("\(gesture.keys) belongs to \(owner). Pick another.")
                    .font(PerryTheme.Scale.secondary)
                    .foregroundStyle(PerryTheme.Colors.caution)
            case .idle, .recording, .captured:
                EmptyView()
            }
            if !presets.isEmpty {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { preset in
                        Button(preset.spoken) { choose(preset) }
                            .buttonStyle(PresetChipStyle(selected: capture.saved == preset))
                    }
                    Button("Custom…", action: toggle)
                        .buttonStyle(PresetChipStyle(selected: !presets.contains(capture.saved)))
                }
            }
        }
        .onDisappear(perform: stopListening)
    }

    private var pillText: String {
        switch capture.state {
        case .recording: capture.allowsChords ? "Press the keys…" : "Hold the keys…"
        case .conflict(let gesture, _), .rejected(let gesture, _): gesture.keys
        case .idle, .captured: capture.saved.keys
        }
    }

    private func choose(_ gesture: Gesture) {
        stopListening()
        capture.choose(gesture)
        if case .captured(let saved) = capture.state { onSave(saved) }
    }

    private func toggle() {
        if capture.state == .recording {
            stopListening()
            capture.cancel()
        } else {
            capture.begin()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
                let modifiers = ModifierSet(event.modifierFlags)
                if event.type == .keyDown {
                    capture.keyDown(event.keyCode, modifiers: modifiers)
                } else {
                    capture.flagsChanged(modifiers)
                }
                if capture.state != .recording {
                    stopListening()
                    if case .captured(let saved) = capture.state { onSave(saved) }
                }
                return nil
            }
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct PresetChipStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PerryTheme.Scale.meta)
            .foregroundStyle(selected ? PerryTheme.Colors.onAccent : PerryTheme.Colors.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(selected ? PerryTheme.Colors.accent : PerryTheme.Colors.chip.opacity(configuration.isPressed ? 0.7 : 1)))
    }
}
