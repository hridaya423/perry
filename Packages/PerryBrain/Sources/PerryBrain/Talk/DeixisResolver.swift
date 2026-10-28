import CoreGraphics
import Foundation

public struct SpokenWord: Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    public var duration: TimeInterval

    public init(text: String, start: TimeInterval, duration: TimeInterval) {
        self.text = text
        self.start = start
        self.duration = duration
    }
}

public struct TraceSample: Sendable, Equatable {
    public var t: TimeInterval
    public var point: CGPoint
    public var windowID: Int?
    public var overPerry: Bool

    public init(t: TimeInterval, point: CGPoint, windowID: Int? = nil, overPerry: Bool = false) {
        self.t = t
        self.point = point
        self.windowID = windowID
        self.overPerry = overPerry
    }
}

public struct ObservedElement: Sendable, Equatable {
    public var id: String
    public var role: String
    public var label: String
    public var frame: CGRect
    public var windowID: Int
    public var value: String?
    public var pressable: Bool

    public init(id: String, role: String, label: String, frame: CGRect, windowID: Int, value: String? = nil, pressable: Bool = true) {
        self.id = id
        self.role = role
        self.label = label
        self.frame = frame
        self.windowID = windowID
        self.value = value
        self.pressable = pressable
    }
}

public struct DeixisBinding: Sendable, Equatable {
    public var word: String
    public var time: TimeInterval
    public var point: CGPoint
    public var windowID: Int?
    public var element: ObservedElement?
    public var isWindowLevel: Bool
}

public enum DeixisResolver {
    public static let pointerLead: TimeInterval = 0.25
    public static let stillThreshold: CGFloat = 4

    private static let lexicon: Set<String> = [
        "this", "that", "here", "there", "these", "those", "it",
        "esto", "este", "esta", "eso", "ese", "esa", "aquí", "ahí", "allí",
        "ceci", "cela", "ça", "ici", "là", "ce", "cette",
        "das", "dies", "dieser", "diese", "dieses", "hier", "dort", "da",
        "yah", "ye", "yahan", "vahan", "wo",
        "यह", "ये", "यहाँ", "यहां", "वहाँ", "वहां", "वो",
        "これ", "それ", "あれ", "ここ", "そこ", "あそこ",
        "这", "这个", "那", "那个", "这里", "那里",
    ]

    private static var cjkEntries: [String] {
        lexicon.filter { $0.unicodeScalars.contains(where: isCJK) }
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF: return true
        default: return false
        }
    }

    private static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    public static func isDemonstrative(_ word: String) -> Bool {
        let normalized = normalize(word)
        if lexicon.contains(normalized) { return true }
        guard normalized.unicodeScalars.contains(where: isCJK) else { return false }
        return cjkEntries.contains { normalized.hasPrefix($0) }
    }

    public static func resolve(
        words: [SpokenWord],
        trace: [TraceSample],
        elements: [ObservedElement],
        windowOffsets: [Int: CGVector] = [:]
    ) -> [DeixisBinding] {
        let eligible = trace.filter { !$0.overPerry }
        let demonstratives = words.filter { isDemonstrative($0.text) }
        let first = eligible.first
        let maxDistance = eligible.reduce(0) { max($0, hypot($1.point.x - (first?.point.x ?? 0), $1.point.y - (first?.point.y ?? 0))) }
        let windowLevel = eligible.isEmpty || maxDistance < stillThreshold

        return demonstratives.map { word in
            if windowLevel {
                // A held-still pointer is still pointing: when it rests on an
                // element, "this" means that element; only empty space falls
                // back to the window.
                let element = first.flatMap {
                    hitTest($0, elements: elements, windowOffsets: windowOffsets)
                }
                return DeixisBinding(
                    word: word.text,
                    time: word.start,
                    point: first?.point ?? .zero,
                    windowID: first?.windowID,
                    element: element,
                    isWindowLevel: element == nil
                )
            }
            let sample = nearestSample(to: word, in: eligible)
            let element = sample.flatMap { hitTest($0, elements: elements, windowOffsets: windowOffsets) }
            return DeixisBinding(
                word: word.text,
                time: word.start,
                point: sample?.point ?? .zero,
                windowID: sample?.windowID,
                element: element,
                isWindowLevel: false
            )
        }
    }

    private static func nearestSample(to word: SpokenWord, in eligible: [TraceSample]) -> TraceSample? {
        let lower = word.start - pointerLead
        let upper = word.start + word.duration
        let inWindow = eligible
            .filter { $0.t >= lower && $0.t <= upper }
            .min { abs($0.t - word.start) < abs($1.t - word.start) }
        if let inWindow { return inWindow }
        if let before = eligible.last(where: { $0.t < lower }) { return before }
        return eligible.first
    }

    private static func hitTest(
        _ sample: TraceSample,
        elements: [ObservedElement],
        windowOffsets: [Int: CGVector]
    ) -> ObservedElement? {
        var p = sample.point
        if let windowID = sample.windowID, let offset = windowOffsets[windowID] {
            p = CGPoint(x: p.x - offset.dx, y: p.y - offset.dy)
        }
        return elements
            .filter { $0.frame.contains(p) && (sample.windowID == nil || $0.windowID == sample.windowID) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    public static func contextLines(_ bindings: [DeixisBinding]) -> [String] {
        bindings.enumerated().map { index, binding in
            let n = index + 1
            if let element = binding.element {
                return "(\(n)) \"\(binding.word)\" → \(element.role) \"\(element.label)\" in window \(element.windowID)"
            }
            if binding.isWindowLevel {
                if let windowID = binding.windowID {
                    return "(\(n)) \"\(binding.word)\" → the whole window \(windowID)"
                }
                return "(\(n)) \"\(binding.word)\" → the whole screen"
            }
            var line = "(\(n)) \"\(binding.word)\" → point (\(Int(binding.point.x)), \(Int(binding.point.y)))"
            if let windowID = binding.windowID {
                line += " in window \(windowID)"
            }
            return line
        }
    }
}
