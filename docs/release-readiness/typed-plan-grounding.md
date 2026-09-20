# Typed execution-plan migration

The M1 release requirement is a versioned, executable plan whose typed actions survive planning, approval, persistence, execution, and verification. Adding metadata around `Step.payload` does not meet that requirement. This document records the current boundary before selecting a replacement design; it is not an implementation or release-evidence claim.

## Current flow

`TaskPlanner.plan` returns `PerryRuntimes.Plan`, containing `Step` values with a kind and string dictionary. `DoSupervisor.run(goal:runtime:)` wraps that plan in `ExecutionPlanAdapter(legacyPlan:)`. Each bound action retains both the legacy step, including its payload, and a metadata-only `PerryCore.AgentAction`. Execution and verification still consume the step. See [AgentRuntime.swift](../../Packages/PerryRuntimes/Sources/PerryRuntimes/AgentRuntime.swift), [RuntimeTypes.swift](../../Packages/PerryRuntimes/Sources/PerryRuntimes/RuntimeTypes.swift), and [DoSupervisor.swift](../../Packages/PerryRuntimes/Sources/PerryRuntimes/DoSupervisor.swift).

The separate `ExecutionPlanAdapter(ExecutionPlan)` initializer reconstructs steps from action kinds and metadata. `AgentAction` has no executable parameters, so this initializer cannot reconstruct file contents, GUI targets, or integration operations. The `migrateLegacy` convenience returns only the metadata plan. Current source searches found its use in a test, not in production persistence. This is a migration hazard, not evidence that the shipping persistence path has already lost parameters.

Background persistence uses `TaskRecord` and its private `PersistedTaskStep`, retaining the original step ID, kind, summary, and payload. The store has schema versions 1 and 2; decoding rejects unknown step kinds and inconsistent checkpoints. `ResumableTaskRunner` executes remaining steps through checkpointing adapters and `DoSupervisor`. The migration must preserve suspended approvals, in-flight uncertainty, cancellation intent, and the next-step index. See [TaskCoordinator.swift](../../Packages/PerryGuide/Sources/PerryGuide/TaskCoordinator.swift) and [ResumableTaskRunner.swift](../../Packages/PerryGuide/Sources/PerryGuide/ResumableTaskRunner.swift).

The unrelated `ExecutionPlanMigrationDecoder` accepts textual summaries and assigns them all `readWindow`. It does not decode the production task-store format. Summary text is insufficient to reconstruct an executable action; migration must retire such records explicitly rather than inventing parameters. See [ExecutionPlan.swift](../../Packages/PerryCore/Sources/PerryCore/ExecutionPlan.swift).

Computer and workspace executors already parse private typed actions at their execution boundaries. Their planner inputs and verifier inputs remain legacy steps. The replacement must connect these boundaries rather than add another parallel action representation.

The current integration write boundary has typed parameters for three Notion operations, Slack posting, and Linear issue updates. `RemoteIntegrationActionRuntime` still accepts raw steps, resolves generic method/path/body fields, and constructs the typed request before approval enforcement. Reads remain generic request shapes. The replacement must keep provider wire details inside adapters and must not claim that this partial catalog implements the full M6 operation set. See [RemoteIntegrations.swift](../../App/RemoteIntegrations.swift).

## Required traces

Both design candidates must trace a file creation with exact UTF-8 contents through plan serialization, reload, approval, execution, and read-back. They must also trace an exact-window computer action, a typed integration write with task-scoped approval, an unknown planner action rejected before effects, and recovery after dispatch without verification. A shell action must name its sandbox and registered runtime rather than infer autonomous execution from unknown planner output.

The plan must contain stable plan and task identities, a schema version, requested approval scopes, and actions whose effects and postconditions are explicit. A supported legacy record must retain every execution-relevant value; an unsupported or ambiguous record must stop with a recoverable explanation. Provider adapters may serialize dictionaries, but policy and execution must not depend on them.

## Historical evidence coverage

Source-control investigation found the original runtime interface sketch and later trust, routing, and sandbox constraints in commits `a472f6e`, `1c8e640`, `1c986d0`, `bc87379`, and `df65aab`. It did not establish why a dictionary was chosen or why the untracked metadata-only model omits executable parameters. The repository has no remote, and `gh` was unavailable, so PR review context could not be searched. The confidence-separated findings and migration constraints are recorded in [typed-plan-lineage.md](typed-plan-lineage.md).

Notion searches for Perry execution plans, AgentAction, legacy payloads, and architecture found no relevant document; meeting notes were unavailable behind the workspace's upgrade gate. Linear searches were unavailable because the connector was not authenticated. These gaps do not establish an original design rationale.

No dedicated team-chat, infrastructure-observability, exception-tracking, or analytics-warehouse search connector was found in the available tool inventory. Those historical records remain unsearched. The release specification supplied by the user is the current product contract; historical intent must not be invented from code structure.
