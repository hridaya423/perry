import XCTest
@testable import PerryCore

final class VoiceConfigurationTests: XCTestCase {
    func testDictionaryStoreRoundTripsAndCleansEntries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceDictionaryStore(supportDirectory: directory)

        try store.save(["  perry  ": " Perry ", "": "ignored", "empty": "  "])

        XCTAssertEqual(try store.entries(), ["perry": "Perry"])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("voice-dictionary.json"))
            ) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
    }

    func testDictionaryStoreLoadsLegacyDictionaryAndMigratesOnWrite() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("voice-dictionary.json")
        try JSONEncoder().encode(["perry": "Perry"]).write(to: fileURL)
        let store = VoiceDictionaryStore(supportDirectory: directory)

        XCTAssertEqual(try store.entries(), ["perry": "Perry"])
        try store.set(spoken: "cua", replacement: "CUA")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual((object["entries"] as? [String: String])?.count, 2)
    }

    func testDictionaryStoreQuarantinesCorruptDataAndSurfacesRecovery() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("voice-dictionary.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: fileURL)
        let store = VoiceDictionaryStore(supportDirectory: directory)

        XCTAssertThrowsError(try store.entries()) { error in
            guard case PersistenceError.recoveredCorruptFile(_, let quarantinePath, _) = error else {
                return XCTFail("expected recovered corrupt file, got \(error)")
            }
            XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: quarantinePath)), corrupt)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try store.entries(), [:])
    }

    func testDictionaryStoreRejectsUnsupportedVersion() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("voice-dictionary.json")
        try Data(#"{"schemaVersion":99,"entries":{}}"#.utf8).write(to: fileURL)
        let store = VoiceDictionaryStore(supportDirectory: directory)

        XCTAssertThrowsError(try store.entries()) { error in
            guard case PersistenceError.recoveredCorruptFile(_, _, let reason) = error else {
                return XCTFail("expected unsupported version recovery, got \(error)")
            }
            XCTAssertTrue(reason.contains("unsupported voice dictionary version 99"))
        }
    }

    func testDictionaryStoreDoesNotOverwriteCorruptDataOnSave() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("voice-dictionary.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: fileURL)
        let store = VoiceDictionaryStore(supportDirectory: directory)

        XCTAssertThrowsError(try store.save(["perry": "Perry"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix("voice-dictionary.json.corrupt-") }
        let quarantinedURL = try XCTUnwrap(quarantined)
        XCTAssertEqual(try Data(contentsOf: quarantinedURL), corrupt)
    }

    func testDictionaryStoreBacksUpPreviousEnvelope() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceDictionaryStore(supportDirectory: directory)
        try store.save(["perry": "Perry"])
        let original = try Data(contentsOf: directory.appendingPathComponent("voice-dictionary.json"))

        try store.save(["cua": "CUA"])

        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("voice-dictionary.json.backup")),
            original
        )
    }

    func testDictionaryStoreRestoresValidBackupAfterPrimaryCorruption() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceDictionaryStore(supportDirectory: directory)
        try store.save(["perry": "Perry"])
        try store.save(["cua": "CUA"])
        let fileURL = directory.appendingPathComponent("voice-dictionary.json")
        let backupURL = fileURL.appendingPathExtension("backup")
        let backupData = try Data(contentsOf: backupURL)
        let corruptData = Data("truncated-dictionary".utf8)
        try corruptData.write(to: fileURL)

        let restored = try store.entries()

        XCTAssertEqual(restored, ["perry": "Perry"])
        XCTAssertEqual(try Data(contentsOf: fileURL), backupData)
        let quarantinedURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix("voice-dictionary.json.corrupt-") }
        )
        XCTAssertEqual(try Data(contentsOf: quarantinedURL), corruptData)
    }

    func testVoiceTextPolicyAppliesLongestDictionaryReplacement() {
        let normalized = VoiceTextPolicy.normalize(
            "open perry workspace",
            frontmostBundleID: nil,
            dictionary: ["perry": "Perry", "perry workspace": "PerryDemo"]
        )

        XCTAssertEqual(normalized, "open PerryDemo")
    }

    func testInsertionTextCollapsesTerminalNewlines() {
        let text = VoiceTextPolicy.insertionText(
            from: "type first line\nsecond line",
            frontmostBundleID: "com.apple.Terminal",
            dictionary: [:]
        )

        XCTAssertEqual(text, "first line second line")
    }

    func testDictationPreferencesNormalizeCustomWords() throws {
        let encoded = try JSONEncoder().encode(
            DictationPreferences(language: .fixed(identifier: "en-GB"), customWords: ["Perry", "perry", " "], inputDeviceID: 42)
        )
        let decoded = try JSONDecoder().decode(DictationPreferences.self, from: encoded)

        XCTAssertEqual(decoded.customWords, ["Perry"])
        XCTAssertEqual(decoded.language, .fixed(identifier: "en-GB"))
        XCTAssertEqual(decoded.inputDeviceID, 42)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
