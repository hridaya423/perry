# Phase 9a: Perrys, routines, suggestions, memory — pure cores

Megaplan §4.6 / §7 Phase 9. The headless-testable half: store, scheduling
decisions, suggestion ranking/quiet rules, memory files, name generation.
AppKit wiring (NSBackgroundActivityScheduler, INFocusStatusCenter, Home UI,
wake word) is 9b.

New files in `Packages/PerryBrain/Sources/PerryBrain/Perrys/`; tests beside the
existing suites. Reuse ThreadStore's atomic-write style for persistence.

## PerryStore.swift

```swift
public struct RoutineSchedule: Codable, Sendable, Equatable {
    public enum Kind: Codable, Sendable, Equatable {
        case daily(hour: Int, minute: Int)          // local time
        case interval(TimeInterval)
        case once(Date)
    }
    public var kind: Kind
    public var consecutiveFailures: Int = 0
    public var paused: Bool = false                 // set after 3 failures
    public var lastRun: Date? = nil
    public var missedRunPending: Bool = false       // catch up once
}
public struct Perry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID; public var name: String; public var job: String
    public var threadID: String
    public var folderPath: String?                  // working directory
    public var schedule: RoutineSchedule?
}
public actor PerryStore {
    public init(directory: URL)
    public func list() -> [Perry]
    @discardableResult public func create(job: String, name: String? = nil,
        folderPath: String? = nil, schedule: RoutineSchedule? = nil) throws -> Perry
    public func update(_ perry: Perry) throws
    public func remove(id: UUID) throws
}
```
- One JSON per Perry (`<id>.json`, atomic write, sorted list). Max 5 creates per
  call when voice-created — enforced by caller, not the store.
- `PerryNameGenerator.twoWordName(for job: String) -> String`: keyword →
  (adjective, noun) map ("clean|desktop|tidy"→"Tidy Desk", "mail|inbox"→"Inbox
  Keeper", "watch|monitor|track"→"Quiet Watcher", "research|news"→"Morning Scout",
  "file|organize|sort"→"Shelf Sorter", default → hash-picked pair like
  "Bright Helper"). Deterministic per job string.

## RoutineDecisions (in PerryStore.swift)

```swift
public enum RoutineDecisions {
    /// catch-up-once: a missed daily/interval slot runs once when awake+online
    public static func nextFire(_ s: RoutineSchedule, now: Date, cal: Calendar) -> Date?
    public static func shouldRun(_ s: RoutineSchedule, now: Date,
                                 isAwake: Bool, hasNetwork: Bool) -> Bool
    /// success resets consecutiveFailures; 3rd failure sets paused
    public static func record(_ s: RoutineSchedule, succeeded: Bool, ranAt: Date) -> RoutineSchedule
}
```
- `paused` or `.once` already-run → never fires.
- `daily`: fires when now >= today's (or next) slot and lastRun < slot; if the
  slot was missed while asleep/offline, `shouldRun` returns true once and
  caller sets `missedRunPending=false` after running.
- `interval`: fires when now >= lastRun + interval.
- `shouldRun` requires isAwake && hasNetwork; when blocked it marks
  `missedRunPending` via `recordMissed`? Keep it pure: `shouldRun` only reads;
  `recordMissed(_ s, now) -> RoutineSchedule` sets the flag.

## SuggestionEngine.swift

```swift
public struct SuggestionCard: Sendable, Equatable, Identifiable {
    public var id: UUID; public var title: String; public var body: String
    public var sourcePerryID: UUID?; public var score: Double
}
public enum SuggestionRules {
    public static func quietNow(isOnCall: Bool, isScreenSharing: Bool,
                                focusActive: Bool) -> Bool
    /// Newest/best first; drops cards below minScore; max 3.
    public static func rank(_ cards: [SuggestionCard], minScore: Double = 0.3,
                            limit: Int = 3) -> [SuggestionCard]
    /// Backoff multiplier: each consecutive ignored day raises the bar.
    public static func effectiveMinScore(base: Double, ignoredDays: Int) -> Double
}
```
- quietNow = isOnCall || isScreenSharing || focusActive.
- effectiveMinScore = min(base + 0.15*ignoredDays, 0.9).

## MemoryFiles.swift

```swift
public struct MemoryFiles: Sendable {
    public init(directory: URL)
    public func profile() -> String        // PROFILE.md, "" when absent
    public func context() -> String        // CONTEXT.md
    public func writeProfile(_ text: String) throws
    public func writeContext(_ text: String) throws
    /// One block for the system prompt; empty sections omitted.
    public func promptBlock() -> String
}
```
Writes are atomic (write to .tmp then replaceFile/rename).

## Tests

PerryStoreTests: create/list/update/remove round-trip; name generator
deterministic + keyword cases; corrupt JSON file skipped not fatal.
RoutineDecisionsTests: daily fires at slot, missed slot while asleep → catches
up once, 3 failures → paused, success resets, once-only, interval drift.
SuggestionRulesTests: quiet flags, rank trims to 3 sorted, backoff raises bar.
MemoryFilesTests: round-trip, promptBlock omits empty, atomic write leaves no
.tmp.

## Verify

`swift test --package-path Packages/PerryBrain` green; app build green.
