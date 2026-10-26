import SwiftUI

@MainActor
final class ShortcutCheck: ObservableObject {
    enum Result: Equatable {
        case idle
        case listening
        case heard
        case needsInputMonitoring
    }

    @Published private(set) var result = Result.idle
    private var timeout: Task<Void, Never>?

    func begin(captureMode: PushToTalkController.CaptureMode?, timeoutAfter: Duration = .seconds(10)) {
        timeout?.cancel()
        guard captureMode == .eventTap else {
            result = .needsInputMonitoring
            return
        }
        result = .listening
        timeout = Task { [weak self] in
            try? await Task.sleep(for: timeoutAfter)
            guard !Task.isCancelled, self?.result == .listening else { return }
            self?.result = .idle
        }
    }

    func intercept() -> Bool {
        guard result == .listening else { return false }
        timeout?.cancel()
        result = .heard
        return true
    }
}

struct ShortcutCheckRow: View {
    @ObservedObject var check: ShortcutCheck
    let gesture: Gesture
    let start: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch check.result {
            case .idle:
                Text("Check that it works in other apps.")
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                Spacer(minLength: 8)
                Button("Try it", action: start)
            case .listening:
                Text("\(gesture.spoken) now…")
                    .foregroundStyle(PerryTheme.Colors.text)
                Spacer(minLength: 8)
            case .heard:
                StatusMark(.ok)
                Text("Heard it. \(gesture.keys) works in other apps.")
                    .foregroundStyle(PerryTheme.Colors.text)
                Spacer(minLength: 8)
                Button("Try again", action: start)
            case .needsInputMonitoring:
                StatusMark(.attention)
                Text("I can’t see that key outside Perry. Turn on Input Monitoring.")
                    .foregroundStyle(PerryTheme.Colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Turn on") { Task { await PermissionGuideCoordinator.guide(.inputMonitoring) } }
            }
        }
        .font(PerryTheme.Scale.secondary)
    }
}
