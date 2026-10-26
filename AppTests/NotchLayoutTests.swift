import XCTest
@testable import Perry

final class NotchLayoutTests: XCTestCase {
    private let screens = [CGSize(width: 1728, height: 1117), CGSize(width: 1512, height: 982),
                           CGSize(width: 1280, height: 720), CGSize(width: 1024, height: 640), CGSize(width: 3840, height: 2160)]

    func testFocusedHeightIsContentPlusChrome() {
        let size = NotchLayout.size(.focused(content: 100), cameraInset: 32, screen: screens[0])
        XCTAssertEqual(size, CGSize(width: 440, height: 194))
    }

    func testEveryModeStaysInsideItsBounds() {
        for screen in screens {
            let cap = NotchLayout.cap(screen: screen)
            XCTAssertLessThanOrEqual(cap.width, min(600, screen.width * 0.4))
            XCTAssertLessThanOrEqual(cap.height, min(440, screen.height * 0.38))
            let window = NotchLayout.windowFrame(screen: CGRect(origin: .zero, size: screen), centerX: screen.width / 2)
            let modes: [(NotchLayout.Mode, CGFloat, ClosedRange<CGFloat>)] =
                [nil, 0, 40, 120, 600, 10_000].map { (.focused(content: $0), 440, 160...320) } + [(.workspace, 560, 220...400)]
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
