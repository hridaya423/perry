import Foundation
import ApplicationServices
import AppKit
import PerryCore

/// Live accessibility-tree reader for the frontmost application window.
/// Requires Accessibility permission (AXIsProcessTrusted); returns a
/// descriptive error when trust is missing so the UI can route to onboarding.
public struct LiveAXTreeReader: AXTreeReading {
    public init() {}

    public enum ReaderError: Error, CustomStringConvertible {
        case notTrusted
        case noFrontmostApp
        case noWindow

        public var description: String {
            switch self {
            case .notTrusted: return "accessibility permission not granted"
            case .noFrontmostApp: return "no frontmost application"
            case .noWindow: return "frontmost app has no readable window"
            }
        }
    }

    public func readFrontmost() async throws -> AXSnapshot {
        guard AXIsProcessTrusted() else { throw ReaderError.notTrusted }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw ReaderError.noFrontmostApp
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let window = try Self.focusedWindow(of: axApp)
        let title = Self.stringAttribute(kAXTitleAttribute, of: window) ?? ""

        var elements: [AXElement] = []
        let collector = ElementCollector(limit: 300)
        Self.walk(element: window, path: "w", depth: 0, maxDepth: 12, collector: collector) { id, role, label, frame, actionable in
            elements.append(AXElement(stableID: id, role: role, label: label, frame: frame, isActionable: actionable))
        }

        return AXSnapshot(
            appBundleID: app.bundleIdentifier ?? "unknown",
            windowTitle: title,
            elements: elements
        )
    }

    private static func focusedWindow(of app: AXUIElement) throws -> AXUIElement {
        var value: CFTypeRef?
        var result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        if result == .cannotComplete {
            Thread.sleep(forTimeInterval: 0.05)
            result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        }
        guard result == .success, let window = value else {
            throw ReaderError.noWindow
        }
        return window as! AXUIElement
    }

    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func walk(
        element: AXUIElement,
        path: String,
        depth: Int,
        maxDepth: Int,
        collector: ElementCollector,
        collect: (_ stableID: String, _ role: AXElement.Role, _ label: String?, _ frame: AXElementFrame, _ actionable: Bool) -> Void
    ) {
        guard depth <= maxDepth, !collector.isFull else { return }

        let rawRole = stringAttribute(kAXRoleAttribute, of: element) ?? ""
        let role = mapRole(rawRole)
        let label = stringAttribute(kAXTitleAttribute, of: element)
            ?? stringAttribute(kAXValueAttribute, of: element)
        let actionable = Self.actionableRoles.contains(role)

        var bounds = CGRect.zero
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref) == .success, let position = ref {
            var point = CGPoint.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &point)
            bounds.origin = point
        }
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref) == .success, let size = ref {
            var cgSize = CGSize.zero
            AXValueGetValue(size as! AXValue, .cgSize, &cgSize)
            bounds.size = cgSize
        }

        collector.count += 1
        collect(
            path,
            role,
            (label?.isEmpty == false) ? label : nil,
            AXElementFrame(x: Double(bounds.minX), y: Double(bounds.minY), width: Double(bounds.width), height: Double(bounds.height)),
            actionable
        )

        guard depth < maxDepth else { return }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }

        let childPathBase = rawRole.isEmpty ? "e" : String(rawRole.dropFirst(2).lowercased())
        for (index, child) in children.enumerated() where index < 40 {
            walk(
                element: child,
                path: "\(path)/\(childPathBase):\(index)",
                depth: depth + 1,
                maxDepth: maxDepth,
                collector: collector,
                collect: collect
            )
        }
    }

    static let actionableRoles: Set<AXElement.Role> = [.button, .textField, .slider, .checkBox, .menu, .menuItem]

    static func mapRole(_ raw: String) -> AXElement.Role {
        switch raw {
        case "AXButton": return .button
        case "AXTextField": return .textField
        case "AXSlider": return .slider
        case "AXCheckBox": return .checkBox
        case "AXMenu": return .menu
        case "AXMenuItem": return .menuItem
        case "AXTabGroup": return .tabGroup
        case "AXStaticText": return .staticText
        case "AXImage": return .image
        default: return .other
        }
    }
}

final class ElementCollector {
    let limit: Int
    var count = 0

    init(limit: Int) {
        self.limit = limit
    }

    var isFull: Bool { count >= limit }
}
