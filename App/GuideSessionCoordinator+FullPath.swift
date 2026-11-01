import Foundation
import PerryCore
import PerryGuide
import PerryRuntimes

struct EverythingGuideSession {
    let id: UUID
    let viewPlan: EverythingViewPlan
    let steps: [GuideStep]
    let observation: GuideObservation
    let context: GuideContext
    let goal: String
}

extension GuideSessionCoordinator {
    func runFullGuide(guide: GuideSessionState, capture: ScreenCapturedWindow) async throws {
        guard let snapshot = capture.accessibilitySnapshotModel else {
            finishGuide(guideID: guide.id, outcome: .failed, summary: "I couldn’t read that window. Try again.")
            return
        }
        let target = capture.target
        guard guideIsCurrent(guide.id), let scope = currentGuideScope else { return }
        await scope.targetStore.set(target.hint)
        let observation = GuideObservation(
            snapshot: snapshot,
            processID: target.processID,
            windowID: target.windowID,
            connectionGeneration: target.connectionGeneration,
            windowBounds: AXElementFrame(x: target.x, y: target.y, width: target.width, height: target.height),
            screenshotData: capture.screenshotData.isEmpty ? nil : capture.screenshotData,
            screenshotMIMEType: capture.screenshotMIMEType,
            observationID: capture.snapshotID
        )
        do {
            try GuideTargetValidator.requireUnprotected(observation)
        } catch {
            finishGuide(guideID: guide.id, outcome: .failed, summary: "That window is protected, so I can’t guide inside it.")
            return
        }
        let guideContext = await planningContext(appBundleID: snapshot.appBundleID)
        guard guideIsCurrent(guide.id) else { return }
        let steps = try await makeGuidePlanner(for: guide).visiblePath(goal: guide.goal, observation: observation, context: guideContext)
        if let barrier = fullGuideContinuationBarrier {
            await barrier(guide.id)
        }
        try Task.checkCancellation()
        guard guideIsCurrent(guide.id),
              let viewPlan = EverythingViewBuilder.build(steps: steps, snapshot: snapshot) else {
            finishGuide(guideID: guide.id, outcome: .failed, summary: "I can’t see anything to point at yet.")
            return
        }
        guard sessionController.transition({ try sessionController.replaceGuidePlan(steps: steps.map { ($0.id, $0.instruction, !$0.target.isVerbal) }) }) else { return }
        everythingGuideSession = EverythingGuideSession(
            id: guide.id,
            viewPlan: viewPlan,
            steps: steps,
            observation: observation,
            context: guideContext,
            goal: guide.goal
        )
        clickObserver.start()
        paint(everything: viewPlan)
        speak("Here’s the path: \(viewPlan.markers.count) steps.", guideID: guide.id)
    }

    func selectMarker(index: Int) {
        guard let session = everythingGuideSession,
              session.id == activeGuideID,
              session.viewPlan.markers.indices.contains(index) else { return }
        select(session.viewPlan.markers[index])
    }

    func selectMarker(at axPoint: CGPointShim) -> Bool {
        guard let session = everythingGuideSession,
              session.id == activeGuideID,
              let marker = session.viewPlan.markers.first(where: {
                  hypot($0.position.x - axPoint.x, $0.position.y - axPoint.y) <= 32
              }) else { return false }
        select(marker)
        return true
    }

    private func paint(everything viewPlan: EverythingViewPlan) {
        guard activeGuideID != nil else { return }
        output?.guideShowFullPath(viewPlan)
        guideControlsState.markerCaptions = viewPlan.markers.map(\.caption)
        guideControlsState.targetLabel = nil
        showGuideControls()
    }

    private func select(_ marker: EverythingViewPlan.Marker) {
        guard let session = everythingGuideSession,
              session.id == activeGuideID,
              let scope = currentGuideScope, let engine = scope.engine else { return }
        let guideID = session.id
        let started = scope.startAction { [weak self] in
            do {
                guard let self, !Task.isCancelled, self.guideIsCurrent(guideID),
                      let firstStep = try await engine.start(
                        goal: session.goal,
                        observation: session.observation,
                        steps: session.steps,
                        selectedIndex: marker.id,
                        context: session.context
                      ),
                      !Task.isCancelled, self.guideIsCurrent(guideID) else { return }
                self.guideStepPosition = marker.id + 1
                self.present(step: firstStep)
                self.speak(firstStep.instruction, guideID: guideID, stepID: firstStep.id)
            } catch {
                guard let self, self.guideIsCurrent(guideID) else { return }
                self.finishGuide(guideID: guideID, outcome: .failed, summary: "That step moved. Tap Find it again.")
            }
        }
        guard started else { return }
        everythingGuideSession = nil
        guideControlsState.markerCaptions = []
    }
}
