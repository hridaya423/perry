import Foundation
import Darwin
import XCTest
import PerryCore
import PerryGuide
import PerryRuntimes
@testable import Perry

private enum CuaTestError: Error {
    case timeout(String)
}

private actor WorkerGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private actor ProviderCallRecorder {
    private var calls = 0

    func record() {
        calls += 1
    }

    func callCount() -> Int {
        calls
    }
}

final class CuaDriverClientTests: XCTestCase {
    private let driverScript = #"""
    #!/bin/sh
    set -eu
    root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
    if [ "${1:-}" = "serve" ]; then
        shift
        socket=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "--socket" ]; then
                shift
                socket="$1"
                break
            fi
            shift
        done
        [ -n "$socket" ]
        : > "$socket"
        trap 'exit 0' TERM
        while :; do sleep 0.05; done
    fi
    starts="$root/starts"
    log="$root/requests.log"
    count=0
    if [ -f "$starts" ]; then
        count=$(cat "$starts")
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$starts"
    printf '%s\n' "$$" > "$root/pid-$count"
    initialized=0
    trap '' TERM
    if [ -f "$root/child-worker" ]; then
        /bin/sh -c 'trap "" TERM; printf "%s\n" "$$" > "$1/pid-99"; while [ ! -f "$1/release-child" ]; do sleep 0.01; done' _ "$root" &
        trap 'exit 0' TERM
    fi
    while IFS= read -r line; do
        printf '%s\n' "$line" >> "$log"
        id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        if printf '%s\n' "$line" | grep -Fq '"method":"initialize"'; then
                if [ "$count" -eq 1 ] && [ -f "$root/delay-initialize" ]; then
                    while [ ! -f "$root/release-initialize" ]; do sleep 0.01; done
                fi
                printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id"
        elif printf '%s\n' "$line" | grep -Fq '"method":"notifications'; then
            initialized=1
        elif printf '%s\n' "$line" | grep -Fq '"method":"tools'; then
                name=$(printf '%s\n' "$line" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
                if [ "$initialized" -eq 0 ]; then
                    printf '{"jsonrpc":"2.0","id":%s,"error":{"message":"not initialized"}}\n' "$id"
                elif [ "$name" = "check_permissions" ]; then
                    if [ "$count" -eq 2 ] && [ -f "$root/delay-second-check" ]; then
                        while [ ! -f "$root/release-second-check" ]; do sleep 0.01; done
                    fi
                    printf '{"jsonrpc":"2.0","id":%s,"result":{"structuredContent":{"accessibility":true,"screen_recording":true,"source":{"attribution":"host","embedded":true}},"content":[]}}\n' "$id"
                    if [ "$count" -eq 1 ] && [ -f "$root/hold-old" ]; then
                        while [ ! -f "$root/exit-old" ]; do sleep 0.01; done
                        printf '%s\n' exiting > "$root/old-exited"
                        exit 0
                    fi
                elif [ "$name" = "start_session" ] || [ "$name" = "end_session" ]; then
                    printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[]}}\n' "$id"
                elif [ "$name" = "list_windows" ]; then
                    printf '{"jsonrpc":"2.0","id":%s,"result":{"structuredContent":{"windows":[{"bundle_id":"com.example.Editor","pid":4242,"window_id":1001,"title":"Editor - Draft","bounds":{"x":10,"y":10,"width":800,"height":600},"z_index":20,"is_on_screen":true,"on_current_space":true},{"bundle_id":"com.example.Editor","pid":4242,"window_id":1002,"title":"Editor - Other","bounds":{"x":40,"y":40,"width":1200,"height":900},"z_index":10,"is_on_screen":true,"on_current_space":true}]},"content":[]}}\n' "$id"
                elif [ "$name" = "get_window_state" ]; then
                    if [ -f "$root/secure-fields" ]; then
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"structuredContent":{"snapshot_id":"snapshot-secure","elements":[{"element_token":"pw","role":"AXSecureTextField","label":"Password","value":"bullets","frame":{"x":20,"y":60,"width":160,"height":24}},{"element_token":"note","role":"AXTextField","value":"draft text","frame":{"x":20,"y":90,"width":160,"height":24}}]},"content":[{"type":"image","data":"AQI=","mimeType":"image/png"}]}}\n' "$id"
                    else
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"structuredContent":{"snapshot_id":"snapshot-1","elements":[{"element_token":"s1","role":"AXButton","label":"Save","frame":{"x":20,"y":20,"width":80,"height":24}}]},"content":[{"type":"image","data":"AQI=","mimeType":"image/png"}]}}\n' "$id"
                    fi
                elif [ "$name" = "verify_state" ]; then
                    mode="status-verified"
                    if [ -f "$root/verification-mode" ]; then
                        mode=$(cat "$root/verification-mode")
                    fi
                    if [ "$mode" = "text-only" ]; then
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"verified"}]}}\n' "$id"
                    elif [ "$mode" = "status-complete" ]; then
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"structuredContent":{"status":"complete"},"content":[{"type":"text","text":"verified"}]}}\n' "$id"
                    else
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"structuredContent":{"status":"verified"},"content":[{"type":"text","text":"verified"}]}}\n' "$id"
                    fi
                elif [ "$name" = "type_text" ]; then
                    if [ -f "$root/unverified-type" ]; then
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"structuredContent":{"effect":"unverifiable","verified":false},"content":[]}}\n' "$id"
                    else
                        printf '{"jsonrpc":"2.0","id":%s,"result":{"structuredContent":{"effect":"confirmed","verified":true},"content":[]}}\n' "$id"
                    fi
                elif [ -f "$root/delay-action" ] && [ "$name" = "click" ]; then
                    if [ ! -f "$root/action-delayed" ]; then
                        : > "$root/action-delayed"
                        while [ ! -f "$root/release-action" ]; do sleep 0.01; done
                        : > "$root/late-response"
                    fi
                    printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[]}}\n' "$id"
                else
                    printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[]}}\n' "$id"
                fi
        fi
    done
    """#

    private var testDirectory: URL!
    private var driverURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-cua-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        driverURL = testDirectory.appendingPathComponent("cua-driver")
        try driverScript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .write(to: driverURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: driverURL.path)
    }

    override func tearDownWithError() throws {
        if let testDirectory {
            try? FileManager.default.removeItem(at: testDirectory)
        }
        testDirectory = nil
        driverURL = nil
        try super.tearDownWithError()
    }

    func testEmbeddedEnvironmentDisablesUpstreamNetworkOperations() {
        let configuration = CuaDriverConfiguration(
            executableURL: driverURL,
            capabilityManifestURL: testDirectory.appendingPathComponent("capabilities.yaml"),
            hostBundleID: "dev.perry.Perry"
        )
        let environment = CuaDriverClient.embeddedEnvironment(configuration: configuration)

        XCTAssertEqual(environment["CUA_DRIVER_RS_UPDATE_CHECK"], "0")
        XCTAssertEqual(environment["CUA_DRIVER_RS_TELEMETRY_ENABLED"], "0")
        XCTAssertEqual(environment["CUA_DRIVER_PERMISSION_MODE"], "bounded")
        XCTAssertEqual(environment["CUA_DRIVER_CAPABILITY_MANIFEST_FILE"], configuration.capabilityManifestURL.path)
        XCTAssertEqual(environment["CUA_DRIVER_CAPABILITY_MANIFEST_APPROVED"], "1")
    }

    func testConcurrentHealthCallsShareInitialization() async throws {
        let client = makeClient()
        addTeardownBlock {
            await client.shutdown()
        }
        try createMarker("delay-initialize")

        let first = Task { await client.health() }
        try await waitForRequest(containing: "\"method\":\"initialize\"")
        let second = Task { await client.health() }
        try await Task.sleep(nanoseconds: 100_000_000)
        try createMarker("release-initialize")

        let firstHealth = await first.value
        let secondHealth = await second.value
        XCTAssertTrue(firstHealth.ready, "\(firstHealth.summary); requests=\(requestLines())")
        XCTAssertTrue(secondHealth.ready, "\(secondHealth.summary); requests=\(requestLines())")

        let lines = requestLines()
        let notificationIndex = try XCTUnwrap(lines.firstIndex { $0.contains("\"method\":\"notifications") })
        let checkIndex = try XCTUnwrap(lines.firstIndex { $0.contains("\"name\":\"check_permissions\"") })
        XCTAssertLessThan(notificationIndex, checkIndex)
    }

    func testPersistedWindowIDMustExistInsteadOfSelectingFallback() async throws {
        let client = makeClient()
        addTeardownBlock {
            await client.shutdown()
        }

        do {
            _ = try await client.capture(
                target: CuaTargetHint(processID: 4242, windowID: 9999, windowTitle: "Editor - Draft"),
                sessionID: "missing-window"
            )
            XCTFail("capture should reject a missing persisted window ID")
        } catch let error as CuaDriverError {
            XCTAssertEqual(error, .noTargetWindow)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let missingTarget = await client.target(for: "missing-window")
        XCTAssertNil(missingTarget)
        XCTAssertTrue(requestLines().contains { $0.contains("\"name\":\"list_windows\"") })
        XCTAssertFalse(requestLines().contains { $0.contains("\"name\":\"get_window_state\"") })
    }

    func testResolveTargetDoesNotRequestWindowState() async throws {
        let client = makeClient()
        addTeardownBlock {
            await client.shutdown()
        }

        let target = try await client.resolveTarget(
            CuaTargetHint(processID: 4242, windowID: 1001),
            sessionID: "resolve-only"
        )

        XCTAssertEqual(target.windowID, 1001)
        XCTAssertTrue(requestLines().contains { $0.contains("\"name\":\"list_windows\"") })
        XCTAssertFalse(requestLines().contains { $0.contains("\"name\":\"get_window_state\"") })
    }

    func testCaptureSeparatesSecureAndUnknownFieldValues() async throws {
        FileManager.default.createFile(
            atPath: testDirectory.appendingPathComponent("secure-fields").path,
            contents: Data()
        )
        let client = makeClient()
        addTeardownBlock {
            await client.shutdown()
        }

        let capture = try await client.capture(
            target: CuaTargetHint(processID: 4242, windowID: 1001),
            sessionID: "secure-capture"
        )
        XCTAssertEqual(capture.snapshotID, "snapshot-secure")
        let snapshot = try XCTUnwrap(capture.accessibilitySnapshotModel)

        let password = try XCTUnwrap(snapshot.element(withStableID: "pw"))
        XCTAssertEqual(password.role, .textField)
        XCTAssertEqual(password.rawRole, "AXSecureTextField")
        XCTAssertEqual(password.sensitivity, .secure)
        XCTAssertNil(password.value)

        let note = try XCTUnwrap(snapshot.element(withStableID: "note"))
        XCTAssertEqual(note.sensitivity, .unknown)
        XCTAssertNil(note.value)
        XCTAssertNil(note.label)
    }

    func testResolvedTargetRejectsMismatchedSession() async throws {
        let client = makeClient()
        addTeardownBlock {
            await client.shutdown()
        }
        let target = try await client.resolveTarget(
            CuaTargetHint(processID: 4242, windowID: 1001),
            sessionID: "resolved-session"
        )

        do {
            _ = try await client.capture(resolvedTarget: target, sessionID: "different-session")
            XCTFail("A resolved target must not be used by another session")
        } catch let error as CuaDriverError {
            XCTAssertEqual(error, .targetSessionMismatch)
        }
        XCTAssertFalse(requestLines().contains { $0.contains("\"name\":\"get_window_state\"") })
    }

    func testResolvedTargetRejectsStaleGenerationAfterRestart() async throws {
        let client = makeClient()
        addTeardownBlock {
            await client.shutdown()
        }
        let target = try await client.resolveTarget(
            CuaTargetHint(processID: 4242, windowID: 1001),
            sessionID: "stale-target"
        )
        XCTAssertEqual(target.connectionGeneration, 0)

        await client.shutdown()
        let restartedHealth = await client.health()
        XCTAssertTrue(restartedHealth.ready)
        XCTAssertEqual(startCount(), 2)

        do {
            _ = try await client.capture(resolvedTarget: target, sessionID: "stale-target")
            XCTFail("A resolved target from an earlier connection must be rejected")
        } catch let error as CuaDriverError {
            XCTAssertEqual(error, .processExited)
        }
        XCTAssertEqual(startCount(), 2)
        XCTAssertFalse(requestLines().contains { $0.contains("\"name\":\"get_window_state\"") })
    }

    func testNoRestartClientDoesNotRestartAfterShutdown() async throws {
        let client = makeClient(allowsRestart: false)
        addTeardownBlock {
            await client.shutdown()
        }

        let firstHealth = await client.health()
        XCTAssertTrue(firstHealth.ready)
        XCTAssertEqual(startCount(), 1)

        await client.shutdown()
        let secondHealth = await client.health()
        XCTAssertFalse(secondHealth.ready)
        XCTAssertEqual(startCount(), 1)
    }

    func testFailedRetargetRetiresPreviousWindowBeforeAnotherAction() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "retargeted-window"
        _ = try await client.capture(
            target: CuaTargetHint(processID: 4242, windowID: 1001),
            sessionID: sessionID
        )

        do {
            _ = try await client.capture(
                target: CuaTargetHint(processID: 4242, windowID: 9999),
                sessionID: sessionID
            )
            XCTFail("A missing replacement window must be rejected")
        } catch let error as CuaDriverError {
            XCTAssertEqual(error, .noTargetWindow)
        }

        let target = await client.target(for: sessionID)
        XCTAssertNil(target)
        do {
            _ = try await client.execute(
                try ComputerAction(
                    actionID: "retarget-guard",
                    command: .pressKey("Return", modifiers: [], target: nil)
                ),
                sessionID: sessionID
            )
            XCTFail("A failed retarget must not leave the previous window executable")
        } catch let error as CuaDriverError {
            XCTAssertEqual(error, .targetNotFound)
        }
        XCTAssertFalse(requestLines().contains { $0.contains("\"name\":\"press_key\"") })
    }

    func testWindowTitleMustExistInsteadOfSelectingFallback() async throws {
        let client = makeClient()
        addTeardownBlock {
            await client.shutdown()
        }

        do {
            _ = try await client.capture(
                target: CuaTargetHint(processID: 4242, windowTitle: "Editor - Closed"),
                sessionID: "missing-window-title"
            )
            XCTFail("capture should reject a missing window title")
        } catch let error as CuaDriverError {
            XCTAssertEqual(error, .noTargetWindow)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertTrue(requestLines().contains { $0.contains("\"name\":\"list_windows\"") })
        XCTAssertFalse(requestLines().contains { $0.contains("\"name\":\"get_window_state\"") })
    }

    func testCaptureRejectsTheHostApplicationBeforeReadingItsWindow() async throws {
        let client = makeClient(hostBundleID: "com.example.Editor")
        addTeardownBlock { await client.shutdown() }

        do {
            _ = try await client.capture(
                target: CuaTargetHint(bundleID: "com.example.Editor", processID: 4242, windowID: 1001),
                sessionID: "host-window"
            )
            XCTFail("Perry must not capture its own window as task context")
        } catch let error as CuaDriverError {
            XCTAssertEqual(error, .noTargetWindow)
        }

        XCTAssertFalse(requestLines().contains { $0.contains("\"name\":\"get_window_state\"") })
    }

    func testBundleIdentityMustMatchInsteadOfSelectingAnotherApplication() async throws {
        let client = makeClient()
        addTeardownBlock {
            await client.shutdown()
        }

        do {
            _ = try await client.capture(
                target: CuaTargetHint(bundleID: "com.example.Other", processID: 4242, windowID: 1001),
                sessionID: "wrong-application"
            )
            XCTFail("capture should reject a window owned by another application")
        } catch let error as CuaDriverError {
            XCTAssertEqual(error, .noTargetWindow)
        }

        XCTAssertFalse(requestLines().contains { $0.contains("\"name\":\"get_window_state\"") })
    }

    func testFocusedTextInsertionRequiresCuaReadBack() async throws {
        let client = makeClient()
        addTeardownBlock {
            await client.shutdown()
        }

        let target = try await client.insertText(
            "Perry verified this",
            target: CuaTargetHint(bundleID: "com.example.Editor", processID: 4242, windowID: 1001),
            sessionID: "dictation"
        )

        XCTAssertEqual(target.windowID, 1001)
        XCTAssertTrue(requestLines().contains { line in
            line.contains("\"name\":\"type_text\"")
                && line.contains("\"text\":\"Perry verified this\"")
                && line.contains("\"delivery_mode\":\"background\"")
        })
        XCTAssertFalse(requestLines().contains { $0.contains("\"name\":\"get_window_state\"") })
    }

    func testResolvedTargetTextInsertionPreservesVerifiedReadback() async throws {
        let client = makeClient()
        addTeardownBlock {
            await client.shutdown()
        }
        let sessionID = "resolved-dictation"
        let target = try await client.resolveTarget(
            CuaTargetHint(bundleID: "com.example.Editor", processID: 4242, windowID: 1001),
            sessionID: sessionID
        )

        let insertedTarget = try await client.insertText(
            "Perry verified this",
            resolvedTarget: target,
            sessionID: sessionID
        )

        XCTAssertEqual(insertedTarget, target)
        XCTAssertTrue(requestLines().contains { line in
            line.contains("\"name\":\"type_text\"")
                && line.contains("\"text\":\"Perry verified this\"")
        })
    }

    func testResolvedTargetTextInsertionRejectsMismatchedSessionWithoutTypeText() async throws {
        let client = makeClient()
        addTeardownBlock {
            await client.shutdown()
        }
        let target = try await client.resolveTarget(
            CuaTargetHint(processID: 4242, windowID: 1001),
            sessionID: "resolved-dictation"
        )

        do {
            _ = try await client.insertText(
                "Must not insert",
                resolvedTarget: target,
                sessionID: "different-dictation"
            )
            XCTFail("A resolved target must not insert through another session")
        } catch let error as CuaDriverError {
            XCTAssertEqual(error, .targetSessionMismatch)
        }
        XCTAssertFalse(requestLines().contains { $0.contains("\"name\":\"type_text\"") })
    }

    func testResolvedTargetTextInsertionRejectsStaleGenerationWithoutTypeText() async throws {
        let client = makeClient()
        addTeardownBlock {
            await client.shutdown()
        }
        let sessionID = "stale-dictation"
        let target = try await client.resolveTarget(
            CuaTargetHint(processID: 4242, windowID: 1001),
            sessionID: sessionID
        )
        await client.shutdown()
        let restartedHealth = await client.health()
        XCTAssertTrue(restartedHealth.ready)

        do {
            _ = try await client.insertText(
                "Must not insert",
                resolvedTarget: target,
                sessionID: sessionID
            )
            XCTFail("A resolved target from an earlier connection must be rejected")
        } catch let error as CuaDriverError {
            XCTAssertEqual(error, .processExited)
        }
        XCTAssertFalse(requestLines().contains { $0.contains("\"name\":\"type_text\"") })
    }

    func testFocusedTextInsertionFailsClosedWhenCuaCannotVerify() async throws {
        let client = makeClient()
        addTeardownBlock {
            await client.shutdown()
        }
        try createMarker("unverified-type")

        do {
            _ = try await client.insertText(
                "Unverified text",
                target: CuaTargetHint(bundleID: "com.example.Editor", processID: 4242, windowID: 1001),
                sessionID: "dictation"
            )
            XCTFail("unverified insertion must fail closed")
        } catch let error as CuaDriverError {
            guard case .toolRejected = error else {
                return XCTFail("unexpected Cua error: \(error)")
            }
        }
    }

    func testVerificationRequiresExplicitPositiveResult() {
        XCTAssertFalse(CuaDriverClient.verificationSucceeded(nil))
        XCTAssertFalse(CuaDriverClient.verificationSucceeded(["verified": false]))
        XCTAssertFalse(CuaDriverClient.verificationSucceeded(["status": "complete"]))
        XCTAssertTrue(CuaDriverClient.verificationSucceeded(["matched": true]))
        XCTAssertTrue(CuaDriverClient.verificationSucceeded(["status": "verified"]))
    }

    func testTextInsertionVerificationRejectsAttemptedAndUnverifiableEffects() {
        XCTAssertFalse(CuaDriverClient.actionWasVerified(nil))
        XCTAssertFalse(CuaDriverClient.actionWasVerified(["effect": "attempted"]))
        XCTAssertFalse(CuaDriverClient.actionWasVerified(["effect": "unverifiable", "verified": false]))
        XCTAssertTrue(CuaDriverClient.actionWasVerified(["effect": "confirmed"]))
        XCTAssertTrue(CuaDriverClient.actionWasVerified(["verified": true]))
    }

    func testStaleReaderCannotTearDownReplacementConnection() async throws {
        let client = makeClient()
        addTeardownBlock {
            await client.shutdown()
        }
        try createMarker("hold-old")

        let initialHealth = await client.health()
        XCTAssertTrue(initialHealth.ready, "\(initialHealth.summary); requests=\(requestLines())")
        await client.shutdown()

        try createMarker("delay-second-check")
        let replacementHealth = Task { await client.health() }
        try await waitForStartCount(2)
        try await waitForRequest(containing: "\"name\":\"check_permissions\"", count: 2)

        try createMarker("exit-old")
        try await waitForMarker("old-exited")
        try await Task.sleep(nanoseconds: 100_000_000)
        try createMarker("release-second-check")

        let result = await replacementHealth.value
        XCTAssertTrue(result.ready, "\(result.summary); requests=\(requestLines())")
        XCTAssertEqual(startCount(), 2)
        let replacementCapture = try await client.capture(
            target: CuaTargetHint(bundleID: "com.example.Editor", processID: 4242, windowID: 1001),
            sessionID: "replacement"
        )
        XCTAssertEqual(replacementCapture.target.connectionGeneration, 1)
    }

    func testDiscoverIgnoresPATHOnlyCandidateWithoutInvokingIt() async throws {
        let suiteName = "dev.perry.CuaDriverClientTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = CuaDriverConfiguration.discover(
            environment: ["PATH": testDirectory.path],
            bundle: Bundle(for: CuaDriverClientTests.self),
            userDefaults: defaults
        )
        XCTAssertNil(configuration)

        let health = await CuaDriverClient(configuration: configuration).health()
        XCTAssertFalse(health.ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: testDirectory.appendingPathComponent("starts").path))
    }

    func testDiscoverRejectsUnverifiedRegisteredCandidateWithoutInvokingIt() async throws {
        let suiteName = "dev.perry.CuaDriverClientTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(driverURL.path, forKey: PerryPreferences.$cuaDriverPath.key)

        let configuration = CuaDriverConfiguration.discover(
            environment: ["PATH": testDirectory.path],
            bundle: Bundle(for: CuaDriverClientTests.self),
            userDefaults: defaults
        )
        XCTAssertNil(configuration)

        let health = await CuaDriverClient(configuration: configuration).health()
        XCTAssertFalse(health.ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: testDirectory.appendingPathComponent("starts").path))
    }

    func testBundledUpstreamFixtureRemainsAvailableForUnsignedHost() throws {
        let bundle = try makeBundleFixture()
        let configuration = try discoverBundledFixture(
            bundle: bundle,
            hostIdentity: .unsignedOrAdHoc,
            driverIdentity: .unsignedOrAdHoc,
            identityVerifier: { _ in true }
        )

        XCTAssertNotNil(configuration)
    }

    func testBundledReSignedFixtureRequiresMatchingDeveloperIDTeamAndIdentifier() throws {
        let bundle = try makeBundleFixture()
        let releaseTeam = "PERRYRELEASE"
        let hostIdentity = CuaCodeIdentity.appleDeveloperID(
            identifier: "dev.perry.Perry",
            teamIdentifier: releaseTeam
        )
        let driverIdentity = CuaCodeIdentity.appleDeveloperID(
            identifier: "cua-driver",
            teamIdentifier: releaseTeam
        )

        let accepted = try discoverBundledFixture(
            bundle: bundle,
            hostIdentity: hostIdentity,
            driverIdentity: driverIdentity,
            identityVerifier: { _ in false }
        )
        XCTAssertNotNil(accepted)

        let rejected: [(String, CuaCodeIdentity, CuaCodeIdentity)] = [
            (
                "different team",
                hostIdentity,
                .appleDeveloperID(identifier: "cua-driver", teamIdentifier: "OTHERTEAM")
            ),
            (
                "different identifier",
                hostIdentity,
                .appleDeveloperID(identifier: "other-driver", teamIdentifier: releaseTeam)
            ),
            ("ad hoc host", .unsignedOrAdHoc, driverIdentity),
            ("ad hoc driver", hostIdentity, .unsignedOrAdHoc),
        ]
        for (name, fixtureHostIdentity, fixtureDriverIdentity) in rejected {
            let configuration = try discoverBundledFixture(
                bundle: bundle,
                hostIdentity: fixtureHostIdentity,
                driverIdentity: fixtureDriverIdentity,
                identityVerifier: { _ in false }
            )
            XCTAssertNil(configuration, name)
        }
    }

    func testBundledFixtureRejectsSymlinkEscapingHost() throws {
        let bundle = try makeBundleFixture()
        let bundledURL = try XCTUnwrap(
            bundle.url(forResource: "cua-driver", withExtension: nil, subdirectory: "CuaDriver/bin")
        )
        let escapedURL = testDirectory.appendingPathComponent("outside-cua-driver")
        try Data([1]).write(to: escapedURL)
        try FileManager.default.removeItem(at: bundledURL)
        try FileManager.default.createSymbolicLink(at: bundledURL, withDestinationURL: escapedURL)

        let allowed = CuaDriverConfiguration.bundledDriverIsAllowed(
            driverURL: bundledURL,
            hostBundleURL: bundle.bundleURL,
            upstreamIdentityVerified: true,
            hostIdentity: nil,
            driverIdentity: nil
        )
        XCTAssertFalse(allowed)
    }

    func testDiscoveryRejectsManifestSymlinkEscapingHost() throws {
        let bundle = try makeBundleFixture()
        let manifestURL = try XCTUnwrap(bundle.url(
            forResource: "capabilities", withExtension: "yaml", subdirectory: "CuaDriver"
        ))
        let externalURL = testDirectory.appendingPathComponent("outside-capabilities.yaml")
        try Data("external capabilities".utf8).write(to: externalURL)
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: externalURL)
        let suiteName = "dev.perry.CuaDriverClientTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for registered in [false, true] {
            if registered {
                defaults.set(driverURL.path, forKey: PerryPreferences.$cuaDriverPath.key)
            }
            let configuration = CuaDriverConfiguration.discover(
                bundle: bundle,
                userDefaults: defaults,
                identityVerifier: { _ in true },
                codeIdentityReader: { _ in nil }
            )
            XCTAssertNil(configuration, "An external manifest must disable both bundled and registered drivers")
        }
    }

    func testRegisteredUpstreamFixtureRemainsAccepted() throws {
        let bundle = try makeBundleFixture(includeDriver: false)
        let suiteName = "dev.perry.CuaDriverClientTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(driverURL.path, forKey: PerryPreferences.$cuaDriverPath.key)
        let expectedURL = driverURL.resolvingSymlinksInPath().standardizedFileURL

        let configuration = CuaDriverConfiguration.discover(
            bundle: bundle,
            userDefaults: defaults,
            identityVerifier: { $0 == expectedURL },
            codeIdentityReader: { _ in
                XCTFail("registered candidates must not use bundled identity authorization")
                return nil
            }
        )

        XCTAssertEqual(configuration?.executableURL, expectedURL)
    }

    func testRegisteredReSignedFixtureDoesNotUseBundledTrustRule() throws {
        let bundle = try makeBundleFixture(includeDriver: false)
        let suiteName = "dev.perry.CuaDriverClientTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(driverURL.path, forKey: PerryPreferences.$cuaDriverPath.key)
        var codeIdentityReaderCalled = false

        let configuration = CuaDriverConfiguration.discover(
            bundle: bundle,
            userDefaults: defaults,
            identityVerifier: { _ in false },
            codeIdentityReader: { _ in
                codeIdentityReaderCalled = true
                return .appleDeveloperID(identifier: "cua-driver", teamIdentifier: "PERRYRELEASE")
            }
        )

        XCTAssertNil(configuration)
        XCTAssertFalse(codeIdentityReaderCalled)
    }

    func testExplicitNilConfigurationRemainsUnavailable() async {
        let health = await CuaDriverClient(configuration: nil).health()

        XCTAssertFalse(health.ready)
        XCTAssertEqual(
            health.summary,
            "Cua Driver is unavailable. Set a verified executable path in Settings or use the signed bundled driver."
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: testDirectory.appendingPathComponent("starts").path))
    }

    func testMalformedComputerActionDoesNotReachTheDriver() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }

        XCTAssertThrowsError(
            try ComputerAction(
                actionID: "invalid-drag",
                command: .drag(
                    from: .accessibilityID("s1"),
                    to: .windowPixels(x: 3, y: 4),
                    durationMilliseconds: 250,
                    steps: 12
                )
            )
        ) { error in
            XCTAssertEqual(error as? CuaDriverError, .targetNotFound)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: testDirectory.appendingPathComponent("starts").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: testDirectory.appendingPathComponent("requests.log").path))
    }

    func testComputerActionsPreserveTypedValuesAndExactWindowOnTheWire() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "typed-actions"
        _ = try await client.capture(
            target: CuaTargetHint(processID: 4242, windowID: 1001),
            sessionID: sessionID
        )
        let point = ExecutableAction.Selector.windowPixels(x: 12.5, y: 20.25)
        let cases: [(ExecutableAction.ComputerCommand, String)] = [
            (.click(point), "click"),
            (.rightClick(point), "right_click"),
            (.doubleClick(point), "double_click"),
            (.typeText("  exact text\n", target: point), "type_text"),
            (.scroll(direction: .down, amount: 7, unit: .line, target: nil), "scroll"),
            (.pressKey("Return", modifiers: [.shift, .command], target: nil), "press_key"),
            (.hotkey(key: "s", modifiers: [.command, .shift], target: nil), "hotkey"),
            (.drag(
                from: .windowPixels(x: 1.5, y: 2),
                to: .windowPixels(x: 30, y: 40),
                durationMilliseconds: 250,
                steps: 12
            ), "drag"),
        ]
        for (command, name) in cases {
            let action = try ComputerAction(actionID: name, command: command)
            let result = try await client.execute(action, sessionID: sessionID)
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.stepID, name)
        }
        let log = try String(contentsOf: testDirectory.appendingPathComponent("requests.log"), encoding: .utf8)
        let requests = try log.split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        for (_, name) in cases {
            let parameters = try XCTUnwrap(requests.compactMap { $0["params"] as? [String: Any] }.first { $0["name"] as? String == name })
            let arguments = try XCTUnwrap(parameters["arguments"] as? [String: Any])
            XCTAssertEqual(arguments["pid"] as? Int, 4242, name)
            XCTAssertEqual(arguments["window_id"] as? Int, 1001, name)
            XCTAssertEqual(arguments["session"] as? String, sessionID, name)
            XCTAssertEqual(arguments["delivery_mode"] as? String, "background", name)
            switch name {
            case "click", "right_click", "double_click", "type_text":
                XCTAssertEqual(arguments["x"] as? Double, 12.5)
                XCTAssertEqual(arguments["y"] as? Double, 20.25)
                if name == "type_text" { XCTAssertEqual(arguments["text"] as? String, "  exact text\n") }
            case "scroll":
                XCTAssertEqual(arguments["direction"] as? String, "down")
                XCTAssertEqual(arguments["amount"] as? Int, 7)
            case "press_key":
                XCTAssertEqual(arguments["key"] as? String, "return")
                XCTAssertEqual(arguments["modifiers"] as? [String], ["shift", "cmd"])
            case "hotkey":
                XCTAssertEqual(arguments["keys"] as? [String], ["cmd", "shift", "s"])
            case "drag":
                XCTAssertEqual(arguments["from_x"] as? Double, 1.5)
                XCTAssertEqual(arguments["to_y"] as? Double, 40)
                XCTAssertEqual(arguments["duration_ms"] as? Int, 250)
                XCTAssertEqual(arguments["steps"] as? Int, 12)
            default:
                XCTFail("Missing wire assertion for \(name)")
            }
        }
    }

    func testKeyboardActionsKeepTheirSuppliedElementTarget() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "targeted-keys"
        _ = try await client.capture(target: CuaTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        for (command, tool) in [
            (ExecutableAction.ComputerCommand.pressKey("Return", modifiers: [], target: .accessibilityID("s1")), "press_key"),
            (.hotkey(key: "s", modifiers: [.command], target: .accessibilityID("s1")), "hotkey"),
        ] {
            _ = try await client.execute(
                try ComputerAction(actionID: tool, command: command),
                sessionID: sessionID
            )
            let log = try String(contentsOf: testDirectory.appendingPathComponent("requests.log"), encoding: .utf8)
            let requests = try log.split(separator: "\n").map { line in
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
            let parameters = try XCTUnwrap(requests.compactMap { $0["params"] as? [String: Any] }.last { $0["name"] as? String == tool })
            let arguments = try XCTUnwrap(parameters["arguments"] as? [String: Any])
            XCTAssertEqual(arguments["element_token"] as? String, "s1", tool)
            XCTAssertEqual(arguments["window_id"] as? Int, 1001, tool)
        }
    }

    func testUnknownElementCannotBecomeAnUntargetedKeyboardAction() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "unknown-element"
        _ = try await client.capture(target: CuaTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        do {
            _ = try await client.execute(
                try ComputerAction(
                    actionID: "missing-control",
                    command: .pressKey("Return", modifiers: [], target: .accessibilityID("missing-control"))
                ),
                sessionID: sessionID
            )
            XCTFail("A missing control must not redirect keys to the focused control")
        } catch let error as CuaDriverError {
            XCTAssertEqual(error, .targetNotFound)
        }
        XCTAssertFalse(requestLines().contains { $0.contains("\"name\":\"press_key\"") })
    }

    func testActionRefusesWindowIdentityThePlanWasNotBoundTo() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "identity-guard"
        let capture = try await client.capture(
            target: CuaTargetHint(processID: 4242, windowID: 1001),
            sessionID: sessionID
        )
        let target = capture.target
        let matching = ExecutableAction.WindowIdentity(
            bundleID: target.bundleID,
            processID: target.processID,
            windowID: UInt32(target.windowID),
            connectionGeneration: target.connectionGeneration
        )
        _ = try await client.execute(
            try ComputerAction(
                actionID: "same-window",
                command: .click(.windowPixels(x: 10, y: 10)),
                expectedWindow: matching
            ),
            sessionID: sessionID
        )
        do {
            _ = try await client.execute(
                try ComputerAction(
                    actionID: "other-window",
                    command: .click(.windowPixels(x: 10, y: 10)),
                    expectedWindow: ExecutableAction.WindowIdentity(
                        bundleID: target.bundleID,
                        processID: target.processID,
                        windowID: UInt32(target.windowID) + 500,
                        connectionGeneration: target.connectionGeneration
                    )
                ),
                sessionID: sessionID
            )
            XCTFail("a plan bound to another window must not act on this one")
        } catch let error as CuaDriverError {
            XCTAssertEqual(error, .targetMismatch)
        }
        let clicks = requestLines().filter { $0.contains("\"name\":\"click\"") }
        XCTAssertEqual(clicks.count, 1, "the mismatched action must not reach the driver")
    }

    func testLateResponseDoesNotReplayAction() async throws {
        let client = makeClient()
        let sessionID = "cancelled-action"
        _ = try await client.capture(target: CuaTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        try createMarker("delay-action")
        let completed = expectation(description: "cancelled requester completes")
        let requester = Task {
            defer { completed.fulfill() }
            try await client.execute(
                try clickAction(id: "cancelled"),
                sessionID: sessionID
            )
        }
        let releaseMarker = testDirectory.appendingPathComponent("release-action")
        addTeardownBlock {
            do {
                try Data([1]).write(to: releaseMarker)
            } catch {
                XCTFail("could not release the delayed action: \(error)")
            }
            requester.cancel()
            do {
                _ = try await requester.value
                XCTFail("cancelled requester completed during teardown")
            } catch is CancellationError {
            } catch {
                XCTFail("cancelled requester failed during teardown: \(error)")
            }
            await client.shutdown()
        }
        try await waitForMarker("action-delayed")
        requester.cancel()
        await fulfillment(of: [completed], timeout: 0.5)
        try createMarker("release-action")
        do {
            _ = try await requester.value
            XCTFail("cancelled action completed")
        } catch is CancellationError {
        }

        try await waitForMarker("late-response")
        let second = try await client.execute(
            try clickAction(id: "after-cancel"),
            sessionID: sessionID
        )
        XCTAssertEqual(second.stepID, "after-cancel")
        XCTAssertEqual(requestLines().filter { $0.contains("\"name\":\"click\"") }.count, 2)
    }

    func testNoRestartTimeoutRetiresClientAndRejectsLaterActions() async throws {
        let client = makeClient(allowsRestart: false)
        let directory = try XCTUnwrap(testDirectory)
        let sessionID = "timeout-retirement"
        _ = try await client.capture(
            target: CuaTargetHint(processID: 4242, windowID: 1001),
            sessionID: sessionID
        )
        try createMarker("delay-action")
        let completed = expectation(description: "timed out requester completes")
        let requester = Task {
            defer { completed.fulfill() }
            try await client.execute(
                try clickAction(id: "timed-out"),
                sessionID: sessionID
            )
        }
        let pid = try Self.processID(forStart: 1, in: directory)
        let releaseMarker = directory.appendingPathComponent("release-action")
        addTeardownBlock {
            do {
                try Data([1]).write(to: releaseMarker)
            } catch {
                XCTFail("could not release the delayed action: \(error)")
            }
            requester.cancel()
            await Self.terminateTestOwnedProcess(pid)
            await client.shutdown()
        }

        try await waitForMarker("action-delayed")
        guard await XCTWaiter.fulfillment(of: [completed], timeout: 17) == .completed else {
            requester.cancel()
            throw CuaTestError.timeout("timed out requester did not finish")
        }
        do {
            _ = try await requester.value
            XCTFail("a timed-out action completed")
        } catch let error as CuaDriverError {
            XCTAssertEqual(error, .protocolFailure("request timed out"))
        } catch {
            XCTFail("timed-out action failed with an unexpected error: \(error)")
        }

        let health = await client.health()
        XCTAssertFalse(health.ready)
        do {
            _ = try await client.execute(
                try clickAction(id: "after-timeout"),
                sessionID: sessionID
            )
            XCTFail("a no-restart client accepted an action after timeout")
        } catch let error as CuaDriverError {
            XCTAssertEqual(error, .processExited)
        }
        XCTAssertEqual(startCount(), 1)
    }

    func testRestartableTimeoutRetiresWedgedDriverAndRespawns() async throws {
        let client = makeClient()
        let directory = try XCTUnwrap(testDirectory)
        let sessionID = "timeout-respawn"
        _ = try await client.capture(
            target: CuaTargetHint(processID: 4242, windowID: 1001),
            sessionID: sessionID
        )
        try await waitForStartCount(1)
        let wedgedPID = try Self.processID(forStart: 1, in: directory)
        try createMarker("delay-action")
        let completed = expectation(description: "timed out requester completes")
        let requester = Task {
            defer { completed.fulfill() }
            try await client.execute(
                try clickAction(id: "timed-out"),
                sessionID: sessionID
            )
        }
        addTeardownBlock {
            do {
                try Data([1]).write(to: directory.appendingPathComponent("release-action"))
            } catch {
                XCTFail("could not release the delayed action: \(error)")
            }
            requester.cancel()
            for index in [1, 2] {
                if let pid = Self.processIDIfPresent(forStart: index, in: directory) {
                    await Self.terminateTestOwnedProcess(pid)
                }
            }
            await client.shutdown()
        }

        try await waitForMarker("action-delayed")
        guard await XCTWaiter.fulfillment(of: [completed], timeout: 17) == .completed else {
            requester.cancel()
            throw CuaTestError.timeout("timed out requester did not finish")
        }
        do {
            _ = try await requester.value
            XCTFail("a timed-out action completed")
        } catch let error as CuaDriverError {
            XCTAssertEqual(error, .protocolFailure("request timed out"))
        } catch {
            XCTFail("timed-out action failed with an unexpected error: \(error)")
        }

        // The delayed click would hang a fresh driver too — clear the marker
        // so the recovery request exercises a healthy driver.
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("delay-action")
        )
        // Release the wedged fixture: it ignores SIGTERM, so termination only
        // completes once its delay loop ends and it writes to the closed pipe.
        try Data([1]).write(to: directory.appendingPathComponent("release-action"))
        let recovered: StepResult
        do {
            recovered = try await client.execute(
                try clickAction(id: "after-timeout"),
                sessionID: sessionID
            )
        } catch {
            XCTFail("recovery execute failed with \(type(of: error)): \(error)")
            return
        }
        XCTAssertTrue(recovered.success)
        try await waitForStartCount(2)
        let respawnedPID = try Self.processID(forStart: 2, in: directory)
        XCTAssertNotEqual(respawnedPID, wedgedPID)
        let wedgedExited = try await Self.waitForProcessExit(wedgedPID, within: 2)
        XCTAssertTrue(wedgedExited, "timed-out request left wedged driver \(wedgedPID) alive")
    }

    func testPreCancelledActionDoesNotStartDriver() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await client.execute(
                try clickAction(id: "pre-cancelled"),
                sessionID: "pre-cancelled"
            )
        }
        do {
            _ = try await task.value
            XCTFail("pre-cancelled action completed")
        } catch is CancellationError {
        }
        XCTAssertEqual(startCount(), 0)
    }

    func testWorkerRetirementStopsDelayedWorkerWithin500Milliseconds() async throws {
        let client = makeClient()
        let directory = try XCTUnwrap(testDirectory)
        addTeardownBlock {
            if let pid = Self.processIDIfPresent(forStart: 1, in: directory) {
                await Self.terminateTestOwnedProcess(pid)
            }
            await client.shutdown()
        }
        let sessionID = "retiring-delayed-worker"
        _ = try await client.capture(
            target: CuaTargetHint(processID: 4242, windowID: 1001),
            sessionID: sessionID
        )
        try createMarker("delay-action")
        let requester = Task {
            try await client.execute(
                try clickAction(id: "delayed-retire"),
                sessionID: sessionID
            )
        }
        addTeardownBlock {
            if let pid = Self.processIDIfPresent(forStart: 1, in: directory) {
                await Self.terminateTestOwnedProcess(pid)
            }
            do {
                try Data([1]).write(to: directory.appendingPathComponent("release-action"))
            } catch {
                XCTFail("could not release the delayed action: \(error)")
            }
            requester.cancel()
            await client.shutdown()
        }

        try await waitForMarker("action-delayed")
        let pid = try Self.processID(forStart: 1, in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("release-action").path))
        let started = ContinuousClock.now
        try await retireWithinDeadline(client)
        XCTAssertLessThanOrEqual(started.duration(to: .now), .milliseconds(500))
        XCTAssertTrue(
            Self.processHasExited(pid),
            "retirement returned while delayed worker \(pid) was still alive"
        )
    }

    func testWorkerRetirementDoesNotInterruptAnotherClient() async throws {
        let clientA = makeClient()
        let clientB = makeClient()
        let directory = try XCTUnwrap(testDirectory)
        addTeardownBlock {
            for index in [1, 2] {
                if let pid = Self.processIDIfPresent(forStart: index, in: directory) {
                    await Self.terminateTestOwnedProcess(pid)
                }
            }
            await clientA.shutdown()
            await clientB.shutdown()
        }
        let sessionA = "retiring-client-a"
        let sessionB = "retiring-client-b"

        _ = try await clientA.capture(
            target: CuaTargetHint(processID: 4242, windowID: 1001),
            sessionID: sessionA
        )
        try await waitForStartCount(1)
        _ = try await clientB.capture(
            target: CuaTargetHint(processID: 4242, windowID: 1001),
            sessionID: sessionB
        )
        try await waitForStartCount(2)
        let pidA = try Self.processID(forStart: 1, in: directory)
        let pidB = try Self.processID(forStart: 2, in: directory)
        try createMarker("delay-action")
        let requesterA = Task {
            try await clientA.execute(
                try clickAction(id: "client-a-delayed"),
                sessionID: sessionA
            )
        }
        addTeardownBlock {
            await Self.terminateTestOwnedProcess(pidA)
            await Self.terminateTestOwnedProcess(pidB)
            do {
                try Data([1]).write(to: directory.appendingPathComponent("release-action"))
            } catch {
                XCTFail("could not release the delayed action: \(error)")
            }
            requesterA.cancel()
            await clientA.shutdown()
            await clientB.shutdown()
        }

        try await waitForMarker("action-delayed")
        let started = ContinuousClock.now
        try await retireWithinDeadline(clientA)
        XCTAssertLessThanOrEqual(started.duration(to: .now), .milliseconds(500))
        XCTAssertTrue(
            Self.processHasExited(pidA),
            "retirement returned while client A worker \(pidA) was still alive"
        )

        let resultB = try await clientB.execute(
            try clickAction(id: "client-b-action"),
            sessionID: sessionB
        )
        XCTAssertTrue(resultB.success)
        XCTAssertFalse(Self.processHasExited(pidB), "retirement interrupted client B worker \(pidB)")
    }

    func testRetiredClientCannotRestartAfterReload() async throws {
        let client = makeClient()
        let directory = try XCTUnwrap(testDirectory)
        addTeardownBlock {
            if let pid = Self.processIDIfPresent(forStart: 1, in: directory) {
                await Self.terminateTestOwnedProcess(pid)
            }
            await client.shutdown()
        }
        let health = await client.health()
        XCTAssertTrue(health.ready)
        try await retireWithinDeadline(client)
        let pid = try Self.processID(forStart: 1, in: directory)
        XCTAssertTrue(Self.processHasExited(pid))
        let requests = requestLines()

        let retiredHealth = await client.health()
        XCTAssertFalse(retiredHealth.ready)
        do {
            _ = try await client.capture(
                target: CuaTargetHint(processID: 4242, windowID: 1001),
                sessionID: "retired"
            )
            XCTFail("A retired client restarted for capture")
        } catch is CuaDriverError {
        }
        await client.reloadConfiguration()
        let reloadedHealth = await client.health()
        XCTAssertFalse(reloadedHealth.ready)
        try await retireWithinDeadline(client)
        XCTAssertEqual(startCount(), 1)
        XCTAssertEqual(requestLines(), requests)
    }

    func testRetirementDuringInitializationStopsWorkerAndCompletesWaiter() async throws {
        let client = makeClient()
        let directory = try XCTUnwrap(testDirectory)
        try createMarker("delay-initialize")
        let finished = expectation(description: "initialization waiter completed")
        let healthTask = Task {
            defer { finished.fulfill() }
            return await client.health()
        }
        addTeardownBlock {
            if let pid = Self.processIDIfPresent(forStart: 1, in: directory) {
                await Self.terminateTestOwnedProcess(pid)
            }
            await client.shutdown()
            healthTask.cancel()
        }
        try await waitForRequest(containing: "\"method\":\"initialize\"")
        let pid = try Self.processID(forStart: 1, in: directory)
        let started = ContinuousClock.now
        try await retireWithinDeadline(client)
        XCTAssertLessThanOrEqual(started.duration(to: .now), .milliseconds(500))
        XCTAssertTrue(Self.processHasExited(pid))
        await fulfillment(of: [finished], timeout: 0.5)
        let health = await healthTask.value
        XCTAssertFalse(health.ready)
        XCTAssertEqual(startCount(), 1)
        XCTAssertFalse(requestLines().contains { $0.contains("\"name\":\"check_permissions\"") })
    }

    func testRetirementRetainsOwnershipAfterShutdownDetachesConnection() async throws {
        let client = makeClient()
        let directory = try XCTUnwrap(testDirectory)
        addTeardownBlock {
            if let pid = Self.processIDIfPresent(forStart: 1, in: directory) {
                await Self.terminateTestOwnedProcess(pid)
            }
            await client.shutdown()
        }
        try createMarker("hold-old")
        let health = await client.health()
        XCTAssertTrue(health.ready)
        let pid = try Self.processID(forStart: 1, in: directory)
        await client.shutdown()

        let started = ContinuousClock.now
        try await retireWithinDeadline(client, cancelCaller: true)
        XCTAssertLessThanOrEqual(started.duration(to: .now), .milliseconds(500))
        XCTAssertTrue(Self.processHasExited(pid))
        XCTAssertEqual(startCount(), 1)
    }

    func testRetirementWaitsForChildAfterParentExits() async throws {
        let client = makeClient()
        let directory = try XCTUnwrap(testDirectory)
        addTeardownBlock {
            for index in [99, 1] {
                if let pid = Self.processIDIfPresent(forStart: index, in: directory) {
                    await Self.terminateTestOwnedProcess(pid)
                }
            }
            await client.shutdown()
        }
        try createMarker("child-worker")
        let health = await client.health()
        XCTAssertTrue(health.ready)
        try await waitForMarker("pid-99")
        let parent = try Self.processID(forStart: 1, in: directory)
        let child = try Self.processID(forStart: 99, in: directory)
        XCTAssertEqual(getpgid(parent), parent)
        XCTAssertEqual(getpgid(child), parent)
        let started = ContinuousClock.now
        try await retireWithinDeadline(client)
        XCTAssertLessThanOrEqual(started.duration(to: .now), .milliseconds(500))
        XCTAssertTrue(Self.processHasExited(parent))
        XCTAssertTrue(Self.processHasExited(child))
    }

    func testTypedComputerExecutionPreservesDriverParameters() async throws {
        let configuration = CuaDriverConfiguration(
            executableURL: driverURL,
            capabilityManifestURL: testDirectory.appendingPathComponent("capabilities.yaml"),
            hostBundleID: "dev.perry.PerryTests"
        )
        let service = CuaWorkerService(configuration: configuration)
        addTeardownBlock { try await service.shutdown() }
        let supervisor = DoSupervisor(
            confirmer: AutoApproveConfirmer(),
            typedVerifier: AlwaysVerifiedTypedVerifier()
        )
        let (outcome, actionCount) = try await service.withWorker(scope: .foreground, resources: []) { worker in
            // The plan must be bound to the window identity this session
            // actually resolved — including its connection generation.
            let capture = try await worker.capture(target: CuaTargetHint(processID: 4242, windowID: 1001))
            let window = ExecutableAction.WindowIdentity(
                bundleID: capture.target.bundleID,
                processID: capture.target.processID,
                windowID: UInt32(capture.target.windowID),
                connectionGeneration: capture.target.connectionGeneration
            )
            let plan = try ExecutionPlan(
                taskID: TaskID("typed-computer"),
                goal: "exercise keyboard, scroll, and drag",
                actions: [
                    try ExecutableAction(
                        id: "press-key",
                        summary: "press shift-command-return",
                        approvalRequirement: .action,
                        operation: .computer(window: window, command: .pressKey("return", modifiers: [.shift, .command], target: nil)),
                        postcondition: .elementValue("")
                    ),
                    try ExecutableAction(
                        id: "scroll-down",
                        summary: "scroll down",
                        approvalRequirement: .action,
                        operation: .computer(window: window, command: .scroll(direction: .down, amount: 1, unit: .line, target: nil)),
                        postcondition: .elementValue("")
                    ),
                    try ExecutableAction(
                        id: "drag-window",
                        summary: "drag across the window",
                        approvalRequirement: .action,
                        operation: .computer(window: window, command: .drag(
                            from: .windowPixels(x: 1, y: 2),
                            to: .windowPixels(x: 3, y: 4),
                            durationMilliseconds: 250,
                            steps: 12
                        )),
                        postcondition: .elementValue("")
                    ),
                ],
                requestedScopes: [.computerControl]
            )
            return (await supervisor.run(
                plan: plan,
                typedExecutor: TypedActionRouter(
                    worker: worker,
                    workspace: nil,
                    remoteIntegrations: nil,
                    askUser: nil,
                    runCodingTask: nil
                )
            ), plan.actions.count)
        }
        guard case .completed(let stepsRun) = outcome else {
            return XCTFail("typed computer plan did not complete: \(outcome)")
        }
        XCTAssertEqual(stepsRun, actionCount)
        let log = try String(contentsOf: testDirectory.appendingPathComponent("requests.log"), encoding: .utf8)
        let requests = try log.split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let calls = requests.compactMap { $0["params"] as? [String: Any] }
        let actionNames = ["press_key", "scroll", "drag"]
        let actionCalls = calls.filter { actionNames.contains($0["name"] as? String ?? "") }
        XCTAssertEqual(actionCalls.compactMap { $0["name"] as? String }, actionNames)
        let actionArguments = try actionCalls.map {
            try XCTUnwrap($0["arguments"] as? [String: Any])
        }
        let sessionID = try XCTUnwrap(actionArguments.first?["session"] as? String)
        XCTAssertNotNil(UUID(uuidString: sessionID))
        for arguments in actionArguments {
            XCTAssertEqual(arguments["pid"] as? Int, 4242)
            XCTAssertEqual(arguments["window_id"] as? Int, 1001)
            XCTAssertEqual(arguments["delivery_mode"] as? String, "background")
            XCTAssertEqual(arguments["session"] as? String, sessionID)
        }
        let keyCall = try XCTUnwrap(calls.first { $0["name"] as? String == "press_key" })
        let keyArguments = try XCTUnwrap(keyCall["arguments"] as? [String: Any])
        XCTAssertEqual(keyArguments["key"] as? String, "return")
        XCTAssertEqual(keyArguments["modifiers"] as? [String], ["shift", "cmd"])
        let scrollCall = try XCTUnwrap(calls.first { $0["name"] as? String == "scroll" })
        let scrollArguments = try XCTUnwrap(scrollCall["arguments"] as? [String: Any])
        XCTAssertEqual(scrollArguments["direction"] as? String, "down")
        XCTAssertEqual(scrollArguments["amount"] as? Int, 1)
        let dragCall = try XCTUnwrap(calls.first { $0["name"] as? String == "drag" })
        let dragArguments = try XCTUnwrap(dragCall["arguments"] as? [String: Any])
        XCTAssertEqual(dragArguments["from_x"] as? Double, 1)
        XCTAssertEqual(dragArguments["from_y"] as? Double, 2)
        XCTAssertEqual(dragArguments["to_x"] as? Double, 3)
        XCTAssertEqual(dragArguments["to_y"] as? Double, 4)
        XCTAssertEqual(dragArguments["duration_ms"] as? Int, 250)
        XCTAssertEqual(dragArguments["steps"] as? Int, 12)
    }

    func testTransformActionWithoutBoundWorkspaceFailsClosed() async throws {
        let service = CuaWorkerService()
        addTeardownBlock { try await service.shutdown() }
        let workspace = testDirectory.appendingPathComponent("unbound-workspace", isDirectory: true)
        let action = try ExecutableAction(
            id: ActionID("unbound-create"),
            summary: "create an unbound file",
            approvalRequirement: .action,
            operation: .transform(
                workspace: workspace,
                command: .createUTF8File(path: "must-not-be-created.txt", contents: "x")
            ),
            postcondition: .fileContents("x")
        )
        let plan = try ExecutionPlan(
            taskID: TaskID("unbound-transform"),
            goal: "create a file without a bound workspace",
            actions: [action],
            requestedScopes: [.workspaceWrite]
        )
        let supervisor = DoSupervisor(
            confirmer: AutoApproveConfirmer(),
            typedVerifier: AlwaysVerifiedTypedVerifier()
        )

        let outcome = await supervisor.run(
            plan: plan,
            typedExecutor: TypedActionRouter(
                worker: nil,
                workspace: nil,
                remoteIntegrations: nil,
                askUser: nil,
                runCodingTask: nil
            )
        )
        guard case .failed(_, let reason) = outcome else {
            return XCTFail("a transform without a bound workspace completed: \(outcome)")
        }
        XCTAssertEqual(reason, "execution error: typed transform is not bound to this executor's workspace")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("must-not-be-created.txt").path
        ))
        XCTAssertEqual(startCount(), 0)
    }

    func testConflictingWorkspaceClaimFailsBeforeExecution() async throws {
        let service = CuaWorkerService()
        addTeardownBlock { try await service.shutdown() }
        let workspace = testDirectory.appendingPathComponent("claimed-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let gate = WorkerGate()
        let holderStarted = expectation(description: "workspace holder started")
        let holderFinished = expectation(description: "workspace holder finished")
        let holderTeardownFinished = XCTestExpectation(description: "workspace holder teardown finished")
        let holder = Task {
            defer {
                holderFinished.fulfill()
                holderTeardownFinished.fulfill()
            }
            return try await service.withWorker(
                scope: .background,
                resources: [.workspace(workspace.path)]
            ) { _ in
                holderStarted.fulfill()
                await gate.waitUntilReleased()
                return true
            }
        }
        addTeardownBlock {
            holder.cancel()
            await gate.release()
            let result = await XCTWaiter.fulfillment(of: [holderTeardownFinished], timeout: 1)
            if result != .completed {
                XCTFail("workspace holder did not finish during teardown")
            }
        }
        let startedResult = await XCTWaiter.fulfillment(of: [holderStarted], timeout: 1)
        XCTAssertEqual(startedResult, .completed)

        do {
            _ = try await service.withWorker(
                scope: .background,
                resources: [.workspace(workspace.path)]
            ) { _ in
                true
            }
            XCTFail("a conflicting workspace claim succeeded")
        } catch let error as CuaWorkerError {
            XCTAssertEqual(error, .resourceBusy)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        await gate.release()
        let finishedResult = await XCTWaiter.fulfillment(of: [holderFinished], timeout: 1)
        guard finishedResult == .completed else {
            XCTFail("workspace holder did not finish after release")
            return
        }
        let holderResult = await holder.result
        if case .failure(let error) = holderResult {
            XCTFail("workspace holder failed: \(error)")
        }
    }

    func testUnknownIntegrationIDFailsBeforeProviderCall() async throws {
        let service = CuaWorkerService()
        addTeardownBlock { try await service.shutdown() }
        let provider = ProviderCallRecorder()
        let client = RemoteIntegrationClient(transport: { _ in
            await provider.record()
            let url = URL(string: "https://provider.example")!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        })
        let remote = RemoteIntegrationActionRuntime(client: client)
        let action = try ExecutableAction(
            id: ActionID("unknown-integration"),
            summary: "write to an unknown integration",
            approvalRequirement: .action,
            operation: .integration(
                accountID: "not-in-catalog",
                command: .slackSendMessage(channelID: "C1", text: "hello")
            ),
            postcondition: .integrationResource(identifier: "C1", expectedText: "hello")
        )
        let plan = try ExecutionPlan(
            taskID: TaskID("unknown-integration"),
            goal: "write to an unknown integration",
            actions: [action],
            requestedScopes: [.integrationWrite]
        )
        let supervisor = DoSupervisor(
            confirmer: AutoApproveConfirmer(),
            typedVerifier: AlwaysVerifiedTypedVerifier()
        )

        let outcome = await supervisor.run(
            plan: plan,
            typedExecutor: TypedActionRouter(
                worker: nil,
                workspace: nil,
                remoteIntegrations: remote,
                askUser: nil,
                runCodingTask: nil
            )
        )
        guard case .failed(_, let reason) = outcome else {
            return XCTFail("an unknown integration action completed: \(outcome)")
        }
        XCTAssertTrue(
            reason.contains("missingIntegration") || reason.contains("not available"),
            "unexpected failure reason: \(reason)"
        )

        let callCount = await provider.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testSupportedIntegrationConflictFailsBeforeProviderCall() async throws {
        let service = CuaWorkerService()
        addTeardownBlock { try await service.shutdown() }
        let gate = WorkerGate()
        let holderStarted = expectation(description: "integration holder started")
        let holderFinished = expectation(description: "integration holder finished")
        let holderTeardownFinished = XCTestExpectation(description: "integration holder teardown finished")
        let holder = Task {
            defer {
                holderFinished.fulfill()
                holderTeardownFinished.fulfill()
            }
            return try await service.withWorker(
                scope: .background,
                resources: [.integration("slack")]
            ) { _ in
                holderStarted.fulfill()
                await gate.waitUntilReleased()
                return true
            }
        }
        addTeardownBlock {
            holder.cancel()
            await gate.release()
            let result = await XCTWaiter.fulfillment(of: [holderTeardownFinished], timeout: 1)
            if result != .completed {
                XCTFail("integration holder did not finish during teardown")
            }
        }
        let startedResult = await XCTWaiter.fulfillment(of: [holderStarted], timeout: 1)
        XCTAssertEqual(startedResult, .completed)

        do {
            _ = try await service.withWorker(
                scope: .background,
                resources: [.integration("slack")]
            ) { _ in
                true
            }
            XCTFail("a conflicting integration claim succeeded")
        } catch let error as CuaWorkerError {
            XCTAssertEqual(error, .resourceBusy)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        await gate.release()
        let finishedResult = await XCTWaiter.fulfillment(of: [holderFinished], timeout: 1)
        guard finishedResult == .completed else {
            XCTFail("integration holder did not finish after release")
            return
        }
        let holderResult = await holder.result
        if case .failure(let error) = holderResult {
            XCTFail("integration holder failed: \(error)")
        }
    }

    private func retireWithinDeadline(_ client: CuaDriverClient, cancelCaller: Bool = false) async throws {
        let completed = expectation(description: "worker retirement completed")
        let task = Task {
            defer { completed.fulfill() }
            if cancelCaller {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            try await client.retire()
        }
        guard await XCTWaiter.fulfillment(of: [completed], timeout: 1) == .completed else {
            task.cancel()
            throw CuaTestError.timeout("worker retirement did not complete")
        }
        try await task.value
    }

    private func makeClient(allowsRestart: Bool = true, hostBundleID: String = "dev.perry.PerryTests") -> CuaDriverClient {
        CuaDriverClient(
            configuration: CuaDriverConfiguration(
                executableURL: driverURL,
                capabilityManifestURL: testDirectory.appendingPathComponent("capabilities.yaml"),
                hostBundleID: hostBundleID
            ),
            allowsRestart: allowsRestart
        )
    }

    private func makeBundleFixture(includeDriver: Bool = true) throws -> Bundle {
        let bundleURL = testDirectory.appendingPathComponent("Perry.app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let cuaURL = resourcesURL.appendingPathComponent("CuaDriver", isDirectory: true)
        let binURL = cuaURL.appendingPathComponent("bin", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        let infoPlist = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>Perry</string>
            <key>CFBundleIdentifier</key>
            <string>dev.perry.Perry.fixture</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
        </dict>
        </plist>
        """#
        try Data(infoPlist.utf8).write(to: contentsURL.appendingPathComponent("Info.plist"))
        try Data("capabilities".utf8).write(to: cuaURL.appendingPathComponent("capabilities.yaml"))
        try Data([1]).write(to: macOSURL.appendingPathComponent("Perry"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: macOSURL.appendingPathComponent("Perry").path
        )
        if includeDriver {
            let driverURL = binURL.appendingPathComponent("cua-driver")
            try Data([1]).write(to: driverURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: driverURL.path)
        }
        return try XCTUnwrap(Bundle(url: bundleURL))
    }

    private func discoverBundledFixture(
        bundle: Bundle,
        hostIdentity: CuaCodeIdentity,
        driverIdentity: CuaCodeIdentity,
        identityVerifier: @escaping (URL) -> Bool
    ) throws -> CuaDriverConfiguration? {
        let suiteName = "dev.perry.CuaDriverClientTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hostURL = bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let driverURL = try XCTUnwrap(
            bundle.url(forResource: "cua-driver", withExtension: nil, subdirectory: "CuaDriver/bin")
        )
        let resolvedDriverURL = driverURL.resolvingSymlinksInPath().standardizedFileURL
        return CuaDriverConfiguration.discover(
            bundle: bundle,
            userDefaults: defaults,
            identityVerifier: identityVerifier,
            codeIdentityReader: { url in
                let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
                if resolvedURL == hostURL {
                    return hostIdentity
                }
                if resolvedURL == resolvedDriverURL {
                    return driverIdentity
                }
                return nil
            }
        )
    }

    private func createMarker(_ name: String) throws {
        try Data([1]).write(to: testDirectory.appendingPathComponent(name))
    }

    private func clickAction(id: String) throws -> ComputerAction {
        try ComputerAction(
            actionID: id,
            command: .click(.windowPixels(x: 12, y: 20))
        )
    }

    private func requestLines() -> [String] {
        guard let content = try? String(
            contentsOf: testDirectory.appendingPathComponent("requests.log"),
            encoding: .utf8
        ) else {
            return []
        }
        return content.split(whereSeparator: { $0 == "\n" }).map(String.init)
    }

    private func startCount() -> Int {
        guard let content = try? String(
            contentsOf: testDirectory.appendingPathComponent("starts"),
            encoding: .utf8
        ) else {
            return 0
        }
        return Int(content.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func processID(forStart count: Int, in directory: URL) throws -> pid_t {
        let content = try String(
            contentsOf: directory.appendingPathComponent("pid-\(count)"),
            encoding: .utf8
        )
        let pid = try XCTUnwrap(pid_t(content.trimmingCharacters(in: .whitespacesAndNewlines)))
        guard pid > 1, pid != getpid() else {
            throw CuaTestError.timeout("fixture returned an unsafe process ID")
        }
        return pid
    }

    private static func processIDIfPresent(forStart count: Int, in directory: URL) -> pid_t? {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("pid-\(count)").path) else {
            return nil
        }
        do {
            return try processID(forStart: count, in: directory)
        } catch {
            XCTFail("could not read the test-owned process ID: \(error)")
            return nil
        }
    }

    private static func processHasExited(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return true }
        if result == -1 { return errno == ECHILD || errno == ESRCH }
        return false
    }

    private static func waitForProcessExit(
        _ pid: pid_t,
        within timeout: TimeInterval
    ) async throws -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if processHasExited(pid) {
                return true
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return processHasExited(pid)
    }

    private static func terminateTestOwnedProcess(_ pid: pid_t) async {
        guard !processHasExited(pid) else { return }
        _ = kill(pid, SIGKILL)
        do {
            let exited = try await waitForProcessExit(pid, within: 0.5)
            if !exited {
                XCTFail("test-owned worker \(pid) remained alive during teardown")
            }
        } catch {
            XCTFail("could not verify test-owned worker \(pid) teardown: \(error)")
        }
    }

    private func waitForRequest(containing value: String, count: Int = 1) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if requestLines().filter({ $0.contains(value) }).count >= count {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CuaTestError.timeout("request \(value) did not occur \(count) time(s)")
    }

    private func waitForStartCount(_ expected: Int) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if startCount() >= expected {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CuaTestError.timeout("expected \(expected) driver starts, found \(startCount())")
    }

    private func waitForMarker(_ name: String) async throws {
        let marker = testDirectory.appendingPathComponent(name)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: marker.path) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CuaTestError.timeout("marker \(name) did not appear")
    }
}

private struct AutoApproveConfirmer: Confirmer {
    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool { true }
}

private struct AlwaysVerifiedTypedVerifier: TypedActionVerifier {
    func verify(
        approvedAction: ApprovedExecutableAction,
        result: ActionExecutionResult,
        context: ScreenContext
    ) async -> VerificationStatus {
        .verified(evidence: "fixture verification")
    }
}
