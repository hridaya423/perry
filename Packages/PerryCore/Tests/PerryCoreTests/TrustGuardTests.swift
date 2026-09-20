import XCTest
@testable import PerryCore

final class TrustGuardTests: XCTestCase {
    private let guard_ = TrustGuard()

    func testGreenTierForReadOnlyKinds() {
        XCTAssertEqual(guard_.classify(ActionDescriptor(kind: .movePointer, summary: "glide")), .green)
        XCTAssertEqual(guard_.classify(ActionDescriptor(kind: .highlightElement, summary: "highlight")), .green)
        XCTAssertEqual(guard_.classify(ActionDescriptor(kind: .readWindow, summary: "read")), .green)
    }

    func testYellowTierForReversibleWrites() {
        XCTAssertEqual(guard_.classify(ActionDescriptor(kind: .typeText, summary: "type")), .yellow)
        XCTAssertEqual(guard_.classify(ActionDescriptor(kind: .clickControl, summary: "click")), .yellow)
        XCTAssertEqual(guard_.classify(ActionDescriptor(kind: .createFile, summary: "create")), .yellow)
        XCTAssertEqual(guard_.classify(ActionDescriptor(kind: .renameFile, summary: "rename")), .yellow)
    }

    func testOrangeTierForIrreversibleWrites() {
        XCTAssertEqual(guard_.classify(ActionDescriptor(kind: .sendEmailOrMessage, summary: "send")), .orange)
        XCTAssertEqual(guard_.classify(ActionDescriptor(kind: .moveToTrash, summary: "trash")), .orange)
        XCTAssertEqual(guard_.classify(ActionDescriptor(kind: .overwriteFile, summary: "overwrite")), .orange)
    }

    func testRedTierForDangerousKinds() {
        XCTAssertEqual(guard_.classify(ActionDescriptor(kind: .emptyTrash, summary: "empty")), .red)
        XCTAssertEqual(guard_.classify(ActionDescriptor(kind: .makePurchase, summary: "buy")), .red)
        XCTAssertEqual(guard_.classify(ActionDescriptor(kind: .accessCredentials, summary: "keychain")), .red)
    }

    func testShellCommandTierDependsOnWorkspaceScope() {
        let sandboxed = ActionDescriptor(kind: .runShellCommand, summary: "ls", shellExecutablePath: "/bin/ls", pathInsideWorkspace: true)
        let outside = ActionDescriptor(kind: .runShellCommand, summary: "rm", shellExecutablePath: "/bin/rm", pathInsideWorkspace: false)
        XCTAssertEqual(guard_.classify(sandboxed), .yellow)
        XCTAssertEqual(guard_.classify(outside), .red)
    }

    func testShellCommandDefaultsOutsideWorkspace() {
        let action = ActionDescriptor(kind: .runShellCommand, summary: "run command")

        XCTAssertEqual(guard_.classify(action), .red)
    }

    func testBankingBundleIDBlocksAnyAction() {
        let decision = guard_.decide(
            action: ActionDescriptor(kind: .readWindow, summary: "peek"),
            targetWindow: WindowContext(appBundleID: "com.agilebits.onepassword-osx", title: "1Password")
        )
        XCTAssertEqual(decision, .deny(reason: "target window is on the blocked list"))
    }

    func testCheckoutTitleKeywordBlocksAnyAction() {
        let decision = guard_.decide(
            action: ActionDescriptor(kind: .clickControl, summary: "click Buy"),
            targetWindow: WindowContext(appBundleID: "com.apple.Safari", title: "Apple Store: Checkout")
        )
        XCTAssertEqual(decision, .deny(reason: "target window is on the blocked list"))
    }

    func testNilWindowNeverBlocked() {
        let decision = guard_.decide(
            action: ActionDescriptor(kind: .readWindow, summary: "read"),
            targetWindow: nil
        )
        XCTAssertEqual(decision, .allowAutonomous(tier: .green))
    }

    func testOrangeRequiresConfirmation() {
        let decision = guard_.decide(
            action: ActionDescriptor(kind: .moveToTrash, summary: "move 34 files to Trash"),
            targetWindow: WindowContext(appBundleID: "com.apple.finder", title: "Desktop")
        )
        guard case .requireConfirmation(let tier, _) = decision else {
            return XCTFail("expected confirmation, got \(decision)")
        }
        XCTAssertEqual(tier, .orange)
    }

    func testCustomBlocklistIsHonored() {
        let custom = TrustGuard(
            blockedBundleIDs: ["com.example.secretapp"],
            sensitiveTitleKeywords: []
        )
        let decision = custom.decide(
            action: ActionDescriptor(kind: .highlightElement, summary: "point"),
            targetWindow: WindowContext(appBundleID: "com.example.SecretApp", title: "Vault")
        )
        XCTAssertEqual(decision, .deny(reason: "target window is on the blocked list"))
    }

    func testBlocklistMatchingIsCaseInsensitiveOnBothSides() {
        let decision = guard_.decide(
            action: ActionDescriptor(kind: .readWindow, summary: "peek"),
            targetWindow: WindowContext(appBundleID: "COM.LASTPASS.LASTPASS", title: "Vault")
        )
        XCTAssertEqual(decision, .deny(reason: "target window is on the blocked list"))
    }
}
