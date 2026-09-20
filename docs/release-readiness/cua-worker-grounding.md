# Cua worker ownership

This is design input for M1–M3, not release evidence. The current implementation has one Cua process shared by foreground execution, background tasks, guides, dictation, and health probes. A protocol session does not isolate a process or its pending requests.

## Current execution paths

AppController owns one CuaDriverClient at App/AppController.swift:138. That actor owns one Process, pipe pair, initialization task, generation counter, read buffer, and pending-request table. Session IDs select target snapshots inside the same actor. Exact window identity includes bundle ID, process ID, window ID, and connection generation.

A new background task probes permissions and Cua health, creates a workspace, captures a window, chooses a planner, persists the plan and target metadata, then constructs SupervisedAgentRuntime with the shared client. The three-task limit and resource reservation happen afterward in startBackgroundTask. Setup can therefore allocate resources before a run slot is available. Queue setup is an unretained Task; backgroundRunTasks contains execution wrappers, not setup tasks.

Resume checks the visible record, acquires a generation-tagged launch lease, rechecks the authoritative record, loads metadata, recaptures the exact target, selects a runtime, saves the route, and checks the lease again before launch. Cancellation invalidates that lease. Cleanup currently calls endSession using the task's stable session string, so a future per-task worker design must bind cleanup to the old worker instance rather than look up a replacement by task ID.

startBackgroundTask reserves application, workspace, and integration resources before starting its execution wrapper. The wrapper awaits ResumableTaskRunner.run, handles the outcome, releases resources, removes itself from backgroundRunTasks, reloads records, and starts queued work. Paused live supervisors remain inside their wrappers; approval suspension returns an outcome and removes the wrapper. A resumed approval therefore creates a new run for the exact suspended action.

Foreground beginDo uses the same client for health, capture, execution, and WorkspaceStepVerifier. cancelActiveTask cancels its DoSupervisor but does not stop a process. ExecutionFinalizer later calls endSession through ComputerUseSessionEnding. CuaGuideTreeReader also holds the shared client. Dictation insertion uses a stable perry-dictation session, and guides use perry-guide.

Configuration reload is guarded against active foreground and background execution, but the asynchronous reload does not reserve that idle state against new setup. Application termination shuts down the shared client. Complete erasure cancels wrapper tasks and awaits them before the Cua artifact eraser shuts down the client; a hanging child can delay reaching that shutdown.

## Cancellation and durable uncertainty

CuaDriverClient.sendRequest now cancels its local waiter promptly and ignores the late response. It does not stop the effect. ensureStarted shares an unstructured initialization task; a caller awaiting that task cannot promptly cancel the shared wait. shutdown closes pipes, cancels initialization, resumes pending requests, and sends TERM to the process. It does not wait for exit or escalate when TERM is ignored.

The pinned Cua 0.22.1 direct MCP loop processes calls serially and does not implement request cancellation. The upstream audit and links are recorded in [Cua request cancellation](cua-request-cancellation.md). Killing the shared worker would interrupt every session. endSession is another serialized RPC, so it cannot interrupt a hung action ahead of it.

TaskCoordinator.beginStep writes the in-flight action ID before base execution. CheckpointingVerifier clears it only after verification for effectful actions. requestCancellation persists cancellation intent before DoSupervisor.cancel cancels its child tasks. That ordering must survive the ownership change.

There is a record-retention defect: after a blocked cancelled run, ResumableTaskRunner calls TaskCoordinator.cancel, whose finish path removes the record even if the in-flight marker remains. The non-running cancellation path in AppController also discards the record. Automatic stop must retain uncertain actions for inspection; explicit confirmed deletion remains a separate user action. A worker exit cannot prove an action was undone.

## Required design traces

The two candidate designs must cover these concrete flows:

1. Three unrelated tasks execute concurrently. Stopping task A terminates only A's worker, leaves B and C progressing, and retains A's uncertain receipt/checkpoint.
2. Cancellation during initialization, capture, runtime selection, or execution retires that attempt. Late setup cannot launch another process or publish a replacement result.
3. Approval suspension and resumption use the exact persisted action once. An old cleanup cannot stop the resumed worker. A paused live task keeps its own execution context.
4. A fourth task queues without consuming a fourth execution worker. Conflicting application, document/workspace, or integration resources stay reserved until the old worker has stopped.
5. Timeout, unexpected worker exit, configuration reload, application termination, and erasure stop or invalidate all affected workers before resources or artifacts are reused.

The process boundary must await bounded termination, reject further work after retirement, keep generation checks on readers and requests, and report failure when stopping cannot be established. It must not invent an unsupported MCP cancellation command or replay an uncertain action.

## Evidence and limits

Current source anchors: App/CuaDriverClient.swift:324–354, 639–785, 1076–1210; App/AppController.swift:836–869, 961–1060, 1113–1415, 1984–2127, 2236–2249, 2572–2580, 2713–2730; Packages/PerryGuide/Sources/PerryGuide/ResumableTaskRunner.swift:36–221; Packages/PerryGuide/Sources/PerryGuide/TaskCoordinator.swift:419–609; Packages/PerryRuntimes/Sources/PerryRuntimes/DoSupervisor.swift:189–203, 636–706, 772–826.

These are current-code mechanics, not claims about the original author's intent. CuaDriverClient is untracked in the salvage wave. Historical-source findings are tracked separately. No new process-isolation or live cancellation claim is supported yet.

The cancellation-record regression is reproduced in /tmp/perry-cancelled-checkpoint-before.log: testCancelledInFlightStepRetainsUncertaintyAcrossReload failed four assertions because both the live and reloaded coordinator had lost the cancelled task's record. The fixture enters execution through approval and the durable beginStep boundary, then acknowledges CancellationError. An unrelated queued record remains unchanged. This test does not exercise Cua or process termination.

## Historical constraints and search coverage

The historical reason for global Cua ownership is unknown. The source-control investigator found no Cua matches in the client's history or AppController pickaxe searches for CuaDriverClient, cuaDriver, and cuaSession. The three AppController commits df65aab, f208332, and 4e40344 contain the older accessibility reader, not Cua. Adjacent commits document Codex workspace confinement (df65aab), capture refusal before pixels exist (6162469), and removal of an inference proxy (1da82d2); none explains the global Cua client.

Linear's workspace probe failed because the connector was not connected, so no tickets were searchable. Notion was connected: 26 scoped Perry queries, including Perry Cua, Perry cancellation, Perry worker lifecycle, Perry Cua worker isolation, Perry direct MCP, and Perry postmortem, returned no relevant document. Thirty unrelated result entries were not opened. Meeting-note access required an upgrade. No dedicated searchable team-chat, infrastructure-observability, exception-tracking, or product-warehouse connector was available. These are coverage gaps, not evidence that no outside rationale exists.

The independent synthesis confirms that the process, pipes, pending requests, initialization, and generation must move together for worker isolation. Preserve the direct embedded boundary, exact targets, intent-before-stop persistence, action-scoped approval, and resource reservations until process exit. Bind retirement to a worker instance rather than a reusable task string. Do not infer that local waiter cancellation undid an external effect or that the uncommitted global client represents a deliberate historical decision.
