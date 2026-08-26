import AppKit
import Carbon.HIToolbox

/// Global hotkey via RegisterEventHotKey. PRD §4: nothing happens without
/// the hotkey or an explicit opt-in wake word. Default: ⌥⌘P.
final class HotkeyController {
    private var eventHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: () -> Void
    private var retainedSelf: HotkeyController?

    init(modifiers: UInt32 = UInt32(optionKey | cmdKey), keyCode: UInt32 = UInt32(kVK_ANSI_P), handler: @escaping () -> Void) {
        self.handler = handler
        install(modifiers: modifiers, keyCode: keyCode)
    }

    deinit {
        uninstall()
    }

    private func install(modifiers: UInt32, keyCode: UInt32) {
        retainedSelf = self
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passRetained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let controller = Unmanaged<HotkeyController>.fromOpaque(userData).takeUnretainedValue()
                controller.handler()
                return noErr
            },
            1,
            &eventType,
            context,
            &eventHandler
        )

        RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: OSType(0x50455252), id: 1),
            GetApplicationEventTarget(),
            0,
            &eventHotKeyRef
        )
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
        retainedSelf = nil
    }
}
