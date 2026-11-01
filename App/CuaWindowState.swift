import Foundation
import PerryBrain
import PerryGuide

struct CuaToolOutput {
    let text: String
    let images: [Data]
    let imageMIMEType: String?
    let isError: Bool
    private let structured: JSONValue?

    init(_ result: JSONValue) {
        let content = result["content"]?.arrayValue ?? []
        let imageParts = content.filter { $0["type"]?.stringValue == "image" }
        text = content.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        images = imageParts.compactMap { $0["data"]?.stringValue.flatMap { Data(base64Encoded: $0) } }
        imageMIMEType = imageParts.compactMap { $0["mimeType"]?.stringValue }.first
        isError = result["isError"]?.boolValue ?? false
        structured = result["structuredContent"]
    }

    var effectConfirmed: Bool {
        let effect = structure(CuaActionEffect.self)
        return effect?.verified == true || effect?.effect == "confirmed"
    }

    func structure<Value: Decodable>(_ type: Value.Type) -> Value? {
        guard let structured, let data = try? structured.data() else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(type, from: data)
    }
}

private struct CuaActionEffect: Decodable {
    let effect: String?
    let verified: Bool?
}

struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

struct CuaPermissionReport: Decodable {
    struct Source: Decodable {
        let attribution: String?
        let embedded: Bool?
    }

    let accessibility: Bool?
    let screenRecording: Bool?
    let source: Source?
}

struct CuaWindowList: Decodable {
    struct Bounds: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct Window: Decodable {
        let pid: Int32
        let windowId: Int64
        let title: String
        let bounds: Bounds
        let bundleId: String?
        let zIndex: Int?
        let isOnScreen: Bool?
        let onCurrentSpace: Bool?
    }

    let windows: [Lossy<Window>]
}

struct CuaElement: Decodable {
    struct Frame: Decodable {
        let x: Double?
        let y: Double?
        let width: Double?
        let height: Double?
        let w: Double?
        let h: Double?
    }

    private enum CodingKeys: String, CodingKey {
        case elementToken, elementIndex, role, label, value, subrole, actions, frame
    }

    let elementToken: String?
    let elementIndex: Int?
    let role: String?
    let label: String?
    let value: String?
    let subrole: String?
    let actions: [String]?
    let frame: Frame?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        elementToken = try? container.decodeIfPresent(String.self, forKey: .elementToken)
        elementIndex = try? container.decodeIfPresent(Int.self, forKey: .elementIndex)
        role = try? container.decodeIfPresent(String.self, forKey: .role)
        label = try? container.decodeIfPresent(String.self, forKey: .label)
        value = try? container.decodeIfPresent(String.self, forKey: .value)
        subrole = try? container.decodeIfPresent(String.self, forKey: .subrole)
        actions = try? container.decodeIfPresent([String].self, forKey: .actions)
        frame = try? container.decodeIfPresent(Frame.self, forKey: .frame)
    }

    var token: String? {
        guard let elementToken, !elementToken.isEmpty else { return nil }
        return elementToken
    }

    var axFrame: AXElementFrame? {
        guard let frame, let x = frame.x, let y = frame.y,
              let width = frame.width ?? frame.w, let height = frame.height ?? frame.h else { return nil }
        return AXElementFrame(x: x, y: y, width: width, height: height)
    }
}

struct CuaWindowState: Decodable {
    let snapshotId: String?
    let elements: [Lossy<CuaElement>]?
    let treeMarkdown: String?
    let truncated: Bool?

    var usableElements: [CuaElement] {
        (elements ?? []).compactMap(\.value)
    }

    var labels: [String: String] {
        usableElements.reduce(into: [:]) { labels, element in
            guard let token = element.elementToken, let label = element.label, !label.isEmpty else { return }
            labels[token] = label
        }
    }

    var details: [String: ScreenElementDetail] {
        usableElements.reduce(into: [:]) { details, element in
            guard let token = element.token else { return }
            details[token] = ScreenElementDetail(value: element.role == "AXSecureTextField" ? nil : Self.nonEmpty(element.value))
        }
    }

    var actionTokens: String? {
        guard !usableElements.isEmpty else { return nil }
        let lines = usableElements.compactMap { element -> String? in
            guard let role = element.role, let label = element.label else { return nil }
            let token = element.elementToken ?? element.elementIndex.map(String.init) ?? "target"
            return "[\(token)] \(Self.shortRole(role)) \(label)"
        }
        let tree = treeMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tree, !tree.isEmpty {
            return lines.isEmpty ? tree : "\(tree)\n\nAction tokens:\n\(lines.joined(separator: "\n"))"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    func guideSnapshot(target: ScreenWindowTarget) -> AXSnapshot? {
        guard elements != nil else { return nil }
        let mapped = usableElements.compactMap { element -> AXElement? in
            let stableID: String
            if let token = element.token {
                stableID = token
            } else if let index = element.elementIndex {
                stableID = "cua-index:\(index)"
            } else {
                return nil
            }
            guard let frame = element.axFrame else { return nil }
            let rawRole = element.role ?? ""
            let role = axGuideRole(rawRole)
            return AXElement(
                stableID: stableID,
                role: role,
                label: Self.nonEmpty(element.label),
                frame: frame,
                isActionable: axGuideRoleIsActionable(role),
                value: nil,
                rawRole: rawRole,
                subrole: Self.nonEmpty(element.subrole),
                sensitivity: rawRole == "AXSecureTextField" ? .secure : .unknown
            )
        }
        return AXSnapshot(appBundleID: target.bundleID, windowTitle: target.title, elements: mapped)
    }

    func uniqueTokenMatching(label targetLabel: String) -> String? {
        let labelled = usableElements.compactMap { element in element.label.map { (element, $0) } }
        let exact = labelled.filter { $0.1.caseInsensitiveCompare(targetLabel) == .orderedSame }
        let candidates = exact.isEmpty ? labelled.filter { $0.1.localizedCaseInsensitiveContains(targetLabel) } : exact
        return candidates.count == 1 ? candidates[0].0.elementToken : nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func shortRole(_ rawRole: String) -> String {
        switch rawRole {
        case "AXButton": return "button"
        case "AXTextField": return "textField"
        case "AXCheckBox": return "checkBox"
        case "AXSlider": return "slider"
        case "AXMenuItem": return "menuItem"
        case "AXMenu": return "menu"
        case "AXStaticText": return "staticText"
        case "AXWindow": return "window"
        case "AXWebArea": return "webArea"
        default: return rawRole
        }
    }
}
