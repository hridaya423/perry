import Foundation

public struct RoutineSchedule: Codable, Sendable, Equatable {
    public enum Kind: Codable, Sendable, Equatable {
        case daily(hour: Int, minute: Int)
        case interval(TimeInterval)
        case once(Date)
    }

    public var kind: Kind
    public var consecutiveFailures: Int = 0
    public var paused = false
    public var lastRun: Date?
    public var missedRunPending = false

    public init(kind: Kind) { self.kind = kind }
}

public struct Perry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var job: String
    public var threadID: String
    public var folderPath: String?
    public var schedule: RoutineSchedule?

    public init(id: UUID = UUID(), name: String, job: String,
                threadID: String, folderPath: String? = nil, schedule: RoutineSchedule? = nil) {
        self.id = id
        self.name = name
        self.job = job
        self.threadID = threadID
        self.folderPath = folderPath
        self.schedule = schedule
    }
}

/// Two-word names that say the job ("Inbox Keeper"). Deterministic per job.
public enum PerryNameGenerator {
    private static let keywordNames: [(keys: [String], name: String)] = [
        (["clean", "desktop", "tidy"], "Tidy Desk"),
        (["mail", "inbox", "email"], "Inbox Keeper"),
        (["watch", "monitor", "track"], "Quiet Watcher"),
        (["research", "news", "read"], "Morning Scout"),
        (["file", "organize", "sort"], "Shelf Sorter"),
        (["calendar", "schedule", "meeting"], "Day Planner"),
        (["backup", "sync"], "Copy Keeper"),
    ]

    private static let fallbackAdjectives = ["Bright", "Steady", "Quick", "Kind", "Calm"]
    private static let fallbackNouns = ["Helper", "Scout", "Keeper", "Runner", "Spotter"]

    public static func twoWordName(for job: String) -> String {
        let words = Set(job.lowercased().split { !$0.isLetter }.map(String.init))
        for entry in keywordNames where entry.keys.contains(where: words.contains) {
            return entry.name
        }
        var hasher = Hasher()
        hasher.combine(job)
        let h = abs(hasher.finalize())
        return "\(fallbackAdjectives[h % fallbackAdjectives.count]) \(fallbackNouns[(h / 97) % fallbackNouns.count])"
    }
}

/// One JSON file per Perry under `directory`; atomic writes.
public actor PerryStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func list() -> [Perry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Perry.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    public func create(
        job: String, name: String? = nil, folderPath: String? = nil, schedule: RoutineSchedule? = nil
    ) throws -> Perry {
        let perry = Perry(
            name: name ?? PerryNameGenerator.twoWordName(for: job),
            job: job,
            threadID: UUID().uuidString,
            folderPath: folderPath,
            schedule: schedule
        )
        try write(perry)
        return perry
    }

    public func update(_ perry: Perry) throws {
        try write(perry)
    }

    public func remove(id: UUID) throws {
        try FileManager.default.removeItem(at: fileURL(for: id))
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func write(_ perry: Perry) throws {
        let data = try JSONEncoder.pretty.encode(perry)
        let tmp = directory.appendingPathComponent(".\(perry.id.uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(fileURL(for: perry.id), withItemAt: tmp)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

/// Pure scheduling decisions; the app-side scheduler (NSBackgroundActivityScheduler)
/// calls these and owns the actual timer.
public enum RoutineDecisions {
    public static let maxConsecutiveFailures = 3

    /// Next scheduled instant after `now`, or nil when the routine is done.
    public static func nextFire(_ s: RoutineSchedule, now: Date, cal: Calendar = .current) -> Date? {
        guard !s.paused else { return nil }
        switch s.kind {
        case .daily(let hour, let minute):
            var components = cal.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            components.second = 0
            guard let todaySlot = cal.date(from: components) else { return nil }
            return todaySlot > now ? todaySlot : cal.date(byAdding: .day, value: 1, to: todaySlot)
        case .interval(let seconds):
            return (s.lastRun ?? now).addingTimeInterval(seconds)
        case .once(let date):
            return s.lastRun == nil ? date : nil
        }
    }

    /// Whether the routine should run right now. Missed daily/interval slots
    /// run once on catch-up (missedRunPending or an overdue slot).
    public static func shouldRun(
        _ s: RoutineSchedule, now: Date, isAwake: Bool, hasNetwork: Bool, cal: Calendar = .current
    ) -> Bool {
        guard isAwake, hasNetwork, !s.paused else { return false }
        return isDue(s, now: now, cal: cal)
    }

    /// A due routine that could not run (asleep/offline) gets one catch-up flag.
    public static func recordMissed(_ s: RoutineSchedule, now: Date, cal: Calendar = .current) -> RoutineSchedule {
        var copy = s
        if isDue(s, now: now, cal: cal) { copy.missedRunPending = true }
        return copy
    }

    public static func record(_ s: RoutineSchedule, succeeded: Bool, ranAt: Date) -> RoutineSchedule {
        var copy = s
        copy.lastRun = ranAt
        copy.missedRunPending = false
        if succeeded {
            copy.consecutiveFailures = 0
        } else {
            copy.consecutiveFailures += 1
            if copy.consecutiveFailures >= maxConsecutiveFailures { copy.paused = true }
        }
        return copy
    }

    private static func isDue(_ s: RoutineSchedule, now: Date, cal: Calendar) -> Bool {
        guard !s.paused else { return false }
        if s.missedRunPending { return true }
        switch s.kind {
        case .daily(let hour, let minute):
            var components = cal.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            components.second = 0
            guard let todaySlot = cal.date(from: components) else { return false }
            return now >= todaySlot && (s.lastRun ?? .distantPast) < todaySlot
        case .interval(let seconds):
            return now >= (s.lastRun ?? .distantPast).addingTimeInterval(seconds)
        case .once(let date):
            return s.lastRun == nil && now >= date
        }
    }
}
