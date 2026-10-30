import ApplicationServices
import PerryGuide

enum MenuBarReader {
    static func elements(pid: pid_t) -> [AXElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let bar = AXQuery.element(app, kAXMenuBarAttribute) else { return [] }
        var openItems: [AXElement] = []
        var barItems: [AXElement] = []
        for item in AXQuery.elements(bar, kAXChildrenAttribute) {
            guard let title = AXQuery.string(item, kAXTitleAttribute), !title.isEmpty,
                  let frame = AXQuery.frame(of: item) else { continue }
            barItems.append(entry("menubar:\(title)", .menu, title, frame))
            guard AXQuery.bool(item, kAXSelectedAttribute) else { continue }
            for menu in AXQuery.elements(item, kAXChildrenAttribute) {
                for menuItem in AXQuery.elements(menu, kAXChildrenAttribute) {
                    guard let label = AXQuery.string(menuItem, kAXTitleAttribute), !label.isEmpty,
                          let frame = AXQuery.frame(of: menuItem), frame.width > 0 else { continue }
                    openItems.append(entry("menu:\(title)/\(label)", .menuItem, label, frame))
                }
            }
        }
        return openItems + barItems
    }

    private static func entry(_ id: String, _ role: AXElement.Role, _ label: String, _ frame: CGRect) -> AXElement {
        AXElement(
            stableID: id, role: role, label: label,
            frame: AXElementFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
            isActionable: true, value: nil, rawRole: role == .menu ? "AXMenuBarItem" : "AXMenuItem",
            subrole: nil, sensitivity: .unknown
        )
    }
}
