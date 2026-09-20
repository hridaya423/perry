import Foundation

/// A demonstrated workflow the user reviewed and saved. Steps re-resolve
/// their targets against a fresh observation at replay — record-time
/// coordinates are never the match anchor.
public struct LearnedRoutine: Codable, Equatable, Sendable, Identifiable {
    public static let currentVersion = 1
    public static let maximumSteps = 60
    public static let maximumEncodedBytes = 64 * 1024

    public let schemaVersion: Int
    public let id: UUID
    public var name: String
    public let bundleID: String
    public var steps: [RoutineStep]
    public let createdAt: Date

    public init(
        schemaVersion: Int = LearnedRoutine.currentVersion,
        id: UUID = UUID(),
        name: String,
        bundleID: String,
        steps: [RoutineStep],
        createdAt: Date = Date()
    ) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard schemaVersion == Self.currentVersion else {
            throw RoutineError.unsupportedVersion
        }
        guard !trimmedName.isEmpty, trimmedName.count <= 120 else {
            throw RoutineError.invalidName
        }
        guard !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              bundleID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else {
            throw RoutineError.invalidBundleID
        }
        guard (1...Self.maximumSteps).contains(steps.count) else {
            throw RoutineError.invalidStepCount
        }
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = trimmedName
        self.bundleID = bundleID
        self.steps = steps
        self.createdAt = createdAt
    }

    /// Parameter slots the routine asks the user to fill at run time, in step
    /// order. Empty means the routine runs as recorded with nothing to prompt.
    public var requiredParameters: [(name: String, prompt: String)] {
        steps.compactMap { step in
            if case .typeText(.parameter(let name, let prompt)) = step.action { return (name, prompt) }
            return nil
        }
    }
}

public enum RoutineError: Error, Equatable {
    case unsupportedVersion
    case invalidName
    case invalidBundleID
    case invalidStepCount
    case emptyDemonstration
    case storageUnavailable
    case routineTooLarge
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

    public init(summary: String, target: RoutineTarget? = nil, action: RoutineAction) {
        self.summary = summary
        self.target = target
        self.action = action
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
        return try LearnedRoutine(name: name, bundleID: demonstration.bundleID, steps: steps)
    }

    private static func typeStep(text: String, target: RoutineTarget?) -> RoutineStep {
        let clipped = text.count > 24 ? String(text.prefix(24)) + "…" : text
        let whereabouts = target.map { " into \($0.label ?? $0.role)" } ?? ""
        return RoutineStep(summary: "Type \"\(clipped)\"\(whereabouts)", target: target, action: .typeText(.literal(text)))
    }
}

/// Local-first routine persistence: one JSON file per routine under
/// `Routines/` in app storage. Malformed or oversized files are skipped, never
/// repaired silently.
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
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  data.count <= LearnedRoutine.maximumEncodedBytes,
                  let routine = try? JSONDecoder().decode(LearnedRoutine.self, from: data),
                  routine.schemaVersion == LearnedRoutine.currentVersion else { return nil }
            return routine
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func routine(id: UUID) -> LearnedRoutine? {
        all().first { $0.id == id }
    }

    public func save(_ routine: LearnedRoutine) throws {
        guard let directory = routinesDirectory() else { throw RoutineError.storageUnavailable }
        let data = try JSONEncoder().encode(routine)
        guard data.count <= LearnedRoutine.maximumEncodedBytes else { throw RoutineError.routineTooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(routine.id.uuidString).json"), options: .atomic)
    }

    public func remove(id: UUID) throws {
        guard let directory = routinesDirectory() else { return }
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func routinesDirectory() -> URL? {
        storageDirectory?.appendingPathComponent("Routines", isDirectory: true)
    }
}
