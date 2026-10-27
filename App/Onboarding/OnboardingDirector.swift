import Foundation
import PerryCapture

@MainActor
final class OnboardingDirector: ObservableObject {
    enum Beat: String, CaseIterable, Sendable {
        case hello, brain, access, shortcuts, interview, apps, firstGoal
    }

    enum Direction: Sendable {
        case forward, backward
    }

    struct Effects {
        var permissionProbe: () async -> PerryPermissionSnapshot = { await PerryPermissionSnapshot.probe() }
        var grant: (PrivacyPane) async -> Void = { _ in }
        var saveName: (String) -> Void = { _ in }
        var mark: (StaticString) -> Void = { _ in }
        var dismiss: () -> Void = {}
        var finish: (_ keepNotchOpen: Bool) -> Void = { _ in }
        var hasApps: () -> Bool = { true }
    }

    static let accessPanes: [PrivacyPane] = [.accessibility, .microphone]

    @Published private(set) var beat: Beat?
    @Published private(set) var direction = Direction.forward
    @Published private(set) var permissions: PerryPermissionSnapshot?
    @Published var choosingBrain = false

    private let effects: Effects
    private let defaults: UserDefaults?
    private var firstAnswerMarked = false
    private var isRefreshingPermissions = false

    init(effects: Effects = Effects(), defaults: UserDefaults? = nil) {
        self.effects = effects
        self.defaults = defaults
    }

    var canGoBack: Bool {
        guard let beat else { return false }
        return beat != .hello
    }

    var accessGranted: Bool {
        guard let permissions else { return false }
        return permissions.accessibility && permissions.microphone.isUsable
    }

    func start(resume: Bool = true) {
        let saved = resume ? defaults?.string(forKey: PerryPreferences.$onboardingBeat.key).flatMap(Beat.init(rawValue:)) : nil
        defaults?.removeObject(forKey: PerryPreferences.$onboardingDismissed.key)
        firstAnswerMarked = false
        effects.mark("onboarding.start")
        enter(saved == .apps && !effects.hasApps() ? .firstGoal : saved ?? .hello, direction: .forward)
    }

    func skip() {
        guard let beat else { return }
        guard let next = neighbor(of: beat, step: 1) else { return finish(keepNotchOpen: false) }
        enter(next, direction: .forward)
    }

    func acceptName(_ name: String) {
        guard beat == .hello else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { effects.saveName(trimmed) }
        skip()
    }

    static func suggestedName(saved: String?, fullName: String) -> String {
        saved ?? fullName.split(separator: " ").first.map(String.init) ?? ""
    }

    func goBack() {
        if choosingBrain { return choosingBrain = false }
        guard canGoBack, let beat, let previous = neighbor(of: beat, step: -1) else { return }
        enter(previous, direction: .backward)
    }

    var beats: [Beat] {
        Beat.allCases.filter { $0 != .apps || effects.hasApps() }
    }

    private func neighbor(of beat: Beat, step: Int) -> Beat? {
        let beats = beats
        guard let index = beats.firstIndex(of: beat) else { return nil }
        return beats.indices.contains(index + step) ? beats[index + step] : nil
    }

    func close() {
        guard beat != nil else { return }
        defaults?.set(true, forKey: PerryPreferences.$onboardingDismissed.key)
        stop()
        effects.dismiss()
    }

    func stop() {
        beat = nil
    }

    func noteTalkTurnCompleted() {
        guard beat != nil, !firstAnswerMarked else { return }
        firstAnswerMarked = true
        effects.mark("onboarding.first_answer")
    }

    func grant(_ pane: PrivacyPane) async {
        guard beat == .access else { return }
        await effects.grant(pane)
        await refreshPermissions()
    }

    func refreshPermissions() async {
        guard beat == .access, !isRefreshingPermissions else { return }
        isRefreshingPermissions = true
        defer { isRefreshingPermissions = false }
        let isFirstProbe = permissions == nil
        let snapshot = await effects.permissionProbe()
        guard beat == .access else { return }
        permissions = snapshot
        if isFirstProbe, direction == .forward, accessGranted { skip() }
    }

    func beginFirstTask() {
        guard beat == .firstGoal else { return }
        finish(keepNotchOpen: true)
    }

    private func finish(keepNotchOpen: Bool) {
        stop()
        defaults?.removeObject(forKey: PerryPreferences.$onboardingBeat.key)
        effects.mark("onboarding.finish")
        effects.finish(keepNotchOpen)
    }

    private func enter(_ next: Beat, direction: Direction) {
        self.direction = direction
        choosingBrain = false
        beat = next
        permissions = nil
        defaults?.set(next.rawValue, forKey: PerryPreferences.$onboardingBeat.key)
        effects.mark(Self.mark(for: next))
    }

    private static func mark(for beat: Beat) -> StaticString {
        switch beat {
        case .hello: "onboarding.beat.hello"
        case .brain: "onboarding.beat.brain"
        case .access: "onboarding.beat.access"
        case .shortcuts: "onboarding.beat.shortcuts"
        case .interview: "onboarding.beat.interview"
        case .apps: "onboarding.beat.apps"
        case .firstGoal: "onboarding.beat.firstGoal"
        }
    }
}
