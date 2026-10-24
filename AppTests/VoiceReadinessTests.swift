import XCTest
import PerryGuide
import PerryOverlay
@testable import Perry

@MainActor
final class VoiceReadinessTests: XCTestCase {
    private var statuses: [String] = []
    private var overlayState: PerryCursorState!
    private var controller: VoiceController!
    private var previousPreferences: [String: Any] = [:]
    private let preferenceKeys = [PerryPreferences.$speechOutputEnabled.key, PerryPreferences.$realtimeVoiceEndpoint.key, PerryPreferences.$realtimeVoiceModel.key]

    override func setUp() {
        super.setUp()
        overlayState = PerryCursorState()
        previousPreferences = preferenceKeys.reduce(into: [:]) { values, key in
            values[key] = UserDefaults.standard.object(forKey: key)
        }
        UserDefaults.standard.set(false, forKey: PerryPreferences.$speechOutputEnabled.key)
        UserDefaults.standard.removeObject(forKey: PerryPreferences.$realtimeVoiceEndpoint.key)
        UserDefaults.standard.removeObject(forKey: PerryPreferences.$realtimeVoiceModel.key)
        controller = VoiceController(
            overlayState: overlayState,
            workers: CuaWorkerService(),
            notifier: ReadinessNotifier(),
            supportDirectory: { nil },
            hooks: VoiceController.Hooks(
                setStatus: { [weak self] text in self?.statuses.append(text) }
            )
        )
    }

    override func tearDown() {
        controller?.cancelInput()
        controller = nil
        overlayState = nil
        for key in preferenceKeys {
            if let value = previousPreferences[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        previousPreferences = [:]
        super.tearDown()
    }

    func testLocalDictationDoesNotClaimListeningWhilePermissionIsPending() async {
        let permission = PermissionStub()
        controller.requestDictationPermission = { await permission.request() }
        controller.startDictationCapture = { XCTFail("Capture started before permission resolved") }
        overlayState.voiceState = .listening
        overlayState.buddyState = .listening

        controller.beginDictation()

        let permissionRequested = await eventually { await permission.requestCount == 1 }
        XCTAssertTrue(permissionRequested)
        XCTAssertEqual(overlayState.voiceState, .idle)
        XCTAssertEqual(overlayState.buddyState, .idle)
        XCTAssertFalse(statuses.contains { $0.hasPrefix("Listening") })

        await permission.resolve(false)
        let denialReported = await eventually {
            self.statuses.contains("Microphone permission is optional; type your request instead.")
        }
        XCTAssertTrue(denialReported)
        XCTAssertEqual(overlayState.voiceState, .idle)
    }

    func testLocalDictationClaimsListeningOnlyAfterCaptureStarts() async {
        var captureCalls = 0
        controller.requestDictationPermission = { true }
        controller.startDictationCapture = {
            captureCalls += 1
            XCTAssertNotEqual(self.overlayState.voiceState, .listening)
            XCTAssertNotEqual(self.overlayState.buddyState, .listening)
        }

        controller.beginDictation()

        let captureStarted = await eventually {
            captureCalls == 1 && self.overlayState.voiceState == .listening
        }
        XCTAssertTrue(captureStarted)
        XCTAssertEqual(overlayState.buddyState, .listening)
        XCTAssertTrue(statuses.last?.hasPrefix("Listening on ") == true)
    }

    func testLocalDictationStartFailureNeverClaimsListening() async {
        controller.requestDictationPermission = { true }
        controller.startDictationCapture = {
            XCTAssertNotEqual(self.overlayState.voiceState, .listening)
            XCTAssertNotEqual(self.overlayState.buddyState, .listening)
            throw DictationController.DictationError.unavailable
        }

        controller.beginDictation()

        let failureReported = await eventually {
            self.statuses.contains(DictationController.DictationError.unavailable.localizedDescription)
        }
        XCTAssertTrue(failureReported)
        XCTAssertEqual(overlayState.voiceState, .idle)
        XCTAssertEqual(overlayState.buddyState, .blocked)
    }

    func testReleaseBeforePermissionResultDoesNotClaimListening() async {
        let permission = PermissionStub()
        var captureCalls = 0
        controller.requestDictationPermission = { await permission.request() }
        controller.startDictationCapture = { captureCalls += 1 }

        controller.beginDictation()
        let permissionRequested = await eventually { await permission.requestCount == 1 }
        XCTAssertTrue(permissionRequested)
        controller.finishDictation()
        await permission.resolve(true)

        let captureStarted = await eventually(timeout: 0.5) { captureCalls == 1 }
        XCTAssertFalse(captureStarted)
        XCTAssertEqual(overlayState.voiceState, .idle)
        XCTAssertEqual(overlayState.buddyState, .idle)
    }

    func testCancelBeforePermissionResultDoesNotClaimListening() async {
        let permission = PermissionStub()
        var captureCalls = 0
        controller.requestDictationPermission = { await permission.request() }
        controller.startDictationCapture = { captureCalls += 1 }

        controller.beginDictation()
        let permissionRequested = await eventually { await permission.requestCount == 1 }
        XCTAssertTrue(permissionRequested)
        controller.cancelInput()
        await permission.resolve(true)

        let captureStarted = await eventually(timeout: 0.5) { captureCalls == 1 }
        XCTAssertFalse(captureStarted)
        XCTAssertEqual(overlayState.voiceState, .idle)
        XCTAssertEqual(overlayState.buddyState, .idle)
    }

    func testRealtimeSessionClaimsListeningOnlyWhenReady() async throws {
        let transport = ReadinessRealtimeTransport(events: [.sessionReady])
        var session: RealtimeVoiceSession?
        configureRealtime { configuration, apiKey, onEvent in
            let made = RealtimeVoiceSession(
                configuration: configuration,
                apiKey: apiKey,
                transport: transport,
                onEvent: onEvent
            )
            made.beginEmptyInputFixture()
            session = made
            return made
        }

        controller.beginDictation()

        XCTAssertEqual(statuses.last, "Connecting to realtime voice…")
        XCTAssertNotEqual(overlayState.voiceState, .listening)
        XCTAssertNotEqual(overlayState.buddyState, .listening)

        let made = try XCTUnwrap(session)
        await made.receiveCurrentFixtureEvents()

        XCTAssertEqual(overlayState.voiceState, .listening)
        XCTAssertEqual(overlayState.buddyState, .listening)
        XCTAssertEqual(statuses.last, "Listening via realtime voice — release the shortcut when you’re done.")
    }

    func testRealtimeBeginInputOnListeningSessionClaimsListening() {
        let transport = ReadinessRealtimeTransport()
        var audioStarts = 0
        configureRealtime { configuration, apiKey, onEvent in
            let made = RealtimeVoiceSession(
                configuration: configuration,
                apiKey: apiKey,
                transport: transport,
                onEvent: onEvent
            )
            made.beginEmptyInputFixture()
            made.audioStartOverrideForTesting = { audioStarts += 1 }
            return made
        }

        controller.beginDictation()
        controller.beginDictation()

        XCTAssertEqual(audioStarts, 1)
        XCTAssertEqual(overlayState.voiceState, .listening)
        XCTAssertEqual(overlayState.buddyState, .listening)
        XCTAssertEqual(statuses.last, "Listening via realtime voice — release the shortcut when you’re done.")
    }

    func testRealtimeBeginInputWhileConnectingDoesNotClaimListening() async {
        let gate = AsyncGate()
        let transport = ReadinessRealtimeTransport(connectGate: gate)
        var session: RealtimeVoiceSession?
        configureRealtime { configuration, apiKey, onEvent in
            let made = RealtimeVoiceSession(
                configuration: configuration,
                apiKey: apiKey,
                transport: transport,
                onEvent: onEvent
            )
            session = made
            return made
        }
        controller.requestDictationPermission = { false }

        controller.beginDictation()
        let connectionStarted = await eventually { await transport.connectCallCount() == 1 }
        XCTAssertTrue(connectionStarted)
        XCTAssertEqual(session?.state, .connecting)
        XCTAssertNotEqual(overlayState.voiceState, .listening)

        controller.beginDictation()

        XCTAssertEqual(session?.state, .connecting)
        XCTAssertEqual(statuses.last, "Connecting to realtime voice…")
        XCTAssertNotEqual(overlayState.voiceState, .listening)
        XCTAssertNotEqual(overlayState.buddyState, .listening)

        controller.cancelInput()
        await gate.open()
        XCTAssertEqual(overlayState.voiceState, .idle)
    }

    func testRealtimeBeginInputFailureIsNotOverwrittenWithListening() async throws {
        let transport = ReadinessRealtimeTransport()
        let permission = PermissionStub()
        var captureCalls = 0
        configureRealtime { configuration, apiKey, onEvent in
            let made = RealtimeVoiceSession(
                configuration: configuration,
                apiKey: apiKey,
                transport: transport,
                onEvent: onEvent
            )
            made.beginEmptyInputFixture()
            made.audioStartOverrideForTesting = { throw RealtimeVoiceError.audioUnavailable }
            return made
        }
        controller.requestDictationPermission = { await permission.request() }
        controller.startDictationCapture = { captureCalls += 1 }

        controller.beginDictation()
        controller.beginDictation()

        let fallbackStarted = await eventually {
            self.statuses.contains("Realtime voice failed; continuing with on-device dictation.")
        }
        XCTAssertTrue(fallbackStarted)
        XCTAssertNotEqual(overlayState.voiceState, .listening)
        XCTAssertNotEqual(overlayState.buddyState, .listening)

        await permission.resolve(true)
        let captureStarted = await eventually {
            captureCalls == 1 && self.overlayState.voiceState == .listening
        }
        XCTAssertTrue(captureStarted)
        XCTAssertEqual(overlayState.buddyState, .listening)
    }

    func testSessionReadyAfterCancelDoesNotReactivateListening() async throws {
        let transport = ReadinessRealtimeTransport(events: [.sessionReady])
        var session: RealtimeVoiceSession?
        configureRealtime { configuration, apiKey, onEvent in
            let made = RealtimeVoiceSession(
                configuration: configuration,
                apiKey: apiKey,
                transport: transport,
                onEvent: onEvent
            )
            made.beginEmptyInputFixture()
            session = made
            return made
        }

        controller.beginDictation()
        let made = try XCTUnwrap(session)
        await made.receiveCurrentFixtureEvents()
        XCTAssertEqual(overlayState.voiceState, .listening)

        controller.cancelInput()
        XCTAssertEqual(overlayState.voiceState, .idle)

        await transport.push(.sessionReady)
        await made.receiveCurrentFixtureEvents()

        XCTAssertEqual(overlayState.voiceState, .idle)
        XCTAssertEqual(overlayState.buddyState, .idle)
    }

    func testSessionReadyAfterReleaseDoesNotReactivateListening() async throws {
        let transport = ReadinessRealtimeTransport(events: [.sessionReady])
        var session: RealtimeVoiceSession?
        configureRealtime { configuration, apiKey, onEvent in
            let made = RealtimeVoiceSession(
                configuration: configuration,
                apiKey: apiKey,
                transport: transport,
                onEvent: onEvent
            )
            made.beginEmptyInputFixture()
            session = made
            return made
        }

        controller.beginDictation()
        let made = try XCTUnwrap(session)
        await made.receiveCurrentFixtureEvents()
        XCTAssertEqual(overlayState.voiceState, .listening)

        controller.finishDictation()
        await transport.push(.sessionReady)
        await made.receiveCurrentFixtureEvents()

        XCTAssertNotEqual(overlayState.voiceState, .listening)
        XCTAssertNotEqual(overlayState.buddyState, .listening)
        _ = await eventually { self.overlayState.voiceState == .idle }
        XCTAssertNotEqual(overlayState.voiceState, .listening)
        XCTAssertNotEqual(overlayState.buddyState, .listening)
    }

    private func configureRealtime(
        sessionFactory: @escaping @MainActor (
            RealtimeVoiceConfiguration,
            String,
            @escaping (RealtimeVoiceEvent) -> Void
        ) -> RealtimeVoiceSession
    ) {
        UserDefaults.standard.set("wss://example.invalid", forKey: PerryPreferences.$realtimeVoiceEndpoint.key)
        UserDefaults.standard.set("fixture-model", forKey: PerryPreferences.$realtimeVoiceModel.key)
        controller.readRealtimeVoiceAPIKey = { "fixture" }
        controller.makeRealtimeVoiceSession = sessionFactory
    }

    private func eventually(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }
}

private actor PermissionStub {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private(set) var requestCount = 0

    func request() async -> Bool {
        requestCount += 1
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func resolve(_ value: Bool) {
        result = value
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: value) }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor ReadinessRealtimeTransport: RealtimeVoiceTransport {
    private var events: [RealtimeVoiceTransportEvent]
    private let connectGate: AsyncGate?
    private(set) var connectCalls = 0

    init(events: [RealtimeVoiceTransportEvent] = [], connectGate: AsyncGate? = nil) {
        self.events = events
        self.connectGate = connectGate
    }

    func connect() async throws {
        connectCalls += 1
        await connectGate?.wait()
    }

    func sendAudio(_ data: Data) async throws {
        XCTFail("Unexpected microphone audio")
    }

    func finishInput(tag: RealtimeVoicePacketTag, request: RealtimeVoiceResponseRequest) async throws {
        XCTFail("Unexpected input commit")
    }

    func commitInput(tag: RealtimeVoicePacketTag) async throws {
        XCTFail("Unexpected transcription commit")
    }

    func cancelResponse() async throws {
        XCTFail("Unexpected response cancellation")
    }

    func clearInput() async throws {}

    func sendText(_ text: String, request: RealtimeVoiceResponseRequest) async throws {
        XCTFail("Unexpected text input")
    }

    func receive() async throws -> RealtimeVoiceTransportEvent {
        guard !events.isEmpty else { throw CancellationError() }
        return events.removeFirst()
    }

    func close() async {}

    func push(_ event: RealtimeVoiceTransportEvent) {
        events.append(event)
    }

    func connectCallCount() -> Int {
        connectCalls
    }
}

private final class ReadinessNotifier: AppNotificationClient, @unchecked Sendable {
    func configure(
        onApprove: @escaping @MainActor @Sendable (TaskID, String, UUID) -> Void,
        onDeny: @escaping @MainActor @Sendable (TaskID, UUID) -> Void,
        onOpen: @escaping @MainActor @Sendable () -> Void
    ) {}

    func requestAuthorization() async -> Bool { true }

    func deliver(_ notification: TaskNotification) async {}
}
