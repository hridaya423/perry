import AppKit
import SwiftUI

/// The guide's active-control highlight: a pulsing accent ring around the
/// target rect with its step caption, drawn under the ghost cursors and ink.
struct ControlGlowLayer: View {
    let state: PerryCursorState
    let screenFrame: CGRect
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        if let screenRect = state.activeControlGlowRect,
           screenRect.intersects(screenFrame) {
            let localRect = PerryOverlaySpace.localRect(screenRect, in: screenFrame)
            ZStack {
                PerryControlGlowView(
                    color: PerryOverlayTheme.Colors.accent,
                    reduceMotion: accessibilityReduceMotion
                )
                .frame(width: max(1, localRect.width), height: max(1, localRect.height))
                .position(x: localRect.midX, y: localRect.midY)

                if let label = state.activeControlGlowLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !label.isEmpty {
                    PerryAnchoredCaption(
                        caption: label,
                        anchor: CGPoint(x: localRect.midX, y: localRect.minY),
                        screenFrame: screenFrame
                    )
                }
            }
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }
}

/// The ink surface: visual guidance scribbles, rectangles, and ellipses
/// published by tools and Guide, plus the circle-select trail and snapped
/// highlight while a spatial selection is being drawn.
struct InkLayer: View {
    let state: PerryCursorState
    let screenFrame: CGRect
    /// Live pointer position in local coordinates — the caption anchor
    /// falls back to it when an overlay has no screen bounds.
    let pointerAnchor: CGPoint
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private var overlaysOnThisScreen: [PerryGuidanceOverlay] {
        state.visualGuidanceOverlays.filter { overlay in
            overlay.screenBounds.intersects(screenFrame)
        }
    }

    private var circleSelectPointsOnThisScreen: [CGPoint] {
        let points = state.circleSelectLivePoints
        guard !points.isEmpty else { return [] }
        return points.compactMap { point in
            guard screenFrame.insetBy(dx: -40, dy: -40).contains(point) else { return nil }
            return PerryOverlaySpace.localPoint(point, in: screenFrame)
        }
    }

    var body: some View {
        ForEach(overlaysOnThisScreen) { overlay in
            guidanceOverlay(overlay)
        }

        if !circleSelectPointsOnThisScreen.isEmpty {
            circleSelectLiveTrail(
                circleSelectPointsOnThisScreen,
                dimmed: state.circleSelectSnappedRect != nil
            )
        }

        if let snappedRect = state.circleSelectSnappedRect,
           snappedRect.intersects(screenFrame) {
            circleSelectSnappedHighlight(
                snappedRect,
                label: state.circleSelectSnapLabel
            )
        }
    }

    @ViewBuilder
    private func circleSelectLiveTrail(_ localPoints: [CGPoint], dimmed: Bool) -> some View {
        PerryFadingTrailView(
            points: localPoints,
            color: PerryOverlayTheme.Colors.selection,
            reduceMotion: accessibilityReduceMotion,
            overallOpacity: dimmed ? 0.35 : 1.0
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func circleSelectSnappedHighlight(_ screenRect: CGRect, label: String?) -> some View {
        let localRect = PerryOverlaySpace.localRect(screenRect, in: screenFrame)
        let trailColor = PerryOverlayTheme.Colors.selection
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(trailColor.opacity(0.10))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(trailColor.opacity(0.92), lineWidth: 2.4)
                .shadow(color: trailColor.opacity(0.55), radius: 8, x: 0, y: 0)

            if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(PerryOverlayTheme.Colors.labelForeground)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(PerryOverlayTheme.Colors.labelBackground)
                    )
                    .position(x: localRect.midX, y: max(14, localRect.minY - 14))
            }
        }
        .frame(width: max(1, localRect.width), height: max(1, localRect.height))
        .position(x: localRect.midX, y: localRect.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.16), value: screenRect)
    }

    @ViewBuilder
    private func guidanceOverlay(_ overlay: PerryGuidanceOverlay) -> some View {
        let color = perryAccentColor(overlay.style.accentHex)
        ZStack {
            switch overlay.kind {
            case .scribble:
                visualGuidanceScribble(overlay, color: color)
            case .rectangle:
                visualGuidanceLoop(overlay, color: color, ellipse: false)
            case .ellipse:
                visualGuidanceLoop(overlay, color: color, ellipse: true)
            }

            if let caption = overlay.style.caption?.trimmingCharacters(in: .whitespacesAndNewlines),
               !caption.isEmpty {
                guidanceCaption(caption, for: overlay, color: color)
            }
        }
        .transition(accessibilityReduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
        .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.18), value: overlay.id)
        .allowsHitTesting(false)
    }

    /// Caption next to a guidance mark (§5): CaptionPlacer picks a slot that
    /// doesn't cover the marked element and stays inside the visible frame
    /// (clear of menu bar / Dock / notch).
    @ViewBuilder
    private func guidanceCaption(_ caption: String, for overlay: PerryGuidanceOverlay, color: Color) -> some View {
        let bubbleSize = estimatedCaptionBubbleSize(for: caption)
        let targetBL = overlay.screenBounds
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? screenFrame.maxY
        // AppKit bottom-left → CG top-left for the solver.
        let anchorCG = CGRect(
            x: targetBL.minX, y: primaryMaxY - targetBL.maxY,
            width: targetBL.width, height: targetBL.height
        )
        let visibleBL = NSScreen.screens
            .first(where: { $0.frame == screenFrame })?.visibleFrame ?? screenFrame
        let screenCG = CGRect(
            x: visibleBL.minX, y: primaryMaxY - visibleBL.maxY,
            width: visibleBL.width, height: visibleBL.height
        )
        let placed = targetBL.isNull
            ? CGRect(
                x: captionAnchor(for: overlay).x - bubbleSize.width / 2,
                y: captionAnchor(for: overlay).y - bubbleSize.height / 2,
                width: bubbleSize.width, height: bubbleSize.height
            )
            : CaptionPlacer.place(
                size: bubbleSize, anchor: anchorCG, in: screenCG
            )
        let centerBL = targetBL.isNull
            ? captionAnchor(for: overlay)
            : CGPoint(x: placed.midX, y: primaryMaxY - placed.midY)
        let local = targetBL.isNull
            ? centerBL
            : PerryOverlaySpace.localPoint(centerBL, in: screenFrame)

        PerryCaptionBubble(caption: caption, position: local)
    }

    @ViewBuilder
    private func visualGuidanceScribble(_ overlay: PerryGuidanceOverlay, color: Color) -> some View {
        let localPoints = overlay.points.map {
            PerryOverlaySpace.localPoint($0.cgPoint, in: screenFrame)
        }
        PerryGuidanceScribbleView(
            points: localPoints,
            color: color,
            lineWidth: CGFloat(overlay.style.lineWidth),
            drawingDuration: min(1.2, max(0.35, overlay.duration * 0.20)),
            reduceMotion: accessibilityReduceMotion
        )
    }

    @ViewBuilder
    private func visualGuidanceLoop(_ overlay: PerryGuidanceOverlay, color: Color, ellipse: Bool) -> some View {
        if let rect = overlay.rect?.normalized.cgRect {
            let localRect = PerryOverlaySpace.localRect(rect, in: screenFrame)
            PerryGuidanceRectangleView(
                color: color,
                lineWidth: CGFloat(overlay.style.lineWidth),
                fillOpacity: overlay.style.fillOpacity,
                drawingDuration: min(0.95, max(0.38, overlay.duration * 0.22)),
                reduceMotion: accessibilityReduceMotion,
                ellipse: ellipse
            )
            .frame(width: localRect.width, height: localRect.height)
            .position(x: localRect.midX, y: localRect.midY)
            .allowsHitTesting(false)
        }
    }

    private func captionAnchor(for overlay: PerryGuidanceOverlay) -> CGPoint {
        let bounds = overlay.screenBounds
        guard !bounds.isNull else { return pointerAnchor }
        return PerryOverlaySpace.localPoint(CGPoint(x: bounds.midX, y: bounds.maxY), in: screenFrame)
    }
}

private struct PerryControlGlowView: View {
    let color: Color
    let reduceMotion: Bool

    @State private var pulse = false

    var body: some View {
        GeometryReader { geometry in
            let radius = min(max(min(geometry.size.width, geometry.size.height) * 0.05, 10), 30)
            ZStack {
                ForEach(0..<5, id: \.self) { index in
                    let inset = CGFloat(index) * 5
                    RoundedRectangle(cornerRadius: max(2, radius - inset * 0.35), style: .continuous)
                        .inset(by: inset)
                        .strokeBorder(
                            color.opacity(glowOpacity(for: index)),
                            lineWidth: CGFloat(5 - index)
                        )
                }

                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(color.opacity(0.78), lineWidth: 1.4)
            }
            .blur(radius: reduceMotion ? 0.2 : (pulse ? 0.45 : 0.9))
            .opacity(reduceMotion ? 0.82 : (pulse ? 0.92 : 0.68))
            .compositingGroup()
            .onAppear {
                pulse = true
            }
            .animation(
                reduceMotion ? nil : PerryOverlayTheme.Motion.ambientPulse.repeatCount(4, autoreverses: true),
                value: pulse
            )
        }
    }

    private func glowOpacity(for index: Int) -> Double {
        let opacities = [0.55, 0.32, 0.20, 0.13, 0.08]
        return opacities[min(max(index, 0), opacities.count - 1)]
    }
}

private struct PerryGuidanceScribbleView: View {
    let points: [CGPoint]
    let color: Color
    let lineWidth: CGFloat
    let drawingDuration: TimeInterval
    let reduceMotion: Bool

    @State private var drawProgress: CGFloat = 0

    var body: some View {
        let clampedProgress = min(max(drawProgress, 0), 1)
        // Hand-inked mark (§5): Catmull-Rom resample + seeded wobble +
        // tapered variable-width outline, drawn on over drawingDuration.
        let samples = InkStroke.sampled(through: points)
        let widths = InkStroke.widths(count: samples.count, baseWidth: lineWidth)

        ZStack(alignment: .topLeading) {
            InkStrokeShape(samples: samples, widths: widths, progress: clampedProgress)
                .fill(color)
                .shadow(
                    color: color.opacity(reduceMotion ? 0.30 : 0.68),
                    radius: reduceMotion ? 2 : 7,
                    x: 0,
                    y: 0
                )

            if !reduceMotion,
               let cursorPoint = InkStroke.point(on: samples, progress: clampedProgress),
               clampedProgress < 0.995 {
                PerryCharacter(mood: .working, size: 24)
                    .shadow(color: color.opacity(0.65), radius: 6, x: 0, y: 0)
                    .position(cursorPoint)
            }
        }
        .onAppear {
            drawProgress = reduceMotion ? 1 : 0
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: drawingDuration)) {
                drawProgress = 1
            }
        }
    }
}

/// Freehand circle-select stroke: smooth path with a comet-style fading tail
/// (oldest segments nearly invisible, head bright and slightly thicker).

private struct PerryFadingTrailView: View {
    let points: [CGPoint]
    let color: Color
    let reduceMotion: Bool
    var overallOpacity: Double = 1.0

    /// How many point-steps make up each fade band. Smaller = smoother fade.
    private let pointsPerBand = 3
    private let minOpacity: Double = 0.08
    private let maxOpacity: Double = 0.95
    private let minLineWidth: CGFloat = 2.2
    private let maxLineWidth: CGFloat = 5.0

    var body: some View {
        let displayPoints = points.count >= 2 ? points : []
        ZStack(alignment: .topLeading) {
            if displayPoints.count >= 2 {
                ForEach(Array(bandRanges(for: displayPoints.count).enumerated()), id: \.offset) { _, range in
                    let progress = bandProgress(range: range, total: displayPoints.count)
                    let opacity = (minOpacity + (maxOpacity - minOpacity) * progress) * overallOpacity
                    let width = minLineWidth + (maxLineWidth - minLineWidth) * CGFloat(progress)
                    let slice = Array(displayPoints[range])
                    PerrySmoothScribblePath(points: slice)
                        .stroke(
                            color.opacity(opacity),
                            style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
                        )
                        .shadow(
                            color: color.opacity(reduceMotion ? opacity * 0.15 : opacity * 0.55),
                            radius: reduceMotion ? 1.5 : (2.5 + 4.5 * progress),
                            x: 0,
                            y: 0
                        )
                }
            }

            if let last = displayPoints.last, overallOpacity > 0.5 {
                Circle()
                    .fill(color.opacity(0.95 * overallOpacity))
                    .frame(width: 8, height: 8)
                    .shadow(color: color.opacity(0.75 * overallOpacity), radius: 5, x: 0, y: 0)
                    .position(last)
            }
        }
        .opacity(overallOpacity)
    }

    /// Overlapping index ranges so band strokes join without gaps.
    private func bandRanges(for count: Int) -> [Range<Int>] {
        guard count >= 2 else { return [] }
        var ranges: [Range<Int>] = []
        var start = 0
        while start < count - 1 {
            let end = min(count, start + pointsPerBand + 1)
            ranges.append(start..<end)
            if end >= count { break }
            // Overlap one point so adjacent bands share a join vertex.
            start = end - 1
        }
        return ranges
    }

    /// 0 at the oldest end of the stroke, 1 at the newest (head).
    private func bandProgress(range: Range<Int>, total: Int) -> Double {
        guard total > 1 else { return 1 }
        let mid = Double(range.lowerBound + range.upperBound - 1) / 2.0
        return min(max(mid / Double(total - 1), 0), 1)
    }
}

private struct PerrySmoothScribblePath: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)

        guard points.count > 2 else {
            if let last = points.last {
                path.addLine(to: last)
            }
            return path
        }

        for index in 1..<points.count {
            let current = points[index]
            if index < points.count - 1 {
                let next = points[index + 1]
                let midpoint = CGPoint(
                    x: (current.x + next.x) / 2,
                    y: (current.y + next.y) / 2
                )
                path.addQuadCurve(to: midpoint, control: current)
            } else {
                path.addQuadCurve(to: current, control: current)
            }
        }

        return path
    }

    static func point(on points: [CGPoint], progress: CGFloat) -> CGPoint? {
        guard let first = points.first else { return nil }
        guard points.count > 1 else { return first }

        let segments = zip(points, points.dropFirst()).map { pair in
            let start = pair.0
            let end = pair.1
            let dx = end.x - start.x
            let dy = end.y - start.y
            return (start: start, end: end, length: (dx * dx + dy * dy).squareRoot())
        }
        let totalLength = segments.reduce(CGFloat(0)) { $0 + $1.length }
        guard totalLength > 0 else { return first }

        var remaining = min(max(progress, 0), 1) * totalLength
        for segment in segments {
            guard segment.length > 0 else { continue }
            if remaining <= segment.length {
                let t = remaining / segment.length
                return CGPoint(
                    x: segment.start.x + (segment.end.x - segment.start.x) * t,
                    y: segment.start.y + (segment.end.y - segment.start.y) * t
                )
            }
            remaining -= segment.length
        }

        return points.last
    }
}

private struct PerryGuidanceRectangleView: View {
    let color: Color
    let lineWidth: CGFloat
    let fillOpacity: Double
    let drawingDuration: TimeInterval
    let reduceMotion: Bool
    var ellipse: Bool = false

    @State private var drawProgress: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let clampedProgress = min(max(drawProgress, 0), 1)

            let inkRect = CGRect(origin: .zero, size: size)
                .insetBy(dx: lineWidth, dy: lineWidth)
            let samples = ellipse ? InkStroke.ellipse(in: inkRect) : InkStroke.rectangle(in: inkRect)
            let widths = InkStroke.widths(count: samples.count, baseWidth: lineWidth)

            ZStack(alignment: .topLeading) {
                (ellipse ? AnyShape(Ellipse()) : AnyShape(Rectangle()))
                    .fill(color.opacity(fillOpacity * Double(clampedProgress)))

                // Inked perimeter (§5): hand-drawn loop, not a crisp rect.
                InkStrokeShape(samples: samples, widths: widths, progress: clampedProgress)
                    .fill(color)
                    .shadow(
                        color: color.opacity(reduceMotion ? 0.30 : 0.70),
                        radius: reduceMotion ? 2 : 9,
                        x: 0,
                        y: 0
                    )

                if !reduceMotion && clampedProgress < 0.995,
                   let tip = InkStroke.point(on: samples, progress: clampedProgress) {
                    PerryCharacter(mood: .working, size: 24)
                        .shadow(color: color.opacity(0.65), radius: 6, x: 0, y: 0)
                        .position(tip)
                }
            }
            .onAppear {
                drawProgress = reduceMotion ? 1 : 0
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: drawingDuration)) {
                    drawProgress = 1
                }
            }
            .onChange(of: geometry.size) { _, _ in
                if reduceMotion {
                    drawProgress = 1
                }
            }
        }
    }
}
