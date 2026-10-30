import SwiftUI

public enum InkStroke {
    public static let defaultStep: CGFloat = 2.5
    public static let defaultJitter: CGFloat = 0.6

    struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    public static func sampled(
        through points: [CGPoint],
        step: CGFloat = defaultStep,
        jitter: CGFloat = defaultJitter,
        seed: UInt64 = 0
    ) -> [CGPoint] {
        guard points.count > 1 else { return points }
        var output: [CGPoint] = []
        var rng = SplitMix64(seed: seed)
        let alpha: CGFloat = 0.5

        func knot(_ index: Int) -> CGPoint {
            points[min(max(index, 0), points.count - 1)]
        }

        for i in 0..<(points.count - 1) {
            let p0 = knot(i - 1)
            let p1 = knot(i)
            let p2 = knot(i + 1)
            let p3 = knot(i + 2)

            let t0: CGFloat = 0
            let t1 = t0 + max(pow(hypot(p1.x - p0.x, p1.y - p0.y), alpha), 1e-4)
            let t2 = t1 + max(pow(hypot(p2.x - p1.x, p2.y - p1.y), alpha), 1e-4)
            let t3 = t2 + max(pow(hypot(p3.x - p2.x, p3.y - p2.y), alpha), 1e-4)

            let chord = hypot(p2.x - p1.x, p2.y - p1.y)
            let substeps = max(1, Int((chord / step).rounded(.up)))

            for s in 0..<substeps {
                let t = t1 + (t2 - t1) * CGFloat(s) / CGFloat(substeps)
                output.append(evaluate(p0, p1, p2, p3, t0: t0, t1: t1, t2: t2, t3: t3, at: t))
            }
        }
        output.append(points[points.count - 1])

        guard jitter > 0, output.count > 2 else { return output }
        for i in 1..<(output.count - 1) {
            let prev = output[i - 1]
            let next = output[i + 1]
            let dx = next.x - prev.x
            let dy = next.y - prev.y
            let length = max(hypot(dx, dy), 1e-4)
            let normal = CGPoint(x: -dy / length, y: dx / length)
            let amount = CGFloat(rng.unit() * 2 - 1) * jitter
            output[i] = CGPoint(x: output[i].x + normal.x * amount,
                                y: output[i].y + normal.y * amount)
        }
        return output
    }

    private static func evaluate(
        _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint,
        t0: CGFloat, t1: CGFloat, t2: CGFloat, t3: CGFloat, at t: CGFloat
    ) -> CGPoint {
        func lerp(_ a: CGPoint, _ b: CGPoint, _ ta: CGFloat, _ tb: CGFloat) -> CGPoint {
            let w = (t - ta) / max(tb - ta, 1e-6)
            return CGPoint(x: a.x + (b.x - a.x) * w, y: a.y + (b.y - a.y) * w)
        }
        let a1 = lerp(p0, p1, t0, t1)
        let a2 = lerp(p1, p2, t1, t2)
        let a3 = lerp(p2, p3, t2, t3)
        let b1 = lerp(a1, a2, t0, t2)
        let b2 = lerp(a2, a3, t1, t3)
        return lerp(b1, b2, t1, t2)
    }

    public static func widths(count: Int, baseWidth: CGFloat, seed: UInt64 = 0) -> [CGFloat] {
        guard count > 0, baseWidth > 0 else { return [] }
        var rng = SplitMix64(seed: seed ^ 0xA5A5A5A5)
        return (0..<count).map { i in
            let progress = CGFloat(i) / CGFloat(max(count - 1, 1))
            let end = min(1, min(progress, 1 - progress) / 0.15)
            let taper = 0.35 + 0.65 * end
            let wobble = 0.82 + 0.36 * rng.unit()
            return max(0.5, baseWidth * taper * wobble)
        }
    }

    public static func rectangle(in rect: CGRect) -> [CGPoint] {
        sampled(through: [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.minY),
        ])
    }

    public static func ellipse(in rect: CGRect, controlPoints count: Int = 14, seed: UInt64 = 1) -> [CGPoint] {
        guard count > 2, rect.width > 0, rect.height > 0 else { return [] }
        let rx = rect.width / 2
        let ry = rect.height / 2
        var control = (0..<count).map { i -> CGPoint in
            let theta = CGFloat(i) / CGFloat(count) * 2 * .pi + 0.35
            return CGPoint(x: rect.midX + rx * cos(theta),
                           y: rect.midY + ry * sin(theta))
        }
        control.append(control[0])
        return sampled(through: control, seed: seed)
    }

    public static func point(on samples: [CGPoint], progress: CGFloat) -> CGPoint? {
        guard let first = samples.first else { return nil }
        guard samples.count > 1 else { return first }
        var lengths: [CGFloat] = [0]
        for i in 1..<samples.count {
            lengths.append(lengths[i - 1] + hypot(samples[i].x - samples[i - 1].x,
                                                  samples[i].y - samples[i - 1].y))
        }
        let total = lengths.last ?? 0
        guard total > 0 else { return first }
        let target = min(max(progress, 0), 1) * total
        for i in 1..<samples.count where lengths[i] >= target {
            let segment = lengths[i] - lengths[i - 1]
            guard segment > 0 else { return samples[i] }
            let t = (target - lengths[i - 1]) / segment
            return CGPoint(x: samples[i - 1].x + (samples[i].x - samples[i - 1].x) * t,
                           y: samples[i - 1].y + (samples[i].y - samples[i - 1].y) * t)
        }
        return samples.last
    }
}

public struct InkStrokeShape: Shape {
    public var samples: [CGPoint]
    public var widths: [CGFloat]
    public var progress: CGFloat

    public init(samples: [CGPoint], widths: [CGFloat], progress: CGFloat = 1) {
        self.samples = samples
        self.widths = widths
        self.progress = progress
    }

    public var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        guard samples.count > 1, widths.count == samples.count else { return path }
        let clamped = min(max(progress, 0), 1)
        let count = max(2, Int((CGFloat(samples.count) * clamped).rounded(.up)))
        let center = Array(samples.prefix(count))
        let half = Array(widths.prefix(count)).map { $0 / 2 }

        func normal(at i: Int) -> CGPoint {
            let prev = center[max(i - 1, 0)]
            let next = center[min(i + 1, center.count - 1)]
            let dx = next.x - prev.x
            let dy = next.y - prev.y
            let length = max(hypot(dx, dy), 1e-4)
            return CGPoint(x: -dy / length, y: dx / length)
        }

        path.move(to: CGPoint(x: center[0].x + normal(at: 0).x * half[0],
                              y: center[0].y + normal(at: 0).y * half[0]))
        for i in 1..<center.count {
            let n = normal(at: i)
            path.addLine(to: CGPoint(x: center[i].x + n.x * half[i],
                                     y: center[i].y + n.y * half[i]))
        }
        for i in stride(from: center.count - 1, through: 0, by: -1) {
            let n = normal(at: i)
            path.addLine(to: CGPoint(x: center[i].x - n.x * half[i],
                                     y: center[i].y - n.y * half[i]))
        }
        path.closeSubpath()
        return path
    }
}

public enum InkColor {
    public static let onDarkHex = String(PerryOverlayTheme.Colors.accentRGB, radix: 16, uppercase: true)
    public static let onLightHex = "3C7765"
    public static let threshold: Double = 0.45

    public static func luminance(of rgba: UnsafeBufferPointer<UInt8>) -> Double? {
        let pixelCount = rgba.count / 4
        guard pixelCount > 0 else { return nil }
        var sum: Double = 0
        for i in 0..<pixelCount {
            let base = i * 4
            sum += 0.299 * Double(rgba[base])
                 + 0.587 * Double(rgba[base + 1])
                 + 0.114 * Double(rgba[base + 2])
        }
        return sum / (Double(pixelCount) * 255.0)
    }

    public static func hex(forLuminance luminance: Double) -> String {
        luminance < threshold ? onDarkHex : onLightHex
    }

    public static func color(forLuminance luminance: Double) -> Color {
        Color(optionalHex: hex(forLuminance: luminance)) ?? PerryOverlayTheme.Colors.accent
    }
}
