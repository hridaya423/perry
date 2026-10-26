import AppKit

struct SettingsWindowSnapshot: Equatable {
    let id: CGWindowID
    let frame: CGRect
}

enum SettingsDock: Equatable {
    case below
    case inside
    case right
    case left
    case clamped
}

@MainActor
final class SettingsWindowTracker {
    static let goneAfter: TimeInterval = 0.5

    var onChange: (SettingsWindowSnapshot) -> Void = { _ in }
    var onGone: () -> Void = {}
    private let locate: () -> SettingsWindowSnapshot?
    private var timer: Timer?
    private var last: SettingsWindowSnapshot?
    private var missingSince: TimeInterval?

    init(locate: @escaping () -> SettingsWindowSnapshot? = SettingsWindowTracker.locate) {
        self.locate = locate
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(now: ProcessInfo.processInfo.systemUptime) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        last = nil
        missingSince = nil
    }

    func tick(now: TimeInterval) {
        if let snapshot = locate() {
            missingSince = nil
            if snapshot != last {
                last = snapshot
                onChange(snapshot)
            }
            return
        }
        guard last != nil else { return }
        let since = missingSince ?? now
        missingSince = since
        if now - since >= Self.goneAfter {
            last = nil
            missingSince = nil
            onGone()
        }
    }

    func waitForStableFrame(budget: Duration = .milliseconds(1200)) async -> SettingsWindowSnapshot? {
        let deadline = ContinuousClock.now + budget
        var previous: SettingsWindowSnapshot?
        while ContinuousClock.now < deadline {
            let current = locate()
            if let current, current == previous { return current }
            previous = current
            try? await Task.sleep(for: .milliseconds(60))
        }
        return previous
    }

    static func locate() -> SettingsWindowSnapshot? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").map(\.processIdentifier))
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let candidates = windows.compactMap { info -> SettingsWindowSnapshot? in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgFrame = CGRect(dictionaryRepresentation: bounds),
                  cgFrame.width >= 300, cgFrame.height >= 200 else { return nil }
            return SettingsWindowSnapshot(id: id, frame: appKitFrame(fromCG: cgFrame, primaryHeight: NSScreen.screens.first?.frame.height ?? 0))
        }
        return candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    static func appKitFrame(fromCG frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    static func dockFrame(settings: NSRect, visible: NSRect, cardSize: CGSize) -> (NSRect, SettingsDock) {
        let gap: CGFloat = 10
        let listMinX = settings.minX + 252
        let listMaxX = settings.maxX - 20
        let centeredX = (listMinX + listMaxX) / 2 - cardSize.width / 2
        let x = min(max(centeredX, visible.minX), visible.maxX - cardSize.width)
        let below = NSRect(x: x, y: settings.minY - gap - cardSize.height, width: cardSize.width, height: cardSize.height)
        if below.minY >= visible.minY { return (below, .below) }
        if cardSize.height + 20 <= settings.height * 0.3 {
            return (NSRect(x: centeredX, y: settings.minY + 20, width: cardSize.width, height: cardSize.height), .inside)
        }
        let y = min(max(settings.minY, visible.minY), visible.maxY - cardSize.height)
        let right = NSRect(x: settings.maxX + gap, y: y, width: cardSize.width, height: cardSize.height)
        if right.maxX <= visible.maxX { return (right, .right) }
        let left = NSRect(x: settings.minX - gap - cardSize.width, y: y, width: cardSize.width, height: cardSize.height)
        if left.minX >= visible.minX { return (left, .left) }
        return (NSRect(x: x, y: visible.minY + gap, width: cardSize.width, height: cardSize.height), .clamped)
    }
}
