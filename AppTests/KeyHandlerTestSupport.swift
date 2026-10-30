import AppKit
@testable import Perry

extension PushToTalkController {
    func handle(keyCode: Int64, timestamp: TimeInterval, isKeyDown: Bool, isKeyUp: Bool, modifiers: Bool, tapDisabled: Bool) {
        handle(
            keyCode: keyCode,
            timestamp: timestamp,
            flags: modifiers ? [.maskAlternate, .maskCommand] : [],
            isKeyDown: isKeyDown,
            isKeyUp: isKeyUp,
            tapDisabled: tapDisabled
        )
    }
}

extension ModifierHoldMonitor {
    func handle(timestamp: TimeInterval, control: Bool, option: Bool, isFlagsChanged: Bool, tapDisabled: Bool) {
        var modifiers: ModifierSet = []
        if control { modifiers.insert(.control) }
        if option { modifiers.insert(.option) }
        handle(timestamp: timestamp, modifiers: modifiers, isFlagsChanged: isFlagsChanged, tapDisabled: tapDisabled)
    }
}
