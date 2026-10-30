import Foundation

public enum DictationLanguageMode: Equatable, Codable, Sendable {
    case automatic
    case fixed(identifier: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case identifier
    }

    private enum Kind: String, Codable {
        case automatic
        case fixed
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .automatic:
            self = .automatic
        case .fixed:
            self = .fixed(identifier: try values.decode(String.self, forKey: .identifier))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try values.encode(Kind.automatic, forKey: .kind)
        case .fixed(let identifier):
            try values.encode(Kind.fixed, forKey: .kind)
            try values.encode(identifier, forKey: .identifier)
        }
    }
}

public struct DictationPreferences: Equatable, Codable, Sendable {
    public var language: DictationLanguageMode
    public var customWords: [String]
    public var inputDeviceID: UInt32?

    public init(
        language: DictationLanguageMode = .automatic,
        customWords: [String] = [],
        inputDeviceID: UInt32? = nil
    ) {
        self.language = language
        self.customWords = Self.normalizedWords(customWords)
        self.inputDeviceID = inputDeviceID
    }

    public static let `default` = DictationPreferences()

    private static func normalizedWords(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.compactMap { word in
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

public struct SpeechPreferences: Equatable, Codable, Sendable {
    public var outputEnabled: Bool
    public var rateMultiplier: Double
    public var voiceIdentifier: String?

    public init(outputEnabled: Bool = true, rateMultiplier: Double = 1, voiceIdentifier: String? = nil) {
        self.outputEnabled = outputEnabled
        self.rateMultiplier = min(max(rateMultiplier, 0.5), 1.5)
        self.voiceIdentifier = voiceIdentifier
    }

    public static let `default` = SpeechPreferences()
}

public struct VoiceDictionaryStore {
    private static let schemaVersion = 1
    private let fileURL: URL?
    private let fileManager: FileManager

    public init(supportDirectory: URL?, fileManager: FileManager = .default) {
        fileURL = supportDirectory?.appendingPathComponent("voice-dictionary.json")
        self.fileManager = fileManager
    }

    public func entries() throws -> [String: String] {
        guard let fileURL, fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw PersistenceError.readFailed(path: fileURL.path, reason: error.localizedDescription)
        }
        do {
            return try Self.decodeEntries(data)
        } catch {
            return try restoreBackup(afterQuarantining: fileURL, reason: error.localizedDescription)
        }
    }

    public func save(_ values: [String: String]) throws {
        guard let fileURL else { return }
        let cleaned = Self.cleaned(values)
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw PersistenceError.createDirectoryFailed(path: directory.path, reason: error.localizedDescription)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(
                VoiceDictionaryEnvelope(schemaVersion: Self.schemaVersion, entries: cleaned)
            )
        } catch {
            throw PersistenceError.encodeFailed(path: fileURL.path, reason: error.localizedDescription)
        }
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try entries()
            let backupURL = fileURL.appendingPathExtension("backup")
            do {
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
                try fileManager.copyItem(at: fileURL, to: backupURL)
            } catch {
                throw PersistenceError.writeFailed(path: backupURL.path, reason: error.localizedDescription)
            }
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw PersistenceError.writeFailed(path: fileURL.path, reason: error.localizedDescription)
        }
    }

    public func set(spoken: String, replacement: String) throws {
        var values = try entries()
        values[spoken] = replacement
        try save(values)
    }

    public func remove(spoken: String) throws {
        var values = try entries()
        values.removeValue(forKey: spoken)
        try save(values)
    }

    private static func cleaned(_ values: [String: String]) -> [String: String] {
        values.reduce(into: [String: String]()) { result, pair in
            let spoken = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty, !replacement.isEmpty else { return }
            result[spoken] = replacement
        }
    }

    private static func decodeEntries(_ data: Data) throws -> [String: String] {
        let decoder = JSONDecoder()
        do {
            let envelope = try decoder.decode(VoiceDictionaryEnvelope.self, from: data)
            guard envelope.schemaVersion == Self.schemaVersion else {
                throw VoiceDictionaryValidationError.unsupportedVersion(envelope.schemaVersion)
            }
            let cleaned = Self.cleaned(envelope.entries)
            guard cleaned == envelope.entries else {
                throw VoiceDictionaryValidationError.invalidEntries
            }
            return cleaned
        } catch is DecodingError {
        } catch {
            throw error
        }
        do {
            let legacy = try decoder.decode([String: String].self, from: data)
            let cleaned = Self.cleaned(legacy)
            guard cleaned == legacy else {
                throw VoiceDictionaryValidationError.invalidLegacyEntries
            }
            return cleaned
        } catch is DecodingError {
            throw VoiceDictionaryValidationError.invalidJSON
        }
    }

    private func restoreBackup(afterQuarantining fileURL: URL, reason: String) throws -> [String: String] {
        let quarantineURL = try quarantine(fileURL)
        let backupURL = fileURL.appendingPathExtension("backup")
        guard fileManager.fileExists(atPath: backupURL.path) else {
            throw PersistenceError.recoveredCorruptFile(
                path: fileURL.path,
                quarantinePath: quarantineURL.path,
                reason: reason
            )
        }
        let backupData: Data
        let entries: [String: String]
        do {
            backupData = try Data(contentsOf: backupURL)
            entries = try Self.decodeEntries(backupData)
        } catch {
            let backupQuarantineURL = try quarantine(backupURL)
            throw PersistenceError.recoveredCorruptFile(
                path: backupURL.path,
                quarantinePath: backupQuarantineURL.path,
                reason: error.localizedDescription
            )
        }
        do {
            try backupData.write(to: fileURL, options: .atomic)
            return entries
        } catch {
            throw PersistenceError.writeFailed(path: fileURL.path, reason: error.localizedDescription)
        }
    }

    private func quarantine(_ fileURL: URL) throws -> URL {
        let quarantineURL = fileURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: fileURL, to: quarantineURL)
        } catch {
            throw PersistenceError.quarantineFailed(path: fileURL.path, reason: error.localizedDescription)
        }
        return quarantineURL
    }
}

private enum VoiceDictionaryValidationError: Error, LocalizedError {
    case unsupportedVersion(Int)
    case invalidEntries
    case invalidLegacyEntries
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "unsupported voice dictionary version \(version)"
        case .invalidEntries:
            return "voice dictionary contains invalid entries"
        case .invalidLegacyEntries:
            return "voice dictionary contains invalid legacy entries"
        case .invalidJSON:
            return "voice dictionary is not valid JSON"
        }
    }
}

private struct VoiceDictionaryEnvelope: Codable {
    let schemaVersion: Int
    let entries: [String: String]
}

public enum VoiceTextPolicy {
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
    ]

    public static func normalize(_ text: String, frontmostBundleID: String?, dictionary: [String: String]) -> String {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (spoken, replacement) in dictionary.sorted(by: { $0.key.count > $1.key.count }) {
            normalized = normalized.replacingOccurrences(
                of: spoken,
                with: replacement,
                options: [.caseInsensitive, .diacriticInsensitive]
            )
        }
        guard let frontmostBundleID, terminalBundleIDs.contains(frontmostBundleID) else { return normalized }
        return normalized.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    public static func insertionText(from text: String, frontmostBundleID: String?, dictionary: [String: String]) -> String? {
        let normalized = normalize(text, frontmostBundleID: frontmostBundleID, dictionary: dictionary)
        let prefixes = ["type ", "dictate ", "paste "]
        guard let prefix = prefixes.first(where: { normalized.lowercased().hasPrefix($0) }) else { return nil }
        let content = String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }
}
