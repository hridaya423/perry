import AppKit
import PerryCore
import PerryGuide
import PerryOverlay
import XCTest
@testable import Perry

@MainActor
final class VoiceRoughEdgeTests: XCTestCase {
    private var statuses: [String] = []
    private var wakeListening: [Bool] = []
    private var dispatched: [String?] = []
    private var controller: VoiceController!
    private var pasteboard: NSPasteboard!
    private var support: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        restoreDefaultsAfterTest([PerryPreferences.$speechOutputEnabled.key])
        UserDefaults.standard.set(true, forKey: PerryPreferences.$speechOutputEnabled.key)
        support = try makeTemporaryDirectory()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("perry.rough-edge-tests.\(UUID().uuidString)"))
        let directory = support!
        controller = VoiceController(
            overlayState: PerryCursorState(),
            workers: ScreenWorkerService(),
            notifier: RoughEdgeNotifier(),
            supportDirectory: { directory },
            hooks: VoiceController.Hooks(
                setStatus: { [weak self] in self?.statuses.append($0) },
                dispatch: { [weak self] text, _ in self?.dispatched.append(text) },
                wakeListeningChanged: { [weak self] in self?.wakeListening.append($0) }
            )
        )
        controller.pasteboard = pasteboard
        controller.outputRoute = { (available: true, muted: true) }
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        controller = nil
        super.tearDown()
    }

    private func seedClipboard() {
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)
    }

    func testMutedAckLeavesTheClipboardAlone() {
        seedClipboard()

        controller.deliverVoiceReply("Typed it.")

        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
        XCTAssertTrue(statuses.contains("Audio output is muted."))
    }

    func testMutedAnswerIsCopiedToTheClipboard() {
        seedClipboard()

        controller.deliverAnswer("Your meeting is at three.")

        XCTAssertEqual(pasteboard.string(forType: .string), "Your meeting is at three.")
    }

    func testFailedInsertionKeepsTheTextOnTheClipboardAndInTheBackup() {
        seedClipboard()
        controller.dictationInsertsWithoutPrefix = true

        controller.handleTranscript("buy oat milk")

        XCTAssertEqual(pasteboard.string(forType: .string), "buy oat milk")
        XCTAssertTrue(dispatched.isEmpty)
        XCTAssertTrue(statuses.contains("I couldn’t type that, so I copied it. Paste it where you want it."))
        let backup = DictationBackupStore(
            directory: support.appendingPathComponent(DictationBackupStore.directoryName, isDirectory: true)
        )
        XCTAssertEqual(backup.entries().map(\.text), ["buy oat milk"])
    }

    func testDictateShortcutTextWithoutPrefixIsInsertedNotDispatched() {
        controller.dictationInsertsWithoutPrefix = true

        controller.handleTranscript("remind me about the invoice")

        XCTAssertTrue(dispatched.isEmpty)
        XCTAssertEqual(pasteboard.string(forType: .string), "remind me about the invoice")
        XCTAssertFalse(controller.dictationInsertsWithoutPrefix)
    }

    func testDictateShortcutTextStripsTheSpokenPrefix() {
        controller.dictationInsertsWithoutPrefix = true

        controller.handleTranscript("type remind me about the invoice")

        XCTAssertEqual(pasteboard.string(forType: .string), "remind me about the invoice")
    }

    func testUnconfirmedInsertionDoesNotClaimTheTextWasNotTyped() {
        seedClipboard()

        controller.keepUnsentDictation("buy oat milk", language: nil, mayHaveTyped: true)

        XCTAssertEqual(pasteboard.string(forType: .string), "buy oat milk")
        XCTAssertTrue(statuses.contains("I couldn’t confirm the text went in, so I copied it. Paste it if it’s missing."))
        XCTAssertFalse(statuses.contains { $0.contains("couldn’t type that") })
    }

    func testWakeWordFailureKeepsThePreferenceOnButReportsNotListening() async {
        restoreDefaultsAfterTest([PerryPreferences.$wakeWordEnabled.key])
        PerryPreferences.wakeWordEnabled = true
        controller.wakeWordListener.retryDelays = []
        controller.wakeWordListener.beginListening = { throw WakeStartFailure() }

        controller.wakeWordListener.start()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(PerryPreferences.wakeWordEnabled)
        XCTAssertEqual(wakeListening, [false])
        XCTAssertEqual(statuses.last, "Wake word is unavailable: mic busy. Use the hotkey instead.")
        controller.wakeWordListener.stop()
    }

    private func failWakeWordStart() async {
        controller.wakeWordListener.start()
        try? await Task.sleep(for: .milliseconds(100))
    }

    private var unavailableStatuses: Int {
        statuses.filter { $0.hasPrefix("Wake word is unavailable") }.count
    }

    func testWakeWordFailureStatusShowsOncePerStreak() async {
        restoreDefaultsAfterTest([PerryPreferences.$wakeWordEnabled.key])
        PerryPreferences.wakeWordEnabled = true
        controller.wakeWordListener.retryDelays = []
        controller.wakeWordListener.beginListening = { throw WakeStartFailure() }

        await failWakeWordStart()
        await failWakeWordStart()
        await failWakeWordStart()

        XCTAssertEqual(unavailableStatuses, 1)
        XCTAssertEqual(wakeListening, [false, false, false])

        controller.wakeWordListener.beginListening = {}
        await failWakeWordStart()
        controller.wakeWordListener.beginListening = { throw WakeStartFailure() }
        await failWakeWordStart()

        XCTAssertEqual(unavailableStatuses, 2)
        controller.wakeWordListener.stop()
    }

    func testTogglingTheWakeWordPreferenceResetsTheFailureStreak() async {
        restoreDefaultsAfterTest([PerryPreferences.$wakeWordEnabled.key])
        PerryPreferences.wakeWordEnabled = true
        controller.wakeWordListener.retryDelays = []
        controller.wakeWordListener.beginListening = { throw WakeStartFailure() }

        await failWakeWordStart()
        await failWakeWordStart()
        XCTAssertEqual(unavailableStatuses, 1)

        controller.updateWakeWordEnabled(false)
        PerryPreferences.wakeWordEnabled = true
        await failWakeWordStart()

        XCTAssertEqual(unavailableStatuses, 2)
        controller.wakeWordListener.stop()
    }

    func testOtherPathsStillNeedAPrefixToInsert() {
        controller.handleTranscript("remind me about the invoice")

        XCTAssertEqual(dispatched, ["remind me about the invoice"])
    }
}

private struct WakeStartFailure: LocalizedError {
    var errorDescription: String? { "mic busy" }
}

private final class RoughEdgeNotifier: AppNotificationClient, @unchecked Sendable {
    func configure(
        onApprove: @escaping @MainActor @Sendable (TaskID, String, UUID) -> Void,
        onDeny: @escaping @MainActor @Sendable (TaskID, UUID) -> Void,
        onOpen: @escaping @MainActor @Sendable () -> Void
    ) {}

    func requestAuthorization() async -> Bool { true }

    func deliver(_ notification: TaskNotification) async {}
}
