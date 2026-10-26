import AppKit
import Carbon.HIToolbox

extension Gesture {
    var carbonHotkey: (keyCode: UInt32, modifiers: UInt32)? {
        guard case .chord(let set, let key) = self else { return nil }
        var modifiers = 0
        if set.contains(.control) { modifiers |= controlKey }
        if set.contains(.option) { modifiers |= optionKey }
        if set.contains(.shift) { modifiers |= shiftKey }
        if set.contains(.command) { modifiers |= cmdKey }
        guard modifiers != 0 else { return nil }
        return (UInt32(key), UInt32(modifiers))
    }
}

final class HotkeyController {
    private var eventHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: () -> Void
    private let hotKeyID: EventHotKeyID
    private(set) var modifiers: UInt32
    private(set) var keyCode: UInt32

    init(
        modifiers: UInt32 = UInt32(optionKey | cmdKey),
        keyCode: UInt32 = UInt32(kVK_ANSI_P),
        id: UInt32 = 1,
        handler: @escaping () -> Void
    ) throws {
        self.handler = handler
        self.hotKeyID = EventHotKeyID(signature: OSType(0x50455252), id: id)
        self.modifiers = modifiers
        self.keyCode = keyCode
        try install(modifiers: modifiers, keyCode: keyCode)
    }

    deinit {
        uninstall()
    }

    private func install(modifiers: UInt32, keyCode: UInt32) throws {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let controller = Unmanaged<HotkeyController>.fromOpaque(userData).takeUnretainedValue()
                var receivedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedID
                )
                guard status == noErr, receivedID.id == controller.hotKeyID.id else { return noErr }
                controller.handler()
                return noErr
            },
            1,
            &eventType,
            context,
            &eventHandler
        )
        guard handlerStatus == noErr else {
            throw HotkeyError.eventHandler(status: handlerStatus)
        }

        do {
            try register(modifiers: modifiers, keyCode: keyCode)
        } catch {
            if let eventHandler {
                RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
            throw error
        }
    }

    func update(modifiers: UInt32, keyCode: UInt32) throws {
        let previousModifiers = self.modifiers
        let previousKeyCode = self.keyCode
        if let eventHotKeyRef {
            UnregisterEventHotKey(eventHotKeyRef)
            self.eventHotKeyRef = nil
        }
        do {
            try register(modifiers: modifiers, keyCode: keyCode)
            self.modifiers = modifiers
            self.keyCode = keyCode
        } catch {
            do {
                try register(modifiers: previousModifiers, keyCode: previousKeyCode)
            } catch {
                throw HotkeyError.restoration
            }
            throw error
        }
    }

    private func register(modifiers: UInt32, keyCode: UInt32) throws {
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &eventHotKeyRef
        )
        guard status == noErr, eventHotKeyRef != nil else {
            eventHotKeyRef = nil
            throw HotkeyError.registration(status: status)
        }
    }

    func uninstall() {
        if let ref = eventHotKeyRef {
            UnregisterEventHotKey(ref)
            eventHotKeyRef = nil
        }
        if let handlerRef = eventHandler {
            RemoveEventHandler(handlerRef)
            eventHandler = nil
        }
    }

    enum HotkeyError: LocalizedError {
        case eventHandler(status: OSStatus)
        case registration(status: OSStatus)
        case restoration
        case needsModifier

        var errorDescription: String? {
            switch self {
            case .eventHandler(let status):
                return "macOS could not install Perry's shortcut handler (\(status))."
            case .registration(let status):
                return "That shortcut could not be registered (\(status)). Choose another shortcut."
            case .restoration:
                return "Perry could not restore the previous shortcut. Choose a wake shortcut to try again."
            case .needsModifier:
                return "The wake shortcut needs ⌃, ⌥, ⇧ or ⌘ together with a key. Choose another shortcut."
            }
        }
    }
}
