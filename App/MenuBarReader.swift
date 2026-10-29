import ApplicationServices
import PerryGuide

/// The target app's menu bar and the menu open on it. A window read never
/// includes them: the menu bar belongs to the application element.
enum MenuBarReader {
    static func elements(pid: pid_t) -> [AXElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let bar = LocalTalkObserver.axValue(app, kAXMenuBarAttribute) else { return [] }
        var openItems: [AXElement] = []
        var barItems: [AXElement] = []
        for item in LocalTalkObserver.axValues(bar, kAXChildrenAttribute) {
            guard let title = LocalTalkObserver.axString(item, kAXTitleAttribute), !title.isEmpty,
                  let frame = axFrame(of: item) else { continue }
            barItems.append(entry("menubar:\(title)", .menu, title, frame))
            guard isSelected(item) else { continue }
            for menu in LocalTalkObserver.axValues(item, kAXChildrenAttribute) {
                for menuItem in LocalTalkObserver.axValues(menu, kAXChildrenAttribute) {
                    guard let label = LocalTalkObserver.axString(menuItem, kAXTitleAttribute), !label.isEmpty,
                          let frame = axFrame(of: menuItem), frame.width > 0 else { continue }
                    openItems.append(entry("menu:\(title)/\(label)", .menuItem, label, frame))
                }
            }
        }
        return openItems + barItems
    }

    private static func isSelected(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) == true
    }

    private static func axFrame(of element: AXUIElement) -> AXElementFrame? {
        guard let position = LocalTalkObserver.axCGPoint(LocalTalkObserver.axRawValue(element, kAXPositionAttribute)),
              let size = LocalTalkObserver.axCGSize(LocalTalkObserver.axRawValue(element, kAXSizeAttribute)) else { return nil }
        return AXElementFrame(x: Double(position.x), y: Double(position.y), width: Double(size.width), height: Double(size.height))
    }

    private static func entry(_ id: String, _ role: AXElement.Role, _ label: String, _ frame: AXElementFrame) -> AXElement {
        AXElement(
            stableID: id, role: role, label: label, frame: frame,
            isActionable: true, value: nil, rawRole: role == .menu ? "AXMenuBarItem" : "AXMenuItem",
            subrole: nil, sensitivity: .unknown
        )
    }
}
