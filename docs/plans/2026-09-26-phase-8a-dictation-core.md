# Phase 8a: Dictation pure cores

Megaplan §4.5/§8. What already exists: `VoiceTextPolicy` (terminal newline
collapsing, dictionary substitution, `insertionText` prefix strip),
`VoiceDictionaryStore` (persistent entries), Cua `insertText` (AX path),
`DictationController` (recognition gate, device/route, language detect).

New pure pieces in `Packages/PerryCore/Sources/PerryCore/DictationCleanup.swift`
(next to VoiceConfiguration), tests in `PerryCoreTests`.

## DictationCleanupGuard

Cleanup runs through the fast-tier model with a "never add words" prompt; the
guard is the enforcement.

```swift
public enum DictationCleanupGuard {
    /// Reject when the cleanup drifts: word-level Levenshtein over
    /// punctuation-stripped lowercase tokens > max(2, ceil(20% of raw words)),
    /// or the cleaned text adds "—"/"…" that the raw text didn't contain.
    public static func isAcceptable(raw: String, cleaned: String) -> Bool
    public static func editDistance(_ a: [String], _ b: [String]) -> Int
}
```

## PersonalDictionaryLearner

"Edit within 20 s to learn a word": compare what dictation inserted with what
the field holds a moment later. Equal token counts → positional 1:1 pairs
learned (`inserted → observed`, preserving observed casing). Unequal counts or
an observation after the window → no learning (don't guess).

```swift
public enum PersonalDictionaryLearner {
    public static let learnWindow: TimeInterval = 20
    public static func learn(inserted: String, observed: String,
                             insertedAt: Date, observedAt: Date) -> [String: String]
}
```

## Tests (`DictationCleanupTests.swift`)

- identical → acceptable; punctuation-only changes acceptable; filler removal
  within budget acceptable; invented words / big rewrites rejected; em-dash and
  ellipsis added → rejected; long text budget scales with length.
- learner: same-length single substitution learned; two substitutions learned;
  within-window guard (21 s → none); word insertions (unequal counts) → none;
  casing preserved.

## Verify

`swift test --package-path Packages/PerryCore` green.
