import SwiftUI

enum NotchMotion {
    static let open = Animation.spring(response: 0.36, dampingFraction: 0.78)
    static let close = Animation.spring(response: 0.30, dampingFraction: 0.95)
    static let resize = Animation.spring(response: 0.32, dampingFraction: 0.90)
    static let contentIn = Animation.easeOut(duration: 0.16).delay(0.04)
    static let contentOut = Animation.easeOut(duration: 0.10)
    static let reduced = Animation.easeInOut(duration: 0.15)
    static let reducedResize = Animation.easeInOut(duration: 0.18)
}

enum NotchGreeting: Equatable {
    case writing, settled
}

@MainActor
final class NotchExpansion: ObservableObject {
    @Published var open = false
    @Published var contentShown = false
    @Published var peeking = false
    @Published var greeting: NotchGreeting?
    @Published var peekHeight: CGFloat?
    @Published var peekThread: UUID?
}
