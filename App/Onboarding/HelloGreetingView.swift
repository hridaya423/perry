import SwiftUI
import PerryOverlay

enum HelloInk {
    static let canvas = CGSize(width: 440, height: 220)
    static let origin = CGPoint(x: 18, y: 20)
    static let mascotSize: CGFloat = 56

    static let points: [CGPoint] = ([
        (10, 150), (43, 116), (77, 64), (94, 30), (91, 16), (79, 24), (68, 60), (57, 110), (48, 150),
        (55, 128), (70, 108), (88, 100), (99, 108), (98, 128), (96, 146), (102, 153), (117, 147),
        (135, 134), (156, 118), (161, 104), (152, 98), (137, 104), (125, 124), (126, 144), (141, 153),
        (164, 148), (186, 128), (215, 74), (232, 34), (232, 16), (220, 22), (206, 66), (195, 124),
        (198, 149), (214, 150), (236, 130), (265, 74), (282, 34), (282, 16), (270, 22), (256, 66),
        (245, 124), (248, 149), (264, 150), (284, 132), (298, 110), (316, 100), (331, 106), (331, 124),
        (319, 144), (302, 152), (289, 145), (289, 127), (300, 109), (314, 101), (329, 99), (341, 102)
    ] as [(CGFloat, CGFloat)]).map { CGPoint(x: $0.0 + origin.x, y: $0.1 + origin.y) }

    static let period = CGPoint(x: 356 + origin.x, y: 147 + origin.y)
    static let periodRadius: CGFloat = 5.2
    static let samples = InkStroke.sampled(through: points, step: 1.2, jitter: 0.22, seed: 11)
    static let widths = pressure(for: samples, baseWidth: 8.2)

    static let arrival = 0.0..<0.42
    static let writing = 0.42..<2.45
    static let lift = 2.45..<2.74
    static let crouch = 2.78..<2.92
    static let leap = 2.92..<3.36
    static let exit = CGPoint(x: canvas.width / 2, y: -150)
    static let duration = 3.4
    static let peekDelay = 3.55

    static func pressure(for samples: [CGPoint], baseWidth: CGFloat) -> [CGFloat] {
        let base = smoothed(InkStroke.widths(count: samples.count, baseWidth: baseWidth, seed: 5), radius: 10)
        let slant = smoothed(samples.indices.map { i in
            let a = samples[max(i - 2, 0)]
            let b = samples[min(i + 2, samples.count - 1)]
            let length = max(hypot(b.x - a.x, b.y - a.y), 0.001)
            return 0.58 + 0.42 * max(0, (b.y - a.y) / length)
        }, radius: 8)
        return zip(base, slant).map { $0 * $1 }
    }

    static func smoothed(_ values: [CGFloat], radius: Int) -> [CGFloat] {
        values.indices.map { i in
            let window = values[max(i - radius, 0)...min(i + radius, values.count - 1)]
            return window.reduce(0, +) / CGFloat(window.count)
        }
    }

    static func phase(_ time: Double, in range: Range<Double>) -> Double {
        min(max((time - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    static func easeInOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }

    static func inkProgress(at time: Double) -> Double {
        let t = phase(time, in: writing)
        return t * t * (3 - 2 * t) * 0.18 + t * 0.82
    }

    static func pen(at time: Double) -> (point: CGPoint, heading: CGVector) {
        let first = samples[0]
        let last = samples[samples.count - 1]
        if time < writing.lowerBound {
            let t = easeOut(phase(time, in: arrival))
            let start = CGPoint(x: first.x + 70, y: first.y - 90)
            let control = CGPoint(x: first.x + 30, y: first.y - 80)
            return (quadratic(start, control, first, t), CGVector(dx: -0.4, dy: 0.9))
        }
        if time < writing.upperBound {
            let index = min(Int((Double(samples.count - 1) * inkProgress(at: time)).rounded()), samples.count - 1)
            let ahead = samples[min(index + 4, samples.count - 1)]
            let behind = samples[max(index - 4, 0)]
            let length = max(hypot(ahead.x - behind.x, ahead.y - behind.y), 0.001)
            return (samples[index], CGVector(dx: (ahead.x - behind.x) / length, dy: (ahead.y - behind.y) / length))
        }
        if time >= leap.lowerBound {
            let t = phase(time, in: leap)
            let control = CGPoint(x: period.x - 10, y: -40)
            let point = quadratic(period, control, exit, t * t)
            let ahead = quadratic(period, control, exit, min(t * t + 0.05, 1))
            let length = max(hypot(ahead.x - point.x, ahead.y - point.y), 0.001)
            return (point, CGVector(dx: (ahead.x - point.x) / length, dy: (ahead.y - point.y) / length))
        }
        let t = easeInOut(phase(time, in: lift))
        let control = CGPoint(x: (last.x + period.x) / 2 + 6, y: min(last.y, period.y) - 34)
        return (quadratic(last, control, period, t), CGVector(dx: 0.3, dy: 0.95))
    }

    static func quadratic(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                       y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }
}

struct HelloScene: View {
    let time: Double

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / HelloInk.canvas.width, proxy.size.height / HelloInk.canvas.height)
            stage
                .frame(width: HelloInk.canvas.width, height: HelloInk.canvas.height)
                .scaleEffect(scale)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(HelloInk.canvas.width / HelloInk.canvas.height, contentMode: .fit)
    }

    private var stage: some View {
        let progress = HelloInk.inkProgress(at: time)
        let pen = HelloInk.pen(at: time)
        let dotted = time >= HelloInk.lift.upperBound
        let dot = HelloInk.easeOut(min(max((time - HelloInk.lift.upperBound) / 0.16, 0), 1))
        let head = HelloInk.samples[max(Int((CGFloat(HelloInk.samples.count) * progress).rounded(.up)) - 1, 0)]
        let headWidth = HelloInk.widths[max(Int((CGFloat(HelloInk.samples.count) * progress).rounded(.up)) - 1, 0)]
        return ZStack(alignment: .topLeading) {
            if time >= HelloInk.writing.lowerBound {
                InkStrokeShape(samples: HelloInk.samples, widths: HelloInk.widths, progress: progress)
                    .fill(PerryTheme.Colors.text)
                if progress < 1 {
                    Circle()
                        .fill(PerryTheme.Colors.text)
                        .frame(width: headWidth, height: headWidth)
                        .position(head)
                }
            }
            if dotted {
                Circle()
                    .fill(PerryTheme.Colors.text)
                    .frame(width: HelloInk.periodRadius * 2, height: HelloInk.periodRadius * 2)
                    .scaleEffect(0.4 + 0.6 * dot)
                    .position(HelloInk.period)
            }
            if time < HelloInk.leap.upperBound {
                PerryCharacterView(pose: pose(heading: pen.heading), size: HelloInk.mascotSize)
                    .position(x: pen.point.x - PerryBodyShape.tip.x * HelloInk.mascotSize,
                              y: pen.point.y - PerryBodyShape.tip.y * HelloInk.mascotSize)
                    .opacity(HelloInk.easeOut(HelloInk.phase(time, in: HelloInk.arrival)) * (1 - HelloInk.phase(time, in: HelloInk.leap)))
            }
        }
    }

    private func pose(heading: CGVector) -> PerryCharacterPose {
        var pose = PerryCharacterPose()
        let crouch = sin(.pi * HelloInk.phase(time, in: HelloInk.crouch))
        let flight = HelloInk.phase(time, in: HelloInk.leap)
        pose.face = time >= HelloInk.lift.upperBound ? .happy : .focused
        pose.gaze = time >= HelloInk.crouch.lowerBound ? CGVector(dx: -0.3, dy: -0.95) : CGVector(dx: heading.dx * 0.8, dy: heading.dy * 0.6)
        pose.lean = time >= HelloInk.crouch.lowerBound ? 0 : Double(heading.dx) * 0.08
        pose.stretch = 1 - 0.2 * crouch + 0.35 * min(flight * 3, 1)
        pose.stretchAngle = flight > 0 ? atan2(Double(heading.dy), Double(heading.dx)) : .pi / 2
        return pose
    }
}

struct NotchPeek: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.notchCameraInset) private var cameraInset
    var size: CGFloat = 44
    var delay = HelloInk.peekDelay
    var progress: Double?
    @State private var shown = false

    var body: some View {
        let reveal = progress ?? (shown || reduceMotion ? 1 : 0)
        PerryCharacterView(pose: pose, size: size)
            .offset(y: -(cameraInset + size * 0.8) * (1 - reveal))
            .frame(width: size, height: size * 0.8, alignment: .bottom)
            .mask(alignment: .bottom) { Rectangle().frame(width: size * 2, height: cameraInset + size * 0.8) }
            .onAppear {
                guard progress == nil else { return }
                withAnimation(.spring(duration: 0.55, bounce: 0.35).delay(delay)) { shown = true }
            }
            .accessibilityHidden(true)
    }

    private var pose: PerryCharacterPose {
        var pose = PerryCharacterPose()
        pose.face = .happy
        pose.gaze = CGVector(dx: 0, dy: 0.9)
        return pose
    }
}

struct HelloGreetingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date.now
    @State private var finished = false

    var body: some View {
        Group {
            if reduceMotion || finished {
                HelloScene(time: HelloInk.duration)
            } else {
                TimelineView(.animation) { timeline in
                    HelloScene(time: min(timeline.date.timeIntervalSince(startedAt), HelloInk.duration))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { finished = true }
        .task {
            startedAt = .now
            try? await Task.sleep(for: .seconds(HelloInk.duration))
            finished = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hello")
        .accessibilityAddTraits(.isImage)
    }
}
