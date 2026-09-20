# M1 typed plan lineage

### The Question

What rationale and constraints must survive replacing legacy `Step` dictionaries with typed actions across planning, persistence, and execution? This synthesis separates the historical record from conclusions needed for the replacement model.

### The Code in Question

The historical boundary starts at `a472f6e: PRD.md:136-147`, where the runtime adapter sketch plans and executes `Step` values. `1c8e640` introduced `Step.payload: [String: String]` and `DoSupervisor`; `1c986d0`, `bc87379`, and `df65aab` added trust, routing, hardware, and runtime-sandbox constraints.

The current typed boundary is `Packages/PerryCore/Sources/PerryCore/ExecutionPlan.swift:51-123`, where `AgentAction` carries policy metadata but no executable parameters. `Packages/PerryRuntimes/Sources/PerryRuntimes/RuntimeTypes.swift:262-329` maps typed actions into legacy `Step` values, while `Packages/PerryGuide/Sources/PerryGuide/TaskCoordinator.swift:914-934` persists the legacy payload verbatim.

### What We Found

- **[Direct]** The PRD calls the original boundary a “Runtime adapter interface sketch” and defines `plan` and `execute` in terms of `Plan`, `Step`, `ScreenContext`, `ConsentHandle`, and `StepResult`. Source: `a472f6e: PRD.md:136-147`.
- **[Direct]** The first runtime-layer commit introduces `Step` with `id`, `kind`, `summary`, and `[String: String] payload`, then drives each plan step through the supervisor. Source: `1c8e640: Packages/PerryRuntimes/Sources/PerryRuntimes/RuntimeTypes.swift:50-85`; `1c8e640: Packages/PerryRuntimes/Sources/PerryRuntimes/DoSupervisor.swift:78-104`. The commit records the end-to-end demo and test result, but gives no rationale for choosing a dictionary.
- **[Direct]** The trust boundary requires typed confirmation for red-tier actions and rejects voice-only approval. The same commit records blocked-window denial in the Finder task suite. Sources: `1c986d0` commit message; `1c986d0: Packages/PerryGuide/Sources/PerryGuide/IntentCard.swift:56-68`; `1c986d0: Packages/PerryGuide/Tests/PerryGuideTests/FinderTaskSuiteTests.swift:65-81`.
- **[Direct]** The runtime ladder routes file and development work to a CLI, GUI grounding to a vision-capable cloud runtime, and offers local execution only when the hardware floor passes and the experimental flag is enabled. Sources: `bc87379` commit message; `bc87379: Packages/PerryGuide/Sources/PerryGuide/RuntimeLadder.swift:114-160`; `bc87379: Packages/PerryGuide/Sources/PerryGuide/HardwareAndKeys.swift:59-84`.
- **[Direct]** Codex planning uses `read-only` with `--ignore-user-config`, while execution uses `workspace-write`. Source: `df65aab` commit message; `df65aab: Packages/PerryRuntimes/Sources/PerryRuntimes/CodexRuntime.swift:40-76`.
- **[Direct]** The current task store writes `TaskRecord.plan`, including every persisted step's `id`, `kind`, `summary`, and raw payload, and reads both envelope versions 1 and 2. Sources: `Packages/PerryGuide/Sources/PerryGuide/TaskCoordinator.swift:100-240`; `Packages/PerryGuide/Sources/PerryGuide/TaskCoordinator.swift:914-965`.
- **[Direct]** The current typed `AgentAction` contains identity, kind, summary, timeout, approval scope, idempotency, expected result, and verification policy, but no target, text, path, body, or other executable parameter field. Source: `Packages/PerryCore/Sources/PerryCore/ExecutionPlan.swift:51-92`.
- **[Direct]** The typed adapter currently constructs a `Step` from typed metadata alone, while the legacy initializer explicitly preserves the old payload. Sources: `Packages/PerryRuntimes/Sources/PerryRuntimes/RuntimeTypes.swift:262-329`; `Packages/PerryRuntimes/Sources/PerryRuntimes/RuntimeTypes.swift:416-430`.

### What We Can Reasonably Infer

- **[Inferred]** The replacement must carry executable parameters as part of the typed lineage, not only policy metadata. Given the original runtime executes `Step` payloads, the current store persists those payloads, and only the legacy adapter preserves them, a metadata-only conversion would not be demonstrably lossless. This is a migration constraint, not evidence that data has already been lost.
- **[Inferred]** Typed actions should keep approval, idempotency, expected-result, and verification semantics adjacent to the action parameters. The later trust commit and the current `AgentAction` fields point toward one execution decision being persisted and checked together, while the historical record does not say whether that was the original intent.
- **[Inferred]** A safe migration needs an explicit disposition for every stored plan. The coordinator’s checkpoints identify the next step and in-flight side effect, so changing IDs, parameters, or policy defaults during decoding could change resumability or repeat a side effect. The evidence supports preserving the old plan or rejecting it for inspection; it does not choose a rollout mechanism.
- **[Inferred]** The local-first and fail-closed contract favors a typed action constructor or decoder that refuses missing parameters and unsupported kinds before execution. The routing and sandbox history establishes the safety direction, but no historical source specifies the typed error taxonomy.

### Competing Hypotheses

- **Hypothesis:** The typed model is a policy envelope over the existing executable payload.
  - **Evidence for:** The typed adapter maps every supported `AgentAction` into a legacy `Step`, and the legacy path preserves payload fields (`RuntimeTypes.swift:262-329`). The task store still treats the payload as persisted execution data (`TaskCoordinator.swift:914-934`).
  - **Evidence against or missing:** The typed `AgentAction` has no parameter container, and no commit or document states that the dictionary remains the source of truth.
- **Hypothesis:** The typed model is intended to retire the dictionary, with executable parameters to be added later.
  - **Evidence for:** `ExecutionPlan.swift` models policy and identity as typed fields without raw parameters, and the file is currently untracked, so its release status is not established.
  - **Evidence against or missing:** No historical rationale, migration record, or live-use evidence says that dropping payload data is intentional or safe. The current production task store still persists the full legacy payload.

### What We Don't Know

- No source-control text explains why `Step.payload` was chosen, whether it was a temporary bridge, or why the new typed model omits executable parameters. The current shape cannot answer its own motivation.
- No evidence establishes that metadata-only typed conversion is used by live persisted tasks, or that any payload has been lost. The current store evidence proves preservation of legacy payloads, not successful typed-plan rollout.
- No explicit decision says whether v1 and v2 task records will be losslessly migrated, retained as legacy plans, or deliberately retired. In particular, the current task envelope versions are not proof of an `ExecutionPlan` schema migration.
- No pull requests or remote review context were available: the repository has no git remotes and `gh` was unavailable. Linear was unavailable without authentication. Notion searches for `Perry`, `ExecutionPlan`, `AgentAction`, `legacyStep`, and `architecture` returned no relevant documents; meeting notes were upgrade-gated.
- No matching MCP was available for real-time chat, infrastructure observability, error tracking, or product analytics, so those records were not searched. The newly authored grounding note was not treated as independent historical evidence.

### Sources Consulted

- **Source control history**: spot-checked commits `a472f6e`, `1c8e640`, `1c986d0`, `bc87379`, and `df65aab`, including their messages and the cited historical file snapshots. No remotes or PR numbers were available; `gh` was unavailable.
- **Current repository code**: read `ExecutionPlan.swift`, the `ExecutionPlanAdapter` and legacy payload bridge in `RuntimeTypes.swift`, `TaskCoordinator.swift`, `ResumableTaskRunner.swift`, and the historical runtime files cited above. The current authored grounding note was excluded as historical evidence.
- **Issue / ticket tracker**: Linear was unavailable unauthenticated; no ticket evidence was available.
- **Long-form documents**: Notion workspace and AI searches for `Perry`, `ExecutionPlan`, `AgentAction`, `legacyStep`, and `architecture` found no relevant documents; meeting-note access was upgrade-gated.
- **Real-time team chat**: not searched. No matching MCP was available.
- **Infrastructure observability**: not searched. No matching MCP was available.
- **Error / exception tracking**: not searched. No matching MCP was available.
- **Product analytics warehouse**: not searched. No matching MCP was available.

### Confidence Summary

The original `Step`-based runtime boundary and the later trust, routing, hardware, and sandbox constraints are directly supported by the named commits and snapshots. The reason for the dictionary and the intended status of the metadata-only typed model remain unknown; preservation of executable payloads is a strong migration constraint, not proof of historical intent or live data loss.

### Preserve / Change / Avoid / Risk

These are constraints for the replacement typed model under the current M1 contract, not claims about undocumented historical motivation.

**Preserve**

- Preserve every executable value currently carried in `Step.payload`, including targets, stable IDs, text, file paths, file contents, remote integration data, and request bodies; a plan must remain executable after persistence and resume.
- Preserve stable action and step identity, checkpoint positions, in-flight markers, approval state, idempotency, expected results, and verification policy so a migration cannot authorize or repeat a different side effect.
- Preserve typed red confirmation, blocked-window denial, local-first routing, the local hardware and experimental gate, and fail-closed behavior when a required capability or parameter is absent.
- Preserve the planning/execution trust split: planning remains read-only, while an explicitly authorized execution path retains its existing workspace boundary.

**Change**

- Give each executable action a discriminated, case-specific parameter value and validate it at the plan boundary; do not leave new execution semantics in an unvalidated string dictionary.
- Version the typed plan separately from the task envelope and define a lossless decoder for v1/v2 legacy records, or explicitly retain and reject records that cannot be migrated.
- Keep any legacy bridge at one boundary. It may serialize typed parameters for old executors, but it must preserve payloads, IDs, and policy fields rather than rebuilding them from summaries.
- Make planning, persistence, and execution consume the same typed action lineage, with tests covering round trips and resumed actions for every supported parameter shape.

**Avoid**

- Avoid a metadata-only conversion that cannot reconstruct the target, path, text, contents, remote body, or other operation-specific parameters.
- Avoid guessing missing parameters from summaries, expected-result text, runtime IDs, or policy metadata, and avoid silently applying weaker defaults.
- Avoid rewriting or deleting v1/v2 records without a documented migration disposition, and avoid presenting the absence of observed loss as proof that loss is impossible.
- Avoid parallel plan protocols and duplicate adapters that let policy and executable data drift apart; the evidence supports one typed lineage with a narrow compatibility boundary.

**Risk**

- Silent payload loss can leave a persisted task looking resumable while changing what it would execute; no evidence shows that this has happened in production, so the risk must remain explicit rather than asserted as an incident.
- Identity or policy drift during migration can invalidate an approval or repeat an uncertain side effect, because the existing coordinator ties checkpoints to step IDs and state.
- Keeping both typed and legacy representations indefinitely can create divergent defaults and routing decisions; the migration boundary needs an explicit owner and retirement condition.
