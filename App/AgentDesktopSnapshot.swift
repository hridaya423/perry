import AppKit
import Foundation
import ImageIO
import PerryBrain
import PerryGuide

struct AgentDesktopNode: Sendable, Equatable {
    let ref: String?
    let role: String
    let name: String?
    let value: String?
    let description: String?
    let states: [String]
    let frame: AXElementFrame?
    let depth: Int

    var isSecure: Bool { states.contains("secure") }

    var label: String? {
        AgentDesktopSnapshot.nonEmpty(name) ?? AgentDesktopSnapshot.nonEmpty(description)
    }

    var rawRole: String {
        if role == "textfield" { return isSecure ? "AXSecureTextField" : "AXTextField" }
        return AgentDesktopSnapshot.axRoles[role] ?? "AX\(role.prefix(1).uppercased())\(role.dropFirst())"
    }
}

struct AgentDesktopElement: Sendable, Equatable {
    let role: String
    let label: String?
    let center: ComputerCoordinates?
    var isSecure = false
}

struct AgentDesktopSnapshot: Sendable {
    let snapshotID: String
    let nodes: [AgentDesktopNode]
    let complete: Bool

    init?(_ data: JSONValue) {
        guard let snapshotID = data["snapshot_id"]?.stringValue, let tree = data["tree"] else { return nil }
        self.snapshotID = snapshotID
        complete = data["complete"]?.boolValue ?? true
        var nodes: [AgentDesktopNode] = []
        Self.flatten(tree, depth: 0, into: &nodes)
        self.nodes = nodes
    }

    var windowFrame: AXElementFrame? {
        nodes.first?.frame
    }

    var actionable: [AgentDesktopNode] {
        nodes.filter { $0.ref != nil }
    }

    var details: [String: ScreenElementDetail] {
        actionable.reduce(into: [:]) { details, node in
            guard let ref = node.ref else { return }
            details[ref] = ScreenElementDetail(value: node.isSecure ? nil : Self.nonEmpty(node.value))
        }
    }

    var actionTokens: String? {
        let lines = nodes.compactMap { node -> String? in
            guard let label = node.label ?? (node.ref != nil && !node.isSecure ? Self.nonEmpty(node.value) : nil) else { return nil }
            let indent = String(repeating: "  ", count: min(node.depth, 12))
            let token = node.ref.map { "[\($0)] " } ?? ""
            return "\(indent)\(token)\(node.role) \(label)"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    func guideSnapshot(target: ScreenWindowTarget) -> AXSnapshot {
        let elements = actionable.compactMap { node -> AXElement? in
            guard let ref = node.ref, let frame = node.frame else { return nil }
            let rawRole = node.rawRole
            let role = axGuideRole(rawRole)
            return AXElement(
                stableID: ref,
                role: role,
                label: node.label,
                frame: frame,
                isActionable: axGuideRoleIsActionable(role),
                value: nil,
                rawRole: rawRole,
                subrole: nil,
                sensitivity: node.isSecure ? .secure : .unknown
            )
        }
        return AXSnapshot(appBundleID: target.bundleID, windowTitle: target.title, elements: elements)
    }

    func elements(in target: ScreenWindowTarget, scale: Double) -> [String: AgentDesktopElement] {
        actionable.reduce(into: [:]) { elements, node in
            guard let ref = node.ref else { return }
            elements[ref] = AgentDesktopElement(
                role: node.role,
                label: node.label,
                center: node.frame.map { frame in
                    ComputerCoordinates(
                        x: (frame.x + frame.width / 2 - target.x) * scale,
                        y: (frame.y + frame.height / 2 - target.y) * scale
                    )
                },
                isSecure: node.isSecure
            )
        }
    }

    func uniqueRefMatching(label targetLabel: String) -> String? {
        let labelled = actionable.compactMap { node in (node.label ?? (node.isSecure ? nil : Self.nonEmpty(node.value))).map { (node, $0) } }
        let exact = labelled.filter { $0.1.caseInsensitiveCompare(targetLabel) == .orderedSame }
        let candidates = exact.isEmpty ? labelled.filter { $0.1.localizedCaseInsensitiveContains(targetLabel) } : exact
        return candidates.count == 1 ? candidates[0].0.ref : nil
    }

    func smallestScrollable(containing point: ComputerCoordinates) -> String? {
        actionable
            .filter { node in
                guard Self.scrollRoles.contains(node.role), let frame = node.frame else { return false }
                return point.x >= frame.x && point.x <= frame.x + frame.width && point.y >= frame.y && point.y <= frame.y + frame.height
            }
            .min { ($0.frame?.width ?? 0) * ($0.frame?.height ?? 0) < ($1.frame?.width ?? 0) * ($1.frame?.height ?? 0) }?
            .ref
    }

    private static let scrollRoles: Set<String> = ["scrollarea", "table", "list", "outline", "webarea", "browser", "collection"]

    var focusedTextField: AgentDesktopNode? {
        let fields = actionable.filter { Self.textRoles.contains($0.role) }
        if let focused = fields.first(where: { $0.states.contains("focused") }) {
            return focused
        }
        return fields.count == 1 ? fields[0] : nil
    }

    private static let textRoles: Set<String> = ["textfield", "textarea", "searchfield"]

    static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func flatten(_ node: JSONValue, depth: Int, into nodes: inout [AgentDesktopNode]) {
        let bounds = node["bounds"]
        let frame = bounds.flatMap { bounds -> AXElementFrame? in
            guard let x = bounds["x"]?.doubleValue, let y = bounds["y"]?.doubleValue,
                  let width = bounds["width"]?.doubleValue, let height = bounds["height"]?.doubleValue else { return nil }
            return AXElementFrame(x: x, y: y, width: width, height: height)
        }
        nodes.append(AgentDesktopNode(
            ref: node["ref_id"]?.stringValue,
            role: node["role"]?.stringValue ?? "unknown",
            name: node["name"]?.stringValue,
            value: node["value"]?.stringValue,
            description: node["description"]?.stringValue,
            states: node["states"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            frame: frame,
            depth: depth
        ))
        for child in node["children"]?.arrayValue ?? [] {
            flatten(child, depth: depth + 1, into: &nodes)
        }
    }

    static let axRoles: [String: String] = [
        "application": "AXApplication",
        "button": "AXButton",
        "menubutton": "AXMenuButton",
        "checkbox": "AXCheckBox",
        "switch": "AXCheckBox",
        "link": "AXLink",
        "menuitem": "AXMenuItem",
        "radiobutton": "AXRadioButton",
        "tab": "AXRadioButton",
        "tablist": "AXTabGroup",
        "slider": "AXSlider",
        "combobox": "AXPopUpButton",
        "treeitem": "AXOutlineRow",
        "row": "AXRow",
        "cell": "AXCell",
        "column": "AXColumn",
        "window": "AXWindow",
        "sheet": "AXSheet",
        "dialog": "AXWindow",
        "group": "AXGroup",
        "radiogroup": "AXRadioGroup",
        "toolbar": "AXToolbar",
        "statictext": "AXStaticText",
        "image": "AXImage",
        "table": "AXTable",
        "list": "AXList",
        "outline": "AXOutline",
        "scrollarea": "AXScrollArea",
        "scrollbar": "AXScrollBar",
        "menu": "AXMenu",
        "incrementor": "AXIncrementor",
        "disclosure": "AXDisclosureTriangle",
        "progressbar": "AXProgressIndicator",
        "webarea": "AXWebArea",
        "heading": "AXHeading",
        "popover": "AXPopover",
    ]
}

struct AgentDesktopWindow: Sendable {
    let windowID: Int64
    let processID: Int32
    let title: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let isFocused: Bool
    let isVisible: Bool

    var frame: [Double] { [x, y, width, height] }

    init?(_ value: JSONValue) {
        guard let id = value["id"]?.stringValue, id.hasPrefix("w-"), let windowID = Int64(id.dropFirst(2)),
              let pid = value["pid"]?.doubleValue else { return nil }
        let bounds = value["bounds"]
        self.windowID = windowID
        processID = Int32(pid)
        title = value["title"]?.stringValue ?? ""
        x = bounds?["x"]?.doubleValue ?? 0
        y = bounds?["y"]?.doubleValue ?? 0
        width = bounds?["width"]?.doubleValue ?? 0
        height = bounds?["height"]?.doubleValue ?? 0
        isFocused = value["is_focused"]?.boolValue ?? false
        isVisible = value["minimized"]?.boolValue != true && value["visible"]?.boolValue != false
    }

    static func list(_ data: JSONValue) -> [AgentDesktopWindow] {
        (data.arrayValue ?? data["windows"]?.arrayValue ?? []).compactMap(AgentDesktopWindow.init)
    }

    static func identifier(_ windowID: Int64) -> String { "w-\(windowID)" }

    static func displayScale(for target: ScreenWindowTarget) -> Double {
        var display = CGMainDisplayID()
        var count: UInt32 = 0
        let center = CGPoint(x: target.x + target.width / 2, y: target.y + target.height / 2)
        if CGGetDisplaysWithPoint(center, 1, &display, &count) != .success || count == 0 {
            display = CGMainDisplayID()
        }
        guard let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else { return 1 }
        return Double(mode.pixelWidth) / Double(mode.width)
    }
}

enum AgentDesktopScreenshot {
    static func croppedToWindow(_ png: Data, width: Double, height: Double, scale: Double) -> Data {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let origin = opaqueOrigin(of: image) else { return png }
        let cropWidth = min(Int((width * scale).rounded()), image.width - origin.x)
        let cropHeight = min(Int((height * scale).rounded()), image.height - origin.y)
        let crop = CGRect(x: origin.x, y: origin.y, width: cropWidth, height: cropHeight)
        guard crop.width > 0, crop.height > 0,
              crop.size != CGSize(width: image.width, height: image.height),
              let cropped = image.cropping(to: crop) else { return png }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return png }
        CGImageDestinationAddImage(destination, cropped, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : png
    }

    private static func opaqueOrigin(of image: CGImage) -> (x: Int, y: Int)? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        func opaque(_ x: Int, _ y: Int) -> Bool { pixels[(y * width + x) * 4 + 3] == 255 }
        guard let left = (0..<width).first(where: { opaque($0, height / 2) }),
              let top = (0..<height).first(where: { opaque(width / 2, $0) }) else { return nil }
        return (left, top)
    }
}
