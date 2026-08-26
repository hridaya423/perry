import Foundation
import PerryCore

public struct AXElementFrame: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct AXElement: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable, CaseIterable {
        case button
        case textField
        case slider
        case checkBox
        case menu
        case menuItem
        case tabGroup
        case staticText
        case image
        case other
    }

    public var id: String { stableID }

    /// Stable across re-reads of the same window; synthesized from role and
    /// path so a Guide plan can re-find its target after the user acts.
    public let stableID: String
    public let role: Role
    public let label: String?
    public let frame: AXElementFrame
    public let isActionable: Bool

    public init(
        stableID: String,
        role: Role,
        label: String?,
        frame: AXElementFrame,
        isActionable: Bool
    ) {
        self.stableID = stableID
        self.role = role
        self.label = label
        self.frame = frame
        self.isActionable = isActionable
    }

    public var center: CGPointShim {
        CGPointShim(
            x: frame.x + frame.width / 2,
            y: frame.y + frame.height / 2
        )
    }
}

/// Coordinate value that survives Codable round-trips without importing
/// CoreGraphics into model payloads.
public struct CGPointShim: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct AXSnapshot: Codable, Equatable, Sendable {
    public let appBundleID: String
    public let windowTitle: String
    public let capturedAt: Date
    public let elements: [AXElement]

    public init(appBundleID: String, windowTitle: String, elements: [AXElement], capturedAt: Date = Date()) {
        self.appBundleID = appBundleID
        self.windowTitle = windowTitle
        self.elements = elements
        self.capturedAt = capturedAt
    }

    public func actionableElements() -> [AXElement] {
        elements.filter(\.isActionable)
    }

    public func element(withStableID id: String) -> AXElement? {
        elements.first { $0.stableID == id }
    }
}

/// Reads the accessibility tree of the frontmost application. The protocol
/// exists so Guide logic is testable without a live AX tree; production
/// binds to ApplicationServices. Vision fills canvas-app gaps per PRD §4.
public protocol AXTreeReading: Sendable {
    func readFrontmost() async throws -> AXSnapshot
}

/// Screen-change detection for step-follows-you: after pointing at control N,
/// Perry waits while you act, then confirms the screen changed before moving on.
public struct ScreenChangeDetector: Sendable {
    private let minimumChangedElements: Int

    public init(minimumChangedElements: Int = 1) {
        self.minimumChangedElements = minimumChangedElements
    }

    /// Compares two snapshots by stable IDs plus labels/roles; returns true
    /// when at least `minimumChangedElements` differ.
    public func didChange(from before: AXSnapshot, to after: AXSnapshot) -> Bool {
        let beforeKeys = Set(before.elements.map(Self.fingerprint))
        let afterKeys = Set(after.elements.map(Self.fingerprint))
        let removed = beforeKeys.subtracting(afterKeys).count
        let added = afterKeys.subtracting(beforeKeys).count
        return (removed + added) >= minimumChangedElements
    }

    /// Title change alone counts (e.g. navigating System Settings panes).
    public func didChange(from before: AXSnapshot, titleAfter: String) -> Bool {
        before.windowTitle != titleAfter
    }

    static func fingerprint(_ element: AXElement) -> String {
        "\(element.stableID)|\(element.role.rawValue)|\(element.label ?? "")"
    }
}
