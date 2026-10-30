import AppKit
import ApplicationServices
import AVFoundation
import Speech
import PerryCore
import PerryGuide
import PerryOverlay
import PerryRuntimes

extension VoiceController {
    func handleTranscript(_ text: String) {
        hooks.setTranscriptPreview("")
        overlayState.voiceState = .processing
        realtimeVoiceSession?.cancelCurrentResponse()
        let voiceTaskScope = dictationScopedTaskID
        dictationScopedTaskID = nil
        if let voiceTaskScope, voiceTaskScope != hooks.executingTaskID() {
            cancelInput()
            hooks.setStatus("The task changed while you were speaking. Hold the shortcut again.")
            return
        }
        let frontmostApplication = dictationTargetApplication
        dictationTargetApplication = nil
        let frontmostBundleID = frontmostApplication?.bundleIdentifier
        let normalized: String
        do {
            normalized = VoiceTextPolicy.normalize(
                text,
                frontmostBundleID: frontmostBundleID,
                dictionary: try voiceDictionaryEntries()
            )
        } catch {
            hooks.setStatus("I couldn’t read your word replacements.")
            deliverVoiceReply("I couldn’t read your word replacements, so I didn’t send that.")
            return
        }
        let request: String
        if let command = wakeWordGate.match(inTranscript: normalized) {
            deliverVoiceReply("Wake word heard.")
            request = command
        } else {
            request = normalized
        }
        if voiceTaskScope == nil, let insertion = VoiceTextPolicy.insertionText(
            from: request,
            frontmostBundleID: frontmostBundleID,
            dictionary: [:]
        ) {
            guard let frontmostApplication else {
                dictationSpeechEndedAt = nil
                deliverVoiceReply("I couldn’t tell which app to type in, so I stopped.")
                return
            }
            insertTextIntoFrontmostApp(insertion, target: frontmostApplication)
            return
        }
        dictationSpeechEndedAt = nil
        hooks.dispatch(request.isEmpty ? nil : request, voiceTaskScope)
    }

    private func insertTextIntoFrontmostApp(_ text: String, target: NSRunningApplication) {
        guard let bundleID = target.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else {
            dictationInsertionID = nil
            dictationWorkerTask?.cancel()
            hooks.setStatus("Keep the target app focused and I’ll type there.")
            return
        }
        let speechEndedAt = dictationSpeechEndedAt
        dictationSpeechEndedAt = nil
        let language = lastDictationLanguageIdentifier
        let targetHint = CuaTargetHint(bundleID: bundleID, processID: target.processIdentifier)
        let insertionID = UUID()
        let previousTask = dictationWorkerTask
        dictationInsertionID = insertionID
        dictationLearnCheckTask?.cancel()
        previousTask?.cancel()
        hooks.setStatus("Typing…")
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if let previousTask {
                await previousTask.value
            }
            guard self.dictationInsertionID == insertionID else {
                if self.dictationInsertionID == nil {
                    self.dictationWorkerTask = nil
                }
                return
            }
            do {
                try await self.workers.withWorker(
                    scope: .dictation,
                    resources: [.application(bundleID)]
                ) { @MainActor worker in
                    _ = try await worker.insertText(text, target: targetHint)
                    guard let speechEndedAt,
                          let performanceSampleLog = self.performanceSampleLog else { return }
                    let elapsed = DispatchTime.now().uptimeNanoseconds - speechEndedAt
                    do {
                        try await performanceSampleLog.append(PerformanceSample(
                            metricID: "dictation.speech_end_to_insert",
                            collector: "perry.app.cua-dictation-insert.v1",
                            unit: "ms",
                            value: Double(elapsed) / 1_000_000,
                            scenario: "cua-verified-text-insertion"
                        ))
                    } catch {
                        guard self.dictationInsertionID == insertionID, !Task.isCancelled else { return }
                        self.hooks.setStatus("Performance recording failed: \(error.localizedDescription)")
                    }
                }
                guard self.dictationInsertionID == insertionID else {
                    if self.dictationInsertionID == nil {
                        self.dictationWorkerTask = nil
                    }
                    return
                }
                self.dictationInsertionID = nil
                self.dictationWorkerTask = nil
                self.deliverVoiceReply("Typed it.")
                self.recordDictationBackup(text, language: language)
                self.scheduleDictationLearnChecks(
                    inserted: text, target: targetHint, bundleID: bundleID, insertedAt: Date()
                )
            } catch {
                guard self.dictationInsertionID == insertionID else {
                    if self.dictationInsertionID == nil {
                        self.dictationWorkerTask = nil
                    }
                    return
                }
                self.dictationInsertionID = nil
                self.dictationWorkerTask = nil
                guard !Task.isCancelled else { return }
                self.hooks.setStatus("I didn’t type because I couldn’t confirm the field. Try again.")
                self.deliverVoiceReply("I couldn’t confirm the text went in, so I stopped.")
            }
        }
        dictationWorkerTask = task
    }

    private func recordDictationBackup(_ text: String, language: String?) {
        guard let support = supportDirectory() else { return }
        try? DictationBackupStore(
            directory: support.appendingPathComponent(DictationBackupStore.directoryName, isDirectory: true)
        ).record(text: text, language: language)
    }

    private func scheduleDictationLearnChecks(
        inserted text: String, target: CuaTargetHint, bundleID: String, insertedAt: Date
    ) {
        dictationLearnCheckTask?.cancel()
        dictationLearnCheckTask = Task { @MainActor [weak self] in
            for delay in [8.0, 17.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                await self.learnDictationEdits(
                    inserted: text, target: target, bundleID: bundleID, insertedAt: insertedAt
                )
            }
        }
    }

    private static let dictationTextRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXWebArea", "AXScrollArea", "AXStaticText", "AXComboBox",
    ]

    private func focusedTextValue(target: CuaTargetHint, bundleID: String) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let pid = target.processID
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first?.processIdentifier
        guard let pid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focused = focusedRef else { return nil }
        let element = focused as! AXUIElement
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleRef
        ) == .success,
              Self.dictationTextRoles.contains(roleRef as? String ?? "") else { return nil }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueRef
        ) == .success else { return nil }
        return valueRef as? String
    }

    private func learnDictationEdits(
        inserted: String, target: CuaTargetHint, bundleID: String, insertedAt: Date
    ) async {
        let insertedTokens = DictationWords.tokens(inserted)
        guard !insertedTokens.isEmpty else { return }
        guard let observed = focusedTextValue(target: target, bundleID: bundleID) else { return }
        let learned = PersonalDictionaryLearner.learn(
            inserted: inserted, observed: observed, insertedAt: insertedAt, observedAt: Date()
        )
        guard !learned.isEmpty else { return }
        for (spoken, replacement) in learned {
            try? VoiceDictionaryStore(supportDirectory: supportDirectory())
                .set(spoken: spoken, replacement: replacement)
        }
    }
}
