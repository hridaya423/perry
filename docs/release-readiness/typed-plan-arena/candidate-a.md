# Candidate A: canonical typed executable plan

The M1 boundary should be one PerryCore-owned, executable action algebra. Runtime adapters parse provider or model wire output once into that algebra; persistence, approval, execution, verification, and recovery consume the same value. The existing `Step` dictionary remains a read-only migration input, never the canonical plan and never a fallback executor.

## Usage first

Planning and persistence have one value to pass around:

```swift
let plan = try await planner.plan(goal: goal, context: context, taskID: taskID)
let record = try await coordinator.enqueue(plan: plan, runtimeID: selectedRuntime.id)

let approval = try await approvals.issue(
    taskID: record.taskID,
    planID: plan.planID,
    actionIDs: plan.actions.map(\.actionID),
    scopes: plan.requestedScopes
)

let outcome = try await runner.run(
    record: record,
    approval: approval,
    executor: executor,
    verifier: verifier
)
```

The foreground caller supplies the Cua worker and exact captured window through the executor context. The existing app-scoped highlight and move-pointer overlay remains a target-context prelude, not an autonomous plan effect. The background caller supplies the selected registry provider and workspace lease through the same context. Neither caller converts a plan to `Step`, owns a raw `Process`, or authorizes from current Settings state.

An adapter turns provider output into a typed value before it reaches the coordinator:

```swift
let action = try planDecoder.decodeComputer(
    output,
    target: .exactWindow(
        window: WindowIdentity(
            bundleID: appID,
            processID: processID,
            windowID: windowID,
            connectionGeneration: connectionGeneration
        ),
        selector: .element(
            ElementSelector(stableID: elementID, label: elementLabel)
        )
    )
)
let plan = try ExecutionPlan(
    schemaVersion: 1,
    planID: planID,
    taskID: taskID,
    actions: [action],
    requestedScopes: [.application(appID)]
)
```

The decoder rejects an unknown operation or an incomplete target. There is no `planner.execute` path after decoding failure.

## Shape

`ExecutionPlan` has exactly the durable identity and effect surface M1 needs. Runtime provider selection stays in the task execution binding so the plan describes work, while `TaskCoordinator` preserves the existing `runtimeID` used for Codex, Claude, OpenCode, direct API, custom, and local providers.

```swift
public struct ExecutionPlan: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let planID: PlanID
    public let taskID: TaskID
    public let actions: [ExecutionAction]
    public let requestedScopes: Set<ExecutionScope>
}

public enum ExecutionAction: Codable, Sendable, Equatable {
    case computer(ComputerAction)
    case integration(IntegrationAction)
    case sandboxedShell(SandboxedShellAction)
    case localTransform(LocalTransformAction)
    case askUser(AskUserAction)

    public var actionID: ActionID {
        switch self {
        case .computer(let action): action.contract.actionID
        case .integration(let action): action.contract.actionID
        case .sandboxedShell(let action): action.contract.actionID
        case .localTransform(let action): action.contract.actionID
        case .askUser(let action): action.contract.actionID
        }
    }
}

public struct ActionContract: Codable, Sendable, Equatable {
    public let actionID: ActionID
    public let target: TargetIdentity
    public let timeout: TimeInterval
    public let approval: ApprovalScope
    public let idempotency: IdempotencyPolicy
    public let postcondition: Postcondition
    public let verification: VerificationPolicy
}

public struct WindowIdentity: Codable, Sendable, Equatable {
    public let bundleID: ApplicationBundleID
    public let processID: ProcessID
    public let windowID: WindowID
    public let connectionGeneration: UInt64
}

public enum TargetIdentity: Codable, Sendable, Equatable {
    case none
    case application(ApplicationBundleID)
    case exactWindow(window: WindowIdentity, selector: ComputerSelector)
    case workspace(WorkspaceID)
    case integration(IntegrationProviderID)
    case sandbox(SandboxID)
}

public enum ComputerSelector: Codable, Sendable, Equatable {
    case element(ElementSelector)
    case windowPixels(WindowPixelCoordinates)
}

public struct ElementSelector: Codable, Sendable, Equatable {
    public let stableID: String?
    public let label: String?
}

public struct WindowPixelCoordinates: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
}

public struct Digest: Codable, Sendable, Equatable, Hashable {
    public let bytes: [UInt8]
}

public struct DispatchID: Codable, Sendable, Equatable, Hashable {
    public let rawValue: String
}

public enum Postcondition: Codable, Sendable, Equatable {
    case fileBytes(path: WorkspaceRelativePath, contents: UTF8Text)
    case exactWindow(WindowIdentity)
    case integrationAccepted(provider: IntegrationProviderID)
    case shellExitCode(Int32)
    case userAnswered
    case none
}

public struct VerificationResult: Codable, Sendable, Equatable {
    public let actionID: ActionID
    public let postcondition: Postcondition
    public let evidence: VerificationEvidence
}

public enum VerificationEvidence: Codable, Sendable, Equatable {
    case fileBytes(Digest)
    case exactWindow(WindowIdentity)
    case integrationAccepted
    case shellExitCode(Int32)
    case userAnswered
}

public enum VerificationPolicy: Codable, Sendable, Equatable {
    case none
    case readBack
    case matchesPostcondition
}
```

Each case owns an `ActionContract` and typed operation data; the contract is not a metadata wrapper because it contains the effect’s target, replay rule, and verifiable postcondition. `ExecutionAction.contract` is an exhaustive switch over the five cases, and plan validation rejects duplicate action IDs, invalid timeouts, scope/target mismatches, unsupported schema versions, and any unknown tagged case.

```swift
public struct ComputerAction: Codable, Sendable, Equatable {
    public let contract: ActionContract
    public let operation: ComputerOperation
}

public enum ComputerOperation: Codable, Sendable, Equatable {
    case click
    case typeText(String)
    case rightClick
    case doubleClick
    case scroll(direction: ScrollDirection, amount: Int)
    case pressKey(Key, modifiers: Set<KeyModifier>)
    case hotkey([Key])
    case drag(from: ComputerCoordinates, to: ComputerCoordinates, duration: TimeInterval)
}

public struct IntegrationAction: Codable, Sendable, Equatable {
    public let contract: ActionContract
    public let operation: IntegrationOperation
}

public enum IntegrationOperation: Codable, Sendable, Equatable {
    case notionCreatePage(parentID: IntegrationResourceID, title: String)
    case notionUpdatePage(pageID: IntegrationResourceID, title: String)
    case notionAppendBlock(blockID: IntegrationResourceID, text: String)
    case slackSendMessage(channelID: IntegrationResourceID, text: String)
    case linearUpdateIssue(issueID: IntegrationResourceID, title: String)
}

public struct SandboxedShellAction: Codable, Sendable, Equatable {
    public let contract: ActionContract
    public let executable: RegisteredExecutableID
    public let arguments: [String]
    public let sandbox: SandboxID
}

public struct LocalTransformAction: Codable, Sendable, Equatable {
    public let contract: ActionContract
    public let operation: LocalTransformOperation
}

public enum LocalTransformOperation: Codable, Sendable, Equatable {
    case createFile(path: WorkspaceRelativePath, contents: UTF8Text)
    case createDirectory(path: WorkspaceRelativePath)
    case rename(path: WorkspaceRelativePath, newPath: WorkspaceRelativePath)
    case moveToTrash(path: WorkspaceRelativePath)
}

public struct AskUserAction: Codable, Sendable, Equatable {
    public let contract: ActionContract
    public let question: UserQuestion
}
```

The existing app-scoped highlight and move-pointer calls stay outside `ExecutionPlan` and `CanonicalActionExecutor`. They render the selected application overlay used by the current foreground flow; they do not become autonomous effects or durable action receipts. Actual click, typing, and other control actions use the exact window contract and its required selector or window-pixel coordinates.

`ExactWindow` requires all four identity fields, plus a `ComputerSelector`. An element selector carries the existing stable ID and label fields and must contain at least one usable selector; a pixel selector carries `windowPixels` coordinates. A click therefore always has either a typed element selector or typed window-pixel coordinates, never only a bundle ID or title. `WorkspaceRelativePath` validates only lexical properties in PerryCore. The workspace executor resolves and checks the real path under its leased workspace immediately before the effect, and the verifier reads through the same filesystem boundary, so Core does not claim to prove symlink confinement. `UTF8Text` encodes the exact bytes required by the existing `WorkspaceFileRuntime`. `IntegrationOperation` deliberately contains provider operations and typed resource IDs, never GraphQL, HTTP methods, URL paths, or arbitrary request bodies. M1 carries the typed write precedents already implemented in `RemoteIntegrationWriteParameters`; M6 can add catalog operations without changing this boundary.

`SandboxedShellAction` means an explicit registered executable and typed argument vector inside a selected sandbox. The current `Step.Kind.delegate` value is not enough to infer that action: the source also maps `runShellCommand` through that legacy kind, and the two meanings are not interchangeable. A Codex delegated task remains provider routing outside this M1 action sum. A legacy record becomes a shell action only when its payload explicitly identifies the registered executable, arguments, sandbox, and confinement; otherwise it is retired as ambiguous rather than guessed.

The runner interfaces are typed at the action boundary, and `TaskCoordinator` is the only durable journal owner:

```swift
public protocol CanonicalTaskPlanner: Sendable {
    func plan(
        goal: String,
        context: ScreenContext,
        taskID: TaskID
    ) async throws -> ExecutionPlan
}

public struct PreparedActionReceipt: Codable, Sendable, Equatable {
    public let taskID: TaskID
    public let planID: PlanID
    public let actionID: ActionID
    public let actionDigest: Digest
}

public struct DispatchedActionReceipt: Codable, Sendable, Equatable {
    public let prepared: PreparedActionReceipt
    public let dispatchID: DispatchID
}

public struct VerifiedActionReceipt: Codable, Sendable, Equatable {
    public let dispatched: DispatchedActionReceipt
    public let result: VerificationResult
}

public enum ActionReceipt: Codable, Sendable, Equatable {
    case prepared(PreparedActionReceipt)
    case dispatched(DispatchedActionReceipt)
    case verified(VerifiedActionReceipt)
}

public protocol CanonicalActionExecutor: Sendable {
    func dispatch(
        _ action: ExecutionAction,
        prepared: PreparedActionReceipt,
        approval: ApprovalReceipt?
    ) async throws -> DispatchedActionReceipt
    func cancel(actionID: ActionID) async
}

public protocol CanonicalActionVerifier: Sendable {
    func verify(
        _ action: ExecutionAction,
        receipt: DispatchedActionReceipt
    ) async throws -> VerifiedActionReceipt
}

public struct ApprovalReceipt: Codable, Sendable, Equatable {
    public let taskID: TaskID
    public let planID: PlanID
    public let planRevision: UInt64
    public let planDigest: Digest
    public let requestedScopesDigest: Digest
    public let runtimeBindingDigest: Digest
    public let effects: [ApprovedEffectBinding]
}

public struct ApprovedEffectBinding: Codable, Sendable, Equatable {
    public let actionID: ActionID
    public let actionDigest: Digest
    public let effectDigest: Digest
}

public actor TaskCoordinator {
    public func prepareAction(
        taskID: TaskID,
        planID: PlanID,
        actionID: ActionID,
        actionDigest: Digest
    ) async throws -> PreparedActionReceipt

    public func recordDispatch(
        _ receipt: DispatchedActionReceipt
    ) async throws

    public func recordVerification(
        _ receipt: VerifiedActionReceipt
    ) async throws
}
```

Before dispatch, `TaskCoordinator.prepareAction` persists the action digest and the existing in-flight checkpoint. The executor returns `DispatchedActionReceipt` only after its local dispatch boundary, and the coordinator records it. The verifier returns `VerifiedActionReceipt` only when the typed `Postcondition` is satisfied; the coordinator then advances the existing checkpoint. A crash with either a prepared or dispatched receipt is uncertain and requires reconciliation. A provider without cancellation cannot turn that uncertainty into a retry. The coordinator records cancellation intent before asking the executor to stop, and it remains the sole writer of task state and action receipts.

`planDigest` is the digest of canonical serialized plan bytes. `actionDigest` is the digest of the canonical action bytes, including its `ActionContract` and typed operation. `effectDigest` is the digest of the action bytes, requested-scope digest, and selected runtime binding digest. The coordinator persists these digests with the plan revision; approval is valid only when every persisted value and the immutable task/plan IDs match. A Settings change or registry descriptor change therefore invalidates the receipt instead of authorizing the old effect.

## Module map

- `Packages/PerryCore/Sources/PerryCore/ExecutionPlan.swift` owns the IDs, closed action sum, contracts, typed payloads, Codable versioning, and structural validation.
- `Packages/PerryRuntimes/Sources/PerryRuntimes/AgentRuntime.swift` exposes typed planner, executor, and verifier interfaces. Wire parsing stays in runtime adapters.
- `App/ComputerAction.swift` moves its target and operation value types into PerryCore, including the four-field exact-window identity and selector/coordinate types; its remaining parser becomes the Cua wire adapter and is deleted after all callers accept `ComputerAction`. App-scoped highlight and move-pointer overlay calls remain in their existing non-plan path.
- `Packages/PerryRuntimes/Sources/PerryRuntimes/WorkspaceFileRuntime.swift` executes `LocalTransformOperation`; its private `WorkspaceFileAction` is removed once the canonical decoder is the only parser.
- `App/RemoteIntegrations.swift` reuses the typed `RemoteIntegrationWriteParameters` cases as PerryCore operations. OAuth, catalog definitions, method/path/body construction, and the client stay in the App adapter.
- `Packages/PerryGuide/Sources/PerryGuide/TaskCoordinator.swift` stores the canonical plan, the existing provider `runtimeID`, immutable plan revision and digests, checkpoints, approval receipt, intent, reconciliation state, and prepared/dispatched/verified action receipts. It is the single durable journal owner. `App/RuntimeSetup.swift` remains the home for setup/readiness/choice/auth records and does not become plan authorization.
- `Packages/PerryGuide/Sources/PerryGuide/ResumableTaskRunner.swift` and `PerryRuntimes` supervision run the typed action sequence and preserve action IDs through checkpointing.
- `App/AppController.swift` selects the registry provider and owns Cua/workspace leases, then passes those handles to typed adapters. It does not construct a second action representation.

## Why this shape

The current `PerryCore.AgentAction` in `ExecutionPlan.swift` carries kind and policy but not executable values. `ExecutionPlanAdapter` in `RuntimeTypes.swift` consequently reconstructs steps from metadata and loses file contents, GUI targets, and integration parameters; its legacy initializer preserves payload only on the old path. `TaskCoordinator` persists `PersistedTaskStep` dictionaries in store versions 1 and 2, while `ComputerAction`, private `WorkspaceFileAction`, and `RemoteIntegrationWriteParameters` prove that the executors already know the needed typed boundaries. M1 should connect those precedents rather than add a second metadata bridge.

Tradeoffs accepted are a larger Codable sum and a deliberate M1 operation set. Closed cases make unknown output fail before approval or effects and make reviewers see every effect class. Provider-specific additions require a case and decoder update, but that cost is safer than accepting a generic path/body or a closure that cannot be audited, persisted, or replay-checked. The registry remains the source of provider descriptors and eligibility; no global resolved-plan cache or new protocol family is introduced.

The rejected alternative is a generic `ActionPayload` dictionary or data-driven closure table. It keeps old planners superficially compatible, but values still disappear at the metadata adapter, approval cannot bind typed scopes, and recovery cannot determine whether replay is safe. Keeping `Step` as the execution API has the same failure mode. A second typed bridge beside `Step` would preserve the duplication this change is meant to remove.

## Required traces

1. **UTF-8 file create.** A decoder creates `LocalTransformOperation.createFile` with a relative path and `UTF8Text`. Serialization and reload retain the exact plan/task/action IDs and bytes. Approval binds the workspace scope. The executor maps the typed operation to the existing workspace runtime, and the verifier reads back the exact UTF-8 bytes before advancing the checkpoint.
2. **Exact-window GUI.** The Cua decoder requires `TargetIdentity.exactWindow` with `bundleID`, `processID`, `windowID`, and `connectionGeneration`, plus either `ElementSelector(stableID:label:)` or `WindowPixelCoordinates(x:y:)`. The existing `ComputerAction` validation rejects a changed generation, window, element selector, or pixel-space target before dispatch.
3. **Approved integration write.** A typed Notion, Slack, or Linear operation is checked against the registry definition and OAuth credential reference, then against an approval receipt whose plan revision, plan digest, action digest, effect digest, requested-scope digest, and runtime-binding digest match the persisted values. Only the adapter derives its private wire request; an unknown provider or operation fails before the client call.
4. **Malformed plan.** Unknown schema or enum tag, duplicate ID, invalid lexical path, missing required target, unregistered shell executable, or mismatched scope is rejected during decode/validation. The workspace executor separately rejects a symlink escape at its leased filesystem boundary. There is no conversion to `.readWindow`, generic remote request, or planner fallback.
5. **Uncertain crash recovery.** The coordinator persists a prepared receipt and in-flight checkpoint before dispatch, then persists a dispatched receipt when the executor returns. A crash at either phase before verification restores the same record as paused/reconciliation-required, retaining approval, cancellation intent, digests, and IDs. Reconciliation must produce a typed verification result; the runner never silently retries a non-idempotent or uncertain action.

## Exact migration and deletion sequence

1. Add the PerryCore sum, contracts, IDs, typed integration operations, UTF-8/path values, versioned decoder, and validation tests. Capture golden fixtures from supported current `Step` payloads before changing readers.
2. Add typed planner decoding and typed executor/verifier interfaces. Implement the file-create, exact-window Cua, and existing typed integration-write vertical slices. Canonical execution must reject unknown output; the legacy executor remains available only to the migration reader. Keep app-scoped highlight and move-pointer overlay calls on their current non-plan path.
3. Change `TaskCoordinator` and `ResumableTaskRunner` to persist `ExecutionPlan` plus the existing `runtimeID` binding. Replace the old step transitions inside that actor with prepared, dispatched, and verified receipts while preserving store v1/v2 fields, action IDs, next-step index, in-flight/suspended IDs, approvals, cancellation intent, and reconciliation disposition.
4. Run a one-time v1/v2 migrator. Records with complete, supported typed payloads become schema 1 plans using their original task and step IDs. `delegate` is converted to `sandboxedShell` only when the payload explicitly carries a registered executable, arguments, sandbox, and confinement; Codex task delegation and `runShellCommand` otherwise remain distinct. Records with missing IDs, ambiguous delegate/remote-read payloads, unsupported operations, or unverifiable postconditions are marked retired with their original record retained; they are never guessed into a runnable action.
5. Route foreground, background, and runtime-provider selection through the canonical plan. Keep registry eligibility, the App-owned Cua/workspace leases, and the overlay flow at their existing boundaries; Settings changes affect new selection only.
6. After references are absent and migration fixtures pass, delete `ExecutionPlanAdapter`, `StepActionMapper`, metadata payload synthesis, textual `ExecutionPlanMigrationDecoder` mapping to `.readWindow`, and canonical-path `Plan`/`Step` execution overloads. Then delete the duplicate App `ComputerAction` payload types and private `WorkspaceFileAction`; retain only a read-only v1/v2 decoder until every stored record is migrated or explicitly retired.

## Open risks and next slice

The exact `TaskID` home must be promoted from PerryGuide without changing serialized IDs, and the existing approval/checkpoint APIs need a typed receipt without weakening their current cancellation and reconciliation behavior. The first implementation slice should be the Core sum plus the UTF-8 file-create round trip and migration fixture, followed by the Cua and integration adapters; no production behavior should switch until those traces prove the same IDs and effects end to end.

Synthesis remains for the arena: this candidate recommends the enum-centered shape because exhaustive cases and typed postconditions make persistence, approval, execution, and recovery share one auditable value.
