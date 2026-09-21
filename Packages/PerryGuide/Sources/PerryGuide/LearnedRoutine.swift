import Foundation

/// A demonstrated workflow the user reviewed and saved. Steps re-resolve
/// their targets against a fresh observation at replay — record-time
/// coordinates are never the match anchor.
public struct LearnedRoutine: Codable, Equatable, Sendable, Identifiable {
    public static let currentVersion = 1
    public static let maximumSteps = 50
    public static let maximumParameters = 20
    public static let maximumEncodedBytes = 64 * 1024
    /// Declared bound for any run-time parameter value or stored literal.
    public static let parameterValueMaxLength = 512

    public let schemaVersion: Int
    public let id: UUID
    public var name: String
    public let appBundleIDs: [String]
    public var steps: [RoutineStep]
    public var revision: Int
    public var provenance: RoutineProvenance
    public let createdAt: Date

    /// The single-application case — replay refuses anything outside this set.
    public var bundleID: String { appBundleIDs[0] }

    public init(
        schemaVersion: Int = LearnedRoutine.currentVersion,
        id: UUID = UUID(),
        name: String,
        appBundleIDs: [String],
        steps: [RoutineStep],
        revision: Int = 1,
        provenance: RoutineProvenance = .recorded,
        createdAt: Date = Date()
    ) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard schemaVersion == Self.currentVersion else {
            throw RoutineError.unsupportedVersion
        }
        guard !trimmedName.isEmpty, trimmedName.count <= 120 else {
            throw RoutineError.invalidName
        }
        guard !appBundleIDs.isEmpty, appBundleIDs.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" })
        }) else {
            throw RoutineError.invalidBundleID
        }
        guard (1...Self.maximumSteps).contains(steps.count) else {
            throw RoutineError.invalidStepCount
        }
        guard revision >= 1 else { throw RoutineError.invalidRevision }
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = trimmedName
        self.appBundleIDs = appBundleIDs
        self.steps = steps
        self.revision = revision
        self.provenance = provenance
        self.createdAt = createdAt
        guard requiredParameters.count <= Self.maximumParameters else {
            throw RoutineError.tooManyParameters
        }
    }

    /// Parameter slots the routine asks the user to fill at run time, in step
    /// order. Empty means the routine runs as recorded with nothing to prompt.
    public var requiredParameters: [(name: String, prompt: String)] {
        steps.compactMap { step in
            if case .typeText(.parameter(let name, let prompt)) = step.action { return (name, prompt) }
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, appBundleIDs, bundleID, steps, revision, provenance, parameters, createdAt
    }

    /// Decodes through the validating init — a stored or imported routine can
    /// never bypass the step/parameter/name bounds. Legacy files carrying a
    /// single `bundleID` still decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bundleIDs = try container.decodeIfPresent([String].self, forKey: .appBundleIDs)
            ?? (try container.decodeIfPresent(String.self, forKey: .bundleID)).map { [$0] }
            ?? []
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            appBundleIDs: bundleIDs,
            steps: container.decode([RoutineStep].self, forKey: .steps),
            revision: container.decodeIfPresent(Int.self, forKey: .revision) ?? 1,
            provenance: container.decodeIfPresent(RoutineProvenance.self, forKey: .provenance) ?? .reviewed,
            createdAt: container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        )
    }

    /// `parameters` in the document is a descriptive mirror — the step slots
    /// stay the single source of truth on decode.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(appBundleIDs, forKey: .appBundleIDs)
        try container.encode(steps, forKey: .steps)
        try container.encode(revision, forKey: .revision)
        try container.encode(provenance, forKey: .provenance)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(requiredParameters.map { RoutineParameter(name: $0.name, prompt: $0.prompt) }, forKey: .parameters)
    }
}

/// How far a routine has earned trust. `tested` can only be set by a verified
/// local run — imports carrying it are downgraded to `reviewed`.
public enum RoutineProvenance: String, Codable, Equatable, Sendable {
    case recorded
    case reviewed
    case tested
}

/// A declared run-time parameter: literal data substitution only, never
/// interpolated shell or code. `kind` and `maxLength` bound what counts as a
/// valid collected value.
public struct RoutineParameter: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case text
        case filename
        case choice
    }

    public var name: String
    public var prompt: String
    public var kind: Kind
    public var maxLength: Int

    public init(name: String, prompt: String, kind: Kind = .text, maxLength: Int = LearnedRoutine.parameterValueMaxLength) {
        self.name = name
        self.prompt = prompt
        self.kind = kind
        self.maxLength = maxLength
    }
}

public enum RoutineError: Error, Equatable {
    case unsupportedVersion
    case invalidName
    case invalidBundleID
    case invalidStepCount
    case invalidRevision
    case tooManyParameters
    case emptyDemonstration
    case storageUnavailable
    case routineTooLarge
    case invalidDocument
    case unknownKeys
}

/// Where a step lands. Matching at replay compares role and label against a
/// fresh observation; the recorded frame is never replayed.
public struct RoutineTarget: Codable, Equatable, Sendable {
    public var role: String
    public var label: String?
    public var subrole: String?

    public init(role: String, label: String? = nil, subrole: String? = nil) {
        self.role = role
        self.label = label
        self.subrole = subrole
    }
}

public struct RoutineStep: Codable, Equatable, Sendable {
    public var summary: String
    public var target: RoutineTarget?
    public var action: RoutineAction
    /// Steps a human must perform — review shows them, replay never runs them.
    public var requiresHuman: Bool
    /// Plain-language outcome the step intends, when review established one.
    public var outcome: String?

    public init(summary: String, target: RoutineTarget? = nil, action: RoutineAction, requiresHuman: Bool = false, outcome: String? = nil) {
        self.summary = summary
        self.target = target
        self.action = action
        self.requiresHuman = requiresHuman
        self.outcome = outcome
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(String.self, forKey: .summary)
        target = try container.decodeIfPresent(RoutineTarget.self, forKey: .target)
        action = try container.decode(RoutineAction.self, forKey: .action)
        requiresHuman = try container.decodeIfPresent(Bool.self, forKey: .requiresHuman) ?? false
        outcome = try container.decodeIfPresent(String.self, forKey: .outcome)
    }
}

public enum RoutineAction: Codable, Equatable, Sendable {
    case click
    case doubleClick
    case typeText(RoutineText)
    case pressKey(String)
    case wait(milliseconds: Int)
}

/// Typed content is either a fixed string or a parameter slot the user fills
/// at run time. The recorder must never capture text aimed at secure fields;
/// nothing sensitive is allowed to enter a routine.
public enum RoutineText: Codable, Equatable, Sendable {
    case literal(String)
    case parameter(name: String, prompt: String)
}

/// What a bounded demonstration produced. The App-side recorder builds this
/// from live input + AX events; inference stays pure and testable.
public struct RecordedDemonstration: Equatable, Sendable {
    public var bundleID: String
    public var events: [RecordedEvent]

    public init(bundleID: String, events: [RecordedEvent]) {
        self.bundleID = bundleID
        self.events = events
    }
}

public enum RecordedEvent: Equatable, Sendable {
    case click(RoutineTarget)
    case doubleClick(RoutineTarget)
    case typed(text: String, into: RoutineTarget?)
    case keyPress(String)
}

/// Turns recorded events into candidate routine steps. The only compression:
/// a click that focuses a field folds into the type step that follows it, and
/// consecutive typed runs on one target merge — everything else is preserved
/// verbatim so review shows what actually happened.
public enum RoutineInference {
    public static func infer(demonstration: RecordedDemonstration, name: String) throws -> LearnedRoutine {
        guard !demonstration.events.isEmpty else { throw RoutineError.emptyDemonstration }
        var steps: [RoutineStep] = []
        var index = 0
        let events = demonstration.events
        while index < events.count {
            switch events[index] {
            case .click(let target):
                // Click-to-focus folds into the type step that follows on the
                // same target.
                if index + 1 < events.count, case .typed(let text, let typedTarget) = events[index + 1],
                   (typedTarget ?? target) == target {
                    steps.append(typeStep(text: text, target: target))
                    index += 2
                    continue
                }
                steps.append(RoutineStep(summary: "Click \(target.label ?? target.role)", target: target, action: .click))
            case .doubleClick(let target):
                steps.append(RoutineStep(summary: "Double-click \(target.label ?? target.role)", target: target, action: .doubleClick))
            case .typed(let text, let target):
                // Merge a run of typed events aimed at the same target.
                var merged = text
                var next = index + 1
                while next < events.count, case .typed(let more, let moreTarget) = events[next], moreTarget == target {
                    merged += more
                    next += 1
                }
                steps.append(typeStep(text: merged, target: target))
                index = next
                continue
            case .keyPress(let key):
                steps.append(RoutineStep(summary: "Press \(key)", action: .pressKey(key)))
            }
            index += 1
        }
        return try LearnedRoutine(name: name, appBundleIDs: [demonstration.bundleID], steps: steps)
    }

    private static func typeStep(text: String, target: RoutineTarget?) -> RoutineStep {
        let clipped = text.count > 24 ? String(text.prefix(24)) + "…" : text
        let whereabouts = target.map { " into \($0.label ?? $0.role)" } ?? ""
        return RoutineStep(summary: "Type \"\(clipped)\"\(whereabouts)", target: target, action: .typeText(.literal(text)))
    }
}

/// The routine document contract: a fenced ```json metadata block followed by
/// editable Markdown. The metadata is authoritative — the body is for humans
/// and is ignored on decode.
public enum RoutineDocument {
    /// Keys the metadata block may carry. Anything else rejects the document —
    /// imported content is inert and untrusted, so smuggled fields never
    /// decode. Duplicate-key detection isn't available through Foundation's
    /// JSON parsers; the decoded-and-revalidated model is the only artifact.
    private static let allowedKeys: Set<String> = [
        "schemaVersion", "id", "revision", "name", "appBundleIDs", "bundleID",
        "parameters", "steps", "provenance", "createdAt"
    ]
    private static let allowedStepKeys: Set<String> = [
        "summary", "target", "action", "requiresHuman", "outcome"
    ]

    public static func encode(_ routine: LearnedRoutine) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadata = try encoder.encode(routine)
        guard let json = String(data: metadata, encoding: .utf8) else { throw RoutineError.invalidDocument }
        var body = "```json\n\(json)\n```\n\n# \(routine.name)\n\n## Steps\n"
        for (index, step) in routine.steps.enumerated() {
            body += "\(index + 1). \(step.summary)\(step.requiresHuman ? " *(manual step)*" : "")\n"
        }
        guard let data = body.data(using: .utf8) else { throw RoutineError.invalidDocument }
        return data
    }

    public static func decode(_ data: Data) throws -> LearnedRoutine {
        guard let text = String(data: data, encoding: .utf8) else { throw RoutineError.invalidDocument }
        guard let metadata = fencedJSON(from: text) else { throw RoutineError.invalidDocument }
        guard let object = try? JSONSerialization.jsonObject(with: metadata), let dictionary = object as? [String: Any] else {
            throw RoutineError.invalidDocument
        }
        guard dictionary.keys.allSatisfy({ allowedKeys.contains($0) }) else { throw RoutineError.unknownKeys }
        if let steps = dictionary["steps"] as? [[String: Any]] {
            guard steps.allSatisfy({ $0.keys.allSatisfy(allowedStepKeys.contains) }) else { throw RoutineError.unknownKeys }
        }
        return try JSONDecoder().decode(LearnedRoutine.self, from: metadata)
    }

    private static func fencedJSON(from text: String) -> Data? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...].makeIterator()
        var inFence = false
        var collected = ""
        while let line = lines.next() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inFence, trimmed == "```json" { inFence = true; continue }
            if inFence, trimmed == "```" { return collected.data(using: .utf8) }
            if inFence { collected += line + "\n" }
        }
        return nil
    }
}

/// Local-first routine persistence: one `.md` document per routine under
/// `Routines/` in app storage (legacy `.json` files still decode). Malformed
/// or oversized files are skipped, never repaired silently.
public struct RoutineStore: @unchecked Sendable {
    private let storageDirectory: URL?

    public init(storageDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory
    }

    public func all() -> [LearnedRoutine] {
        guard let directory = routinesDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else { return [] }
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  data.count <= LearnedRoutine.maximumEncodedBytes else { return nil }
            switch url.pathExtension {
            case "md": return try? RoutineDocument.decode(data)
            case "json":
                guard let routine = try? JSONDecoder().decode(LearnedRoutine.self, from: data),
                      routine.schemaVersion == LearnedRoutine.currentVersion else { return nil }
                return routine
            default: return nil
            }
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func routine(id: UUID) -> LearnedRoutine? {
        all().first { $0.id == id }
    }

    public func save(_ routine: LearnedRoutine) throws {
        guard let directory = routinesDirectory() else { throw RoutineError.storageUnavailable }
        let data = try RoutineDocument.encode(routine)
        guard data.count <= LearnedRoutine.maximumEncodedBytes else { throw RoutineError.routineTooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(routine.id.uuidString).md"), options: .atomic)
    }

    /// Import from a user-selected file: strict decode, then save under our
    /// own generated filename. An imported `tested` provenance is not local
    /// evidence — it downgrades to `reviewed`.
    public func importRoutine(from url: URL) throws -> LearnedRoutine {
        let data = try Data(contentsOf: url)
        guard data.count <= LearnedRoutine.maximumEncodedBytes else { throw RoutineError.routineTooLarge }
        var routine: LearnedRoutine
        if url.pathExtension == "json" {
            routine = try JSONDecoder().decode(LearnedRoutine.self, from: data)
        } else {
            routine = try RoutineDocument.decode(data)
        }
        if routine.provenance == .tested { routine.provenance = .reviewed }
        try save(routine)
        return routine
    }

    public func exportData(_ routine: LearnedRoutine) throws -> Data {
        try RoutineDocument.encode(routine)
    }

    public func remove(id: UUID) throws {
        guard let directory = routinesDirectory() else { return }
        for ext in ["md", "json"] {
            let url = directory.appendingPathComponent("\(id.uuidString).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func routinesDirectory() -> URL? {
        storageDirectory?.appendingPathComponent("Routines", isDirectory: true)
    }
}

/// Provider wording pass over a locally-inferred draft. The provider sees only
/// step structure — action kind, target role/label, app bundle ID — never typed
/// values, screenshots, or tools, and may only rename the routine and rephrase
/// step summaries. Anything outside the strict schema is discarded and the
/// local draft stands.
public enum RoutineSynthesis {
    public static let maximumResponseBytes = 8 * 1024

    public static func polish(
        routine: LearnedRoutine,
        complete: @Sendable (String) async throws -> String
    ) async throws -> LearnedRoutine {
        let raw = try await complete(prompt(for: routine))
        return try apply(raw: raw, to: routine)
    }

    static func prompt(for routine: LearnedRoutine) -> String {
        let steps = routine.steps.enumerated().map { index, step in
            "\(index + 1). \(describe(step))"
        }.joined(separator: "\n")
        return """
        Name this recorded macOS routine and write one short summary per step.
        Reply with ONLY a JSON object: {"name": string, "stepSummaries": [string]} —
        exactly \(routine.steps.count) summaries, no other keys, no prose.
        App: \(routine.appBundleIDs.joined(separator: ", "))
        Steps:
        \(steps)
        """
    }

    static func apply(raw: String, to routine: LearnedRoutine) throws -> LearnedRoutine {
        guard raw.utf8.count <= maximumResponseBytes else { throw RoutineError.invalidDocument }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["name", "stepSummaries"],
              let name = object["name"] as? String,
              let summaries = object["stepSummaries"] as? [String],
              summaries.count == routine.steps.count else {
            throw RoutineError.invalidDocument
        }
        var polished = routine
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty, trimmedName.count <= 120 {
            polished.name = trimmedName
        }
        for (index, summary) in summaries.enumerated() {
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.count <= 120 {
                polished.steps[index].summary = trimmed
            }
        }
        return polished
    }

    private static func describe(_ step: RoutineStep) -> String {
        let target = step.target.map { "\($0.role) \"\($0.label ?? "unlabeled")\"" } ?? "no target"
        switch step.action {
        case .click: return "click \(target)"
        case .doubleClick: return "double-click \(target)"
        case .typeText(let text):
            switch text {
            case .literal: return "type recorded text into \(target)"
            case .parameter(let name, _): return "type {\(name)} into \(target)"
            }
        case .pressKey(let key): return "press \(key) on \(target)"
        case .wait(let ms): return "wait \(ms) ms"
        }
    }
}
