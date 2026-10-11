import AppKit
import ApplicationServices
import PerryGuide
import ScreenCaptureKit

/// Talk's fast capture path. The bundled driver's `get_window_state` walks the
/// target's whole AX tree over IPC (~6–11s measured, over the 15s request
/// timeout under load). Everything Talk needs is cheaper locally: window
/// discovery via CGWindowList (~100ms), a pointer hit-test (~80–450ms), a
/// bounded index of the pointed element's neighbourhood (~25ms per batched
/// describe), and a ScreenCaptureKit frame (~300–600ms). A hung target app can
/// still stall AX IPC, so the whole path runs inside a timeout and the caller
/// falls back to the driver.
struct LocalTalkObserver: GuideObserving {
    let hint: CuaTargetHint
    let pointerAXPoint: CGPoint
    let targetStore: CuaGuideTargetStore

    enum Failure: Error, Sendable {
        case accessibilityNotTrusted
        case noTargetWindow
        case timeout
    }

    private static let overallTimeout: TimeInterval = 4
    private static let messagingTimeout: Float = 2
    private static let maxSiblingDescribes = 30
    private static let maxHitChildDescribes = 10
    private static let screenshotMaxPoints: CGFloat = 1600
    private static let jpegQuality: CGFloat = 0.75

    func observe() async throws -> GuideObservation {
        guard AXIsProcessTrusted() else { throw Failure.accessibilityNotTrusted }
        let hint = self.hint
        let anchor = pointerAXPoint
        let store = targetStore
        return try await Self.withTimeout(seconds: Self.overallTimeout) {
            guard let window = Self.resolveWindow(hint: hint, anchor: anchor) else {
                throw Failure.noTargetWindow
            }
            async let shot = Self.captureJPEG(windowID: window.windowID, bounds: window.bounds)
            let elements = Self.elementIndex(pid: window.pid, bounds: window.bounds, anchor: anchor)
            await store.set(window.hint)
            return GuideObservation(
                snapshot: AXSnapshot(appBundleID: window.bundleID, windowTitle: window.title, elements: elements),
                processID: window.pid,
                windowID: window.windowID,
                connectionGeneration: nil,
                windowBounds: AXElementFrame(
                    x: Double(window.bounds.minX), y: Double(window.bounds.minY),
                    width: Double(window.bounds.width), height: Double(window.bounds.height)
                ),
                screenshotData: await shot,
                screenshotMIMEType: "image/jpeg",
                observationID: "local-\(window.windowID)-\(Int(Date().timeIntervalSince1970 * 1000))"
            )
        }
    }

    struct ResolvedWindow: Sendable {
        let pid: pid_t
        let windowID: Int64
        let title: String
        let bounds: CGRect
        let bundleID: String

        var hint: CuaTargetHint {
            CuaTargetHint(bundleID: bundleID, processID: pid, windowID: windowID, windowTitle: title)
        }
    }

    /// The hint is fresh at keypress so it wins. When its window has vanished,
    /// the window under the pointer is the next-best statement of intent —
    /// Talk is point-driven.
    private static func resolveWindow(hint: CuaTargetHint, anchor: CGPoint) -> ResolvedWindow? {
        if let windowID = hint.windowID,
           let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]])?.first,
           (info[kCGWindowIsOnscreen as String] as? Bool) == true {
            return resolved(info)
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        func layer0Window(matching predicate: ([String: Any]) -> Bool) -> [String: Any]? {
            onScreen.first {
                ($0[kCGWindowLayer as String] as? Int) == 0
                    && ($0[kCGWindowOwnerPID as String] as? Int32) != ownPID
                    && predicate($0)
            }
        }
        if let info = layer0Window(matching: { info in
            guard let dict = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return false }
            return frame.contains(anchor)
        }) ?? hint.processID.flatMap({ pid in
            layer0Window { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
        }) ?? NSWorkspace.shared.frontmostApplication.flatMap({ app in
            app.processIdentifier == ownPID ? nil : layer0Window { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier }
        }) {
            return resolved(info)
        }
        return nil
    }

    private static func resolved(_ info: [String: Any]) -> ResolvedWindow? {
        guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
              let number = info[kCGWindowNumber as String] as? Int,
              let dict = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
        return ResolvedWindow(
            pid: pid,
            windowID: Int64(number),
            title: (info[kCGWindowName as String] as? String) ?? "",
            bounds: bounds,
            bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        )
    }

    /// The index is deliberately shallow: the pointed element, its parent, the
    /// parent's children (siblings), and the hit's own children. That covers
    /// "this" (the hit) and "that" (a sibling near another trace point) — the
    /// cases `DeixisResolver` needs — without the full-tree cost. Every
    /// describe is one batched AX round-trip.
    private static func elementIndex(pid: pid_t, bounds: CGRect, anchor: CGPoint) -> [AXElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)

        var hitRef: AXUIElement?
        _ = AXUIElementCopyElementAtPosition(app, Float(anchor.x), Float(anchor.y), &hitRef)
        let hit = hitRef ?? matchingAXWindow(app: app, bounds: bounds) ?? app

        var described: [AXElement] = []
        var seen: [AXUIElement] = []
        func include(_ element: AXUIElement) {
            guard !seen.contains(where: { CFEqual($0, element) }) else { return }
            seen.append(element)
            if let axElement = describe(element, index: described.count) {
                described.append(axElement)
            }
        }

        include(hit)
        let parent = axValue(hit, kAXParentAttribute)
        var neighbourhoodSource = parent ?? hit
        if let parent {
            include(parent)
            // When the hit is the window itself, the app's children are just
            // windows — the useful neighbourhood is inside the hit.
            if axString(parent, kAXRoleAttribute) == "AXApplication" {
                neighbourhoodSource = hit
            }
        }
        for sibling in axValues(neighbourhoodSource, kAXChildrenAttribute).prefix(maxSiblingDescribes) {
            include(sibling)
        }
        if neighbourhoodSource !== hit {
            for child in axValues(hit, kAXChildrenAttribute).prefix(maxHitChildDescribes) {
                include(child)
            }
        }
        return described
    }

    private static func describe(_ element: AXUIElement, index: Int) -> AXElement? {
        let names = [
            kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
            kAXDescriptionAttribute, kAXPositionAttribute, kAXSizeAttribute,
        ] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names, [], &values) == .success,
              let list = values as? [Any], list.count == 6,
              let rawRole = list[0] as? String,
              let position = axCGPoint(list[4]),
              let size = axCGSize(list[5]) else { return nil }
        let role = axGuideRole(rawRole)
        return AXElement(
            stableID: "local-\(index)",
            role: role,
            label: (list[2] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (list[3] as? String).flatMap { $0.isEmpty ? nil : $0 },
            frame: AXElementFrame(
                x: Double(position.x), y: Double(position.y),
                width: Double(size.width), height: Double(size.height)
            ),
            isActionable: axGuideRoleIsActionable(role),
            value: nil,
            rawRole: rawRole,
            subrole: list[1] as? String,
            sensitivity: rawRole == "AXSecureTextField" ? .secure : .unknown
        )
    }

    private static func matchingAXWindow(app: AXUIElement, bounds: CGRect) -> AXUIElement? {
        for window in axValues(app, kAXWindowsAttribute) {
            guard let position = axCGPoint(axRawValue(window, kAXPositionAttribute)),
                  let size = axCGSize(axRawValue(window, kAXSizeAttribute)),
                  abs(position.x - bounds.minX) < 4,
                  abs(position.y - bounds.minY) < 4,
                  abs(size.width - bounds.width) < 4,
                  abs(size.height - bounds.height) < 4 else { continue }
            return window
        }
        return nil
    }

    private static func axRawValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axValues(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func axCGPoint(_ value: Any?) -> CGPoint? {
        guard let value, CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func axCGSize(_ value: Any?) -> CGSize? {
        guard let value, CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    private static func captureJPEG(windowID: Int64, bounds: CGRect) async -> Data? {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == CGWindowID(windowID) }) else { return nil }
        let scale = min(2, screenshotMaxPoints / max(bounds.width, bounds.height))
        let configuration = SCStreamConfiguration()
        configuration.width = Int(bounds.width * scale)
        configuration.height = Int(bounds.height * scale)
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration
        ), let rep = NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg, properties: [.compressionFactor: jpegQuality]
        ) else { return nil }
        return rep
    }

    private static func withTimeout<T: Sendable>(seconds: TimeInterval, work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Failure.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

/// Shared with `CuaDriverClient`'s snapshot mapping — both readers must agree
/// on what counts as actionable so Guide validation behaves identically across
/// capture paths.
func axGuideRole(_ rawRole: String) -> AXElement.Role {
    switch rawRole {
    case "AXButton", "button": return .button
    case "AXTextField", "AXSecureTextField", "AXTextArea", "textField": return .textField
    case "AXSlider", "slider": return .slider
    case "AXCheckBox", "checkBox": return .checkBox
    case "AXMenu", "menu": return .menu
    case "AXMenuItem", "menuItem": return .menuItem
    case "AXTabGroup", "tabGroup": return .tabGroup
    case "AXStaticText", "staticText": return .staticText
    case "AXImage", "image": return .image
    default: return .other
    }
}

func axGuideRoleIsActionable(_ role: AXElement.Role) -> Bool {
    switch role {
    case .button, .textField, .slider, .checkBox, .menu, .menuItem:
        return true
    default:
        return false
    }
}
