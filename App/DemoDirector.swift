import Combine
import Foundation
import PerryRuntimes

struct DemoPreflightResult: Equatable {
    let ready: Bool
    let failureMessage: String

    static let ready = DemoPreflightResult(ready: true, failureMessage: "")
}

@MainActor
final class DemoDirector: ObservableObject {
    enum Phase: Equatable {
        case idle
        case prechecking
        case waking
        case spatial
        case guiding
        case doing
        case reporting
        case failed
    }

    struct Hooks {
        let preflight: () async -> DemoPreflightResult
        let wake: () -> Void
        let speak: (String) -> Void
        let waitForSpatialSelection: () async -> SpatialSelection?
        let cancelPendingInputs: () -> Void
        let describeSpatialSelection: (SpatialSelection) async -> Bool
        let runGuide: (String) async -> Bool
        let runDo: (String) async -> DoOutcome?
        let report: (DoOutcome) -> Void
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = ""
    @Published private(set) var lastError: String?
    /// Verified result text from the last successful run — shown on the final
    /// onboarding card so onboarding ends on evidence, not a generic greeting.
    private(set) var lastVerifiedResult: String?

    private let hooks: Hooks
    private var runTask: Task<Void, Never>?
    private var cancelled = false
    private var completion: ((Bool) -> Void)?

    init(hooks: Hooks) {
        self.hooks = hooks
    }

    func run(
        recipe: DemoRecipe = .current,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard runTask == nil, (phase == .idle || phase == .failed) else { return }
        cancelled = false
        lastError = nil
        lastVerifiedResult = nil
        self.completion = completion
        runTask = Task { @MainActor [weak self] in
            await self?.execute(recipe: recipe)
            self?.runTask = nil
        }
    }

    func cancel() {
        cancelled = true
        runTask?.cancel()
        hooks.cancelPendingInputs()
        phase = .idle
        status = ""
        finish(succeeded: false)
    }

    private func execute(recipe: DemoRecipe) async {
        phase = .prechecking
        status = "Checking permissions and the local agent."
        let preflight = await hooks.preflight()
        guard !cancelled else { return }
        guard preflight.ready else {
            fail(preflight.failureMessage)
            return
        }
        guard !cancelled else { return }

        phase = .waking
        status = "Waking Perry."
        hooks.wake()
        await settle(for: 0.6)
        guard !cancelled else { return }

        phase = .spatial
        status = "Circle a real area with ⌥⌘ and drag."
        hooks.speak("Circle any real area on screen with Option Command and drag. I’ll read what’s there.")
        guard !cancelled else { return }
        guard let selection = await hooks.waitForSpatialSelection() else {
            guard !cancelled else { return }
            fail("I didn’t receive a completed circle, so I stopped the demo without pretending.")
            return
        }
        guard !cancelled else { return }
        guard await hooks.describeSpatialSelection(selection) else {
            guard !cancelled else { return }
            fail("I couldn’t describe the circled area, so I stopped the demo honestly.")
            return
        }
        guard !cancelled else { return }

        phase = .guiding
        status = "Teaching live steps: \(recipe.guideTask)."
        guard await hooks.runGuide(recipe.guideGoal) else {
            guard !cancelled else { return }
            fail("The live guide could not start, so I stopped the demo honestly.")
            return
        }
        guard !cancelled else { return }

        phase = .doing
        status = "Running the real task in PerryDemo."
        guard let outcome = await hooks.runDo(recipe.doGoal) else {
            guard !cancelled else { return }
            fail("The sandboxed task could not start, so I stopped the demo honestly.")
            return
        }
        guard !cancelled else { return }
        switch outcome {
        case .completed:
            break
        case .blocked(let reason):
            fail("The demo stopped safely: \(reason)")
            return
        case .failed(let step, let reason):
            fail("The demo stopped at \(step): \(reason)")
            return
        }

        phase = .reporting
        status = "Writing the verified result to history."
        hooks.report(outcome)
        await settle(for: 0.4)
        phase = .idle
        status = "Demo complete."
        lastVerifiedResult = recipe.expectedResult
        finish(succeeded: true)
    }

    private func settle(for seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func fail(_ message: String) {
        lastError = message
        status = message
        phase = .failed
        hooks.speak(message)
        finish(succeeded: false)
    }

    private func finish(succeeded: Bool) {
        let callback = completion
        completion = nil
        callback?(succeeded)
    }
}
