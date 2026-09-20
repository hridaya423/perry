# Canonical executable plan: candidate B

This candidate makes `PerryRuntimes` the owner of the executable plan. `PerryCore` keeps generic trust and policy values, while `PerryRuntimes` owns the action algebra, parameter validation, plan codec, coordinator journal boundary, and the boundary that turns a plan action into an executor request. The plan is a complete execution object, not metadata attached to a legacy `Step`.

## Usage first

A planner returns a complete plan. The caller persists that plan before it asks for approval or starts an effect.

```swift
let plan = try await planner.makePlan(
    goal: "Create the report in the workspace",
    context: context,
    taskID: taskID
)

try planStore.save(plan)
let grant = try approval.authorize(plan: plan, actionID: nil)
let result = try await executor.execute(plan: plan, actionID: grant.actionID, approval: grant)
let entry = try await journal.record(result, for: plan, actionID: grant.actionID)
try await verifier.verify(entry: entry, against: plan)
```

A background task resumes through the same object. The coordinator owns the checkpoint and compares the exact record it admitted.

```swift
let record = try await taskCoordinator.admitRun(
    taskID: taskID,
    expectedRecord: expectedRecord,
    approval: approval
)
let outcome = await runner.run(
    record: record,
    expectedRecord: record,
    runtime: runtime
)
```

A foreground computer action does not reconstruct a `Step` or ask the driver to rediscover parameters.

```swift
let action = try plan.action(id: actionID)
let result = try await runtime.execute(
    action: action,
    approval: grant,
    resources: resources
)
```

The returned result is recorded by the coordinator journal against the same plan, task, and action identities that were admitted. A caller cannot replace the action with a summary, a new target, or an untyped provider path between approval and execution.

## Shape

### Ownership boundary

`PerryCore` retains values that are useful to several domains: `TrustTier`, `ApprovalScope`, `IdempotencyPolicy`, and generic verification or capability policy. It does not define the executable action graph.

`PerryRuntimes` owns these public types:

```swift
public struct ExecutionPlan: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let planID: PlanID
    public let taskID: ExecutionTaskID
    public let goal: String
    public let requestedScopes: Set<ExecutionScope>
    public let actions: [ExecutableAction]
}

public struct ExecutableAction: Codable, Equatable, Sendable, Identifiable {
    public let actionID: ActionID
    public let target: ActionTarget
    public let timeout: Duration
    public let approvalRequirement: ApprovalRequirement
    public let idempotency: IdempotencyKey
    public let postcondition: Postcondition
    public let verification: VerificationSpec
    public let operation: Operation

    public var id: ActionID { actionID }

    public enum Operation: Codable, Equatable, Sendable {
        case computer(ComputerOperation)
        case integration(IntegrationOperation)
        case sandboxedShell(SandboxedShellOperation)
        case localTransform(LocalTransformOperation)
        case askUser(AskUserOperation)
    }
}
```

`PlanID`, `ExecutionTaskID`, `ActionID`, `ExecutionScope`, `Duration`, and `IdempotencyKey` are validated value types. `Duration` rejects zero, negative, non-finite, and out-of-policy values. Action IDs are unique within a plan. The plan constructor rejects duplicate IDs, empty goals, unsupported schema versions, actions whose target is incompatible with their operation, and requested scopes that do not cover the operation.

`ApprovalRequirement` is part of the immutable action and says what authority the action requires. `ApprovalGrant` is a separate runtime value issued after the user or policy owner approves; it contains the approved plan ID, task ID, action ID, exact target fingerprint, scope, grant identity, and issuance time. The executor accepts only a matching grant. A plan never embeds a granted identity or issuance time.

`ExecutionTaskID` is the runtime-owned representation of the task identity. `PerryGuide.TaskID` is converted to it at the Guide-to-Runtimes boundary; `PerryRuntimes` does not import `PerryGuide`.

`ActionTarget` is a closed identity type:

```swift
public enum ActionTarget: Codable, Equatable, Sendable {
    case none
    case window(WindowIdentity)
    case workspace(WorkspaceIdentity)
    case integration(IntegrationIdentity)
    case sandbox(SandboxIdentity)
}

public struct ExecutionTaskID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String
}

public struct ExecutionResourceClaim: Codable, Equatable, Sendable {
    public let resources: Set<ExecutionScope>
}

public struct WindowIdentity: Codable, Equatable, Sendable {
    public let bundleID: String
    public let processID: Int
    public let windowID: Int
    public let connectionGeneration: Int
}
```

Every executable window action carries the exact `bundleID`, `processID`, `windowID`, and `connectionGeneration`. A stable ID, label, or title can be used to resolve a target before admission, but it is not the persisted target identity and cannot authorize a later substitution. A stale connection generation is a typed stale-target failure requiring explicit replanning or reconciliation; the CUA executor may not resolve a generic label again and choose another window. Coordinates are part of `ComputerOperation` and carry their coordinate space.

### Case-specific executable data

The cases contain the values the executor needs. They do not contain a raw payload or a generic provider path.

```swift
public enum ComputerOperation: Codable, Equatable, Sendable {
    case click(target: ComputerTarget)
    case typeText(text: String, target: ComputerTarget)
    case rightClick(target: ComputerTarget)
    case doubleClick(target: ComputerTarget)
    case scroll(direction: ScrollDirection, amount: Int, by: ScrollUnit, target: ComputerTarget?)
    case pressKey(key: Key, modifiers: Set<KeyModifier>, target: ComputerTarget?)
    case hotkey(modifiers: Set<KeyModifier>, key: Key, target: ComputerTarget?)
    case drag(from: WindowPoint, to: WindowPoint, durationMilliseconds: Int, steps: Int)
}

public enum IntegrationOperation: Codable, Equatable, Sendable {
    case notion(NotionOperation)
    case slack(SlackOperation)
    case linear(LinearOperation)
}

public enum NotionOperation: Codable, Equatable, Sendable {
    case createPage(parentID: ProviderID, title: String)
    case updatePage(pageID: ProviderID, title: String)
    case appendBlock(blockID: ProviderID, text: String)
}

public enum SlackOperation: Codable, Equatable, Sendable {
    case sendMessage(channel: ProviderID, text: String)
}

public enum LinearOperation: Codable, Equatable, Sendable {
    case updateIssue(issueID: ProviderID, title: String)
}

public struct SandboxedShellOperation: Codable, Equatable, Sendable {
    public let sandbox: SandboxIdentity
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: WorkspaceIdentity?
}

public enum LocalTransformOperation: Codable, Equatable, Sendable {
    case createUTF8File(path: WorkspacePath, contents: String)
    case createDirectory(path: WorkspacePath)
    case rename(path: WorkspacePath, destination: WorkspacePath)
    case moveToTrash(path: WorkspacePath)
}

public struct AskUserOperation: Codable, Equatable, Sendable {
    public let questionID: String
    public let prompt: String
    public let choices: [String]
}
```

`ComputerOperation` is the canonical home for the existing `ComputerAction` shape. The current App type moves behind this boundary or becomes a compatibility initializer. `LocalTransformOperation` absorbs the private `WorkspaceFileAction` cases. `IntegrationOperation` absorbs the currently supported `RemoteIntegrationWriteParameters` catalog. M1 does not claim to model the full M6 catalog; later provider-specific cases add typed operations and executors without introducing generic GraphQL, arbitrary URLs, or provider paths into the plan.

`Postcondition` and `VerificationSpec` are also closed values. Examples include `fileContents(path, encoding: .utf8, digest)`, `windowContains(target, text)`, `integrationAcknowledged(providerOperation)`, and `userAnswered(questionID)`. A postcondition is not a free-form expected-result string. An executor returns a typed `ActionOutput`, and a verifier receives the action, output, captured evidence, and journal entry identity.

### Receipts and uncertainty

```swift
public struct ActionJournalEntry: Codable, Equatable, Sendable {
    public let entryID: UUID
    public let planID: PlanID
    public let taskID: ExecutionTaskID
    public let actionID: ActionID
    public let attemptID: UUID
    public let inputDigest: Digest
    public let state: JournalState
    public let targetFingerprint: Digest?
    public let output: ActionOutput?
}

public enum JournalState: Codable, Equatable, Sendable {
    case prepared
    case dispatched
    case verified
    case failed(reason: String)
    case uncertain(reason: String)
}

public struct ActionExecutionResult: Codable, Equatable, Sendable {
    public let attemptID: UUID
    public let output: ActionOutput?
    public let state: ExecutionResultState
}

public enum ExecutionResultState: Codable, Equatable, Sendable {
    case completed
    case failed(reason: String)
    case uncertain(reason: String)
}

public protocol ExecutablePlanRuntime: Sendable {
    func execute(
        action: ExecutableAction,
        approval: ApprovalGrant,
        resources: ExecutionResourceClaim
    ) async throws -> ActionExecutionResult
}

public protocol ActionJournal: Sendable {
    func prepare(plan: ExecutionPlan, action: ExecutableAction, approval: ApprovalGrant) async throws -> ActionJournalEntry
    func markDispatched(_ entry: ActionJournalEntry) async throws -> ActionJournalEntry
    func record(_ result: ActionExecutionResult, for plan: ExecutionPlan, actionID: ActionID) async throws -> ActionJournalEntry
    func markVerified(_ entry: ActionJournalEntry, evidence: VerificationEvidence) async throws -> ActionJournalEntry
}
```

The `TaskCoordinator` owns the durable action journal. It records `prepared` before dispatch, transitions the same entry to `dispatched` immediately before the effect, and records `verified` only after the verifier succeeds. The runtime returns a transient `ActionExecutionResult`; it does not persist an independent receipt or advance a checkpoint. Cancellation after `prepared` or `dispatched` records intent and preserves the exact in-flight action. A timeout, crash, lost response, or failed stop produces `.uncertain`; relaunch never replays it automatically. Reconciliation either marks the coordinator entry verified with evidence or leaves the task inspectable and non-resumable.

The coordinator is the sole durable owner of journal entries, task checkpoints, approval state, cancellation, and recovery disposition. The runtime owns only effect execution and transient result production. `ResumableTaskRunner` coordinates the calls and never manufactures a journal entry or decides that an uncertain effect is safe to repeat. Resource claims are attached to the prepared action and released only after execution termination or explicit reconciliation.

### Serialization and adapters

`ExecutionPlan` is `Codable` and has its own `schemaVersion`. The codec is in `PerryRuntimes`, next to the action algebra. Its decoder parses external JSON once into `ExecutionPlan`; unknown enum cases, missing required fields, invalid numeric values, mismatched targets, and extra executable data that cannot be interpreted are errors. Unknown planner output never becomes an autonomous action.

The compatibility adapter is one-way at the production boundary:

```swift
public enum LegacyPlanAdapter {
    public static func migrate(
        legacy: Plan,
        taskID: ExecutionTaskID,
        planID: PlanID
    ) throws -> ExecutionPlan

    public static func legacyStep(
        for action: ExecutableAction
    ) throws -> Step
}
```

`migrate` is lossless for supported legacy kinds and preserves the original step ID as `actionID`, every executable payload value, approval-relevant target data, and checkpoint identity. A legacy `delegate` migrates only when the payload contains an explicit executable, argument vector, sandbox identity, and authority that can be represented by `SandboxedShellOperation`. A delegate containing only task prose, a target path, or an opaque CLI request is insufficient authority: the original record is retained and explicitly retired from automatic execution. `legacyStep` exists only while an old executor remains; it serializes the typed operation back to the legacy shape without making the dictionary the source of truth. The adapter is deleted once all production runtimes accept `ExecutableAction`.

## Module map

| Module | Owns | Does not own |
| --- | --- | --- |
| `PerryCore` | Trust tiers, generic approval scopes, idempotency policy primitives, generic capability policy | Executable action parameters, provider payloads, task persistence |
| `PerryRuntimes` | `ExecutionPlan`, action algebra, value types, codec, legacy migration, journal boundary, runtime execution boundary | UI approval prompts, task-store file layout, provider connector credentials |
| `PerryGuide` | `TaskRecord`, v1/v2/v3 task envelope, checkpoints, approvals, cancellation, recovery disposition, conditional admission, `PerryGuide.TaskID` to `ExecutionTaskID` mapping | Parsing provider JSON, target resolution, effect journal ownership |
| App CUA layer | CUA process ownership, target freshness, typed `ComputerOperation` execution | Reconstructing actions from dictionaries, approval policy |
| `WorkspaceFileRuntime` | Workspace confinement and typed local transforms | Plan parsing and task lifecycle |
| Remote integration runtime | Provider authentication and typed provider operation execution | Generic GraphQL or arbitrary provider paths |
| Verifiers | Postcondition evidence and typed verification result | Advancing task checkpoints without coordinator authority |

The deep interface is `ExecutablePlanRuntime.execute(action:approval:resources:)`. It hides driver, filesystem, provider, and process mechanics behind one typed operation and one transient result. Callers still see the action, approval, and resource claim because those are the authority inputs; they do not see wire dictionaries, target-refresh loops, or provider serialization.

## Exact migration and deletion sequence

1. Add the canonical `PerryRuntimes.ExecutionPlan` and action codec without changing `TaskRecord`. Add round-trip tests for every operation and reject unknown or incomplete actions.
2. Add a `TaskRecord` v3 envelope that stores the canonical plan, `planID`, `taskID`, requested scopes, action IDs, checkpoint action ID, suspended approval action ID, cancellation intent, recovery disposition, and retained journal entries. Keep the existing v1/v2 decoder intact.
3. Decode v1/v2 records into the legacy `Plan`, then run `LegacyPlanAdapter.migrate`. Supported records retain exact IDs, payload values, checkpoint indexes, suspended approvals, cancellation intent, in-flight action IDs, and reconciliation state. A delegate is supported only with explicit executable, arguments, sandbox, and authority fields. The migrated v3 record is written atomically before it is eligible for execution.
4. If any legacy step is ambiguous, unsupported, malformed, missing an effectful parameter, contains only delegate prose, or cannot preserve its checkpoint or approval identity, retain the original record and mark it explicitly retired and non-resumable with a recoverable migration disposition. Do not invent parameters from summaries and do not delete the record automatically.
5. Change planner protocols so production planners return `ExecutionPlan`. Local planners remain the first choice; provider fallback returns the same typed plan or fails with a typed planning error. The planner may not return an unknown action envelope.
6. Change approval to receive the canonical plan and action. Persist the approval fingerprint against `planID`, `taskID`, `actionID`, target identity, requested scope, and action digest.
7. Change `DoSupervisor` and `ResumableTaskRunner` to iterate canonical actions. `beginStep` becomes `beginAction` and persists the action ID before the runtime call. Completion consumes a matching journal entry and verifier result.
8. Change `WorkspaceFileRuntime`, the CUA worker, and remote integration executor to accept their typed operation. Keep the legacy executor adapter only for untouched callers and tests.
9. Change `TaskCoordinator` persistence validation so a checkpoint must name an existing action, an approval must name the suspended action, and an uncertain journal entry cannot enter an automatic resume path. Preserve explicit cancellation and reconciliation transitions.
10. Remove `PerryCore.AgentAction`, `ExecutionPlanAdapter`, `BoundAction.step`, `StepActionMapper` execution use, and the production `AgentRuntime.execute(Step, consent:)` requirement after all production callers have moved. Keep a test-only legacy decoder only for the documented v1/v2 migration fixtures, then delete it when the retention window ends.

## Required traces

### UTF-8 file creation

The local planner emits an action with `LocalTransformOperation.createUTF8File(path: "report.txt", contents: exactString)`, a workspace target, a file postcondition, a task approval scope, and a non-repeating idempotency key. The codec serializes the case, path, and exact Unicode string. Reload reconstructs the same operation and digest. Approval matches the plan and action IDs. The runtime writes `Data(contents.utf8)` inside the claimed workspace. The coordinator journal records the digest and completed state. The verifier reads the file as UTF-8 and confirms the postcondition before `completeAction` advances the checkpoint.

### Exact-window GUI action

The planner emits a `ComputerOperation.click` with a `WindowIdentity` containing the exact bundle ID, process ID, window ID, and connection generation, plus any window-pixel coordinates required by the operation. Approval fingerprints that identity. The CUA worker validates the same identity before capture or effect, claims the application resource, and executes the typed operation. A stale generation, different bundle, different process, different window, or unsupported coordinate space returns a typed failure; it does not re-resolve a generic label or fall back to the frontmost process.

### Approved integration write

The planner emits a provider-specific `IntegrationOperation`, such as `notion(.createPage(parentID:title:))`, with the integration scope in `requestedScopes`. Approval binds the exact provider operation and action digest. The integration runtime converts the typed case into its private HTTP request, claims the integration resource, and returns a transient result. The coordinator records the result in its journal. The plan never stores a generic GraphQL query, arbitrary path, or untyped body. A provider response that cannot satisfy the operation’s typed acknowledgment fails closed and leaves the action uncompleted.

### Malformed plan

The decoder rejects an unknown operation case, missing required action parameter, empty provider identifier, non-finite coordinate, invalid timeout, duplicate action ID, unsupported schema version, mismatched target, or approval scope that does not cover the operation. No target refresh, credential lookup, resource claim, capture, filesystem call, or provider request occurs before decoding and validation complete.

### Crash after dispatch

The coordinator writes the action ID and `prepared` journal entry before dispatch, then records `dispatched` before the effect. If the process dies after dispatch and before completion, relaunch preserves the task, exact action ID, journal state, checkpoint, approval, and cancellation intent. Recovery marks the action uncertain and blocks automatic resume. Reconciliation can inspect a file, target, or provider acknowledgment and then record a verified journal entry. If reconciliation cannot establish the postcondition, the task remains retained for inspection; the executor never retries the effect because the operation is marked non-repeating in its idempotency policy.

## Synthesis decision

This candidate is intentionally a single typed executable model owned by `PerryRuntimes`, rather than a second metadata envelope in `PerryCore`. The ownership choice follows the existing runtime boundary: planners, executors, workspace actions, CUA actions, and provider writes already converge there. `PerryCore` remains reusable policy vocabulary, while runtime-specific executable data stays close to the code that validates and executes it.

## Tradeoffs accepted

- We accept a larger runtime model in exchange for making executable parameters, approvals, targets, and postconditions one persisted value.
- We accept explicit provider enum growth in exchange for rejecting generic paths and GraphQL-shaped autonomy.
- We accept a temporary legacy adapter in exchange for a lossless staged migration; the adapter has a deletion condition and is not a second source of truth.
- We accept retained uncertain records in exchange for never replaying an effect whose result is unknown.
- We accept typed postconditions that cover fewer operations initially in exchange for making unsupported verification visible instead of treating a string summary as proof.

## Alternatives considered

### Keep the canonical model in `PerryCore`

This would make the plan broadly reusable, but `PerryCore` would need to own CUA targets, workspace paths, provider operations, sandbox identities, and receipts or leak those decisions back into runtimes. That creates a shallow shared model and duplicates the current executor precedents. It loses on ownership and interface depth.

### Keep `ExecutionPlan` as metadata and add a typed parameter map

This preserves the existing adapter shape but leaves execution semantics split between typed fields and a dictionary. Persistence, approval, and verification would still have to rediscover operation parameters. It is the metadata-wrapper design this contract excludes.

### Create one protocol per executor with a shared plan envelope

This hides less than the canonical action algebra and makes approval, checkpoint, and receipt handling vary by executor. It also forces `TaskCoordinator` and `DoSupervisor` to know several action protocols. It loses because the stable boundary is the action plus receipt, not each transport.

## Open questions and risks

- Should `TaskRecord` v3 embed the canonical plan directly, or store a versioned plan blob addressed by `planID` while retaining a compact task index?
- Which existing `PerryCore` policy types are stable enough to keep source-compatible, and which should move into `PerryRuntimes` with the executable model?
- Should reconciliation be a runtime-owned operation with typed evidence, or a coordinator transition that accepts a verifier-produced receipt?
- Which M1 provider operations are required for release, and which enum cases should remain unavailable until M6?
- What retention policy allows old v1/v2 records to be migrated without deleting ambiguous records before the user can inspect them?

## Next implementation step

Define the `PerryRuntimes` action algebra and codec first, then write lossless v1/v2 migration fixtures before changing any planner or executor protocol.
