import AppKit
import Foundation

public struct PerryGuidancePoint: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        self.x = Double(point.x)
        self.y = Double(point.y)
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }

    func clamped(to rect: CGRect) -> PerryGuidancePoint {
        PerryGuidancePoint(
            x: min(max(x, Double(rect.minX)), Double(rect.maxX)),
            y: min(max(y, Double(rect.minY)), Double(rect.maxY))
        )
    }
}

public struct PerryGuidanceRect: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.width)
        self.height = Double(rect.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var normalized: PerryGuidanceRect {
        let minX = min(x, x + width)
        let minY = min(y, y + height)
        return PerryGuidanceRect(
            x: minX,
            y: minY,
            width: abs(width),
            height: abs(height)
        )
    }

    func clamped(to bounds: CGRect) -> PerryGuidanceRect {
        let rect = normalized.cgRect.intersection(bounds)
        guard !rect.isNull else {
            return PerryGuidanceRect(x: bounds.minX, y: bounds.minY, width: 0, height: 0)
        }
        return PerryGuidanceRect(rect)
    }
}

public enum PerryGuidanceOverlayKind: String, Codable, Equatable, Sendable {
    case scribble
    case rectangle
    case ellipse
}

public struct PerryGuidanceStyle: Codable, Equatable, Hashable, Sendable {
    public var accentHex: String?
    public var lineWidth: Double
    public var fillOpacity: Double
    public var caption: String?

    public init(accentHex: String? = nil, lineWidth: Double = 5, fillOpacity: Double = 0.12, caption: String? = nil) {
        self.accentHex = accentHex
        self.lineWidth = max(1, min(lineWidth, 48))
        self.fillOpacity = max(0, min(fillOpacity, 0.65))
        self.caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

public struct PerryGuidanceOverlay: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: PerryGuidanceOverlayKind
    public var points: [PerryGuidancePoint]
    public var rect: PerryGuidanceRect?
    public var style: PerryGuidanceStyle
    public var duration: TimeInterval
    public var createdAt: Date
    /// The app's controls around the mark, in screen points; its caption
    /// avoids covering them when a free side exists.
    public var nearbyControls: [CGRect]?

    init(
        id: UUID = UUID(),
        kind: PerryGuidanceOverlayKind,
        points: [PerryGuidancePoint] = [],
        rect: PerryGuidanceRect? = nil,
        style: PerryGuidanceStyle = PerryGuidanceStyle(),
        duration: TimeInterval = 6,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.points = points
        self.rect = rect
        self.style = style
        self.duration = max(0.2, min(duration, 60))
        self.createdAt = createdAt
    }

    var screenBounds: CGRect {
        switch kind {
        case .rectangle, .ellipse:
            return rect?.normalized.cgRect ?? .null
        case .scribble:
            guard let first = points.first else { return .null }
            return points.dropFirst().reduce(CGRect(origin: first.cgPoint, size: .zero)) { partial, point in
                partial.union(CGRect(origin: point.cgPoint, size: .zero))
            }
        }
    }

    func clamped(to desktopBounds: CGRect) -> PerryGuidanceOverlay {
        var overlay = self
        overlay.points = points.map { $0.clamped(to: desktopBounds) }
        overlay.rect = rect?.clamped(to: desktopBounds)
        return overlay
    }

    /// A copy shifted by `delta` (AppKit bottom-left screen points). Used by
    /// the reanchor poller to keep marks glued to a window the user moved.
    public func translated(by delta: CGPoint) -> PerryGuidanceOverlay {
        var copy = self
        copy.points = points.map {
            PerryGuidancePoint(x: $0.x + Double(delta.x), y: $0.y + Double(delta.y))
        }
        if let rect {
            copy.rect = PerryGuidanceRect(
                x: rect.x + Double(delta.x), y: rect.y + Double(delta.y),
                width: rect.width, height: rect.height
            )
        }
        copy.nearbyControls = nearbyControls?.map { $0.offsetBy(dx: delta.x, dy: delta.y) }
        return copy
    }
}

extension PerryGuidanceOverlay {
    public static func scribble(
        points: [CGPoint],
        accentHex: String? = nil,
        lineWidth: Double = 5,
        caption: String? = nil,
        duration: TimeInterval = 6
    ) -> PerryGuidanceOverlay {
        PerryGuidanceOverlay(
            kind: .scribble,
            points: points.map { point in
                PerryGuidancePoint(x: Double(point.x), y: Double(point.y))
            },
            style: PerryGuidanceStyle(accentHex: accentHex, lineWidth: lineWidth, fillOpacity: 0, caption: caption),
            duration: duration
        )
    }

    public static func rectangle(
        rect: CGRect,
        accentHex: String? = nil,
        lineWidth: Double = 4,
        fillOpacity: Double = 0.05,
        caption: String? = nil,
        duration: TimeInterval = 6
    ) -> PerryGuidanceOverlay {
        PerryGuidanceOverlay(
            kind: .rectangle,
            rect: PerryGuidanceRect(rect).normalized,
            style: PerryGuidanceStyle(accentHex: accentHex, lineWidth: lineWidth, fillOpacity: fillOpacity, caption: caption),
            duration: duration
        )
    }

    public static func ellipse(
        rect: CGRect,
        accentHex: String? = nil,
        lineWidth: Double = 4,
        fillOpacity: Double = 0.05,
        caption: String? = nil,
        duration: TimeInterval = 6
    ) -> PerryGuidanceOverlay {
        PerryGuidanceOverlay(
            kind: .ellipse,
            rect: PerryGuidanceRect(rect).normalized,
            style: PerryGuidanceStyle(accentHex: accentHex, lineWidth: lineWidth, fillOpacity: fillOpacity, caption: caption),
            duration: duration
        )
    }

    /// `point`: a hand-inked dot on the element's center, reached by a short
    /// leader stroke from below-left. Replaces the degenerate two-point
    /// scribble, which rendered nothing.
    public static func pointMark(
        center: CGPoint,
        accentHex: String? = nil,
        caption: String? = nil,
        duration: TimeInterval = 6
    ) -> PerryGuidanceOverlay {
        let radius: Double = 13
        let startAngle = -Double.pi * 0.75
        var points = [
            CGPoint(x: center.x - 34, y: center.y - 48),
            CGPoint(x: center.x + radius * cos(startAngle), y: center.y + radius * sin(startAngle)),
        ]
        for i in 1...16 {
            let theta = startAngle + Double(i) / 16 * 2 * .pi
            points.append(CGPoint(x: center.x + radius * cos(theta), y: center.y + radius * sin(theta)))
        }
        return .scribble(points: points, accentHex: accentHex, lineWidth: 4.5, caption: caption, duration: duration)
    }

    /// `arrow`: a shaft ending in a hand-inked head just below the element's
    /// edge — the head, not a bare line end, carries the direction.
    public static func arrowMark(
        to rect: CGRect,
        accentHex: String? = nil,
        caption: String? = nil,
        duration: TimeInterval = 6
    ) -> PerryGuidanceOverlay {
        let tip = CGPoint(x: rect.midX, y: rect.minY - 4)
        let tail = CGPoint(x: rect.midX, y: rect.minY - 40)
        return .scribble(
            points: [
                tail, tip,
                CGPoint(x: tip.x - 6.5, y: tip.y - 12),
                tip,
                CGPoint(x: tip.x + 6.5, y: tip.y - 12),
            ],
            accentHex: accentHex, lineWidth: 5, caption: caption, duration: duration
        )
    }

    /// `underline`: a short stroke just below the element's bottom edge —
    /// AppKit space, so below is `minY -`, not `maxY +`.
    public static func underlineMark(
        below rect: CGRect,
        accentHex: String? = nil,
        caption: String? = nil,
        duration: TimeInterval = 6
    ) -> PerryGuidanceOverlay {
        .scribble(
            points: [
                CGPoint(x: rect.minX, y: rect.minY - 4),
                CGPoint(x: rect.maxX, y: rect.minY - 4),
            ],
            accentHex: accentHex, lineWidth: 4, caption: caption, duration: duration
        )
    }

    /// `ring` / `caption`: a hand-inked ellipse around the element, padded so
    /// the ink never touches the control it circles.
    public static func ringMark(
        around rect: CGRect,
        padding: Double = 8,
        accentHex: String? = nil,
        caption: String? = nil,
        duration: TimeInterval = 6
    ) -> PerryGuidanceOverlay {
        .ellipse(
            rect: rect.insetBy(dx: -padding, dy: -padding),
            accentHex: accentHex,
            caption: caption,
            duration: duration
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
