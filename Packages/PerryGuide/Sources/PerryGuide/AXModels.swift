import Foundation
import PerryCore
import CoreGraphics

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

public enum AXSensitivity: String, Codable, Sendable, CaseIterable {
    case ordinary
    case secure
    case unknown
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
    public let value: String?
    public let frame: AXElementFrame
    public let isActionable: Bool
    public let rawRole: String?
    public let subrole: String?
    public let sensitivity: AXSensitivity

    public init(
        stableID: String,
        role: Role,
        label: String?,
        frame: AXElementFrame,
        isActionable: Bool,
        value: String? = nil,
        rawRole: String? = nil,
        subrole: String? = nil,
        sensitivity: AXSensitivity = .unknown
    ) {
        self.stableID = stableID
        self.role = role
        self.label = label
        self.value = sensitivity == .ordinary ? value : nil
        self.frame = frame
        self.isActionable = isActionable
        self.rawRole = rawRole
        self.subrole = subrole
        self.sensitivity = sensitivity
    }

    private enum CodingKeys: String, CodingKey {
        case stableID, role, label, value, frame, isActionable, rawRole, subrole, sensitivity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stableID = try container.decode(String.self, forKey: .stableID)
        role = try container.decode(Role.self, forKey: .role)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        frame = try container.decode(AXElementFrame.self, forKey: .frame)
        isActionable = try container.decode(Bool.self, forKey: .isActionable)
        rawRole = try container.decodeIfPresent(String.self, forKey: .rawRole)
        subrole = try container.decodeIfPresent(String.self, forKey: .subrole)
        sensitivity = (try? container.decode(AXSensitivity.self, forKey: .sensitivity)) ?? .unknown
        value = sensitivity == .ordinary ? try container.decodeIfPresent(String.self, forKey: .value) : nil
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
        elements.element(withStableID: id)
    }
}

public extension Array where Element == AXElement {
    func element(withStableID id: String) -> AXElement? {
        first { $0.stableID == id }
    }

    /// The same control in this later read. Element ids are per read
    /// (cua-driver tokens change on every observation), so identity comes
    /// from what the element is: its role and label, and among look-alikes
    /// the one nearest its old frame. `relabeled` also accepts a control of
    /// the same role at the same frame whose label changed in place.
    func counterpart(of element: AXElement, relabeled: Bool = false) -> AXElement? {
        let twins = filter { $0.role == element.role && $0.rawRole == element.rawRole && $0.label == element.label }
        if let nearest = twins.min(by: { element.frame.distance(to: $0.frame) < element.frame.distance(to: $1.frame) }) {
            return nearest
        }
        guard relabeled else { return nil }
        return first {
            $0.role == element.role && $0.rawRole == element.rawRole && element.frame.distance(to: $0.frame) < 4
        }
    }
}

extension AXElementFrame {
    func distance(to other: AXElementFrame) -> Double {
        hypot(x + width / 2 - other.x - other.width / 2, y + height / 2 - other.y - other.height / 2)
            + abs(width - other.width) + abs(height - other.height)
    }
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
        "\(element.stableID)|\(element.role.rawValue)|\(element.label ?? "")|\(element.value ?? "")"
    }
}

/// Accessibility reports geometry in global coordinates with a top-left
/// origin; AppKit screens use bottom-left. Convert once, here, everywhere.
public enum AXCoordinateConverter {
    public static func appKitRect(
        axX: Double,
        axY: Double,
        width: Double,
        height: Double,
        primaryScreenMaxY: Double
    ) -> CGRect {
        CGRect(
            x: axX,
            y: primaryScreenMaxY - axY - height,
            width: width,
            height: height
        )
    }

    public static func appKitPoint(
        axX: Double,
        axY: Double,
        primaryScreenMaxY: Double,
        elementHeight: Double
    ) -> CGPoint {
        CGPoint(x: axX, y: primaryScreenMaxY - axY - elementHeight / 2)
    }
}
