import AppKit
import PerryOverlay
import SwiftUI

enum NotchEyeMood: Equatable, CaseIterable {
    case resting, listening, working, needsYou, asleep

    init(_ mood: PerryMood) {
        switch mood {
        case .listening: self = .listening
        case .thinking, .speaking, .working: self = .working
        case .needsYou: self = .needsYou
        case .sleeping: self = .asleep
        case .resting, .celebrating: self = .resting
        }
    }

    var isActive: Bool { self == .listening || self == .working || self == .needsYou }
}

struct EyeScheduler {
    struct Blink: Equatable {
        var delay: TimeInterval
        var double: Bool
    }

    static let blinkRange: ClosedRange<TimeInterval> = 3.2...7.5
    static let glanceRange: ClosedRange<TimeInterval> = 8...20
    static let workingGlanceRange: ClosedRange<TimeInterval> = 2.5...4
    static let doubleBlinkChance = 0.15

    var paused = false

    func nextBlink<R: RandomNumberGenerator>(mood: NotchEyeMood, using rng: inout R) -> Blink? {
        guard !paused, mood != .needsYou, mood != .asleep else { return nil }
        return Blink(delay: .random(in: Self.blinkRange, using: &rng),
                     double: Double.random(in: 0..<1, using: &rng) < Self.doubleBlinkChance)
    }

    func nextGlance<R: RandomNumberGenerator>(mood: NotchEyeMood, using rng: inout R) -> TimeInterval? {
        guard !paused, mood != .needsYou, mood != .asleep else { return nil }
        return .random(in: mood == .working ? Self.workingGlanceRange : Self.glanceRange, using: &rng)
    }
}

@MainActor
final class NotchEyesModel: ObservableObject {
    @Published private(set) var mood: NotchEyeMood = .resting
    @Published private(set) var lid: CGFloat = 1
    @Published private(set) var look: CGSize = .zero
    @Published private(set) var swollen = false

    private var source: NotchEyeMood = .resting
    private var scheduler = EyeScheduler()
    private var rng = SystemRandomNumberGenerator()
    private var blinkTimer: Timer?
    private var glanceTimer: Timer?
    private var sleepTimer: Timer?
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    private var screensAsleep = false
    private var locked = false

    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { _ in }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }
        observe(.default, .NSProcessInfoPowerStateDidChange) { _ in }
        reschedule()
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        [blinkTimer, glanceTimer, sleepTimer].forEach { $0?.invalidate() }
        blinkTimer = nil
        glanceTimer = nil
        sleepTimer = nil
    }

    func setMood(_ mood: NotchEyeMood) {
        guard mood != source else { return }
        source = mood
        wake()
    }

    func hover(_ inside: Bool) {
        withAnimation(inside ? .spring(response: 0.30, dampingFraction: 0.72) : .spring(response: 0.26, dampingFraction: 0.95)) {
            swollen = inside
            look = inside ? CGSize(width: -2, height: 1) : .zero
        }
        if inside { wake() }
    }

    private func wake() {
        if mood != source {
            withAnimation(.easeInOut(duration: 0.2)) { mood = source }
        }
        reschedule()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping @MainActor (NotchEyesModel) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                self.reschedule()
            }
        }
        observers.append((center, token))
    }

    private func reschedule() {
        scheduler.paused = screensAsleep || locked || ProcessInfo.processInfo.isLowPowerModeEnabled
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        blinkTimer?.invalidate()
        glanceTimer?.invalidate()
        sleepTimer?.invalidate()
        blinkTimer = nil
        glanceTimer = nil
        sleepTimer = nil
        if let blink = scheduler.nextBlink(mood: mood, using: &rng) {
            blinkTimer = oneShot(blink.delay) { $0.blink(twice: blink.double) }
        }
        if let glance = scheduler.nextGlance(mood: mood, using: &rng) {
            glanceTimer = oneShot(glance) { $0.glance() }
        }
        if mood == .resting, !scheduler.paused {
            sleepTimer = oneShot(PerryCharacterRig.sleepAfter) { model in
                withAnimation(.easeInOut(duration: 0.4)) { model.mood = .asleep }
                model.reschedule()
            }
        }
    }

    private func oneShot(_ delay: TimeInterval, _ action: @escaping @MainActor (NotchEyesModel) -> Void) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func blink(twice: Bool) {
        withAnimation(.easeInOut(duration: 0.075)) { lid = 0.08 } completion: {
            withAnimation(.easeInOut(duration: 0.075)) { self.lid = 1 } completion: {
                guard twice else { return self.reschedule() }
                self.blinkTimer = self.oneShot(0.03) { $0.blink(twice: false) }
            }
        }
    }

    private func glance() {
        let side: CGFloat = Bool.random(using: &rng) ? 2 : -2
        withAnimation(.easeInOut(duration: 0.22)) { look = CGSize(width: side, height: 1) } completion: {
            self.glanceTimer = self.oneShot(0.9) { model in
                withAnimation(.easeInOut(duration: 0.22)) { model.look = .zero }
                model.reschedule()
            }
        }
    }
}

struct NotchEyesView: View {
    static let wing: CGFloat = 38
    static let padding: CGFloat = 10

    @ObservedObject var model: NotchEyesModel
    let notch: CGSize?
    let height: CGFloat
    private var active: Bool { model.mood.isActive }

    private var bodyWidth: CGFloat {
        guard let notch else { return 150 }
        return notch.width + 4 + Self.wing + (active ? Self.wing : 0)
    }

    private var bodyOffset: CGFloat {
        notch == nil || active ? 0 : Self.wing / 2
    }

    var body: some View {
        ZStack(alignment: .top) {
            if notch != nil || active {
                ZStack {
                    NotchShape.closed.fill(PerryTheme.Colors.crown)
                        .shadow(color: .black.opacity(model.swollen ? 0.3 : 0), radius: 6)
                    HStack(spacing: 0) {
                        glyph.frame(width: Self.wing)
                        Spacer(minLength: 0)
                        eyes.frame(width: Self.wing)
                    }
                    .padding(.horizontal, NotchShape.closed.topRadius)
                }
                .frame(width: bodyWidth + NotchShape.closed.topRadius * 2 + (model.swollen ? 6 : 0),
                       height: height + (model.swollen ? 4 : 0))
                .offset(x: bodyOffset)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.30, dampingFraction: 0.82), value: active)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        if active {
            Image(systemName: model.mood == .listening ? "waveform" : model.mood == .needsYou ? "exclamationmark" : "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.mood == .needsYou ? PerryTheme.Colors.caution : PerryTheme.Colors.accent)
                .frame(height: height)
        }
    }

    private var eyes: some View {
        let mood = model.mood
        let size = switch mood {
        case .listening: CGSize(width: 8, height: 14)
        case .needsYou: CGSize(width: 7, height: 14)
        case .asleep: CGSize(width: 7, height: 2.5)
        case .resting, .working: CGSize(width: 7, height: 12)
        }
        let fill = switch mood {
        case .listening: PerryTheme.Colors.accent
        case .needsYou: PerryTheme.Colors.caution
        case .asleep: PerryTheme.Colors.eye.opacity(0.6)
        case .resting, .working: PerryTheme.Colors.eye
        }
        return HStack(spacing: 8) {
            ForEach(0..<2, id: \.self) { _ in
                Capsule().fill(fill).frame(width: size.width, height: size.height)
            }
        }
        .scaleEffect(x: 1, y: mood == .asleep ? 1 : model.lid)
        .scaleEffect(model.swollen ? 1.12 : 1)
        .offset(model.look)
        .shadow(color: PerryTheme.Colors.accent.opacity(mood == .asleep ? 0 : mood == .listening ? 0.55 : 0.3), radius: 6)
        .frame(height: height)
    }
}
