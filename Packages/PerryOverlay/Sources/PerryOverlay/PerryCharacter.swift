import SwiftUI

public enum PerryMood: String, Equatable, Sendable, CaseIterable {
    case resting
    case listening
    case thinking
    case speaking
    case working
    case celebrating
    case needsYou
    case sleeping

    public init(voice: PerryVoicePhase, buddy: PerryBuddyState) {
        switch voice {
        case .listening: self = .listening; return
        case .processing: self = .thinking; return
        case .responding: self = .speaking; return
        case .idle: break
        }
        switch buddy {
        case .idle, .guiding: self = .resting
        case .listening: self = .listening
        case .thinking: self = .thinking
        case .acting: self = .working
        case .success: self = .celebrating
        case .awaitingApproval, .blocked: self = .needsYou
        }
    }
}

struct PerryStroke: Equatable, Sendable {
    var start: CGPoint
    var control: CGPoint
    var end: CGPoint
    var width: CGFloat

    static func vertical(_ length: CGFloat, width: CGFloat) -> PerryStroke {
        PerryStroke(start: CGPoint(x: 0, y: -length / 2), control: .zero, end: CGPoint(x: 0, y: length / 2), width: width)
    }

    static func horizontal(_ length: CGFloat, width: CGFloat) -> PerryStroke {
        PerryStroke(start: CGPoint(x: -length / 2, y: 0), control: .zero, end: CGPoint(x: length / 2, y: 0), width: width)
    }

    static func arc(_ length: CGFloat, bend: CGFloat, width: CGFloat) -> PerryStroke {
        PerryStroke(
            start: CGPoint(x: -length / 2, y: bend / 2),
            control: CGPoint(x: 0, y: -bend * 1.5),
            end: CGPoint(x: length / 2, y: bend / 2),
            width: width
        )
    }

    static let hidden = PerryStroke(start: .zero, control: .zero, end: .zero, width: 0)

    func mixed(with other: PerryStroke, _ t: Double) -> PerryStroke {
        PerryStroke(
            start: start.mixed(with: other.start, t),
            control: control.mixed(with: other.control, t),
            end: end.mixed(with: other.end, t),
            width: width + (other.width - width) * t
        )
    }
}

public struct PerryCharacterPose: Equatable, Sendable {
    public enum Face: Equatable, Sendable {
        case open
        case wide
        case focused
        case speaking
        case worried
        case happy
        case asleep

        var eye: PerryStroke {
            switch self {
            case .open: .vertical(0.15, width: 0.09)
            case .wide: .vertical(0.2, width: 0.105)
            case .focused: .vertical(0.06, width: 0.09)
            case .speaking: .vertical(0.12, width: 0.09)
            case .worried: .vertical(0.035, width: 0.115)
            case .happy: .arc(0.085, bend: 0.04, width: 0.055)
            case .asleep: .arc(0.1, bend: -0.04, width: 0.065)
            }
        }

        var mouth: PerryStroke {
            switch self {
            case .happy: .arc(0.1, bend: -0.04, width: 0.045)
            case .worried: .vertical(0.012, width: 0.055)
            case .speaking: .horizontal(0.04, width: 0.065)
            case .open, .wide, .focused, .asleep: .hidden
            }
        }
    }

    enum Status: Equatable, Sendable {
        case none
        case listening(level: Double, phase: Double)
        case thinking(phase: Double)
        case working(phase: Double)
        case done(progress: Double)
        case needsYou(pulse: Double)
        case asleep(phase: Double)

        var kind: Int {
            switch self {
            case .none: 0
            case .listening: 1
            case .thinking: 2
            case .working: 3
            case .done: 4
            case .needsYou: 5
            case .asleep: 6
            }
        }
    }

    public var face = Face.open {
        didSet { (eye, mouth) = (face.eye, face.mouth) }
    }
    public var gaze: CGVector = .zero
    public var lean: Double = 0
    public var stretch: Double = 1
    public var stretchAngle: Double = .pi / 2
    public var hop: Double = 0
    var eye = Face.open.eye
    var mouth = Face.open.mouth
    var eyeOpen: Double = 1
    var trail: CGVector = .zero
    var status = Status.none
    var statusPresence: Double = 1
    var statusScale: Double = 1

    public init() {}
}

public struct PerryCharacterRig: Sendable {
    public static let sleepAfter: TimeInterval = 45
    public static let celebrationLength: TimeInterval = 0.9
    static let blendLength: TimeInterval = 0.28
    static let maxLean = 0.18
    static let blinkLength = 0.14

    public var mood: PerryMood
    public var previousMood: PerryMood?
    public var moodAge: TimeInterval
    public var time: TimeInterval
    public var velocity: CGVector = .zero
    public var acceleration: CGVector = .zero
    public var micLevel: Double = 0
    public var stillFor: TimeInterval = 0
    public var reduceMotion = false

    public init(
        mood: PerryMood,
        previousMood: PerryMood? = nil,
        moodAge: TimeInterval,
        time: TimeInterval,
        velocity: CGVector = .zero,
        acceleration: CGVector = .zero,
        micLevel: Double = 0,
        stillFor: TimeInterval = 0,
        reduceMotion: Bool = false
    ) {
        self.mood = mood
        self.previousMood = previousMood
        self.moodAge = moodAge
        self.time = time
        self.velocity = velocity
        self.acceleration = acceleration
        self.micLevel = micLevel
        self.stillFor = stillFor
        self.reduceMotion = reduceMotion
    }

    public var effectiveMood: PerryMood {
        mood == .resting && stillFor >= Self.sleepAfter ? .sleeping : mood
    }

    public var pose: PerryCharacterPose {
        var (from, age) = (previousMood, moodAge)
        if mood == .resting, effectiveMood == .sleeping {
            (from, age) = (.resting, stillFor - Self.sleepAfter)
        }
        var pose = expression(effectiveMood, age: age)
        if let from, from != effectiveMood, age < Self.blendLength {
            let progress = age / Self.blendLength
            pose = Self.blend(expression(from, age: age + Self.blendLength), pose, progress: progress, reduceMotion: reduceMotion)
            if !reduceMotion, pose.hop == 0 {
                pose.stretch -= 0.09 * sin(.pi * progress)
            }
        }
        applyTravel(to: &pose)
        return pose
    }

    private func expression(_ mood: PerryMood, age: TimeInterval) -> PerryCharacterPose {
        var pose = PerryCharacterPose()
        let level = min(max(micLevel, 0), 1)
        let t = reduceMotion ? 0 : time
        pose.eyeOpen = reduceMotion ? 1 : Self.blinkOpenness(at: time)

        switch mood {
        case .resting:
            pose.gaze = CGVector(dx: -0.5, dy: -0.4)
        case .sleeping:
            pose.face = .asleep
            pose.eyeOpen = 1
            pose.status = .asleep(phase: (t / 2.6).truncatingRemainder(dividingBy: 1))
            pose.stretch = 0.9 + 0.04 * sin(t * 2 * .pi / 3.2)
        case .listening:
            pose.face = .wide
            pose.status = .listening(level: level, phase: t)
            pose.stretch = 1.07 + 0.1 * level
        case .thinking:
            pose.gaze = CGVector(dx: 0.7 + 0.3 * sin(t * 1.3), dy: -0.75)
            pose.status = .thinking(phase: (t / 1.1).truncatingRemainder(dividingBy: 1))
            pose.lean = -0.12 + 0.05 * sin(t * 2 * .pi / 1.6)
        case .speaking:
            let chatter = reduceMotion ? 0.5 : 0.2 + 0.8 * abs(sin(t * 10.5)) * max(level, 0.45)
            pose.face = .speaking
            pose.mouth.width = 0.03 + 0.07 * chatter
            pose.hop = 0.18 * chatter
        case .working:
            pose.face = .focused
            pose.gaze = CGVector(dx: -0.6, dy: -0.8)
            pose.status = .working(phase: (t / 0.85).truncatingRemainder(dividingBy: 1))
            pose.hop = 0.1 * abs(sin(t * .pi * 2.4))
            pose.lean = 0.08
            pose.stretch = 0.94
        case .celebrating:
            pose.face = .happy
            pose.eyeOpen = 1
            pose.status = .done(progress: reduceMotion ? 1 : min(age / Self.celebrationLength, 1))
        case .needsYou:
            pose.face = .worried
            pose.status = .needsYou(pulse: 0.5 + 0.5 * sin(t * 2 * .pi / 1.4))
            let beat = (t / 1.4).truncatingRemainder(dividingBy: 1)
            pose.lean = beat < 0.35 ? 0.16 * sin(beat / 0.35 * 6 * .pi) * (1 - beat / 0.35) : 0
            pose.stretch = 1.06
        }
        if mood == .celebrating && !reduceMotion {
            let p = min(age / Self.celebrationLength, 1)
            let crouch = p < 0.18 ? sin(p / 0.18 * .pi) : 0
            let air = p >= 0.18 ? sin((p - 0.18) / 0.82 * .pi) : 0
            pose.hop = air
            pose.stretch = 1 - 0.12 * crouch + 0.1 * air * (1 - p)
        }
        if reduceMotion {
            (pose.lean, pose.stretch, pose.hop) = (0, 1, 0)
        }
        return pose
    }

    private func applyTravel(to pose: inout PerryCharacterPose) {
        let speed = hypot(velocity.dx, velocity.dy)
        if speed > 40 {
            let look = min(speed / 600, 1)
            let dir = CGVector(dx: velocity.dx / speed, dy: velocity.dy / speed)
            pose.gaze = CGVector(dx: pose.gaze.dx + (dir.dx - pose.gaze.dx) * look, dy: pose.gaze.dy + (dir.dy - pose.gaze.dy) * look)
        }
        guard !reduceMotion else { return }
        let sway = velocity.dx / 3500 - acceleration.dx / 90000
        pose.lean = max(-Self.maxLean, min(Self.maxLean, pose.lean + sway))
        if speed > 60, pose.hop < 0.1 {
            pose.stretch = 1 + min(speed / 8000, 0.14)
            pose.stretchAngle = atan2(velocity.dy, velocity.dx)
        }
        let lag = min(speed, 1600) / 1600 * 0.09
        if speed > 1 {
            pose.trail = CGVector(dx: -velocity.dx / speed * lag, dy: -velocity.dy / speed * lag)
        }
    }

    static func blend(_ a: PerryCharacterPose, _ b: PerryCharacterPose, progress: Double, reduceMotion: Bool) -> PerryCharacterPose {
        let u = 1 - pow(1 - min(max(progress, 0), 1), 3)
        var pose = b
        pose.eye = a.eye.mixed(with: b.eye, u)
        pose.mouth = a.mouth.mixed(with: b.mouth, u)
        pose.gaze = CGVector(dx: a.gaze.dx + (b.gaze.dx - a.gaze.dx) * u, dy: a.gaze.dy + (b.gaze.dy - a.gaze.dy) * u)
        pose.eyeOpen = b.eyeOpen
        pose.lean = a.lean + (b.lean - a.lean) * u
        pose.stretch = a.stretch + (b.stretch - a.stretch) * u
        if a.status.kind != b.status.kind {
            let outgoing = progress < 0.4
            pose.status = outgoing ? a.status : b.status
            let local = outgoing ? 1 - progress / 0.4 : (progress - 0.4) / 0.6
            pose.statusPresence = min(max(local, 0), 1)
            pose.statusScale = reduceMotion ? 1 : outgoing ? 0.6 + 0.4 * local : backOut(local)
        }
        return pose
    }

    static func backOut(_ t: Double) -> Double {
        let x = min(max(t, 0), 1) - 1
        return 0.6 + 0.4 * (1 + 2.7 * x * x * x + 1.7 * x * x)
    }

    static func blinkOpenness(at time: TimeInterval) -> Double {
        let cycle = 3.9
        let index = floor(time / cycle)
        let jitter = (sin(index * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
        let blinkStart = abs(jitter) * (cycle - 0.6)
        let local = time - index * cycle - blinkStart
        guard local >= 0, local < blinkLength else { return 1 }
        return max(abs(local / blinkLength * 2 - 1), 0.3)
    }
}

extension CGPoint {
    func mixed(with other: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: x + (other.x - x) * t, y: y + (other.y - y) * t)
    }
}

public struct PerryCharacterView: View {
    public var pose: PerryCharacterPose
    public var size: CGFloat
    public var tint: Color

    public init(pose: PerryCharacterPose, size: CGFloat = 40, tint: Color = PerryCharacterView.fern) {
        self.pose = pose
        self.size = size
        self.tint = tint
    }

    public static let fern = Color(red: 0.369, green: 0.859, blue: 0.506)
    static let carbon = Color(red: 0.047, green: 0.051, blue: 0.055)
    static let amber = Color(red: 0.98, green: 0.70, blue: 0.20)

    public var body: some View {
        Canvas { context, canvas in
            context.translateBy(x: canvas.width / 2, y: canvas.height / 2 - CGFloat(pose.hop) * size * 0.32)
            context.scaleBy(x: size, y: size)
            drawBody(&context)
            drawStatus(&context)
        }
        .frame(width: size * 2, height: size * 2)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var bodyTransform: CGAffineTransform {
        let tip = PerryBodyShape.tip
        let a = CGFloat(pose.stretchAngle)
        let k = CGFloat(pose.stretch)
        return CGAffineTransform(translationX: -tip.x, y: -tip.y)
            .concatenating(CGAffineTransform(rotationAngle: -a))
            .concatenating(CGAffineTransform(scaleX: k, y: 1 / k))
            .concatenating(CGAffineTransform(rotationAngle: a + CGFloat(pose.lean)))
            .concatenating(CGAffineTransform(translationX: tip.x, y: tip.y))
    }

    private func drawBody(_ context: inout GraphicsContext) {
        let shape = PerryBodyShape.unitPath.applying(bodyTransform)
        var shadowed = context
        shadowed.addFilter(.shadow(color: .black.opacity(0.3), radius: 0.045, x: 0, y: 0.025))
        shadowed.stroke(shape, with: .color(.white), style: StrokeStyle(lineWidth: 0.15, lineJoin: .miter, miterLimit: 3))
        context.fill(shape, with: .color(tint))
        context.stroke(shape, with: .color(Self.carbon), style: StrokeStyle(lineWidth: 0.055, lineJoin: .miter, miterLimit: 3))
        let face = PerryBodyShape.faceCenter
        let look = CGPoint(x: pose.gaze.dx * 0.035, y: pose.gaze.dy * 0.03)
        for side in [-1.0, 1.0] {
            let eye = CGPoint(x: face.x + side * 0.095 + look.x, y: face.y - 0.025 + look.y)
            draw(pose.eye, at: eye, squash: pose.eyeOpen, in: &context)
        }
        draw(pose.mouth, at: CGPoint(x: face.x + look.x * 0.6, y: face.y + 0.18 + look.y * 0.6), squash: 1, in: &context)
    }

    private func draw(_ stroke: PerryStroke, at center: CGPoint, squash: Double, in context: inout GraphicsContext) {
        guard stroke.width > 0.004 else { return }
        var path = Path()
        path.move(to: stroke.start)
        path.addQuadCurve(to: stroke.end, control: stroke.control)
        let shape = path.strokedPath(StrokeStyle(lineWidth: stroke.width, lineCap: .round))
            .applying(CGAffineTransform(scaleX: 1.15, y: 1.15 * CGFloat(squash)))
            .applying(CGAffineTransform(rotationAngle: CGFloat(pose.lean)))
        let anchor = center.applying(bodyTransform)
        let placed = shape.applying(CGAffineTransform(translationX: anchor.x, y: anchor.y))
        context.fill(placed, with: .color(Self.carbon))
    }

    private func drawStatus(_ context: inout GraphicsContext) {
        guard pose.status != .none, pose.statusPresence > 0.01 else { return }
        var chip = context
        chip.opacity = pose.statusPresence
        chip.translateBy(x: 0.44 + pose.trail.dx, y: -0.33 + pose.trail.dy)
        chip.scaleBy(x: pose.statusScale * 1.4, y: pose.statusScale * 1.4)
        switch pose.status {
        case .none:
            break
        case .listening(let level, let phase):
            plate(&chip, width: 0.5, height: 0.36, fill: Self.carbon)
            for i in 0..<3 {
                let wave = 0.5 + 0.5 * sin(phase * 9 + Double(i) * 2.1)
                let h = 0.08 + (0.06 + 0.12 * level) * (i == 1 ? 1 : 0.7) * (0.45 + 0.55 * wave)
                let x = CGFloat(i - 1) * 0.115
                chip.fill(Path(roundedRect: CGRect(x: x - 0.04, y: -h / 2, width: 0.08, height: h), cornerRadius: 0.04), with: .color(tint))
            }
        case .thinking(let phase):
            let dots: [(CGPoint, CGFloat)] = [(CGPoint(x: -0.07, y: 0.06), 0.09), (CGPoint(x: 0.035, y: -0.05), 0.125), (CGPoint(x: 0.17, y: -0.19), 0.17)]
            for (i, dot) in dots.enumerated() {
                let pulse = max(0, sin((phase - Double(i) * 0.22) * 2 * .pi))
                let d = dot.1 * (1 + 0.18 * pulse)
                let rect = CGRect(x: dot.0.x - d / 2, y: dot.0.y - d / 2, width: d, height: d)
                chip.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 0.06)
                chip.fill(Path(ellipseIn: rect), with: .color(Self.carbon))
            }
        case .working(let phase):
            plate(&chip, width: 0.42, height: 0.42, fill: Self.carbon)
            var arc = Path()
            arc.addArc(center: .zero, radius: 0.105, startAngle: .radians(phase * 2 * .pi), endAngle: .radians(phase * 2 * .pi + 4.2), clockwise: false)
            chip.stroke(arc, with: .color(tint), style: StrokeStyle(lineWidth: 0.065, lineCap: .round))
        case .done(let progress):
            plate(&chip, width: 0.42, height: 0.42, fill: Self.carbon)
            var tick = Path()
            tick.move(to: CGPoint(x: -0.09, y: 0.0))
            tick.addLine(to: CGPoint(x: -0.025, y: 0.065))
            tick.addLine(to: CGPoint(x: 0.095, y: -0.075))
            chip.stroke(tick.trimmedPath(from: 0, to: min(progress * 2.6, 1)), with: .color(tint), style: StrokeStyle(lineWidth: 0.075, lineCap: .round, lineJoin: .round))
        case .needsYou(let pulse):
            chip.scaleBy(x: 1 + 0.07 * pulse, y: 1 + 0.07 * pulse)
            plate(&chip, width: 0.42, height: 0.42, fill: Self.amber)
            chip.fill(Path(roundedRect: CGRect(x: -0.035, y: -0.13, width: 0.07, height: 0.15), cornerRadius: 0.035), with: .color(Self.carbon))
            chip.fill(Path(ellipseIn: CGRect(x: -0.038, y: 0.06, width: 0.076, height: 0.076)), with: .color(Self.carbon))
        case .asleep(let phase):
            for i in 0..<2 {
                let p = (phase + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                let k = 0.12 + 0.08 * p
                var z = Path()
                z.move(to: CGPoint(x: -k / 2, y: -k / 2))
                z.addLine(to: CGPoint(x: k / 2, y: -k / 2))
                z.addLine(to: CGPoint(x: -k / 2, y: k / 2))
                z.addLine(to: CGPoint(x: k / 2, y: k / 2))
                let placed = z.applying(CGAffineTransform(translationX: -0.1 + 0.3 * p, y: 0.1 - 0.46 * p))
                var glyph = chip
                glyph.opacity = sin(p * .pi)
                glyph.stroke(placed, with: .color(.white), style: StrokeStyle(lineWidth: 0.13, lineCap: .round, lineJoin: .round))
                glyph.stroke(placed, with: .color(Self.carbon), style: StrokeStyle(lineWidth: 0.065, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func plate(_ context: inout GraphicsContext, width: CGFloat, height: CGFloat, fill: Color) {
        let shape = Path(roundedRect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height), cornerRadius: min(width, height) / 2)
        var shadowed = context
        shadowed.addFilter(.shadow(color: .black.opacity(0.28), radius: 0.035, x: 0, y: 0.02))
        shadowed.stroke(shape, with: .color(.white), lineWidth: 0.07)
        context.fill(shape, with: .color(fill))
    }
}

public struct PerryBodyShape: Shape {
    public static let tip = CGPoint(x: -0.3, y: -0.4)
    static let center = CGPoint(x: 0.101, y: 0.124)
    static let radius: CGFloat = 0.285
    static let faceCenter = CGPoint(x: 0.096, y: 0.104)

    static let unitPath: Path = {
        let d = hypot(center.x - tip.x, center.y - tip.y)
        let axis = atan2(center.y - tip.y, center.x - tip.x)
        let spread = acos(radius / d)
        let start = axis + .pi - spread
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: center.x + radius * cos(start), y: center.y + radius * sin(start)))
        path.addArc(center: center, radius: radius, startAngle: .radians(start), endAngle: .radians(axis + .pi + spread), clockwise: true)
        path.closeSubpath()
        return path
    }()

    public init() {}

    public func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        return Self.unitPath.applying(CGAffineTransform(scaleX: s, y: s).concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)))
    }
}

final class PerryCharacterMotion {
    private var lastPosition: CGPoint?
    private var lastSampleTime: TimeInterval = 0
    private var lastMoveTime: TimeInterval = 0
    private var velocity: CGVector = .zero
    private var acceleration: CGVector = .zero
    private var mood: PerryMood?
    private var previousMood: PerryMood?
    private var moodSince: TimeInterval = 0

    func rig(at time: TimeInterval, position: CGPoint, mood: PerryMood, micLevel: Double, reduceMotion: Bool) -> PerryCharacterRig {
        if mood != self.mood {
            previousMood = self.mood
            self.mood = mood
            moodSince = time
        }
        if let last = lastPosition {
            let dt = max(time - lastSampleTime, 1.0 / 240)
            let raw = CGVector(dx: (position.x - last.x) / dt, dy: (position.y - last.y) / dt)
            let blend = min(dt * 14, 1)
            let next = CGVector(dx: velocity.dx + (raw.dx - velocity.dx) * blend, dy: velocity.dy + (raw.dy - velocity.dy) * blend)
            let rawAcceleration = CGVector(dx: (next.dx - velocity.dx) / dt, dy: (next.dy - velocity.dy) / dt)
            acceleration = CGVector(dx: acceleration.dx + (rawAcceleration.dx - acceleration.dx) * blend, dy: acceleration.dy + (rawAcceleration.dy - acceleration.dy) * blend)
            velocity = next
            if position != last { lastMoveTime = time }
        } else {
            lastMoveTime = time
        }
        lastPosition = position
        lastSampleTime = time
        return PerryCharacterRig(
            mood: mood,
            previousMood: previousMood,
            moodAge: time - moodSince,
            time: time,
            velocity: velocity,
            acceleration: acceleration,
            micLevel: micLevel,
            stillFor: time - lastMoveTime,
            reduceMotion: reduceMotion
        )
    }

    var isMoving: Bool { hypot(velocity.dx, velocity.dy) > 4 }
}

private struct PerryCharacterPausedKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var perryCharacterPaused: Bool {
        get { self[PerryCharacterPausedKey.self] }
        set { self[PerryCharacterPausedKey.self] = newValue }
    }
}

public struct PerryCharacter: View {
    let mood: PerryMood
    let position: CGPoint
    let micLevel: Double
    let size: CGFloat
    @State private var motion = PerryCharacterMotion()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.perryCharacterPaused) private var paused

    public init(mood: PerryMood, position: CGPoint = .zero, micLevel: Double = 0, size: CGFloat = 44) {
        self.mood = mood
        self.position = position
        self.micLevel = micLevel
        self.size = size
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval, paused: paused)) { context in
            let rig = motion.rig(
                at: context.date.timeIntervalSinceReferenceDate,
                position: position,
                mood: mood,
                micLevel: micLevel,
                reduceMotion: reduceMotion
            )
            PerryCharacterView(pose: rig.pose, size: size)
        }
    }

    private var frameInterval: TimeInterval {
        if reduceMotion { return 1.0 / 8 }
        switch mood {
        case .resting, .sleeping: return motion.isMoving ? 1.0 / 60 : 1.0 / 15
        case .listening, .speaking, .celebrating, .thinking, .working, .needsYou: return 1.0 / 60
        }
    }
}
