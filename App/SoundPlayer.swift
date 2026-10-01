import AppKit

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
        PerfMark.mark("sound.warmup")
    }

    static func play(_ cue: Cue) {
        guard let sound = players[cue] ?? load(cue) else { return }
        sound.stop()
        sound.currentTime = 0
        sound.play()
        PerfMark.markDynamic("sound.cue.\(cue.rawValue)")
    }

    private static func load(_ cue: Cue) -> NSSound? {
        guard let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "caf", subdirectory: "Sounds"),
              let sound = NSSound(contentsOf: url, byReference: true) else { return nil }
        players[cue] = sound
        return sound
    }
}
