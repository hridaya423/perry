import AppKit
import Intents

/// UI sound design: small crafted chimes, preloaded so first play is instant
/// (the chime-warmer idea from HeyClicky's ClickyChimeWarmer). Respects the
/// system mute of NSSound's own output routing; sounds are decorative only.
enum SoundPlayer {
    enum Cue: String {
        case wake
        case send
        case receive
        case done
        case fail
    }

    private static var players: [Cue: NSSound] = [:]

    static func warmUp(bundle: Bundle = .main) {
        for cue in [Cue.wake, .send, .receive, .done, .fail] where players[cue] == nil {
            if let url = bundle.url(forResource: cue.rawValue, withExtension: "caf", subdirectory: "Sounds"),
               let sound = NSSound(contentsOf: url, byReference: true) {
                players[cue] = sound
            }
        }
        _ = QuietHours.isActive
        PerfMark.mark("sound.warmup")
    }

    static let subtleVolume: Float = 0.45

    static func play(_ cue: Cue) {
        guard PerryPreferences.soundsEnabled, !QuietHours.isActive else { return }
        guard let sound = players[cue] ?? load(cue) else { return }
        sound.stop()
        sound.currentTime = 0
        sound.volume = subtleVolume
        sound.play()
        PerfMark.markDynamic("sound.cue.\(cue.rawValue)")
    }

    private static func load(_ cue: Cue) -> NSSound? {
        guard let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "caf", subdirectory: "Sounds"),
              let sound = NSSound(contentsOf: url, byReference: true) else { return nil }
        players[cue] = sound
        return sound
    }

    static func cue(from old: SessionState, to new: SessionState) -> Cue? {
        switch (old, new) {
        case (.reporting(let before), .reporting(let after)) where before.taskID == after.taskID:
            return nil
        case (_, .reporting(let report)):
            return report.outcome == .completed ? .done : nil
        case (.failed, .failed):
            return nil
        case (_, .failed):
            return .fail
        case (.executing(let before), .executing(let after)):
            return after.phase == .awaitingApproval && before.phase != .awaitingApproval ? .receive : nil
        case (_, .executing(let execution)):
            return execution.phase == .awaitingApproval ? .receive : nil
        default:
            return nil
        }
    }
}

enum QuietHours {
    private static var cached: (value: Bool, readAt: TimeInterval)?

    static var isActive: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached, now - cached.readAt < 30 { return cached.value }
        let value = INFocusStatusCenter.default.focusStatus.isFocused == true
        cached = (value, now)
        return value
    }
}
