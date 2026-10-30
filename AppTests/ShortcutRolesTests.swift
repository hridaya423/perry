import AppKit
import Carbon.HIToolbox
import PerryCore
import XCTest
@testable import Perry

@MainActor
final class ShortcutRolesTests: XCTestCase {
    private func preserveDefaults() {
        let keys = [
            PerryPreferences.$legacyPttShortcut.key, PerryPreferences.$legacyWakeShortcut.key,
            PerryPreferences.$storedDictateGesture.key, PerryPreferences.$storedWakeGesture.key,
            PerryPreferences.$typeGesture.key,
        ]
        restoreDefaultsAfterTest(keys)
    }

    func testDictateMigratesEachLegacyValueOnFirstRead() {
        preserveDefaults()
        let table: [(String, Gesture)] = [
            ("functionHold", .hold([.function])),
            ("optionCommandSpace", .chord([.option, .command], keyCode: 49)),
            ("capsLockDoubleTap", .doubleTap([.capsLock])),
            ("controlOptionCommandHold", .hold([.control, .option, .command])),
        ]
        for (legacy, expected) in table {
            UserDefaults.standard.removeObject(forKey: PerryPreferences.$storedDictateGesture.key)
            PerryPreferences.legacyPttShortcut = legacy
            XCTAssertEqual(PerryPreferences.dictateGesture, expected, legacy)
            XCTAssertEqual(PerryPreferences.storedDictateGesture, expected.rawValue, legacy)
            XCTAssertNil(PerryPreferences.legacyPttShortcut, legacy)
            XCTAssertEqual(PerryPreferences.dictateGesture, expected, legacy)
        }
    }

    func testWakeMigratesEachLegacyValueOnFirstRead() {
        preserveDefaults()
        let table: [(String, Gesture)] = [
            ("optionCommandP", .chord([.option, .command], keyCode: 35)),
            ("optionCommandO", .chord([.option, .command], keyCode: 31)),
            ("controlCommandP", .chord([.control, .command], keyCode: 35)),
            ("controlCommandO", .chord([.control, .command], keyCode: 31)),
        ]
        for (legacy, expected) in table {
            UserDefaults.standard.removeObject(forKey: PerryPreferences.$storedWakeGesture.key)
            PerryPreferences.legacyWakeShortcut = legacy
            XCTAssertEqual(PerryPreferences.wakeGesture, expected, legacy)
            XCTAssertEqual(PerryPreferences.storedWakeGesture, expected.rawValue, legacy)
            XCTAssertNil(PerryPreferences.legacyWakeShortcut, legacy)
        }
    }

    func testDefaultsMatchTheShortcutsPerryShippedWith() {
        preserveDefaults()
        XCTAssertEqual(PerryPreferences.dictateGesture, .hold([.function]))
        XCTAssertEqual(PerryPreferences.wakeGesture, .chord([.option, .command], keyCode: 35))
        XCTAssertEqual(PerryPreferences.typeGesture, .doubleTap([.control]))
        UserDefaults.standard.set("gone", forKey: PerryPreferences.$legacyPttShortcut.key)
        UserDefaults.standard.set("gone", forKey: PerryPreferences.$legacyWakeShortcut.key)
        XCTAssertEqual(PerryPreferences.dictateGesture, .hold([.function]))
        XCTAssertEqual(PerryPreferences.wakeGesture, .chord([.option, .command], keyCode: 35))
    }

    func testASavedGestureBeatsAStaleLegacyValueAndSurvivesARoundTrip() {
        preserveDefaults()
        PerryPreferences.legacyPttShortcut = "functionHold"
        PerryPreferences.dictateGesture = .chord([.control, .option], keyCode: 2)
        XCTAssertEqual(PerryPreferences.dictateGesture, .chord([.control, .option], keyCode: 2))
        PerryPreferences.wakeGesture = .chord([.control, .shift, .command], keyCode: 40)
        XCTAssertEqual(PerryPreferences.wakeGesture, .chord([.control, .shift, .command], keyCode: 40))
        PerryPreferences.dictateGesture = .doubleTap([.capsLock])
        XCTAssertEqual(PerryPreferences.dictateGesture, .doubleTap([.capsLock]))
        XCTAssertEqual(Gesture.doubleTap([.capsLock]).spoken, "Double-tap Caps Lock")
    }

    private func captures(_ gestures: [ShortcutRole: Gesture], hotkeys: [SymbolicHotkey] = []) -> [ShortcutRole: ShortcutCapture] {
        Dictionary(uniqueKeysWithValues: ShortcutRole.allCases.map { ($0, $0.capture(gestures: gestures, hotkeys: hotkeys)) })
    }

    func testEveryRoleConflictsWithTheOtherThreeButNotWithItself() {
        let gestures: [ShortcutRole: Gesture] = [
            .talk: .hold([.control, .option]),
            .type: .doubleTap([.control]),
            .dictate: .hold([.function]),
            .wake: .chord([.option, .command], keyCode: 35),
        ]
        let names: [ShortcutRole: String] = [
            .talk: "Talk to Perry", .type: "Type to Perry",
            .dictate: "Dictate anywhere", .wake: "Open Perry",
        ]
        for role in ShortcutRole.allCases {
            for other in ShortcutRole.allCases {
                var capture = captures(gestures)[role]!
                capture.choose(gestures[other]!)
                if other == role {
                    XCTAssertEqual(capture.state, .captured(gestures[other]!), "\(role) re-picking its own gesture")
                } else {
                    XCTAssertEqual(capture.state, .conflict(gestures[other]!, owner: names[other]!), "\(role) picking \(other)’s gesture")
                }
            }
        }
    }

    func testEachRecorderOnlyCapturesTheGesturesItsRuntimeCanDetect() {
        var talk = captures([:])[.talk]!
        talk.begin()
        talk.keyDown(2, modifiers: [.option, .command])
        XCTAssertEqual(talk.state, .recording)
        talk.flagsChanged([.shift])
        talk.flagsChanged([])
        XCTAssertEqual(talk.state, .captured(.hold([.shift])))

        var type = captures([:])[.type]!
        type.begin()
        type.keyDown(2, modifiers: [.option, .command])
        XCTAssertEqual(type.state, .recording)
        type.flagsChanged([.option])
        type.flagsChanged([])
        XCTAssertEqual(type.state, .captured(.doubleTap([.option])))

        var dictate = captures([:])[.dictate]!
        dictate.begin()
        dictate.flagsChanged([.control, .shift])
        dictate.flagsChanged([])
        XCTAssertEqual(dictate.state, .captured(.hold([.control, .shift])))
        dictate.begin()
        dictate.keyDown(2, modifiers: [.control, .shift])
        XCTAssertEqual(dictate.state, .captured(.chord([.control, .shift], keyCode: 2)))

        var wake = captures([:])[.wake]!
        wake.begin()
        wake.flagsChanged([.option])
        wake.flagsChanged([])
        XCTAssertEqual(wake.state, .recording)
        wake.keyDown(2, modifiers: [.option, .rightOption, .command])
        XCTAssertEqual(wake.state, .captured(.chord([.option, .command], keyCode: 2)))
    }

    func testMacOSSymbolicHotkeysAreCheckedForEveryChordRole() {
        let hotkeys = [SymbolicHotkey(keyCode: 49, modifiers: 0x40000)]
        for role in [ShortcutRole.dictate, .wake] {
            var capture = captures([:], hotkeys: hotkeys)[role]!
            capture.begin()
            capture.keyDown(49, modifiers: [.control])
            XCTAssertEqual(capture.state, .conflict(.chord([.control], keyCode: 49), owner: "a macOS keyboard shortcut"), "\(role)")
        }
    }

    func testCapsLockPresetIsAcceptedAsADictationChoice() {
        var capture = captures([:])[.dictate]!
        capture.choose(.doubleTap([.capsLock]))
        XCTAssertEqual(capture.state, .captured(.doubleTap([.capsLock])))
        XCTAssertTrue(ShortcutRole.dictate.presets.contains(.doubleTap([.capsLock])))
    }

    func testWakeRegistrationUsesTheSavedChordsKeyCodeAndCarbonModifiers() throws {
        preserveDefaults()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = AppController.testing(directory: directory)
        defer { controller.subsystems.notchPresence.stop() }

        let first = Gesture.chord([.control, .option, .shift, .command], keyCode: 105)
        try controller.updateWakeShortcut(first)
        XCTAssertEqual(controller.hotkey?.keyCode, UInt32(kVK_F13))
        XCTAssertEqual(controller.hotkey?.modifiers, UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(PerryPreferences.wakeGesture, first)

        let second = Gesture.chord([.control, .option, .command], keyCode: 107)
        try controller.updateWakeShortcut(second)
        XCTAssertEqual(controller.hotkey?.keyCode, 107)
        XCTAssertEqual(controller.hotkey?.modifiers, UInt32(controlKey | optionKey | cmdKey))
        XCTAssertEqual(PerryPreferences.wakeGesture, second)

        XCTAssertThrowsError(try controller.updateWakeShortcut(.hold([.function])))
        XCTAssertThrowsError(try controller.updateWakeShortcut(.chord([.function], keyCode: 96)))
        XCTAssertEqual(controller.hotkey?.keyCode, 107)
        XCTAssertEqual(PerryPreferences.wakeGesture, second)
    }

    func testCarbonMappingKeepsOnlyTheModifiersCarbonKnows() {
        XCTAssertEqual(Gesture.chord([.option, .command], keyCode: 35).carbonHotkey?.modifiers, UInt32(optionKey | cmdKey))
        XCTAssertEqual(Gesture.chord([.option, .rightOption, .command, .function], keyCode: 123).carbonHotkey?.modifiers, UInt32(optionKey | cmdKey))
        XCTAssertEqual(Gesture.chord([.control, .shift], keyCode: 40).carbonHotkey?.keyCode, 40)
        XCTAssertNil(Gesture.chord([.function], keyCode: 96).carbonHotkey)
        XCTAssertNil(Gesture.hold([.control]).carbonHotkey)
        XCTAssertNil(Gesture.doubleTap([.control]).carbonHotkey)
    }
}

@MainActor
final class DictateAndTypeDetectionTests: XCTestCase {
    private final class Log {
        var presses = 0
        var releases = 0
    }

    private func makeController(_ gesture: Gesture) -> (PushToTalkController, Log) {
        let log = Log()
        return (PushToTalkController(gesture: gesture, onPress: { log.presses += 1 }, onRelease: { log.releases += 1 }), log)
    }

    private func key(_ controller: PushToTalkController, code: Int64, flags: CGEventFlags, down: Bool, at timestamp: TimeInterval = 1) {
        controller.handle(keyCode: code, timestamp: timestamp, flags: flags, isKeyDown: down, isKeyUp: !down, tapDisabled: false)
    }

    private func flags(_ flags: CGEventFlags, on controller: PushToTalkController, at timestamp: TimeInterval = 1) {
        controller.handle(keyCode: 0, timestamp: timestamp, flags: flags, isKeyDown: false, isKeyUp: false, tapDisabled: false)
    }

    func testASavedChordPressesOnItsKeyWithExactlyItsModifiers() {
        let (controller, log) = makeController(.chord([.control, .option], keyCode: 2))
        key(controller, code: 2, flags: [.maskControl, .maskAlternate, .maskShift], down: true)
        key(controller, code: 2, flags: [.maskControl], down: true)
        key(controller, code: 3, flags: [.maskControl, .maskAlternate], down: true)
        XCTAssertEqual(log.presses, 0)
        key(controller, code: 2, flags: [.maskControl, .maskAlternate], down: true)
        XCTAssertEqual(log.presses, 1)
        key(controller, code: 2, flags: [.maskControl, .maskAlternate], down: true, at: 1.1)
        XCTAssertEqual(log.presses, 1)
        key(controller, code: 2, flags: [], down: false, at: 1.5)
        XCTAssertEqual(log.releases, 1)
    }

    func testTheOldOptionCommandSpaceChordStillWorksWithEitherOptionKey() {
        let (controller, log) = makeController(.chord([.option, .command], keyCode: 49))
        let rightOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue | 0x40)
        key(controller, code: 49, flags: rightOption, down: true)
        XCTAssertEqual(log.presses, 1)
        key(controller, code: 49, flags: [], down: false, at: 2)
        XCTAssertEqual(log.releases, 1)
    }

    func testASavedHoldIgnoresAnySupersetOfItsModifiers() async throws {
        let (controller, log) = makeController(.hold([.control, .shift]))
        flags([.maskControl, .maskShift, .maskCommand], on: controller)
        flags([.maskControl, .maskShift, .maskSecondaryFn], on: controller, at: 1.1)
        flags([.maskControl], on: controller, at: 1.2)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(log.presses, 0)
        flags([], on: controller, at: 1.5)
        flags([.maskControl, .maskShift], on: controller, at: 2)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(log.presses, 1)
        flags([.maskControl, .maskShift, .maskCommand], on: controller, at: 2.5)
        XCTAssertEqual(log.releases, 1)
    }

    func testFunctionHoldNoLongerFiresWhenAnotherModifierJoins() async throws {
        let (controller, log) = makeController(.hold([.function]))
        flags([.maskSecondaryFn, .maskControl], on: controller)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(log.presses, 0)
    }

    func testCapsLockDoubleTapStillStartsAndStopsDictation() {
        let (controller, log) = makeController(.doubleTap([.capsLock]))
        key(controller, code: 57, flags: [], down: true, at: 1.0)
        key(controller, code: 57, flags: [], down: false, at: 1.1)
        key(controller, code: 57, flags: [], down: true, at: 1.2)
        XCTAssertEqual(log.presses, 1)
        key(controller, code: 57, flags: [], down: false, at: 1.3)
        key(controller, code: 57, flags: [], down: true, at: 1.4)
        XCTAssertEqual(log.releases, 1)
    }

    func testCapsLockToggleEventsWithoutKeyUpStillDoubleTap() {
        let (controller, log) = makeController(.doubleTap([.capsLock]))
        controller.capsLockToggled(at: 1.0, flags: .maskAlphaShift)
        XCTAssertEqual(log.presses, 0)
        controller.capsLockToggled(at: 1.2, flags: [])
        XCTAssertEqual(log.presses, 1)
        controller.capsLockToggled(at: 3.0, flags: .maskAlphaShift)
        XCTAssertEqual(log.releases, 1)
    }

    func testAnUnsupportedDoubleTapNeverPressesDictation() {
        let (controller, log) = makeController(.doubleTap([.control]))
        flags([.maskControl], on: controller, at: 1.0)
        flags([], on: controller, at: 1.1)
        flags([.maskControl], on: controller, at: 1.2)
        key(controller, code: 57, flags: [], down: true, at: 1.3)
        key(controller, code: 57, flags: [], down: true, at: 1.4)
        XCTAssertEqual(log.presses, 0)
    }

    func testUpdatingTheGestureSwitchesWhatPresses() {
        let (controller, log) = makeController(.chord([.option, .command], keyCode: 49))
        controller.update(gesture: .chord([.control], keyCode: 2))
        key(controller, code: 49, flags: [.maskAlternate, .maskCommand], down: true)
        XCTAssertEqual(log.presses, 0)
        key(controller, code: 2, flags: [.maskControl], down: true, at: 2)
        XCTAssertEqual(log.presses, 1)
    }

    private final class TypeLog {
        var composers = 0
    }

    private func makeMonitor(type: ModifierSet) -> (ModifierHoldMonitor, TypeLog) {
        let log = TypeLog()
        let monitor = ModifierHoldMonitor(
            commitDelay: 0,
            talkHold: { [.function] },
            typeTap: { type },
            onHoldStart: {},
            onHoldCommit: {},
            onHoldEnd: {},
            onHoldCancel: {},
            onHoldTap: {},
            onComposer: { log.composers += 1 }
        )
        return (monitor, log)
    }

    private func tap(_ monitor: ModifierHoldMonitor, _ modifiers: ModifierSet, at timestamp: TimeInterval) {
        monitor.handle(timestamp: timestamp, modifiers: modifiers, isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: timestamp + 0.05, modifiers: [], isFlagsChanged: true, tapDisabled: false)
    }

    func testASavedDoubleTapOpensTheComposerAndOnlyThatOne() {
        let (monitor, log) = makeMonitor(type: [.option])
        tap(monitor, [.control], at: 1.0)
        tap(monitor, [.control], at: 1.2)
        XCTAssertEqual(log.composers, 0)
        tap(monitor, [.option], at: 2.0)
        monitor.handle(timestamp: 2.2, modifiers: [.option], isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.composers, 1)
    }

    func testASupersetOfTheSavedDoubleTapNeverOpensTheComposer() {
        let (monitor, log) = makeMonitor(type: [.option])
        tap(monitor, [.option], at: 1.0)
        monitor.handle(timestamp: 1.2, modifiers: [.option, .command], isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.25, modifiers: [], isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.composers, 0)

        tap(monitor, [.option, .command], at: 3.0)
        monitor.handle(timestamp: 3.2, modifiers: [.option], isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.composers, 0)
    }

    func testAMultiModifierDoubleTapNeedsBothModifiersEachTime() {
        let (monitor, log) = makeMonitor(type: [.option, .shift])
        monitor.handle(timestamp: 1.0, modifiers: [.option], isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.02, modifiers: [.option, .shift], isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.06, modifiers: [], isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.2, modifiers: [.shift], isFlagsChanged: true, tapDisabled: false)
        monitor.handle(timestamp: 1.22, modifiers: [.option, .shift], isFlagsChanged: true, tapDisabled: false)
        XCTAssertEqual(log.composers, 1)
    }
}
