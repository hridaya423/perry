#if DEBUG
enum FailureDrill: String, CaseIterable, Identifiable {
    case routeFlip
    case microphoneWedge
    case mutedOutput
    case runtimeMissing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .routeFlip: return "Simulate audio route flip"
        case .microphoneWedge: return "Simulate wedged microphone"
        case .mutedOutput: return "Simulate muted output"
        case .runtimeMissing: return "Simulate missing runtime"
        }
    }
}
#endif
