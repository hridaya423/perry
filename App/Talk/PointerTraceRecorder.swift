import AppKit
import PerryBrain
import QuartzCore

@MainActor
final class PointerTraceRecorder {
    typealias PointProvider = @MainActor () -> CGPoint
    typealias WindowProbe = @MainActor (CGPoint) -> Int?
    typealias FrameListProvider = @MainActor () -> [CGRect]

    private let point: PointProvider
    private let perryFrames: FrameListProvider
    private let windowUnder: WindowProbe
    private let interval: TimeInterval
    private let capacity: Int
    private let now: @MainActor () -> TimeInterval

    private var timer: Timer?
    private var startedAt: TimeInterval = 0
    private(set) var samples: [TraceSample] = []

    init(
        point: @escaping PointProvider,
        perryFrames: @escaping FrameListProvider = { [] },
        windowUnder: @escaping WindowProbe = { _ in nil },
        interval: TimeInterval = 1.0 / 60,
        capacity: Int = 360,
        now: @escaping @MainActor () -> TimeInterval = { CACurrentMediaTime() }
    ) {
        self.point = point
        self.perryFrames = perryFrames
        self.windowUnder = windowUnder
        self.interval = interval
        self.capacity = capacity
        self.now = now
    }

    static func live() -> PointerTraceRecorder {
        PointerTraceRecorder(
            point: { Self.mouseLocationInAXSpace() },
            perryFrames: { Self.perryWindowFramesInAXSpace() },
            windowUnder: { Self.onScreenWindow(under: $0) }
        )
    }

    func start() {
        timer?.invalidate()
        samples = []
        startedAt = now()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.record() }
        }
    }

    @discardableResult
    func stop() -> [TraceSample] {
        timer?.invalidate()
        timer = nil
        return samples
    }

    @discardableResult
    func record() -> TraceSample {
        let p = point()
        let sample = TraceSample(
            t: now() - startedAt,
            point: p,
            windowID: windowUnder(p),
            overPerry: perryFrames().contains { $0.contains(p) }
        )
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
        return sample
    }

    static func mouseLocationInAXSpace() -> CGPoint {
        let location = NSEvent.mouseLocation
        let maxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: location.x, y: maxY - location.y)
    }

    static func perryWindowFramesInAXSpace() -> [CGRect] {
        let maxY = NSScreen.screens.first?.frame.maxY ?? 0
        return perryInteractiveFrames(of: NSApp.windows, primaryMaxY: maxY)
    }

    static func perryInteractiveFrames(of windows: [NSWindow], primaryMaxY maxY: CGFloat) -> [CGRect] {
        windows
            .filter { $0.isVisible && !$0.ignoresMouseEvents && $0.alphaValue > 0.01 }
            .map { window in
                let frame = window.frame
                return CGRect(x: frame.minX, y: maxY - frame.maxY, width: frame.width, height: frame.height)
            }
    }

    static func onScreenWindow(under axPoint: CGPoint) -> Int? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.contains(axPoint),
                  let number = info[kCGWindowNumber as String] as? Int else {
                continue
            }
            return number
        }
        return nil
    }
}
