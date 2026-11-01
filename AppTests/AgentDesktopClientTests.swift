import CryptoKit
import Darwin
import AppKit
import Foundation
import ImageIO
import XCTest
import PerryBrain
import PerryCore
import PerryGuide
import PerryRuntimes
@testable import Perry

private enum AgentDesktopTestError: Error {
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

final class AgentDesktopClientTests: XCTestCase {
    private let driverScript = #"""
    #!/bin/sh
    set -eu
    root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
    IFS=$(printf '\t')
    printf '%s\n' "$*" >> "$root/calls.log"
    unset IFS
    command="$1"
    has() {
        for argument in "$@"; do
            if [ "$argument" = "$flag" ]; then return 0; fi
        done
        return 1
    }
    ok() { printf '{"version":"2.5","ok":true,"command":"%s","data":%s}\n' "$command" "$1"; }
    fail() { printf '{"version":"2.5","ok":false,"command":"%s","error":{"code":"%s","message":"%s","disposition":{"delivery":"%s"}}}\n' "$command" "$1" "$2" "${3:-not_delivered}"; }
    flag="--headed"; headed=0; if has "$@"; then headed=1; fi
    flag="-i"; interactive=0; if has "$@"; then interactive=1; fi
    flag="focused"; focused=0; if has "$@"; then focused=1; fi
    case "$command" in
    permissions)
        if [ -f "$root/no-screen-recording" ]; then
            ok '{"accessibility":{"state":"granted"},"screen_recording":{"state":"denied"}}'
        else
            ok '{"accessibility":{"state":"granted"},"screen_recording":{"state":"granted"}}'
        fi
        ;;
    focus-window)
        : > "$root/focused-window"
        ok '{}'
        ;;
    list-windows)
        if [ -f "$root/window-manager-backdrop" ]; then
            ok '[{"id":"w-1001","title":"Editor - Draft","app_name":"Editor","pid":4242,"bounds":{"x":10,"y":10,"width":800,"height":600},"is_focused":true},{"id":"w-2002","title":"Desktop Backdrop","app_name":"WindowManager","pid":999,"bounds":{"x":10,"y":10,"width":800,"height":600},"is_focused":false}]'
            exit 0
        fi
        if [ -f "$root/staged" ] && [ ! -f "$root/focused-window" ]; then
            ok '[{"id":"w-1001","title":"Editor - Draft","app_name":"Editor","pid":4242,"bounds":{"x":15,"y":507,"width":143,"height":136},"is_focused":false},{"id":"w-2001","title":"Gesture Blocking Overlay","app_name":"WindowManager","pid":999,"bounds":{"x":15,"y":507,"width":143,"height":136},"is_focused":false}]'
            exit 0
        fi
        ok '[{"id":"w-1001","title":"Editor - Draft","app_name":"Editor","pid":4242,"bounds":{"x":10,"y":10,"width":800,"height":600},"is_focused":true},{"id":"w-1002","title":"Editor - Other","app_name":"Editor","pid":4242,"bounds":{"x":40,"y":40,"width":1200,"height":900},"is_focused":false}]'
        ;;
    snapshot)
        if [ -f "$root/focused-secure" ]; then
            ok '{"snapshot_id":"snap-1","complete":true,"ref_count":2,"tree":{"role":"window","name":"Editor - Draft","children":[{"ref_id":"@snap-1:e1","role":"button","name":"Save","available_actions":["Click"],"bounds":{"x":20,"y":20,"width":80,"height":24}},{"ref_id":"@snap-1:e2","role":"textfield","name":"Password","states":["focused","secure"],"bounds":{"x":20,"y":60,"width":300,"height":24}}]}}'
        elif [ -f "$root/secure-fields" ]; then
            ok '{"snapshot_id":"snap-secure","complete":true,"ref_count":2,"tree":{"role":"window","name":"Editor - Draft","children":[{"ref_id":"@snap-secure:e1","role":"textfield","name":"Password","value":"bullets","states":["secure"],"bounds":{"x":20,"y":60,"width":160,"height":24}},{"ref_id":"@snap-secure:e2","role":"textfield","value":"draft text","bounds":{"x":20,"y":90,"width":160,"height":24}},{"ref_id":"@snap-secure:e3","role":"textfield","value":"hunter2","states":["secure"]}]}}'
        elif [ -f "$root/stale-ref" ] && [ "$interactive" -eq 1 ] && [ "$focused" -eq 0 ]; then
            ok '{"snapshot_id":"snap-2","complete":true,"ref_count":1,"tree":{"role":"window","name":"Editor - Draft","children":[{"ref_id":"@snap-2:e1","role":"button","name":"Save","available_actions":["Click"],"bounds":{"x":20,"y":20,"width":80,"height":24}}]}}'
        else
            ok '{"snapshot_id":"snap-1","complete":true,"ref_count":2,"tree":{"role":"window","name":"Editor - Draft","children":[{"ref_id":"@snap-1:e1","role":"button","name":"Save","available_actions":["Click"],"bounds":{"x":20,"y":20,"width":80,"height":24}},{"ref_id":"@snap-1:e2","role":"textfield","name":"Body","states":["focused"],"bounds":{"x":20,"y":60,"width":300,"height":200}}]}}'
        fi
        ;;
    screenshot)
        if [ -f "$root/large-image" ]; then
            printf '{"version":"2.5","ok":true,"command":"screenshot","data":{"format":"png","width":1600,"height":1200,"scale_factor":2,"data":"'
            cat "$root/large-image"
            printf '"}}\n'
        else
            ok '{"format":"png","width":1600,"height":1200,"scale_factor":2,"data":"AQI="}'
        fi
        ;;
    type)
        eval "text=\${$#}"
        if [ -f "$root/verified-type" ]; then
            ok '{"disposition":{"delivery":"delivered_verified"}}'
        elif [ ! -f "$root/unverified-type" ]; then
            printf '%s' "$text" > "$root/typed"
            ok '{}'
        else
            ok '{}'
        fi
        ;;
    get)
        value=""
        if [ -f "$root/typed" ]; then value=$(cat "$root/typed"); fi
        ok "{\"property\":\"value\",\"ref\":\"$2\",\"value\":\"$value\"}"
        ;;
    click)
        if [ -f "$root/stale-ref" ] && [ "${2#@snap-1:}" != "$2" ]; then
            fail STALE_REF "snapshot snap-1 is no longer current"
        elif [ -f "$root/stale-after-delivery" ]; then
            fail STALE_REF "the window changed after the press" delivered_unverified
        elif [ -f "$root/refuse-background" ] && [ "$headed" -eq 0 ]; then
            fail POLICY_DENIED "window w-1001 is not key"
        elif [ -f "$root/refuse-after-delivery" ]; then
            fail ACTION_FAILED "press failed" delivered_unverified
        elif [ -f "$root/app-busy" ]; then
            fail TIMEOUT "the app did not answer within the budget"
        elif [ -f "$root/click-opens-sheet" ]; then
            ok '{"disposition":{"delivery":"delivered_unverified"},"surfaces":[{"kind":"sheet"}]}'
        elif [ -f "$root/click-unverified" ]; then
            ok '{"disposition":{"delivery":"delivered_unverified"}}'
        elif [ -f "$root/delay-action" ] && [ ! -f "$root/action-delayed" ]; then
            printf '%s\n' "$$" > "$root/delayed-pid"
            : > "$root/action-delayed"
            while [ ! -f "$root/release-action" ]; do sleep 0.01; done
            : > "$root/late-response"
            ok '{}'
        else
            ok '{}'
        fi
        ;;
    mouse-click)
        if [ -f "$root/delay-action" ] && [ ! -f "$root/action-delayed" ]; then
            printf '%s\n' "$$" > "$root/delayed-pid"
            : > "$root/action-delayed"
            while [ ! -f "$root/release-action" ]; do sleep 0.01; done
            : > "$root/late-response"
        fi
        ok '{}'
        ;;
    *)
        ok '{}'
        ;;
    esac
    """#

    private let cuaScript = #"""
    #!/bin/sh
    root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
    while IFS= read -r line; do
        printf '%s\n' "$line" >> "$root/cua-requests.log"
        id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        [ -n "$id" ] || continue
        case "$line" in
            *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id" ;;
            *check_permissions*) printf '{"jsonrpc":"2.0","id":%s,"result":{"structuredContent":{"accessibility":true,"screen_recording":true,"source":{"attribution":"host","embedded":true}},"content":[]}}\n' "$id" ;;
            *list_windows*) printf '{"jsonrpc":"2.0","id":%s,"result":{"structuredContent":{"windows":[{"bundle_id":"com.example.Editor","pid":4242,"window_id":1001,"title":"Editor - Draft","bounds":{"x":10,"y":10,"width":800,"height":600},"z_index":20,"is_on_screen":true,"on_current_space":true}]},"content":[]}}\n' "$id" ;;
            *type_text*) printf '{"jsonrpc":"2.0","id":%s,"result":{"structuredContent":{"effect":"confirmed","verified":true},"content":[]}}\n' "$id" ;;
            *) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[]}}\n' "$id" ;;
        esac
    done
    """#

    private var testDirectory: URL!
    private var driverURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-agent-desktop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        driverURL = testDirectory.appendingPathComponent("agent-desktop")
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

    func testEnvironmentKeepsDriverStateInsidePerrySupport() {
        let configuration = makeConfiguration()
        XCTAssertEqual(configuration.environment["AGENT_DESKTOP_HOME"], configuration.stateDirectoryURL.path)
        XCTAssertNil(configuration.environment["PATH"])
    }

    func testHealthNeedsBothPermissions() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let ready = await client.health()
        XCTAssertTrue(ready.ready, ready.summary)
        try createMarker("no-screen-recording")
        let missing = await client.health()
        XCTAssertFalse(missing.ready)
        XCTAssertEqual(calls(named: "permissions").count, 2)
    }

    func testLargeCapturePreservesEveryByte() async throws {
        let expected = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: ($0 * 31) ^ ($0 >> 8)) })
        try expected.base64EncodedString().write(
            to: testDirectory.appendingPathComponent("large-image"), atomically: true, encoding: .utf8
        )
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        for index in 0..<3 {
            let capture = try await client.capture(
                target: ScreenTargetHint(bundleID: "com.example.Editor", windowTitle: "Editor - Draft"),
                sessionID: "large-capture-\(index)"
            )
            XCTAssertEqual(capture.screenshotData, expected)
        }
    }

    func testEveryCallRunsInItsOwnSession() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: "session-a")
        for call in calls() {
            XCTAssertEqual(Array(call.suffix(2)), ["--session", "session-a"], call.joined(separator: " "))
        }
        let snapshot = try XCTUnwrap(calls(named: "snapshot").first)
        XCTAssertTrue(snapshot.contains("--include-bounds"))
        XCTAssertEqual(snapshot[snapshot.index(after: try XCTUnwrap(snapshot.firstIndex(of: "--window-id")))], "w-1001")
        XCTAssertEqual(calls(named: "screenshot").count, 1)
    }

    func testPersistedWindowIDMustExistInsteadOfSelectingFallback() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        do {
            _ = try await client.capture(
                target: ScreenTargetHint(processID: 4242, windowID: 9999, windowTitle: "Editor - Draft"),
                sessionID: "missing-window"
            )
            XCTFail("capture should reject a missing persisted window ID")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .noTargetWindow)
        }
        let missingTarget = await client.target(for: "missing-window")
        XCTAssertNil(missingTarget)
        XCTAssertEqual(calls(named: "list-windows").count, 1)
        XCTAssertTrue(calls(named: "snapshot").isEmpty)
    }

    func testResolveTargetDoesNotReadTheWindow() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let target = try await client.resolveTarget(ScreenTargetHint(processID: 4242), sessionID: "resolve-only")
        XCTAssertEqual(target.windowID, 1001, "the focused window wins")
        XCTAssertEqual(target.bundleID, "com.example.Editor")
        XCTAssertTrue(calls(named: "snapshot").isEmpty)
        XCTAssertTrue(calls(named: "screenshot").isEmpty)
    }

    func testWindowTitleMustExistInsteadOfSelectingFallback() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        do {
            _ = try await client.capture(
                target: ScreenTargetHint(processID: 4242, windowTitle: "Editor - Closed"),
                sessionID: "missing-window-title"
            )
            XCTFail("capture should reject a missing window title")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .noTargetWindow)
        }
        XCTAssertTrue(calls(named: "snapshot").isEmpty)
    }

    func testCaptureRejectsTheHostApplicationBeforeReadingItsWindow() async throws {
        let client = makeClient(hostBundleID: "com.example.Editor")
        addTeardownBlock { await client.shutdown() }
        do {
            _ = try await client.capture(
                target: ScreenTargetHint(bundleID: "com.example.Editor", processID: 4242, windowID: 1001),
                sessionID: "host-window"
            )
            XCTFail("Perry must not capture its own window as task context")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .noTargetWindow)
        }
        XCTAssertTrue(calls(named: "snapshot").isEmpty)
    }

    func testBundleIdentityMustMatchInsteadOfSelectingAnotherApplication() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        do {
            _ = try await client.capture(
                target: ScreenTargetHint(bundleID: "com.example.Other", processID: 4242, windowID: 1001),
                sessionID: "wrong-application"
            )
            XCTFail("capture should reject a window owned by another application")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .noTargetWindow)
        }
        XCTAssertTrue(calls(named: "snapshot").isEmpty)
    }

    func testCaptureKeepsOrdinaryFieldValuesForTheAgentButNeverSecureOnes() async throws {
        try createMarker("secure-fields")
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let capture = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: "secure-capture")
        XCTAssertEqual(capture.snapshotID, "snap-secure")
        let snapshot = try XCTUnwrap(capture.accessibilitySnapshotModel)

        let password = try XCTUnwrap(snapshot.element(withStableID: "@snap-secure:e1"))
        XCTAssertEqual(password.role, .textField)
        XCTAssertEqual(password.rawRole, "AXSecureTextField")
        XCTAssertEqual(password.sensitivity, .secure)
        XCTAssertNil(password.value)
        XCTAssertNotNil(capture.elementDetails["@snap-secure:e1"])
        XCTAssertNil(capture.elementDetails["@snap-secure:e1"]?.value)
        XCTAssertFalse(capture.accessibilitySnapshot?.contains("bullets") ?? false)
        XCTAssertFalse(capture.accessibilitySnapshot?.contains("hunter2") ?? false, "an unnamed secure field must not leak its value")
        XCTAssertNil(capture.elementDetails["@snap-secure:e3"]?.value)

        let note = try XCTUnwrap(snapshot.element(withStableID: "@snap-secure:e2"))
        XCTAssertEqual(note.sensitivity, .unknown)
        XCTAssertNil(note.value)
        XCTAssertNil(note.label)
        XCTAssertEqual(capture.elementDetails["@snap-secure:e2"]?.value, "draft text")
        XCTAssertTrue(capture.treeComplete)
    }

    func testResolvedTargetRejectsMismatchedSession() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let target = try await client.resolveTarget(ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: "resolved-session")
        do {
            _ = try await client.capture(resolvedTarget: target, sessionID: "different-session")
            XCTFail("A resolved target must not be used by another session")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .targetSessionMismatch)
        }
        XCTAssertTrue(calls(named: "snapshot").isEmpty)
    }

    func testResolvedTargetRejectsStaleGenerationAfterShutdown() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let target = try await client.resolveTarget(ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: "stale-target")
        XCTAssertEqual(target.connectionGeneration, 0)
        await client.shutdown()
        let restartedHealth = await client.health()
        XCTAssertTrue(restartedHealth.ready)
        do {
            _ = try await client.capture(resolvedTarget: target, sessionID: "stale-target")
            XCTFail("A resolved target from an earlier generation must be rejected")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .processExited)
        }
        XCTAssertTrue(calls(named: "snapshot").isEmpty)
    }

    func testNoRestartClientDoesNotRunAfterShutdown() async throws {
        let client = makeClient(allowsRestart: false)
        addTeardownBlock { await client.shutdown() }
        let firstHealth = await client.health()
        XCTAssertTrue(firstHealth.ready)
        await client.shutdown()
        let secondHealth = await client.health()
        XCTAssertFalse(secondHealth.ready)
        XCTAssertEqual(calls(named: "permissions").count, 1)
    }

    func testFailedRetargetRetiresPreviousWindowBeforeAnotherAction() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "retargeted-window"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        do {
            _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 9999), sessionID: sessionID)
            XCTFail("A missing replacement window must be rejected")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .noTargetWindow)
        }
        let target = await client.target(for: sessionID)
        XCTAssertNil(target)
        do {
            _ = try await client.execute(
                try ComputerAction(actionID: "retarget-guard", command: .pressKey("Return", modifiers: [], target: nil)),
                sessionID: sessionID
            )
            XCTFail("A failed retarget must not leave the previous window executable")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .targetNotFound)
        }
        XCTAssertTrue(calls(named: "press").isEmpty)
    }

    func testTextInsertionTypesIntoTheFocusedFieldAndReadsItBack() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let target = try await client.insertText(
            "Perry verified this",
            target: ScreenTargetHint(bundleID: "com.example.Editor", processID: 4242, windowID: 1001),
            sessionID: "dictation"
        )
        XCTAssertEqual(target.windowID, 1001)
        let focusedSnapshot = try XCTUnwrap(calls(named: "snapshot").first)
        XCTAssertTrue(focusedSnapshot.contains("focused"))
        XCTAssertEqual(calls(named: "type").first, ["type", "@snap-1:e2", "--session", "dictation", "--", "Perry verified this"])
        XCTAssertEqual(calls(named: "get").first.map { Array($0.prefix(4)) }, ["get", "@snap-1:e2", "--property", "value"])
        XCTAssertTrue(calls(named: "screenshot").isEmpty)
        XCTAssertFalse(calls().contains { $0.contains("--headed") }, "dictation never takes the foreground")
    }

    func testTextInsertionFailsClosedWhenTheFieldDoesNotHoldTheText() async throws {
        try createMarker("unverified-type")
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        do {
            _ = try await client.insertText(
                "Perry verified this",
                target: ScreenTargetHint(processID: 4242, windowID: 1001),
                sessionID: "unverified"
            )
            XCTFail("text the field does not hold must not count as inserted")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .toolRejected("I couldn’t confirm the text went into the field."))
        }
    }

    func testResolvedTargetTextInsertionRejectsMismatchedSessionWithoutTyping() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let target = try await client.resolveTarget(ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: "owner")
        do {
            _ = try await client.insertText("hello", resolvedTarget: target, sessionID: "intruder")
            XCTFail("another session must not type into a resolved target")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .targetSessionMismatch)
        }
        XCTAssertTrue(calls(named: "type").isEmpty)
    }

    func testBundledFixtureIsAvailableForUnsignedHost() throws {
        let bundle = try makeBundleFixture()
        XCTAssertNotNil(try discoverBundledFixture(bundle: bundle, hostIdentity: .unsignedOrAdHoc, driverIdentity: .unsignedOrAdHoc))
    }

    func testMissingBundledDriverIsUnavailable() throws {
        let bundle = try makeBundleFixture(includeDriver: false)
        XCTAssertNil(AgentDesktopConfiguration.discover(bundle: bundle, supportDirectory: testDirectory, codeIdentityReader: { _ in .unsignedOrAdHoc }))
    }

    func testDeveloperIDHostRequiresTheDriverSignedByTheSameTeam() throws {
        let bundle = try makeBundleFixture()
        let team = "PERRYRELEASE"
        let host = ScreenCodeIdentity.appleDeveloperID(identifier: "dev.perry.Perry", teamIdentifier: team)
        let driver = ScreenCodeIdentity.appleDeveloperID(identifier: "agent-desktop", teamIdentifier: team)
        XCTAssertNotNil(try discoverBundledFixture(bundle: bundle, hostIdentity: host, driverIdentity: driver))
        let rejected: [(String, ScreenCodeIdentity)] = [
            ("different team", .appleDeveloperID(identifier: "agent-desktop", teamIdentifier: "OTHERTEAM")),
            ("different identifier", .appleDeveloperID(identifier: "other-driver", teamIdentifier: team)),
            ("upstream ad hoc driver", .unsignedOrAdHoc),
        ]
        for (name, driverIdentity) in rejected {
            XCTAssertNil(try discoverBundledFixture(bundle: bundle, hostIdentity: host, driverIdentity: driverIdentity), name)
        }
    }

    func testBundledDriverSymlinkEscapingTheHostIsRejected() throws {
        let bundle = try makeBundleFixture()
        let bundledURL = try XCTUnwrap(bundle.url(forResource: "agent-desktop", withExtension: nil, subdirectory: "AgentDesktop/bin"))
        let escapedURL = testDirectory.appendingPathComponent("outside-agent-desktop")
        try Data([1]).write(to: escapedURL)
        try FileManager.default.removeItem(at: bundledURL)
        try FileManager.default.createSymbolicLink(at: bundledURL, withDestinationURL: escapedURL)
        XCTAssertFalse(AgentDesktopConfiguration.bundledDriverIsAllowed(
            driverURL: bundledURL,
            hostBundleURL: bundle.bundleURL,
            hostIdentity: .unsignedOrAdHoc,
            driverIdentity: .unsignedOrAdHoc
        ))
    }

    func testExplicitNilConfigurationRemainsUnavailable() async {
        let health = await AgentDesktopClient(configuration: nil).health()
        XCTAssertFalse(health.ready)
        XCTAssertEqual(health.summary, "Screen control isn’t available. Reinstall Perry.")
        XCTAssertTrue(calls().isEmpty)
    }

    func testMalformedComputerActionDoesNotReachTheDriver() async throws {
        XCTAssertThrowsError(
            try ComputerAction(
                actionID: "invalid-drag",
                command: .drag(from: .accessibilityID("s1"), to: .windowPixels(x: 3, y: 4), durationMilliseconds: 250, steps: 12)
            )
        ) { error in
            XCTAssertEqual(error as? ScreenDriverError, .targetNotFound)
        }
        XCTAssertTrue(calls().isEmpty)
    }

    func testForegroundComputerActionsReachTheDriverAsScreenPoints() async throws {
        let client = makeClient(allowsForegroundInput: true)
        addTeardownBlock { await client.shutdown() }
        let sessionID = "typed-actions"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        let point = ExecutableAction.Selector.windowPixels(x: 40, y: 60)
        let commands: [(String, ExecutableAction.ComputerCommand)] = [
            ("click", .click(point)),
            ("right-click", .rightClick(point)),
            ("double-click", .doubleClick(point)),
            ("type", .typeText("  exact text", target: point)),
            ("scroll", .scroll(direction: .down, amount: 7, unit: .line, target: nil)),
            ("key", .pressKey("Return", modifiers: [.shift, .command], target: nil)),
            ("hotkey", .hotkey(key: "s", modifiers: [.command, .shift], target: nil)),
            ("drag", .drag(from: .windowPixels(x: 2, y: 4), to: .windowPixels(x: 30, y: 40), durationMilliseconds: 250, steps: 12)),
        ]
        for (id, command) in commands {
            let result = try await client.execute(try ComputerAction(actionID: id, command: command), sessionID: sessionID)
            XCTAssertTrue(result.success, id)
            XCTAssertEqual(result.stepID, id)
        }
        let mouse = calls(named: "mouse-click").map { Array($0.dropLast(2)) }
        XCTAssertEqual(mouse, [
            ["mouse-click", "--xy=30,40", "--button", "left", "--count", "1", "--headed"],
            ["mouse-click", "--xy=30,40", "--button", "right", "--count", "1", "--headed"],
            ["mouse-click", "--xy=30,40", "--button", "left", "--count", "2", "--headed"],
            ["mouse-click", "--xy=30,40", "--button", "left", "--count", "1", "--headed"],
        ])
        XCTAssertEqual(calls(named: "type").first, ["type", "@snap-1:e2", "--session", sessionID, "--", "  exact text"])
        XCTAssertEqual(calls(named: "scroll").first.map { Array($0.prefix(6)) }, ["scroll", "@snap-1:e2", "--direction", "down", "--amount", "7"])
        XCTAssertEqual(calls(named: "press").map { Array($0.prefix(4)) }, [
            ["press", "shift+cmd+return", "--window-id", "w-1001"],
            ["press", "cmd+shift+s", "--window-id", "w-1001"],
        ])
        XCTAssertEqual(calls(named: "drag").first.map { Array($0.dropLast(2)) }, [
            "drag", "--from-xy=11,12", "--to-xy=25,30", "--headed", "--duration", "250",
        ])
    }

    func testBackgroundClientRefusesPointerInputWithoutMovingTheCursor() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "background-pointer"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        for command in [
            ExecutableAction.ComputerCommand.click(.windowPixels(x: 40, y: 60)),
            .drag(from: .windowPixels(x: 1, y: 2), to: .windowPixels(x: 3, y: 4), durationMilliseconds: 250, steps: 12),
        ] {
            do {
                _ = try await client.execute(try ComputerAction(actionID: "pointer", command: command), sessionID: sessionID)
                XCTFail("a background client must not move the cursor")
            } catch let error as ScreenDriverError {
                XCTAssertEqual(error, AgentDesktopClient.pointerNeedsForeground)
            }
        }
        XCTAssertTrue(calls(named: "mouse-click").isEmpty)
        XCTAssertTrue(calls(named: "drag").isEmpty)
    }

    func testBackgroundClientActsOnElementsWithoutTheForeground() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "background-element"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        let save = ComputerTarget.element(id: "@snap-1:e1", label: "Save", point: ComputerCoordinates(x: 40, y: 60))
        _ = try await client.execute(ComputerAction(stepID: "save", operation: .click(save)), sessionID: sessionID)
        XCTAssertEqual(calls(named: "click").map { Array($0.dropLast(2)) }, [["click", "@snap-1:e1"]])
        XCTAssertFalse(calls().contains { $0.contains("--headed") })
    }

    func testKeyboardActionsFocusTheirSuppliedElementFirst() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "targeted-keys"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        for command in [
            ExecutableAction.ComputerCommand.pressKey("Return", modifiers: [], target: .accessibilityID("@snap-1:e2")),
            .hotkey(key: "s", modifiers: [.command], target: .accessibilityID("@snap-1:e2")),
        ] {
            _ = try await client.execute(try ComputerAction(actionID: "key", command: command), sessionID: sessionID)
        }
        let names = calls().map(\.[0]).filter { $0 == "focus" || $0 == "press" }
        XCTAssertEqual(names, ["focus", "press", "focus", "press"])
        XCTAssertTrue(calls(named: "focus").allSatisfy { $0[1] == "@snap-1:e2" })
    }

    func testClickOnUnmatchedLabelUsesTheObservedPoint() async throws {
        let client = makeClient(allowsForegroundInput: true)
        addTeardownBlock { await client.shutdown() }
        let sessionID = "unmatched-label"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        let target = ComputerTarget.label("Cedar review\nNoor owns the venue checklist.", point: ComputerCoordinates(x: 40, y: 60))
        _ = try await client.execute(ComputerAction(stepID: "text-area", operation: .click(target)), sessionID: sessionID)
        XCTAssertEqual(calls(named: "mouse-click").first?[1], "--xy=30,40")
        XCTAssertTrue(calls(named: "click").isEmpty)
    }

    func testOnlyAForegroundClientRetriesRefusedInputHeaded() async throws {
        try createMarker("refuse-background")
        let save = ComputerTarget.element(id: "@snap-1:e1", label: nil, point: nil)
        for allowed in [false, true] {
            let client = makeClient(allowsForegroundInput: allowed)
            let sessionID = "focus-\(allowed)"
            _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
            do {
                _ = try await client.execute(ComputerAction(stepID: "click", operation: .click(save)), sessionID: sessionID)
                XCTAssertTrue(allowed, "A background client must not take focus")
            } catch let error as ScreenDriverError {
                XCTAssertFalse(allowed, "\(error)")
                XCTAssertEqual(error, .unsupportedAction)
            }
            await client.shutdown()
        }
        XCTAssertEqual(calls(named: "click").filter { $0.contains("--headed") }.count, 1)
    }

    func testOnlyAForegroundClientSendsFinderInputHeaded() async throws {
        try createMarker("finder")
        let save = ComputerTarget.element(id: "@snap-1:e1", label: nil, point: nil)
        for allowed in [false, true] {
            let client = makeClient(allowsForegroundInput: allowed)
            let sessionID = "finder-\(allowed)"
            _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
            _ = try await client.execute(ComputerAction(stepID: "click", operation: .click(save)), sessionID: sessionID)
            await client.shutdown()
        }
        let clicks = calls(named: "click")
        XCTAssertEqual(clicks.filter { !$0.contains("--headed") }.count, 1)
        XCTAssertEqual(clicks.filter { $0.contains("--headed") }.count, 1)
    }

    func testCurrentSnapshotElementActsByRefWithoutRequerying() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "snapshot-ref"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        let area = ComputerTarget.element(id: "@snap-1:e2", label: nil, point: ComputerCoordinates(x: 50, y: 50))
        _ = try await client.execute(ComputerAction(stepID: "key", operation: .pressKey(key: "end", modifiers: [], target: area)), sessionID: sessionID)
        XCTAssertEqual(calls(named: "snapshot").count, 1)
        XCTAssertEqual(calls(named: "focus").first?[1], "@snap-1:e2")
    }

    func testStaleRefIsFoundAgainByItsLabel() async throws {
        try createMarker("stale-ref")
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "stale-ref"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        let save = ComputerTarget.element(id: "@snap-1:e1", label: "Save", point: nil)
        _ = try await client.execute(ComputerAction(stepID: "save", operation: .click(save)), sessionID: sessionID)
        XCTAssertEqual(calls(named: "click").map { $0[1] }, ["@snap-1:e1", "@snap-2:e1"])
    }

    func testUnknownElementCannotBecomeAnUntargetedKeyboardAction() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "unknown-element"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        do {
            _ = try await client.execute(
                try ComputerAction(actionID: "missing-control", command: .pressKey("Return", modifiers: [], target: .accessibilityID("missing-control"))),
                sessionID: sessionID
            )
            XCTFail("A missing control must not redirect keys to the focused control")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .targetNotFound)
        }
        XCTAssertTrue(calls(named: "press").isEmpty)
    }

    func testActionRefusesWindowIdentityThePlanWasNotBoundTo() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "identity-guard"
        let target = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID).target
        func identity(_ windowID: UInt32) -> ExecutableAction.WindowIdentity {
            ExecutableAction.WindowIdentity(
                bundleID: target.bundleID,
                processID: target.processID,
                windowID: windowID,
                connectionGeneration: target.connectionGeneration
            )
        }
        let save = ExecutableAction.ComputerCommand.click(.accessibilityID("@snap-1:e1"))
        _ = try await client.execute(
            try ComputerAction(actionID: "same-window", command: save, expectedWindow: identity(UInt32(target.windowID))),
            sessionID: sessionID
        )
        do {
            _ = try await client.execute(
                try ComputerAction(actionID: "other-window", command: save, expectedWindow: identity(UInt32(target.windowID) + 500)),
                sessionID: sessionID
            )
            XCTFail("a plan bound to another window must not act on this one")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .targetMismatch)
        }
        XCTAssertEqual(calls(named: "click").count, 1, "the mismatched action must not reach the driver")
    }

    func testCancelledActionStopsItsCommandAndDoesNotReplay() async throws {
        let client = makeClient()
        addTeardownBlock {
            try? Data([1]).write(to: self.testDirectory.appendingPathComponent("release-action"))
            await client.shutdown()
        }
        let sessionID = "cancelled-action"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        try createMarker("delay-action")
        let requester = Task { try await client.execute(try saveAction(id: "cancelled"), sessionID: sessionID) }
        try await waitForMarker("action-delayed")
        let pid = try delayedProcessID()
        requester.cancel()
        do {
            _ = try await requester.value
            XCTFail("cancelled action completed")
        } catch is CancellationError {
        }
        let exited = try await Self.waitForProcessExit(pid, within: 1)
        XCTAssertTrue(exited, "the cancelled command \(pid) kept running")
        try createMarker("release-action")
        let second = try await client.execute(try saveAction(id: "after-cancel"), sessionID: sessionID)
        XCTAssertEqual(second.stepID, "after-cancel")
        XCTAssertFalse(FileManager.default.fileExists(atPath: testDirectory.appendingPathComponent("late-response").path))
        XCTAssertEqual(calls(named: "click").count, 2)
    }

    func testAfterACancelledActionTheNextStepLooksTheControlUpAgain() async throws {
        let client = makeClient()
        addTeardownBlock {
            try? Data([1]).write(to: self.testDirectory.appendingPathComponent("release-action"))
            await client.shutdown()
        }
        let sessionID = "cancel-forgets-snapshot"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        let save = ComputerAction(stepID: "save", operation: .click(.element(id: "@snap-1:e1", label: "Save", point: nil)))
        _ = try await client.execute(save, sessionID: sessionID)
        let lookups = calls(named: "snapshot").count
        try createMarker("delay-action")
        let requester = Task { try await client.execute(save, sessionID: sessionID) }
        try await waitForMarker("action-delayed")
        requester.cancel()
        _ = try? await requester.value
        try createMarker("release-action")

        _ = try await client.execute(save, sessionID: sessionID)

        XCTAssertEqual(calls(named: "snapshot").count, lookups + 1)
        XCTAssertEqual(calls(named: "snapshot").last?.contains("-i"), true)
    }

    func testAPasswordIsTypedThroughCuaAndNeverOnTheCommandLine() async throws {
        try createMarker("focused-secure")
        let client = try makeClientWithCua()
        addTeardownBlock { await client.shutdown() }
        let target = try await client.resolveTarget(ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: "secure-insert")

        _ = try await client.insertText("hunter2", resolvedTarget: target, sessionID: "secure-insert")

        XCTAssertEqual(cuaCalls(named: "type_text").first?["text"] as? String, "hunter2")
        XCTAssertTrue(calls(named: "type").isEmpty)
        XCTAssertFalse(calls().contains { $0.contains("hunter2") })
    }

    func testAPasswordFieldNamedByTheStepIsTypedThroughCua() async throws {
        try createMarker("focused-secure")
        let client = try makeClientWithCua()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "secure-step"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)

        _ = try await client.execute(ComputerAction(stepID: "password", operation: .typeText(text: "hunter2", target: .element(id: "@snap-1:e2", label: nil, point: nil))), sessionID: sessionID)

        XCTAssertEqual(calls(named: "focus").first?.contains("@snap-1:e2"), true)
        XCTAssertEqual(cuaCalls(named: "type_text").first?["text"] as? String, "hunter2")
        XCTAssertFalse(calls().contains { $0.contains("hunter2") })
    }

    func testSettingAPasswordFieldsValueIsRefused() async throws {
        try createMarker("focused-secure")
        let client = try makeClientWithCua()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "secure-set-value"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        do {
            _ = try await client.execute(ComputerAction(stepID: "password", operation: .setValue(value: "hunter2", target: .element(id: "@snap-1:e2", label: nil, point: nil))), sessionID: sessionID)
            XCTFail("a password must not go through set-value")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, AgentDesktopClient.secureFieldNeedsTheUser)
        }
        XCTAssertFalse(calls().contains { $0.contains("hunter2") })
        XCTAssertTrue(cuaCalls(named: "type_text").isEmpty)
    }

    func testWithoutCuaAPasswordIsRefusedRatherThanPutOnTheCommandLine() async throws {
        try createMarker("focused-secure")
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let target = try await client.resolveTarget(ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: "secure-no-cua")
        do {
            _ = try await client.insertText("hunter2", resolvedTarget: target, sessionID: "secure-no-cua")
            XCTFail("a password must not go through argv")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, AgentDesktopClient.secureFieldNeedsTheUser)
        }
        XCTAssertFalse(calls().contains { $0.contains("hunter2") })
    }

    func testNoRestartTimeoutRetiresClientAndRejectsLaterActions() async throws {
        let client = makeClient(allowsRestart: false, requestTimeout: .milliseconds(500))
        addTeardownBlock {
            try? Data([1]).write(to: self.testDirectory.appendingPathComponent("release-action"))
            await client.shutdown()
        }
        let sessionID = "timeout-retirement"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        try createMarker("delay-action")
        do {
            _ = try await client.execute(try saveAction(id: "timed-out"), sessionID: sessionID)
            XCTFail("a timed-out action completed")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .requestTimedOut)
        }
        let health = await client.health()
        XCTAssertFalse(health.ready)
        do {
            _ = try await client.execute(try saveAction(id: "after-timeout"), sessionID: sessionID)
            XCTFail("a no-restart client accepted an action after timeout")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .processExited)
        }
        XCTAssertEqual(calls(named: "click").count, 1)
    }

    func testRestartableTimeoutStartsANewGeneration() async throws {
        let client = makeClient(requestTimeout: .milliseconds(500))
        addTeardownBlock {
            try? Data([1]).write(to: self.testDirectory.appendingPathComponent("release-action"))
            await client.shutdown()
        }
        let sessionID = "timeout-respawn"
        let before = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID).target
        try createMarker("delay-action")
        do {
            _ = try await client.execute(try saveAction(id: "timed-out"), sessionID: sessionID)
            XCTFail("a timed-out action completed")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .requestTimedOut)
        }
        let wedged = try delayedProcessID()
        let exited = try await Self.waitForProcessExit(wedged, within: 1)
        XCTAssertTrue(exited, "the timed-out command \(wedged) kept running")
        do {
            _ = try await client.capture(resolvedTarget: before, sessionID: sessionID)
            XCTFail("a target from before the timeout must be rejected")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .processExited)
        }
        let after = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID).target
        XCTAssertEqual(after.connectionGeneration, before.connectionGeneration + 1)
        let recovered = try await client.execute(try saveAction(id: "after-timeout"), sessionID: sessionID)
        XCTAssertTrue(recovered.success)
    }

    func testPreCancelledActionDoesNotRunTheDriver() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await client.execute(try saveAction(id: "pre-cancelled"), sessionID: "pre-cancelled")
        }
        do {
            _ = try await task.value
            XCTFail("pre-cancelled action completed")
        } catch is CancellationError {
        }
        XCTAssertTrue(calls().isEmpty)
    }

    func testRetirementStopsAnInFlightCommandWithin500Milliseconds() async throws {
        let client = makeClient()
        addTeardownBlock {
            try? Data([1]).write(to: self.testDirectory.appendingPathComponent("release-action"))
            await client.shutdown()
        }
        let sessionID = "retiring-delayed-worker"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        try createMarker("delay-action")
        let requester = Task { try await client.execute(try saveAction(id: "delayed-retire"), sessionID: sessionID) }
        try await waitForMarker("action-delayed")
        let pid = try delayedProcessID()
        let started = ContinuousClock.now
        try await retireWithinDeadline(client)
        let exited = try await Self.waitForProcessExit(pid, within: 0.5)
        XCTAssertLessThanOrEqual(started.duration(to: .now), .milliseconds(500))
        XCTAssertTrue(exited, "retirement left command \(pid) running")
        do {
            _ = try await requester.value
            XCTFail("an action interrupted by retirement completed")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .processExited)
        }
    }

    func testRetirementDoesNotInterruptAnotherClient() async throws {
        let clientA = makeClient()
        let clientB = makeClient()
        addTeardownBlock {
            try? Data([1]).write(to: self.testDirectory.appendingPathComponent("release-action"))
            await clientA.shutdown()
            await clientB.shutdown()
        }
        _ = try await clientA.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: "client-a")
        _ = try await clientB.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: "client-b")
        try await retireWithinDeadline(clientA)
        let resultB = try await clientB.execute(try saveAction(id: "client-b-action"), sessionID: "client-b")
        XCTAssertTrue(resultB.success)
        do {
            _ = try await clientA.execute(try saveAction(id: "client-a-action"), sessionID: "client-a")
            XCTFail("a retired client acted")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .processExited)
        }
    }

    func testRetiredClientCannotRestartAfterReload() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let health = await client.health()
        XCTAssertTrue(health.ready)
        try await retireWithinDeadline(client)
        let callsAfterRetirement = calls()
        let retiredHealth = await client.health()
        XCTAssertFalse(retiredHealth.ready)
        do {
            _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: "retired")
            XCTFail("A retired client restarted for capture")
        } catch is ScreenDriverError {
        }
        await client.reloadConfiguration()
        let reloadedHealth = await client.health()
        XCTAssertFalse(reloadedHealth.ready)
        try await retireWithinDeadline(client)
        XCTAssertEqual(calls(), callsAfterRetirement)
    }

    func testBackgroundPointerInputGoesThroughCuaWithoutTheCursor() async throws {
        let client = try makeClientWithCua()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "cua-pointer"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        _ = try await client.execute(try ComputerAction(actionID: "point", command: .click(.windowPixels(x: 40, y: 60))), sessionID: sessionID)
        _ = try await client.execute(
            try ComputerAction(actionID: "drag", command: .drag(from: .windowPixels(x: 2, y: 4), to: .windowPixels(x: 30, y: 40), durationMilliseconds: 250, steps: 12)),
            sessionID: sessionID
        )
        XCTAssertTrue(calls(named: "mouse-click").isEmpty)
        XCTAssertTrue(calls(named: "drag").isEmpty)
        let click = try XCTUnwrap(cuaCalls(named: "click").first)
        XCTAssertEqual(click["x"] as? Double, 40)
        XCTAssertEqual(click["y"] as? Double, 60)
        XCTAssertEqual(click["window_id"] as? Int, 1001)
        XCTAssertEqual(click["delivery_mode"] as? String, "background")
        let drag = try XCTUnwrap(cuaCalls(named: "drag").first)
        XCTAssertEqual(drag["from_x"] as? Double, 2)
        XCTAssertEqual(drag["to_y"] as? Double, 40)
    }

    func testClickTheAppReportsAsUnverifiedIsRepeatedOnceThroughCua() async throws {
        try createMarker("click-unverified")
        let client = try makeClientWithCua()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "cua-unverified"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        _ = try await client.execute(ComputerAction(stepID: "save", operation: .click(.element(id: "@snap-1:e1", label: nil, point: nil))), sessionID: sessionID)
        XCTAssertEqual(calls(named: "click").count, 1)
        XCTAssertEqual(calls(named: "screenshot").count, 1, "only the capture takes a screenshot")
        XCTAssertEqual(cuaCalls(named: "click").count, 1)
        let retry = try XCTUnwrap(cuaCalls(named: "click").first)
        XCTAssertEqual(retry["x"] as? Double, 100)
        XCTAssertEqual(retry["y"] as? Double, 44)
    }

    func testClickWithNoUnverifiedReportIsNotRepeated() async throws {
        let client = try makeClientWithCua()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "cua-verified"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        _ = try await client.execute(ComputerAction(stepID: "save", operation: .click(.element(id: "@snap-1:e1", label: nil, point: nil))), sessionID: sessionID)
        XCTAssertEqual(calls(named: "click").count, 1)
        XCTAssertTrue(cuaCalls(named: "click").isEmpty)
    }

    func testClickThatOpenedASheetIsNotRepeated() async throws {
        try createMarker("click-opens-sheet")
        let client = try makeClientWithCua()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "cua-sheet"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        _ = try await client.execute(ComputerAction(stepID: "save", operation: .click(.element(id: "@snap-1:e1", label: nil, point: nil))), sessionID: sessionID)
        XCTAssertTrue(cuaCalls(named: "click").isEmpty)
    }

    func testConsequentialControlIsNeverClickedTwice() async throws {
        try createMarker("click-unverified")
        let client = try makeClientWithCua()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "cua-consequential"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        _ = try await client.execute(ComputerAction(stepID: "send", operation: .click(.element(id: "@snap-1:e1", label: "Send", point: nil))), sessionID: sessionID)
        _ = try await client.execute(ComputerAction(stepID: "body", operation: .click(.element(id: "@snap-1:e2", label: nil, point: nil))), sessionID: sessionID)
        XCTAssertEqual(calls(named: "click").count, 2)
        XCTAssertTrue(cuaCalls(named: "click").isEmpty)
    }

    func testOnlyLabelledPlainControlsWithoutConsequentialWordsAreRepeatable() {
        func element(_ role: String, _ label: String?) -> AgentDesktopElement {
            AgentDesktopElement(role: role, label: label, center: nil)
        }
        let repeatable: [(AgentDesktopElement?, String?)] = [
            (element("button", "Save"), nil),
            (element("button", "Display"), nil),
            (element("link", "Learn more"), nil),
            (element("tab", "General"), nil),
            (element("button", nil), "Learn more"),
        ]
        let refused: [(AgentDesktopElement?, String?)] = [
            (element("button", "Send"), nil),
            (element("button", "Send message"), nil),
            (element("button", "Add to Cart"), nil),
            (element("button", "Sign Out"), nil),
            (element("button", "Move to Trash"), nil),
            (element("button", "Save"), "Delete draft"),
            (element("button", nil), nil),
            (element("button", "  "), nil),
            (element("checkbox", "Bold"), nil),
            (element("switch", "Wi-Fi"), nil),
            (element("menubutton", "Options"), nil),
            (AgentDesktopElement(role: "button", label: "Mute", center: nil, holdsState: true), nil),
            (nil, "Save"),
        ]
        for (candidate, label) in repeatable {
            XCTAssertTrue(AgentDesktopClient.canRepeatClick(on: candidate, label: label), "\(String(describing: candidate)) \(label ?? "")")
        }
        for (candidate, label) in refused {
            XCTAssertFalse(AgentDesktopClient.canRepeatClick(on: candidate, label: label), "\(String(describing: candidate)) \(label ?? "")")
        }
    }

    func testRefusedElementClickFallsBackToCuaInTheBackground() async throws {
        try createMarker("refuse-background")
        let client = try makeClientWithCua()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "cua-refused"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        _ = try await client.execute(ComputerAction(stepID: "send", operation: .click(.element(id: "@snap-1:e1", label: "Send", point: nil))), sessionID: sessionID)
        XCTAssertFalse(calls().contains { $0.contains("--headed") })
        XCTAssertEqual(cuaCalls(named: "click").first?["x"] as? Double, 100)
    }

    func testFailureAfterDeliveryIsNeverRepeatedThroughCua() async throws {
        try createMarker("refuse-after-delivery")
        let client = try makeClientWithCua()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "cua-delivered-failure"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        do {
            _ = try await client.execute(ComputerAction(stepID: "save", operation: .click(.element(id: "@snap-1:e1", label: nil, point: nil))), sessionID: sessionID)
            XCTFail("a press that may have landed must surface its failure")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .toolRejected("press failed"))
        }
        XCTAssertEqual(calls(named: "click").count, 1)
        XCTAssertTrue(cuaCalls(named: "click").isEmpty)
    }

    func testAnAppTooBusyToTakeThePressIsNotClickedAnotherWay() async throws {
        try createMarker("app-busy")
        let client = try makeClientWithCua()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "cua-app-busy"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        do {
            _ = try await client.execute(ComputerAction(stepID: "send", operation: .click(.element(id: "@snap-1:e1", label: "Send", point: nil))), sessionID: sessionID)
            XCTFail("a busy app must surface the timeout")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .appBusy)
        }
        XCTAssertTrue(cuaCalls(named: "click").isEmpty)
    }

    func testStaleRefAfterDeliveryIsNotClickedAgain() async throws {
        try createMarker("stale-after-delivery")
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "stale-after-delivery"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        let save = ComputerTarget.element(id: "@snap-1:e1", label: "Save", point: nil)
        do {
            _ = try await client.execute(ComputerAction(stepID: "save", operation: .click(save)), sessionID: sessionID)
            XCTFail("a stale ref reported after delivery must not be retried")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .staleTarget)
        }
        XCTAssertEqual(calls(named: "click").count, 1)
    }

    func testTextThatLooksLikeAFlagIsTypedAsText() async throws {
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "flag-text"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        _ = try await client.execute(ComputerAction(stepID: "type", operation: .typeText(text: "--headed", target: nil)), sessionID: sessionID)
        XCTAssertEqual(calls(named: "type").first, ["type", "@snap-1:e2", "--session", sessionID, "--", "--headed"])
        let target = try await client.insertText("-5 degrees", target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: "flag-insert")
        XCTAssertEqual(target.windowID, 1001)
        XCTAssertEqual(calls(named: "type").last, ["type", "@snap-1:e2", "--session", "flag-insert", "--", "-5 degrees"])
    }

    func testTextInsertionTrustsTheDriversOwnVerification() async throws {
        try createMarker("verified-type")
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        _ = try await client.insertText("hello", target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: "verified")
        XCTAssertEqual(calls(named: "get").count, 1, "only the value before typing is read")
    }

    func testTextInsertionRejectsTextTheFieldAlreadyHeld() async throws {
        try createMarker("unverified-type")
        try "hello".write(to: testDirectory.appendingPathComponent("typed"), atomically: true, encoding: .utf8)
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        do {
            _ = try await client.insertText("hello", target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: "already-there")
            XCTFail("text the field held before typing must not count as inserted")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .toolRejected("I couldn’t confirm the text went into the field."))
        }
    }

    func testStageManagerOverlayIsNeverATarget() async throws {
        try createMarker("staged")
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        do {
            _ = try await client.resolveTarget(ScreenTargetHint(processID: 999), sessionID: "overlay")
            XCTFail("the Stage Manager overlay must not be a target")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, .noTargetWindow)
        }
    }

    func testBackgroundWorkerReadsAStagedWindowButRefusesItsThumbnail() async throws {
        try createMarker("staged")
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        do {
            _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: "staged-picture")
            XCTFail("a thumbnail is not a picture of the window")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, AgentDesktopClient.windowInStageStrip)
        }
        let target = try await client.resolveTarget(ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: "staged-tree")
        let capture = try await client.capture(resolvedTarget: target, sessionID: "staged-tree", includeScreenshot: false)
        XCTAssertEqual(capture.snapshotID, "snap-1")
        XCTAssertTrue(calls(named: "screenshot").isEmpty)
        XCTAssertTrue(calls(named: "focus-window").isEmpty, "a background worker never brings a window forward")
    }

    func testStagedWindowIsNeverClickedPhysically() async throws {
        try createMarker("staged")
        try createMarker("click-unverified")
        let client = try makeClientWithCua()
        addTeardownBlock { await client.shutdown() }
        let sessionID = "staged-click"
        let target = try await client.resolveTarget(ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        _ = try await client.capture(resolvedTarget: target, sessionID: sessionID, includeScreenshot: false)
        _ = try await client.execute(ComputerAction(stepID: "save", operation: .click(.element(id: "@snap-1:e1", label: nil, point: nil))), sessionID: sessionID)
        XCTAssertEqual(calls(named: "click").count, 1)
        do {
            _ = try await client.execute(try ComputerAction(actionID: "point", command: .click(.windowPixels(x: 40, y: 60))), sessionID: sessionID)
            XCTFail("a click at a point would land on the thumbnail")
        } catch let error as ScreenDriverError {
            XCTAssertEqual(error, AgentDesktopClient.windowInStageStrip)
        }
        XCTAssertTrue(cuaCalls(named: "click").isEmpty)
    }

    func testForegroundPointerInputNeverLandsOnAStagedThumbnail() async throws {
        let client = makeClient(allowsForegroundInput: true)
        addTeardownBlock { await client.shutdown() }
        let sessionID = "staged-mid-run"
        _ = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: sessionID)
        try createMarker("staged")
        for command in [
            ExecutableAction.ComputerCommand.click(.windowPixels(x: 40, y: 60)),
            .drag(from: .windowPixels(x: 2, y: 4), to: .windowPixels(x: 30, y: 40), durationMilliseconds: 250, steps: 12),
        ] {
            do {
                _ = try await client.execute(try ComputerAction(actionID: "pointer", command: command), sessionID: sessionID)
                XCTFail("pointer input must not land on the strip thumbnail")
            } catch let error as ScreenDriverError {
                XCTAssertEqual(error, AgentDesktopClient.windowInStageStrip)
            }
        }
        XCTAssertTrue(calls(named: "mouse-click").isEmpty)
        XCTAssertTrue(calls(named: "drag").isEmpty)
    }

    func testOnlyTheStageOverlayMarksAWindowAsStaged() async throws {
        try createMarker("window-manager-backdrop")
        let client = makeClient()
        addTeardownBlock { await client.shutdown() }
        let capture = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: "backdrop")
        XCTAssertFalse(capture.screenshotData.isEmpty)
    }

    func testForegroundWorkerBringsAStagedWindowForwardFirst() async throws {
        try createMarker("staged")
        let client = makeClient(allowsForegroundInput: true)
        addTeardownBlock { await client.shutdown() }
        let capture = try await client.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001), sessionID: "staged-front")
        XCTAssertEqual(calls(named: "focus-window").first.map { Array($0.prefix(3)) }, ["focus-window", "--window-id", "w-1001"])
        XCTAssertEqual(capture.target.width, 800)
        XCTAssertFalse(capture.screenshotData.isEmpty)
    }

    func testTypedComputerExecutionReachesTheDriver() async throws {
        let service = ScreenWorkerService(configuration: makeConfiguration())
        addTeardownBlock { try await service.shutdown() }
        let supervisor = DoSupervisor(confirmer: AutoApproveConfirmer(), typedVerifier: AlwaysVerifiedTypedVerifier())
        let (outcome, actionCount) = try await service.withWorker(scope: .foreground, resources: []) { worker in
            let capture = try await worker.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001))
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
                            from: .windowPixels(x: 2, y: 4),
                            to: .windowPixels(x: 30, y: 40),
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
                typedExecutor: TypedActionRouter(worker: worker, workspace: nil, remoteIntegrations: nil, askUser: nil, runCodingTask: nil)
            ), plan.actions.count)
        }
        guard case .completed(let stepsRun) = outcome else {
            return XCTFail("typed computer plan did not complete: \(outcome)")
        }
        XCTAssertEqual(stepsRun, actionCount)
        let actions = calls().filter { ["press", "scroll", "drag"].contains($0[0]) }
        XCTAssertEqual(actions.map(\.[0]), ["press", "scroll", "drag"])
        let sessionID = try XCTUnwrap(actions.first?.last)
        XCTAssertNotNil(UUID(uuidString: sessionID))
        XCTAssertTrue(actions.allSatisfy { $0.last == sessionID })
        XCTAssertEqual(Array(actions[0].prefix(4)), ["press", "shift+cmd+return", "--window-id", "w-1001"])
        XCTAssertEqual(Array(actions[1].prefix(6)), ["scroll", "@snap-1:e2", "--direction", "down", "--amount", "1"])
        XCTAssertEqual(Array(actions[2].prefix(6)), ["drag", "--from-xy=11,12", "--to-xy=25,30", "--headed", "--duration", "250"])
    }

    func testTypedRouterDispatchesTheCommandBoundJustBeforeTheStep() async throws {
        let service = ScreenWorkerService(configuration: makeConfiguration())
        addTeardownBlock { try await service.shutdown() }
        let evidence = EvidenceRecordingTypedVerifier()
        let supervisor = DoSupervisor(confirmer: AutoApproveConfirmer(), typedVerifier: evidence)
        let outcome = try await service.withWorker(scope: .foreground, resources: []) { worker in
            let capture = try await worker.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001))
            let window = ExecutableAction.WindowIdentity(
                bundleID: capture.target.bundleID,
                processID: capture.target.processID,
                windowID: UInt32(capture.target.windowID),
                connectionGeneration: capture.target.connectionGeneration
            )
            let plan = try ExecutionPlan(
                taskID: TaskID("bound-click"),
                goal: "click where the control is now",
                actions: [
                    try ExecutableAction(
                        id: "routine-step-0",
                        summary: "click the control",
                        approvalRequirement: .action,
                        operation: .computer(window: window, command: .click(.windowPixels(x: 1, y: 2))),
                        postcondition: .elementValue("")
                    )
                ],
                requestedScopes: [.computerControl]
            )
            var router = TypedActionRouter(worker: worker, workspace: nil, remoteIntegrations: nil, askUser: nil, runCodingTask: nil)
            router.bindComputerCommand = { _ in
                RoutineStepBinding(command: .click(.windowPixels(x: 40, y: 60)), baselineSHA256: "baseline-before-step")
            }
            return await supervisor.run(plan: plan, typedExecutor: router)
        }
        guard case .completed = outcome else {
            return XCTFail("bound click did not complete: \(outcome)")
        }
        XCTAssertEqual(calls(named: "mouse-click").map { $0[1] }, ["--xy=30,40"])
        XCTAssertEqual(evidence.recorded, [.windowBaseline("baseline-before-step")])
    }

    func testVisualChangeIsMeasuredAgainstTheScreenBeforeThatStep() async throws {
        let service = ScreenWorkerService(configuration: makeConfiguration())
        addTeardownBlock { try await service.shutdown() }
        let (unchanged, changed) = try await service.withWorker(scope: .foreground, resources: []) { worker in
            let capture = try await worker.capture(target: ScreenTargetHint(processID: 4242, windowID: 1001))
            let window = ExecutableAction.WindowIdentity(
                bundleID: capture.target.bundleID,
                processID: capture.target.processID,
                windowID: UInt32(capture.target.windowID),
                connectionGeneration: capture.target.connectionGeneration
            )
            let screenNow = SHA256.hash(data: capture.screenshotData).map { String(format: "%02x", $0) }.joined()
            let staleBaseline = String(repeating: "0", count: 64)
            let action = try ExecutableAction(
                id: "routine-step-1",
                summary: "click the control",
                approvalRequirement: .action,
                operation: .computer(window: window, command: .click(.windowPixels(x: 1, y: 2))),
                postcondition: .visualChange(baselineSHA256: staleBaseline)
            )
            let plan = try ExecutionPlan(
                taskID: TaskID("per-step-baseline"),
                goal: "judge each click against its own before-screen",
                actions: [action],
                requestedScopes: [.computerControl]
            )
            let grant = try await ExecutionApprovalRegistry().issue(plan: plan, scope: .action(action.id))
            let approved = try ApprovedExecutableAction(plan: plan, actionID: action.id, grant: grant)
            let verifier = CompositeActionVerifier(workspace: self.testDirectory, worker: worker)
            let unchanged = await verifier.verify(
                approvedAction: approved,
                result: ActionExecutionResult(action: action, evidence: .windowBaseline(screenNow)),
                context: .empty
            )
            let changed = await verifier.verify(
                approvedAction: approved,
                result: ActionExecutionResult(action: action, evidence: .windowBaseline(staleBaseline)),
                context: .empty
            )
            return (unchanged, changed)
        }
        guard case .unverified = unchanged else {
            return XCTFail("a step that left the screen as it found it was verified: \(unchanged)")
        }
        guard case .verified = changed else {
            return XCTFail("a step that changed the screen was not verified: \(changed)")
        }
    }

    func testTransformActionWithoutBoundWorkspaceFailsClosed() async throws {
        let service = ScreenWorkerService()
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
        XCTAssertTrue(calls().isEmpty)
    }

    func testUnknownIntegrationIDFailsBeforeProviderCall() async throws {
        let service = ScreenWorkerService()
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
        let service = ScreenWorkerService()
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
        } catch let error as ScreenWorkerError {
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

    private func retireWithinDeadline(_ client: AgentDesktopClient) async throws {
        let completed = expectation(description: "worker retirement completed")
        let task = Task {
            defer { completed.fulfill() }
            try await client.retire()
        }
        guard await XCTWaiter.fulfillment(of: [completed], timeout: 1) == .completed else {
            task.cancel()
            throw AgentDesktopTestError.timeout("worker retirement did not complete")
        }
        try await task.value
    }

    private func makeConfiguration(hostBundleID: String = "dev.perry.PerryTests") -> AgentDesktopConfiguration {
        let finderMarker = testDirectory.appendingPathComponent("finder").path
        return AgentDesktopConfiguration(
            executableURL: driverURL,
            hostBundleID: hostBundleID,
            stateDirectoryURL: testDirectory.appendingPathComponent("state", isDirectory: true),
            bundleIdentifier: { pid in
                if pid == 999 { return "com.apple.WindowManager" }
                guard pid == 4242 else { return nil }
                return FileManager.default.fileExists(atPath: finderMarker) ? "com.apple.finder" : "com.example.Editor"
            }
        )
    }

    private func makeClient(
        allowsRestart: Bool = true,
        allowsForegroundInput: Bool = false,
        hostBundleID: String = "dev.perry.PerryTests",
        requestTimeout: Duration = .seconds(15)
    ) -> AgentDesktopClient {
        AgentDesktopClient(
            configuration: makeConfiguration(hostBundleID: hostBundleID),
            allowsRestart: allowsRestart,
            allowsForegroundInput: allowsForegroundInput,
            requestTimeout: requestTimeout
        )
    }

    private func makeClientWithCua() throws -> AgentDesktopClient {
        let cuaURL = testDirectory.appendingPathComponent("cua-driver")
        try cuaScript.trimmingCharacters(in: .whitespacesAndNewlines).write(to: cuaURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cuaURL.path)
        let cua = CuaDriverClient(configuration: CuaDriverConfiguration(
            executableURL: cuaURL,
            capabilityManifestURL: testDirectory.appendingPathComponent("capabilities.yaml"),
            hostBundleID: "dev.perry.PerryTests"
        ))
        return AgentDesktopClient(configuration: makeConfiguration(), fallback: cua)
    }

    private func cuaCalls(named name: String) -> [[String: Any]] {
        guard let log = try? String(contentsOf: testDirectory.appendingPathComponent("cua-requests.log"), encoding: .utf8) else {
            return []
        }
        return log.split(separator: "\n").compactMap { line in
            guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let parameters = request["params"] as? [String: Any],
                  parameters["name"] as? String == name else { return nil }
            return parameters["arguments"] as? [String: Any]
        }
    }

    private func makeBundleFixture(includeDriver: Bool = true) throws -> Bundle {
        let bundleURL = testDirectory.appendingPathComponent("Perry.app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let binURL = contentsURL.appendingPathComponent("Resources/AgentDesktop/bin", isDirectory: true)
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
        for executable in [macOSURL.appendingPathComponent("Perry")] + (includeDriver ? [binURL.appendingPathComponent("agent-desktop")] : []) {
            try Data([1]).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        return try XCTUnwrap(Bundle(url: bundleURL))
    }

    private func discoverBundledFixture(
        bundle: Bundle,
        hostIdentity: ScreenCodeIdentity,
        driverIdentity: ScreenCodeIdentity
    ) throws -> AgentDesktopConfiguration? {
        let hostURL = bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        return AgentDesktopConfiguration.discover(
            bundle: bundle,
            supportDirectory: testDirectory,
            codeIdentityReader: { url in
                url.resolvingSymlinksInPath().standardizedFileURL == hostURL ? hostIdentity : driverIdentity
            }
        )
    }

    private func createMarker(_ name: String) throws {
        try Data([1]).write(to: testDirectory.appendingPathComponent(name))
    }

    private func saveAction(id: String) throws -> ComputerAction {
        try ComputerAction(actionID: id, command: .click(.accessibilityID("@snap-1:e1")))
    }

    private func calls() -> [[String]] {
        guard let content = try? String(contentsOf: testDirectory.appendingPathComponent("calls.log"), encoding: .utf8) else {
            return []
        }
        return content.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    private func calls(named name: String) -> [[String]] {
        calls().filter { $0.first == name }
    }

    private func delayedProcessID() throws -> pid_t {
        let content = try String(contentsOf: testDirectory.appendingPathComponent("delayed-pid"), encoding: .utf8)
        let pid = try XCTUnwrap(pid_t(content.trimmingCharacters(in: .whitespacesAndNewlines)))
        guard pid > 1, pid != getpid() else {
            throw AgentDesktopTestError.timeout("fixture returned an unsafe process ID")
        }
        return pid
    }

    private static func waitForProcessExit(_ pid: pid_t, within timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return kill(pid, 0) != 0
    }

    private func waitForMarker(_ name: String) async throws {
        let marker = testDirectory.appendingPathComponent(name)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: marker.path) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AgentDesktopTestError.timeout("marker \(name) did not appear")
    }
}

private struct AutoApproveConfirmer: Confirmer {
    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool { true }
}

private final class EvidenceRecordingTypedVerifier: TypedActionVerifier, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ActionExecutionEvidence?] = []

    var recorded: [ActionExecutionEvidence?] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func verify(
        approvedAction: ApprovedExecutableAction,
        result: ActionExecutionResult,
        context: ScreenContext
    ) async -> VerificationStatus {
        lock.lock()
        storage.append(result.evidence)
        lock.unlock()
        return .verified(evidence: "recorded")
    }
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


final class AgentDesktopLabelMatchTests: XCTestCase {
    private func snapshot(_ elements: [(label: String, ref: String)]) throws -> AgentDesktopSnapshot {
        let children = elements.map { JSONValue.object(["name": .string($0.label), "ref_id": .string($0.ref), "role": .string("button")]) }
        return try XCTUnwrap(AgentDesktopSnapshot(.object([
            "snapshot_id": .string("s1"),
            "tree": .object(["role": .string("window"), "children": .array(children)]),
        ])))
    }

    func testAnExactLabelBeatsALongerOneThatContainsIt() throws {
        XCTAssertEqual(try snapshot([("Save As…", "@s1:e1"), ("Save", "@s1:e2")]).uniqueRefMatching(label: "Save"), "@s1:e2")
    }

    func testTwoControlsWithTheSameLabelAreAmbiguous() throws {
        XCTAssertNil(try snapshot([("Close", "@s1:e1"), ("Close", "@s1:e2")]).uniqueRefMatching(label: "Close"))
    }

    func testAPartialLabelMatchesOnlyWhenItIsTheOnlyOne() throws {
        XCTAssertEqual(try snapshot([("Export PDF…", "@s1:e3")]).uniqueRefMatching(label: "Export"), "@s1:e3")
        XCTAssertNil(try snapshot([("Save As…", "@s1:e1"), ("Don’t Save", "@s1:e2")]).uniqueRefMatching(label: "Save"))
    }

    private func tree(_ nodes: [[String: JSONValue]]) throws -> AgentDesktopSnapshot {
        try XCTUnwrap(AgentDesktopSnapshot(.object([
            "snapshot_id": .string("s1"),
            "tree": .object(["role": .string("window"), "children": .array(nodes.map(JSONValue.object))]),
        ])))
    }

    func testTextGoesOnlyIntoTheFocusedFieldOrTheOnlyField() throws {
        let field: (String, Bool) -> [String: JSONValue] = { ref, focused in
            ["ref_id": .string(ref), "role": .string("textfield"), "states": .array(focused ? [.string("focused")] : [])]
        }
        let button: [String: JSONValue] = ["ref_id": .string("@s1:e9"), "role": .string("button"), "name": .string("Go")]
        XCTAssertEqual(try tree([field("@s1:e1", false), field("@s1:e2", true)]).focusedTextField?.ref, "@s1:e2")
        XCTAssertEqual(try tree([button, field("@s1:e1", false)]).focusedTextField?.ref, "@s1:e1")
        XCTAssertNil(try tree([field("@s1:e1", false), field("@s1:e2", false)]).focusedTextField)
        XCTAssertNil(try tree([button]).focusedTextField)
    }

    func testElementCentresAreWindowPixelsAtTheBackingScale() throws {
        let snapshot = try tree([[
            "ref_id": .string("@s1:e1"), "role": .string("button"), "name": .string("Save"),
            "bounds": .object(["x": .number(20), "y": .number(20), "width": .number(80), "height": .number(24)]),
        ]])
        let target = ScreenWindowTarget(
            bundleID: "com.example.Editor", processID: 4242, windowID: 1001, connectionGeneration: 0, sessionID: "s",
            title: "Editor", x: 10, y: 10, width: 800, height: 600, zIndex: 1, isOnScreen: true, isOnCurrentSpace: true
        )
        XCTAssertEqual(
            snapshot.elements(in: target, scale: 2)["@s1:e1"],
            AgentDesktopElement(role: "button", label: "Save", center: ComputerCoordinates(x: 100, y: 44))
        )
    }

    func testScreenshotIsCroppedToTheOpaqueWindowInsideItsShadow() throws {
        let width = 40, height = 30
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.3))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 6, y: 10, width: 24, height: 16))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let cropped = AgentDesktopScreenshot.croppedToWindow(output as Data, width: 12, height: 8, scale: 2)
        let image = try XCTUnwrap(NSBitmapImageRep(data: cropped))
        XCTAssertEqual(image.pixelsWide, 24)
        XCTAssertEqual(image.pixelsHigh, 16)
        XCTAssertEqual(image.colorAt(x: 0, y: 0)?.alphaComponent, 1)
        XCTAssertEqual(image.colorAt(x: 23, y: 15)?.alphaComponent, 1)
        XCTAssertEqual(AgentDesktopScreenshot.croppedToWindow(Data([1, 2]), width: 12, height: 8, scale: 2), Data([1, 2]))
    }

    func testListedWindowsKeepTheirNumericIdentity() throws {
        let windows = AgentDesktopWindow.list(.array([
            .object(["id": .string("w-77"), "pid": .number(12), "title": .string("Doc"), "is_focused": .bool(true),
                     "bounds": .object(["x": .number(1), "y": .number(2), "width": .number(300), "height": .number(200)])]),
            .object(["id": .string("not-a-window"), "pid": .number(12)]),
            .object(["id": .string("w-78"), "pid": .number(12), "minimized": .bool(true)]),
        ]))
        XCTAssertEqual(windows.map(\.windowID), [77, 78])
        XCTAssertEqual(windows.map(\.isVisible), [true, false])
        XCTAssertEqual(AgentDesktopWindow.identifier(77), "w-77")
    }
}
