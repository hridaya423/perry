import AppKit
import PerryBrain
import PerryCore
import PerryGuide
import PerryOverlay

@MainActor
final class TalkMarks {
    private let overlayState: PerryCursorState
    var index = ElementIndex(elements: [])
    private var overlayIDs: Set<UUID> = []
    private var firstInkMarked = false
    private var reanchorTimer: Timer?
    private var windowID: CGWindowID?
    private var windowBL = CGRect.zero

    private var primaryMaxY: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    init(overlayState: PerryCursorState) {
        self.overlayState = overlayState
    }

    func beginTurn() {
        firstInkMarked = false
    }

    func clear() {
        overlayState.visualGuidanceOverlays = []
        overlayIDs = []
        stopReanchor()
    }

    func clearForNewObservation() {
        index = ElementIndex(elements: [])
        overlayState.visualGuidanceOverlays.removeAll { overlayIDs.contains($0.id) }
        overlayIDs.removeAll()
        stopReanchor()
    }

    func draw(_ command: DrawCommand, observation: GuideObservation) {
        if command.verb == .clear {
            clear()
            return
        }
        guard let frame = command.frame ?? index.element(for: command.elementID ?? "")?.frame else { return }
        let rect = AXCoordinateConverter.appKitRect(
            axX: frame.origin.x,
            axY: frame.origin.y,
            width: frame.width,
            height: frame.height,
            primaryScreenMaxY: primaryMaxY
        )
        let accentHex = observation.screenshotData.flatMap { data in
            InkAccentSampler.accentHex(
                imageJPEG: data,
                elementCenterAX: CGPoint(x: frame.midX, y: frame.midY),
                windowBoundsAX: observation.windowBounds.map {
                    CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                } ?? .zero
            )
        } ?? "#9CCBB6"
        var overlay: PerryGuidanceOverlay
        switch command.verb {
        case .point:
            overlay = .pointMark(center: CGPoint(x: rect.midX, y: rect.midY), accentHex: accentHex, caption: command.label, duration: 15)
        case .arrow:
            overlay = .arrowMark(to: rect, accentHex: accentHex, caption: command.label, duration: 15)
        case .underline:
            overlay = .underlineMark(below: rect, accentHex: accentHex, caption: command.label, duration: 15)
        case .ring, .caption:
            overlay = .ringMark(around: rect, accentHex: accentHex, caption: command.label, duration: 15)
        case .clear:
            return
        }
        overlay.nearbyControls = (command.nearbyFrames.isEmpty ? index.controlFrames(near: frame) : command.nearbyFrames).map {
            AXCoordinateConverter.appKitRect(
                axX: $0.origin.x, axY: $0.origin.y, width: $0.width, height: $0.height,
                primaryScreenMaxY: primaryMaxY
            )
        }
        overlayState.visualGuidanceOverlays.append(overlay)
        overlayIDs.insert(overlay.id)
        if reanchorTimer == nil {
            startReanchor(for: observation)
        }
        if !firstInkMarked {
            firstInkMarked = true
            PerfMark.mark("ink.first_draw")
        }
    }

    private func startReanchor(for observation: GuideObservation) {
        guard let windowID = observation.windowID else { return }
        self.windowID = CGWindowID(windowID)
        windowBL = observation.windowBounds.map {
            AXCoordinateConverter.appKitRect(
                axX: $0.x, axY: $0.y, width: $0.width, height: $0.height,
                primaryScreenMaxY: primaryMaxY
            )
        } ?? .zero
        reanchorTimer?.invalidate()
        reanchorTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reanchor() }
        }
    }

    private func stopReanchor() {
        reanchorTimer?.invalidate()
        reanchorTimer = nil
        windowID = nil
        windowBL = .zero
    }

    private func reanchor() {
        overlayIDs.formIntersection(
            Set(overlayState.visualGuidanceOverlays.map(\.id))
        )
        guard !overlayIDs.isEmpty else {
            stopReanchor()
            return
        }
        guard let windowID,
              let list = CGWindowListCopyWindowInfo(
                  [.optionIncludingWindow], windowID
              ) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? [String: Any],
              let topLeft = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { return }
        let bottomLeft = CGRect(
            x: topLeft.minX, y: primaryMaxY - topLeft.maxY,
            width: topLeft.width, height: topLeft.height
        )
        if windowBL == .zero {
            windowBL = bottomLeft
            return
        }
        let delta = CGPoint(
            x: bottomLeft.minX - windowBL.minX,
            y: bottomLeft.minY - windowBL.minY
        )
        guard delta != .zero else { return }
        windowBL = bottomLeft
        overlayState.visualGuidanceOverlays = overlayState.visualGuidanceOverlays.map {
            overlayIDs.contains($0.id) ? $0.translated(by: delta) : $0
        }
    }
}
