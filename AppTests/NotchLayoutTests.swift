import XCTest
@testable import Perry

final class NotchLayoutTests: XCTestCase {
    private let screens = [CGSize(width: 1728, height: 1117), CGSize(width: 1512, height: 982),
                           CGSize(width: 1280, height: 720), CGSize(width: 1024, height: 640), CGSize(width: 3840, height: 2160)]

    func testFocusedHeightIsContentPlusChrome() {
        let size = NotchLayout.size(.focused(content: 100), cameraInset: 32, screen: screens[0])
        XCTAssertEqual(size, CGSize(width: 440, height: 178))
    }

    @MainActor
    func testHoverOnlyShrinksTheNotchWhenThePeekIsShowing() {
        let presentation = NotchPresentation()
        let expansion = NotchExpansion()
        expansion.peeking = true
        XCTAssertEqual(NotchLayout.mode(presentation, expansion: expansion, showsPeek: true), .peek(content: nil))
        XCTAssertEqual(NotchLayout.mode(presentation, expansion: expansion, showsPeek: false), .workspace)
        expansion.greeting = .writing
        XCTAssertEqual(NotchLayout.mode(presentation, expansion: expansion, showsPeek: false), .greeting(.writing))
    }

    func testGreetingIsSmallerThanTheWorkspace() {
        let writing = NotchLayout.size(.greeting(.writing), cameraInset: 32, screen: screens[0])
        let settled = NotchLayout.size(.greeting(.settled), cameraInset: 32, screen: screens[0])
        let workspace = NotchLayout.size(.workspace, cameraInset: 32, screen: screens[0])
        XCTAssertLessThan(writing.height, settled.height)
        XCTAssertLessThan(settled.height, workspace.height)
        XCTAssertLessThan(settled.width, workspace.width)
    }

    func testEveryModeStaysInsideItsBounds() {
        for screen in screens {
            let cap = NotchLayout.cap(screen: screen)
            XCTAssertLessThanOrEqual(cap.width, min(800, screen.width - 64))
            XCTAssertLessThanOrEqual(cap.height, min(540, screen.height * 0.62))
            let window = NotchLayout.windowFrame(screen: CGRect(origin: .zero, size: screen), centerX: screen.width / 2)
            let modes: [(NotchLayout.Mode, CGFloat, ClosedRange<CGFloat>)] =
                [nil, 0, 40, 120, 600, 10_000].map { (.focused(content: $0), 440, 120...340) } + [(.workspace, 780, 220...520)]
            for (mode, width, heights) in modes {
                let size = NotchLayout.size(mode, cameraInset: 32, screen: screen)
                XCTAssertEqual(size.width, min(width, cap.width), "\(mode) on \(screen)")
                XCTAssertGreaterThanOrEqual(size.height, min(heights.lowerBound, cap.height), "\(mode) on \(screen)")
                XCTAssertLessThanOrEqual(size.height, min(heights.upperBound, cap.height), "\(mode) on \(screen)")
                let visible = NotchLayout.visibleFrame(size, in: window)
                XCTAssertTrue(window.contains(visible), "\(mode) on \(screen)")
                XCTAssertEqual(visible.maxY, screen.height)
            }
        }
    }
}
