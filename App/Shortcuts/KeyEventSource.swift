import AppKit

@MainActor
final class KeyEventSource {
    enum Capture {
        case eventTap
        case fallbackMonitors
    }

    struct Event {
        enum Kind {
            case keyDown
            case keyUp
            case flagsChanged
            case tapDisabled
        }

        let kind: Kind
        let keyCode: Int64
        let flags: CGEventFlags
        let timestamp: TimeInterval
    }

    static let eventMask =
        (CGEventMask(1) &<< CGEventType.keyDown.rawValue)
        | (CGEventMask(1) &<< CGEventType.keyUp.rawValue)
        | (CGEventMask(1) &<< CGEventType.flagsChanged.rawValue)
        | (CGEventMask(1) &<< CGEventType.tapDisabledByTimeout.rawValue)
        | (CGEventMask(1) &<< CGEventType.tapDisabledByUserInput.rawValue)

    private let handler: (Event) -> Void
    private(set) var capture: Capture?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fallbackMonitors: [Any] = []
    private var tapRetry: Timer?

    init(handler: @escaping (Event) -> Void) {
        self.handler = handler
    }

    func start() {
        guard capture == nil else { return }
        if installEventTap() { return }
        installFallbackMonitors()
        tapRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.upgradeToEventTap() }
        }
    }

    func stop() {
        tapRetry?.invalidate()
        tapRetry = nil
        removeEventTap()
        removeFallbackMonitors()
        capture = nil
    }

    func reenable() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    static func isTapDisabled(_ type: CGEventType) -> Bool {
        type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
    }

    private static var mayListen: Bool {
        CGPreflightListenEventAccess() || AXIsProcessTrusted()
    }

    private func installEventTap() -> Bool {
        guard Self.mayListen,
              let tap = CGEvent.tapCreate(
                  tap: .cgSessionEventTap,
                  place: .headInsertEventTap,
                  options: .listenOnly,
                  eventsOfInterest: Self.eventMask,
                  callback: { _, type, event, refcon in
                      guard let refcon else { return Unmanaged.passUnretained(event) }
                      let source = Unmanaged<KeyEventSource>.fromOpaque(refcon).takeUnretainedValue()
                      let kind: Event.Kind? = switch type {
                      case .keyDown: .keyDown
                      case .keyUp: .keyUp
                      case .flagsChanged: .flagsChanged
                      case .tapDisabledByTimeout, .tapDisabledByUserInput: .tapDisabled
                      default: nil
                      }
                      if let kind {
                          let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                          let flags = event.flags
                          let timestamp = ProcessInfo.processInfo.systemUptime
                          Task { @MainActor [weak source] in
                              source?.handler(Event(kind: kind, keyCode: keyCode, flags: flags, timestamp: timestamp))
                          }
                      }
                      return Unmanaged.passUnretained(event)
                  },
                  userInfo: Unmanaged.passUnretained(self).toOpaque()
              ) else { return false }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        capture = .eventTap
        return true
    }

    private func removeEventTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func installFallbackMonitors() {
        capture = .fallbackMonitors
        let types: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        let deliver: (NSEvent) -> Void = { [weak self] event in
            let kind: Event.Kind = switch event.type {
            case .keyDown: .keyDown
            case .keyUp: .keyUp
            default: .flagsChanged
            }
            self?.handler(Event(
                kind: kind,
                keyCode: Int64(event.keyCode),
                flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)),
                timestamp: event.timestamp
            ))
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: types, handler: deliver) {
            fallbackMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: types, handler: { event in
            deliver(event)
            return event
        }) {
            fallbackMonitors.append(monitor)
        }
    }

    private func removeFallbackMonitors() {
        for monitor in fallbackMonitors { NSEvent.removeMonitor(monitor) }
        fallbackMonitors = []
    }

    private func upgradeToEventTap() {
        guard capture == .fallbackMonitors, Self.mayListen, installEventTap() else { return }
        removeFallbackMonitors()
        tapRetry?.invalidate()
        tapRetry = nil
    }
}
