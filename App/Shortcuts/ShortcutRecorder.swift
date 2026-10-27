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

    enum ModifierKind {
        case hold
        case doubleTap
        case unsupported
    }

    private(set) var state: State = .idle
    private(set) var saved: Gesture
    let defaultGesture: Gesture
    var allowsChords = true
    var modifierKind = ModifierKind.hold
    var perryOwners: [Owner] = []
    var systemHotkeys: [SymbolicHotkey] = []
    private var held: ModifierSet = []

    init(saved: Gesture, defaultGesture: Gesture) {
        self.saved = saved
        self.defaultGesture = defaultGesture
    }

    var prompt: String {
        if allowsChords { return "Press the keys…" }
        return modifierKind == .doubleTap ? "Tap the keys…" : "Hold the keys…"
    }

    mutating func begin() {
        state = .recording
        held = []
    }

    mutating func flagsChanged(_ modifiers: ModifierSet) {
        guard state == .recording else { return }
        if modifiers.isEmpty {
            guard !held.isEmpty else { return }
            let set = held
            held = []
            switch modifierKind {
            case .hold: evaluate(.hold(set))
            case .doubleTap: evaluate(.doubleTap(set))
            case .unsupported: break
            }
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
            evaluate(.chord(modifiers.withoutSide, keyCode: keyCode))
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
        switch gesture {
        case .hold(let set), .doubleTap(let set):
            if !(1...3).contains(set.subtracting(set.contains(.rightOption) ? .option : []).count) {
                state = .recording
                return
            }
        case .chord:
            break
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
        if gesture == saved { return nil }
        if let owner = perryOwners.first(where: { $0.gesture == gesture }) { return owner.name }
        if case .chord(let set, let key) = gesture,
           SymbolicHotkeys.conflicts(keyCode: Int(key), modifiers: set.symbolicBits, in: systemHotkeys) {
            return "a macOS keyboard shortcut"
        }
        return Self.knownApps.first { $0.gesture == gesture }?.name
    }
}

private extension ModifierSet {
    var count: Int { [ModifierSet.control, .option, .command, .shift, .function, .rightOption, .capsLock].filter(contains).count }

    var symbolicBits: Int {
        (contains(.shift) ? 0x20000 : 0) | (contains(.control) ? 0x40000 : 0)
            | (contains(.option) ? 0x80000 : 0) | (contains(.command) ? 0x100000 : 0)
    }
}

struct ShortcutRecorder: View {
    let title: String
    @Binding var capture: ShortcutCapture
    var presets: [Gesture] = []
    var presetLabel: (Gesture) -> String = \.spoken
    var onSave: (Gesture) -> Void = { _ in }
    @MainActor static var recording = false
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
                .buttonStyle(.pressable)
                .accessibilityLabel("\(title) shortcut, \(pillText)")
                .accessibilityHint(capture.state == .recording ? "Press the keys. Escape cancels, Delete resets." : "Records a new shortcut")
            }
            switch capture.state {
            case .conflict(_, let owner):
                HStack(spacing: 8) {
                    Text("\(owner) already uses this.")
                        .foregroundStyle(PerryTheme.Colors.caution)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Pick another") { capture.pickAnother() }
                        .fixedSize()
                    Button("Use anyway") {
                        capture.useAnyway()
                        onSave(capture.saved)
                    }
                    .fixedSize()
                }
                .font(PerryTheme.Scale.secondary)
                .buttonStyle(.pressable)
                .foregroundStyle(PerryTheme.Colors.accent)
            case .rejected(let gesture, let owner):
                Text("\(gesture.keys) is taken by \(owner). Pick another.")
                    .font(PerryTheme.Scale.secondary)
                    .foregroundStyle(PerryTheme.Colors.caution)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle, .recording, .captured:
                EmptyView()
            }
            if !presets.isEmpty {
                WrappingRow(spacing: 6) {
                    ForEach(presets, id: \.self) { preset in
                        Button(presetLabel(preset)) { choose(preset) }
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
        case .recording: capture.prompt
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
            Self.recording = true
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
        Self.recording = false
    }
}

private struct WrappingRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrange(width: bounds.width, subviews).origins
        for (subview, origin) in zip(subviews, origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width
            widest = max(widest, x)
            x += spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, CGSize(width: widest, height: y + rowHeight))
    }
}

private struct PresetChipStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PerryTheme.Scale.meta)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(selected ? PerryTheme.Colors.onAccent : PerryTheme.Colors.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(selected ? PerryTheme.Colors.accent : PerryTheme.Colors.chip.opacity(configuration.isPressed ? 0.7 : 1)))
            .controlFeedback(Capsule())
    }
}
