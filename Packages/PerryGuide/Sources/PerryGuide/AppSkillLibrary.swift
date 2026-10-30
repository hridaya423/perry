import Foundation

public struct AppSkill: Equatable, Sendable, Identifiable {
    public let id: String
    public let bundleID: String
    public let displayName: String
    public let body: String
    public let source: Source

    public enum Source: String, Equatable, Sendable {
        case bundled
        case user
    }

    public init(bundleID: String, body: String, source: Source, displayName: String? = nil) {
        self.id = bundleID
        self.bundleID = bundleID
        self.body = body
        self.source = source
        self.displayName = displayName ?? bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}

public struct AppSkillLibrary: @unchecked Sendable {
    private struct BundledEntry {
        let body: String
        let displayName: String
    }

    private let bundledSkills: [String: BundledEntry]
    private let storageDirectory: URL?
    private let defaults: UserDefaults

    public static let maximumSkillBytes = 64 * 1024

    public init(storageDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        self.storageDirectory = storageDirectory
        self.defaults = defaults
        self.bundledSkills = Self.loadBundledSkills()
    }

    public func skill(for bundleID: String?) -> AppSkill? {
        guard let bundleID = Self.normalizedBundleID(bundleID) else { return nil }
        if let storageDirectory,
           let body = Self.readUserSkill(at: fileURL(for: bundleID, in: storageDirectory)) {
            return AppSkill(bundleID: bundleID, body: body, source: .user)
        }
        guard let entry = bundledSkills[bundleID] else { return nil }
        return AppSkill(bundleID: bundleID, body: entry.body, source: .bundled, displayName: entry.displayName)
    }

    public func promptContext(for bundleID: String?) -> String? {
        guard let normalized = Self.normalizedBundleID(bundleID), isEnabled(normalized) else { return nil }
        return skill(for: normalized)?.body
    }

    public func allSkills() -> [AppSkill] {
        let userSkills = storageDirectory.map(Self.loadUserSkills(in:)) ?? [:]
        let bundleIDs = Set(bundledSkills.keys).union(userSkills.keys)
        return bundleIDs.sorted().compactMap { bundleID in
            skill(for: bundleID)
        }
    }

    public func isEnabled(_ bundleID: String) -> Bool {
        guard let normalized = Self.normalizedBundleID(bundleID) else { return false }
        let disabled = Set(defaults.stringArray(forKey: Self.disabledSkillsKey) ?? [])
        return !disabled.contains(normalized)
    }

    public func setEnabled(_ enabled: Bool, for bundleID: String) {
        guard let normalized = Self.normalizedBundleID(bundleID) else { return }
        var disabled = Set(defaults.stringArray(forKey: Self.disabledSkillsKey) ?? [])
        if enabled {
            disabled.remove(normalized)
        } else {
            disabled.insert(normalized)
        }
        defaults.set(disabled.sorted(), forKey: Self.disabledSkillsKey)
    }

    public func save(_ body: String, for bundleID: String) throws {
        guard let normalized = Self.normalizedBundleID(bundleID) else {
            throw AppSkillError.invalidBundleID
        }
        guard let storageDirectory else {
            throw AppSkillError.storageUnavailable
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppSkillError.emptySkill
        }
        guard trimmed.utf8.count <= Self.maximumSkillBytes else {
            throw AppSkillError.skillTooLarge
        }
        let directory = storageDirectory.appendingPathComponent("AppSkills", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try trimmed.write(to: fileURL(for: normalized, in: storageDirectory), atomically: true, encoding: .utf8)
    }

    private func fileURL(for bundleID: String, in directory: URL) -> URL {
        directory.appendingPathComponent("AppSkills", isDirectory: true).appendingPathComponent("\(bundleID).md")
    }

    private static func normalizedBundleID(_ bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        let value = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        return value
    }

    private static let disabledSkillsKey = "perry.skills.disabled"

    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let bundleID: String
            let displayName: String
            let resource: String
        }
        let version: Int
        let skills: [Entry]
    }

    private static func loadBundledSkills() -> [String: BundledEntry] {
        guard let url = Bundle.module.url(forResource: "skills-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == 1 else { return [:] }
        return manifest.skills.reduce(into: [:]) { result, entry in
            guard normalizedBundleID(entry.bundleID) == entry.bundleID,
                  !entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let resourceURL = Bundle.module.url(forResource: entry.resource, withExtension: nil),
                  resourceURL.pathExtension == "md",
                  let body = try? String(contentsOf: resourceURL, encoding: .utf8),
                  body.utf8.count <= maximumSkillBytes else { return }
            result[entry.bundleID] = BundledEntry(body: body, displayName: entry.displayName)
        }
    }

    private static func loadUserSkills(in directory: URL) -> [String: String] {
        let skillsDirectory = directory.appendingPathComponent("AppSkills", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: skillsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        return files.reduce(into: [:]) { result, url in
            guard url.pathExtension == "md" else { return }
            let bundleID = url.deletingPathExtension().lastPathComponent
            guard normalizedBundleID(bundleID) != nil,
                  let body = readUserSkill(at: url) else { return }
            result[bundleID] = body
        }
    }

    private static func readUserSkill(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              data.count <= maximumSkillBytes,
              let body = String(data: data, encoding: .utf8),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return body
    }
}

public enum AppSkillError: Error, Equatable {
    case invalidBundleID
    case storageUnavailable
    case emptySkill
    case skillTooLarge
}
