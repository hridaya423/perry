import CoreGraphics

public enum CaptionPlacer {
    public static let defaultMargin: CGFloat = 10
    public static let defaultGap: CGFloat = 8

    private static func candidates(
        size: CGSize, anchor: CGRect, screen: CGRect, margin: CGFloat, gap: CGFloat
    ) -> [CGRect] {
        let w = size.width
        let h = size.height
        var slots: [CGRect] = [
            CGRect(x: anchor.midX - w / 2, y: anchor.maxY + gap, width: w, height: h),
            CGRect(x: anchor.midX - w / 2, y: anchor.minY - gap - h, width: w, height: h),
            CGRect(x: anchor.maxX + gap, y: anchor.midY - h / 2, width: w, height: h),
            CGRect(x: anchor.minX - gap - w, y: anchor.midY - h / 2, width: w, height: h),
        ]
        let inset = screen.insetBy(dx: margin, dy: margin)
        slots.append(contentsOf: [
            CGRect(x: inset.minX, y: inset.minY, width: w, height: h),
            CGRect(x: inset.maxX - w, y: inset.minY, width: w, height: h),
            CGRect(x: inset.minX, y: inset.maxY - h, width: w, height: h),
            CGRect(x: inset.maxX - w, y: inset.maxY - h, width: w, height: h),
        ])
        return slots
    }

    static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        guard !a.isNull, !b.isNull else { return 0 }
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    static func overflowArea(_ rect: CGRect, in screen: CGRect) -> CGFloat {
        rect.width * rect.height - overlapArea(rect, screen)
    }

    public static func place(
        size: CGSize,
        anchor: CGRect,
        avoiding: [CGRect] = [],
        preferablyAvoiding: [CGRect] = [],
        in screen: CGRect,
        margin: CGFloat = defaultMargin,
        gap: CGFloat = defaultGap
    ) -> CGRect {
        let obstacles = [anchor] + avoiding
        let bounds = screen.insetBy(dx: margin, dy: margin)

        var best: (rect: CGRect, score: CGFloat, soft: CGFloat)?
        for (index, slot) in candidates(size: size, anchor: anchor, screen: screen,
                                        margin: margin, gap: gap).enumerated() {
            let clamped = clamp(slot, into: bounds)
            let overlap = obstacles.reduce(CGFloat(0)) { $0 + overlapArea(clamped, $1) }
            let score = overlap + 4 * overflowArea(clamped, in: screen)
            let soft = index < 4 ? preferablyAvoiding.reduce(CGFloat(0)) { $0 + overlapArea(clamped, $1) } : 0
            guard let current = best else {
                best = (clamped, score, soft)
                continue
            }
            if score < current.score - 0.5 || (index < 4 && abs(score - current.score) <= 0.5 && soft < current.soft - 0.5) {
                best = (clamped, score, soft)
            }
        }
        return best?.rect
            ?? clamp(CGRect(origin: .zero, size: size), into: bounds)
    }

    static func clamp(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        var r = rect
        if r.width > bounds.width {
            r.origin.x = bounds.midX - r.width / 2
        } else {
            r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        }
        if r.height > bounds.height {
            r.origin.y = bounds.midY - r.height / 2
        } else {
            r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        }
        return r
    }
}
