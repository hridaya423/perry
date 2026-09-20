# Execution lifecycle verification

The execution session stores its lifecycle as a single enum. Awaiting approval carries the approval ID; finalizing carries the terminal phase and cannot retain an approval. The initializer accepts that typed lifecycle instead of independent phase, finalized, and approval fields.

AppController rejects events for another task or a finalizing task. For events that change the session, it projects the corresponding activity UI only after the session transition succeeds. Pause and resume events now update the session as well as the activity panel.

Independent review identified that a late step receipt could restore the working UI after pause or Stop. SessionController now admits new steps only while running; paused and stopping sessions still accept verification for a previously admitted step. AppController also rejects stale starting and steering UI updates. A second finding showed that generic phase changes could clear approval without an ID. Only `acceptApproval(id:)` now permits the approval-to-running transition.

SessionController also owns the finalization decision. It returns the execution snapshot and resolved outcome together. A Stop admitted before finalization changes a late completed outcome into stopped, with an explicit explanation that completed actions were not undone. A completion committed before dismissal remains complete. Premature completion in the starting or awaiting-approval states becomes a failed outcome, allowing normal failure reporting and cleanup. AppController uses the resolved outcome for the finalizer, activity UI, and its return value; it no longer chooses a finalization phase independently.

DoSupervisor awaits its event callback, and the foreground app awaits the main-actor handler directly. The confirmation request reaches the session before the confirmer checks it, and the final event is handled before the run returns to finalization. An accepted confirmation carries its approval ID; SessionController rejects stale or repeated acceptance and transitions the matching task back to running. The app no longer infers approval acceptance from the next step starting.

The supervisor checks the pause/cancellation boundary again after presenting a step and checks cancellation after delivering confirmation events. These checks prevent a cancellation received during the new callback suspension from proceeding into an action or opening a confirmation.

The executor dispatch boundary also waits for pause/resume and checks cancellation. A regression test reproduced an action running while approval acceptance was suspended and the task was paused: before the dispatch check, the executor ran once and the supervisor then rejected completion from its paused state. With the dispatch check, the executor remains idle until resume and the task completes normally. The failing run is recorded in `/tmp/perry-approval-pause-red-20260831.log`.

Cancelling the task that owns a run now exits the start-window and pause loops, rather than swallowing sleep cancellation and continuing to wait. Cancellation also propagates into the active planning child. Three regression tests each failed their 500 ms completion deadline before these fixes; their cleanup issued a separate supervisor Stop so no test worker remained running. The failing logs are `/tmp/perry-parent-cancellation-red-20260831.log` and `/tmp/perry-planner-parent-cancellation-red-20260831.log`.

Two regression tests exercise the SessionController boundary. Finalizing an approval retires that approval, rejects late evidence and state updates, and still permits reporting. A startup failure can finalize before the runtime enters its running phase.

Further tests cover stale and repeated approval acceptance, receipt ordering through a complete approved action, and cancellation while a step-event consumer is suspended. The suspended-consumer test asserts that the executor runs zero actions.

## Evidence

On 31 August 2026, the arm64 Perry app test suite passed 197 tests with zero failures and zero skipped tests on macOS 26.5.1. The command was:

```sh
xcodebuild test -quiet -project Perry.xcodeproj -scheme Perry -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO
```

The result bundle is `/Users/hridyaagrawal/Library/Developer/Xcode/DerivedData/Perry-dbedeyvgtejrpvaqzbsiwlrlfdhq/Logs/Test/Test-Perry-2026.08.31_09-20-47-+0100.xcresult`. The command log is `/tmp/perry-session-lifecycle-20260831.log`. `git diff --check` passed.

After awaited delivery and explicit approval acceptance were added, the same app test command passed 198 tests with zero failures or skips. The result bundle is `/Users/hridyaagrawal/Library/Developer/Xcode/DerivedData/Perry-dbedeyvgtejrpvaqzbsiwlrlfdhq/Logs/Test/Test-Perry-2026.08.31_09-26-18-+0100.xcresult`, with log `/tmp/perry-approval-receipts-app-20260831.log`.

`swift test --package-path Packages/PerryRuntimes` passed 96 tests with zero failures; seven authenticated-provider smoke tests were skipped because their opt-in environment flags were not enabled. The runtime log is `/tmp/perry-approval-receipts-runtime-20260831.log`. These skipped tests do not establish live authentication or provider functionality.

After the dispatch-boundary fix, the runtime suite passed 97 tests with the same seven live-provider skips and zero failures. The log is `/tmp/perry-approval-pause-green-20260831.log`.

After parent-task cancellation was repaired, the runtime suite passed 100 tests with seven live-provider skips and zero failures. All three cancellation fixtures completed within their 500 ms test deadlines. The final log is `/tmp/perry-planner-parent-cancellation-green-20260831.log`. These deterministic fixtures do not establish cancellation latency for every live provider or a consumer that ignores cancellation.

The dependent PerryGuide suite did not reach its tests. Its first incremental link retained a FinderTaskSuiteTests object referencing the old synchronous callback initializer; after that generated object was removed for recompilation, SDK module generation failed with `No space left on device`. Logs are `/tmp/perry-approval-pause-guide-20260831.log` and `/tmp/perry-approval-pause-guide-rebuilt-20260831.log`. The failed build's regenerable ModuleCache was removed; source and logs were preserved. PerryGuide must be rebuilt and tested after sufficient disk space is available.

The bundled-Codex live smoke was explicitly enabled and invoked with `--skip-build`, using Perry's own runtime home. The binary SHA-256 matched `scripts/codex-runtime.lock`. Codex's official login-status command reported that this runtime was not signed in, so the test skipped without a planning request. The log is `/tmp/perry-bundled-codex-live-20260831.log`; this is an authentication prerequisite result, not a passed planning smoke.

With full app builds constrained by disk space, a temporary standalone check compiled the actual `App/SessionController.swift` using the existing Xcode module cache. It first failed because a paused session admitted a late step, then passed checks for paused/stopping step rejection, retained in-flight verification, and ID-bound approval acceptance. Logs are `/tmp/perry-session-admission-red-20260831.log` and `/tmp/perry-session-admission-green-20260831.log`. Matching regressions were added to `AppTests/SessionControllerTests.swift`; that updated XCTest suite and the AppController UI changes have not yet been rebuilt or run. The temporary check is not a substitute for those tests.

A second standalone check linked the actual session controller against existing PerryRuntimes/PerryCore objects and passed the Stop/completion ordering, retained evidence, invalid-completion, and committed-outcome cases. Its log is `/tmp/perry-finalization-outcome-check-20260831.log`. SessionController typechecking, AppController parsing, and typechecking the updated SessionControllerTests against a temporary testable module passed. The test typecheck used Xcode's XCTest framework and Swift support-module search paths; initial attempts without those paths failed to import the Swift XCTest API. No full app test result is claimed for these changes.

## Approval cancellation and reporting rerun

Task reporting no longer assumes all actions ran in a sandbox. Whole-task verification is true only when every recorded step has successful verification evidence; partial or absent evidence remains unknown, and an explicit failure remains false. A focused executable compiled the actual SessionController and ExecutionFinalizer against existing package objects and passed all four evidence cases. Its log is `/tmp/perry-finalizer-report-check-20260831.log`. Test-only actors satisfied the unused Cua and telemetry extension declarations; this check exercised report construction, not persistence, Cua, telemetry, or UI. The temporary executable and fixture source were removed. Matching XCTest regressions subsequently passed in the app-suite rerun.

The foreground approval wait now installs a task-cancellation handler. It closes only the IntentCardWindow carrying the cancelled approval ID, and an old window's completion no longer clears a replacement window. A passing regression in `OnboardingWindowTests` waits for the real prompt, cancels the owning task, and asserts a false response and a closed window within 500 ms. DoSupervisor owns a cancellable confirmation child and propagates both explicit Stop and parent-task cancellation into that child. Four runtime tests cover plan/action approval for both cancellation sources and assert no accepted event and zero executor calls.

The cancellation audit and approval-label fixes passed a parent rerun of `swift test --package-path Packages/PerryRuntimes`: 110 tests total, 103 passed, seven live-provider tests skipped, zero failures. The log is `/tmp/perry-resumed-runtime-20260831.log`. The suspended-verification test verifies that cancellation preserves the successful action's confirmed, verified activity entry. The plan-approval tests distinguish cancellation during acceptance from explicit denial and assert that neither dispatches an action.

After disk space increased, the full app suite passed 206 tests with zero failures or skips. The result bundle is `/Users/hridyaagrawal/Library/Developer/Xcode/DerivedData/Perry-dbedeyvgtejrpvaqzbsiwlrlfdhq/Logs/Test/Test-Perry-2026.08.31_10-08-13-+0100.xcresult`; the log is `/tmp/perry-approval-finalization-app-20260831.log`. This run includes the finalization outcome, approval-window cancellation, and partial-verification regressions.

The guide package passed all 102 tests after rebuilding with the existing Xcode SDK module cache:

```sh
swift test --package-path Packages/PerryGuide -Xswiftc -module-cache-path -Xswiftc /Users/hridyaagrawal/Library/Developer/Xcode/DerivedData/ModuleCache.noindex
```

Its log is `/tmp/perry-approval-finalization-guide-20260831.log`. The runtime package rerun passed 107 tests, with seven live-provider skips and zero failures, in `/tmp/perry-approval-owner-cancellation-20260831.log`. Independent read-only review confirmed the finalization outcome and approval-ID fixes and found no concrete defect in the scoped window cancellation or reporting changes.

The four new runtime fixtures use a two-second XCTest deadline to wait for approval presentation instead of an unbounded continuation. The suite passed again with the same 107 passes and seven skips; the log is `/tmp/perry-approval-cancellation-bounded-fixtures-20260831.log`.

## Remaining work

These runs used the existing development worktree and unsigned Debug test host. They do not establish clean-checkout reproducibility, authenticated end-to-end approval behavior, cancellation latency for every worker, or M1 completion. The real-window test does not cover simultaneous approval and cancellation or a replacement-window race. AppController still owns execution policy that must move behind the session boundary. Awaited delivery removes the per-event task backlog; it does not establish a latency bound for an arbitrary event consumer.
