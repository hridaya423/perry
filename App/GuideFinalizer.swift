import Foundation
import PerryCore
import PerryGuide

@MainActor
final class GuideFinalizer {
    private let transcriptStore: TranscriptStore
    private let memoryStore: MemoryStore
    private var inFlight: [UUID: GuideWorkerSession] = [:]

    init(transcriptStore: TranscriptStore, memoryStore: MemoryStore) {
        self.transcriptStore = transcriptStore
        self.memoryStore = memoryStore
    }

    func schedule(for scope: GuideWorkerSession) {
        guard let request = scope.takePendingFinalization() else { return }
        inFlight[scope.id] = scope
        scope.finalizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlight[scope.id] = nil }
            scope.conversationOutcome = (await Self.conversationAnswer(request, engine: scope.engine), request.agentFinish)
            guard !scope.finalizationSuppressed else { return }
            _ = await self.transcriptStore.append(request.transcriptEntry)
            if let workflow = request.workflowMemory {
                _ = await self.memoryStore.remember(workflow)
            }
        }
    }

    func suppressInFlight() {
        inFlight.values.forEach { $0.suppressFinalization() }
    }

    func settle(_ scopes: [GuideWorkerSession]) async {
        for scope in scopes + Array(inFlight.values) {
            await scope.finalizationTask?.value
        }
    }

    private static func conversationAnswer(_ request: GuideFinalizationRequest, engine: GuideEngine?) async -> String {
        let progress = await engine?.progress
        let current = await engine?.currentPresentation()?.step.instruction
        var details = [request.summary]
        if let progress {
            if !progress.completedInstructions.isEmpty {
                details.append("Observed completed steps:\n" + progress.completedInstructions.joined(separator: "\n"))
            }
            if !progress.userConfirmedInstructions.isEmpty {
                details.append("User-confirmed steps, not independently verified:\n" + progress.userConfirmedInstructions.joined(separator: "\n"))
            }
        }
        if let current { details.append("Last instruction, not verified complete: " + current) }
        return details.joined(separator: "\n\n")
    }
}
