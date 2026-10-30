import SwiftUI

@MainActor
final class NotchExpansion: ObservableObject {
    @Published var open = false
    @Published var contentShown = false
    @Published var peeking = false
    @Published var onboardingHeight: CGFloat?
    @Published var peekHeight: CGFloat?
    @Published var peekThread: UUID?
}
