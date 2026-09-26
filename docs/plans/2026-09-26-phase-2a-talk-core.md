# Phase 2a: Talk core (pure, headless-testable)

Scope: the pure logic of the Talk loop that lives in `Packages/PerryBrain` and
needs no TCC, audio device, or screen. App wiring (TalkSession, speech I/O,
ModifierHoldMonitor, barge-in) is Phase 2b.

All new code goes in `Packages/PerryBrain/Sources/PerryBrain/Talk/`, tests in
`Packages/PerryBrain/Tests/PerryBrainTests/`. No new dependencies. Use
`CoreGraphics` geometry types (`CGPoint`, `CGRect`, `CGVector`).

## 1. DeixisResolver (`Talk/DeixisResolver.swift`)

```swift
public struct SpokenWord: Sendable, Equatable {
    public var text: String; public var start: TimeInterval; public var duration: TimeInterval
}
public struct TraceSample: Sendable, Equatable {
    public var t: TimeInterval; public var point: CGPoint; public var windowID: Int?
    public var overPerry: Bool          // pointer was over a Perry overlay window
}
public struct ObservedElement: Sendable, Equatable {
    public var id: String; public var role: String; public var label: String
    public var frame: CGRect; public var windowID: Int
}
public struct DeixisBinding: Sendable, Equatable {
    public var word: String; public var time: TimeInterval; public var point: CGPoint
    public var windowID: Int?; public var element: ObservedElement?; public var isWindowLevel: Bool
}
public enum DeixisResolver {
    public static let pointerLead: TimeInterval = 0.25
    public static let stillThreshold: CGFloat = 4
    public static func isDemonstrative(_ word: String) -> Bool
    /// windowOffsets: per-window displacement since the observation was taken
    /// (current origin - observed origin). Trace points are mapped back by subtracting it.
    public static func resolve(words: [SpokenWord], trace: [TraceSample],
                               elements: [ObservedElement],
                               windowOffsets: [Int: CGVector] = [:]) -> [DeixisBinding]
    public static func contextLines(_ bindings: [DeixisBinding]) -> [String]
}
```

Rules:
- Normalize a word: lowercase, trim punctuation/whitespace. Lexicon (Set):
  en `this that here there these those it`; es `esto este esta eso ese esa aquí ahí allí`;
  fr `ceci cela ça ici là ce cette`; de `das dies dieser diese dieses hier dort da`;
  hi `yah ye yahan vahan wo यह ये यहाँ यहां वहाँ वहां वो`; ja `これ それ あれ ここ そこ あそこ`;
  zh `这 这个 那 那个 这里 那里`. For ja/zh, STT words may carry trailing particles
  (`これは`, `这个按钮`): a word containing a CJK scalar matches if it has a lexicon CJK
  entry as a prefix.
- Ignore trace samples with `overPerry == true` entirely.
- If the eligible trace is empty, or its max distance from the first eligible point is
  `< stillThreshold`, every binding is window-level: `element = nil`,
  `isWindowLevel = true`, `point` = first eligible point (or `.zero`), `windowID` from it.
- Otherwise for each demonstrative word pick the eligible sample nearest to `word.start`
  within `[start - pointerLead, start + duration]`; if none, the latest eligible sample
  before `start - pointerLead`; if none, the earliest eligible sample.
- Hit-test: `p = sample.point - windowOffsets[windowID]` (when present); among elements
  whose `frame.contains(p)` and (sample.windowID == nil or element.windowID == sample.windowID),
  choose the smallest area. `point` in the binding is the sample's *current* point.
- `contextLines` format, 1-based:
  `(1) "this" → AXButton "Export" in window 42` /
  `(2) "here" → point (512, 300) in window 42` (no element) /
  `(1) "this" → the whole window 42` (window-level; `the whole screen` when windowID nil).
  Points rounded to Int.

Tests (`DeixisResolverTests.swift`), each its own test:
single "this"; "move this … here" → two bindings on two different elements; no pointer
movement → window-level; overPerry samples ignored (element behind the overlay chosen
from the non-overlay samples); stale element re-resolved via windowOffsets; one test per
language en/es/fr/de/hi/ja/zh (ja `これは`, zh `这个按钮` prefix cases); pointer arrives 200 ms
before the word → still binds; pointer 400 ms before only (outside lead) → falls back to
latest-before rule; smallest nested element wins; contextLines exact strings.

## 2. InlineMarkupParser (`Talk/InlineMarkupParser.swift`)

For providers without tools. Tag grammar: `⟦verb target? "label"?⟧`, verbs
`point ring arrow underline caption clear`. target is an element id token `[A-Za-z0-9_.-]+`.

```swift
public struct DrawCommand: Sendable, Equatable {
    public enum Verb: String, Sendable, CaseIterable { case point, ring, arrow, underline, caption, clear }
    public var verb: Verb; public var elementID: String?; public var label: String?
}
public struct InlineMarkupParser: Sendable {
    public init(validElementIDs: Set<String>)
    public mutating func feed(_ chunk: String) -> (text: String, commands: [DrawCommand])
    public mutating func finish() -> (text: String, commands: [DrawCommand])
}
```

Rules: text outside tags passes through immediately. A tag may be split across chunks;
buffer from `⟦` until `⟧`. On a complete tag: the label (if any) is emitted as text in
place of the tag; a command is emitted only if verb is known and (verb == .clear, or
elementID ∈ validElementIDs). Unknown verb / invalid id → label still emitted as text, no
command (dropped silently). `clear` takes no target. An unterminated `⟦` buffer longer than
200 characters, or still open at `finish()`, is flushed verbatim as text.

Tests (`InlineMarkupParserTests.swift`): passthrough; one valid ring → text "Click Export
to save" + command; tag split across 3 chunks, including a split inside the label;
invalid id → text kept, no command; unknown verb; `⟦clear⟧`; two tags in one chunk;
unterminated flush at 200 chars and at finish.

## 3. Tool surfaces (`Talk/ToolSurface.swift`) — Ask-never-acts, structurally

```swift
public enum ToolSurface: String, Sendable, Hashable { case talk, guide, agent }
public enum ToolGate {
    public static let observeTools: Set<String> = ["screen.observe","screen.desktop","screen.zoom","browser.read","document.read","clipboard.read"]
    public static let drawTools: Set<String> = ["point","ring","arrow","underline","caption","path","clear"]
    public static func allows(_ name: String, on surface: ToolSurface) -> Bool
    // talk & guide: observe ∪ draw only. agent: everything.
    public static func filter(_ specs: [ToolSpec], for surface: ToolSurface) -> [ToolSpec]
    /// Rejected calls return a ToolRejection and are logged via os.Logger
    /// (subsystem "ai.perry.brain", category "tool-gate") with the tool name only.
    public static func check(_ call: ToolCall, on surface: ToolSurface) -> ToolRejection?
}
public struct ToolRejection: Error, Sendable, Equatable { public var callID: String; public var toolName: String; public var surface: ToolSurface }
```

Tests (`ToolGateTests.swift`): malicious `ui.click` on `.talk` → rejection with matching
fields; `ring` on `.talk` allowed; `ui.click` on `.agent` allowed; `filter` strips act tools
for `.talk`; `files.delete` on `.guide` rejected.

## Verification

`swift test --package-path Packages/PerryBrain` green (existing 71 + new).
`git diff --check` clean.
