import SwiftUI

enum NotchMotion {
    static let open = Animation.spring(response: 0.38, dampingFraction: 0.82)
    static let close = Animation.spring(response: 0.30, dampingFraction: 0.95)
    static let resize = Animation.spring(response: 0.32, dampingFraction: 0.90)
    static let contentIn = Animation.easeOut(duration: 0.20).delay(0.12)
    static let contentOut = Animation.easeIn(duration: 0.10)
    static let reduced = Animation.easeInOut(duration: 0.15)
    static let reducedResize = Animation.easeInOut(duration: 0.18)
}

@MainActor
final class NotchExpansion: ObservableObject {
    @Published var open = false
    @Published var contentShown = false
    @Published var peeking = false
    @Published var peekHeight: CGFloat?
}
