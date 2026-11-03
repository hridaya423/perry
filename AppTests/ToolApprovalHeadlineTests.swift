import XCTest
import PerryBrain
@testable import Perry

@MainActor
final class ToolApprovalHeadlineTests: XCTestCase {
    func testHeadlinesNameTheActionInPlainWords() {
        func headline(_ name: String, _ target: String?) -> String {
            ToolApprovalPresenter.headline(ToolCall(id: "1", name: name, arguments: .object([:])), target: target)
        }
        XCTAssertEqual(headline("app.launch", "Calculator"), "Open Calculator?")
        XCTAssertEqual(headline("files.trash", "/Users/me/report.txt"), "Move report.txt to the Trash?")
        XCTAssertEqual(headline("ui.click", nil), "Click here?")
        XCTAssertEqual(headline("browser.js", nil), "Run a script on this page?")
        XCTAssertEqual(headline("browser.connect", nil), "Let Perry use your browser?")
        XCTAssertEqual(headline("browser.connect", "Google Chrome"), "Let Perry use Google Chrome?")
        XCTAssertEqual(headline("mcp.github.create_issue", nil), "Use github’s create_issue?")
    }
}
