import CryptoKit
import Foundation
import PerryCore
import PerryRuntimes

struct CompositeActionVerifier: TypedActionVerifier {
    let workspace: URL
    let worker: CuaWorkerHandle?
    private let workspaceVerifier: WorkspaceFileVerifier

    init(workspace: URL, worker: CuaWorkerHandle?) {
        self.workspace = workspace.resolvingSymlinksInPath().standardizedFileURL
        self.worker = worker
        self.workspaceVerifier = WorkspaceFileVerifier(baseURL: workspace)
    }

    func verify(
        approvedAction: ApprovedExecutableAction,
        result: ActionExecutionResult,
        context: ScreenContext
    ) async -> VerificationStatus {
        let action = approvedAction.action
        guard result.actionID == action.id, result.operation == action.operation else {
            return .unverified(reason: "the typed executor returned a mismatched action")
        }
        switch action.operation {
        case .transform:
            return await workspaceVerifier.verify(approvedAction: approvedAction, result: result, context: context)
        case .shell:
            return verifyShellPostcondition(action)
        case .computer(let window, _):
            return await verifyComputerPostcondition(action, window: window, result: result)
        case .integration:
            return verifyIntegrationPostcondition(action, result: result)
        case .askUser:
            return .verified(evidence: "the user answered the question")
        }
    }

    private func verifyShellPostcondition(_ action: ExecutableAction) -> VerificationStatus {
        guard case .workspaceFileContents(let path, let contents) = action.postcondition else {
            return .unverified(reason: "the shell action has no workspace postcondition")
        }
        let url = workspace.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(workspace.path + "/") else {
            return .unverified(reason: "the workspace postcondition escapes the workspace")
        }
        guard let data = try? Data(contentsOf: url) else {
            return .unverified(reason: "the expected workspace result could not be read back")
        }
        guard data == Data(contents.utf8) else {
            return .unverified(reason: "the workspace result does not contain the expected contents")
        }
        return .verified(evidence: "the workspace result was read back with the expected contents")
    }

    private func verifyComputerPostcondition(
        _ action: ExecutableAction,
        window: ExecutableAction.WindowIdentity,
        result: ActionExecutionResult
    ) async -> VerificationStatus {
        guard let worker else {
            return .unverified(reason: "no live window reader is attached to this session")
        }
        let capture: CuaCapturedWindow
        do {
            capture = try await worker.capture(target: nil)
        } catch {
            return .unverified(reason: "the target window could not be re-observed")
        }
        let target = capture.target
        guard target.processID == window.processID,
              target.windowID == Int64(window.windowID),
              target.bundleID.lowercased() == window.bundleID.lowercased() else {
            return .unverified(reason: "the target window changed since the plan was made")
        }
        switch action.postcondition {
        case .elementValue(let expected):
            let labels = capture.accessibilitySnapshotModel?.elements.compactMap(\.label) ?? []
            guard labels.contains(where: { $0.contains(expected) })
                    || capture.accessibilitySnapshot?.contains(expected) == true else {
                return .unverified(reason: "the typed text was not observed in the window")
            }
            return .verified(evidence: "the typed text was observed in the window's accessibility tree")
        case .visualChange(let plannedBaseline):
            let baselineSHA256: String
            if case .windowBaseline(let beforeStep) = result.evidence {
                baselineSHA256 = beforeStep
            } else {
                baselineSHA256 = plannedBaseline
            }
            guard !capture.screenshotData.isEmpty else {
                return .unverified(reason: "the window could not be re-screenshotted")
            }
            let digest = SHA256.hash(data: capture.screenshotData).map { String(format: "%02x", $0) }.joined()
            guard digest != baselineSHA256 else {
                return .unverified(reason: "the window did not visibly change")
            }
            return .verified(evidence: "the window visibly changed after the action")
        default:
            return .unverified(reason: "the computer action has no observable postcondition")
        }
    }

    private func verifyIntegrationPostcondition(
        _ action: ExecutableAction,
        result: ActionExecutionResult
    ) -> VerificationStatus {
        guard case .integrationResource(_, let expectedText) = action.postcondition else {
            return .unverified(reason: "the integration action has no resource postcondition")
        }
        guard case .integrationResponse(let data) = result.evidence,
              let body = String(data: data, encoding: .utf8) else {
            return .unverified(reason: "the service returned no response body to verify")
        }
        guard body.contains(expectedText) else {
            return .unverified(reason: "the service response did not echo the written content")
        }
        return .verified(evidence: "the service response echoed the written content")
    }
}
