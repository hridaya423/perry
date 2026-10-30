import Foundation
import PerryGuide
@testable import Perry

extension AppController {
    static func testing(
        directory: URL,
        session: SessionController? = nil,
        overrides configure: (inout LaunchOverrides) -> Void = { _ in }
    ) -> AppController {
        var overrides = LaunchOverrides()
        overrides.storageDirectory = directory
        overrides.guidePlanner = AXGuidePlanner()
        configure(&overrides)
        return AppController(sessionController: session ?? SessionController(), overrides: overrides)
    }
}
