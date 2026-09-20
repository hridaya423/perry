# Subprocess lifetime evidence

Owner: Runtime/Execution. Scope: M1 cancellation and M4 subprocess capture. Environment: Apple Silicon macOS 26.5.1, dirty development checkout. Status: deterministic tests, not release-proven runtime behavior.

## Reproduced failures

The direct process runner attempted launch even when its task was already canceled. A nonexistent fixture executable produced a Cocoa launch error instead of cancellation. A separate shell fixture exited while a child retained its output descriptors; the runner returned success after 2.015 seconds despite a 100 ms timeout. Both failures are recorded in /tmp/perry-process-lifetime-before-20260831.log.

A child that ignored SIGTERM also survived cancellation after its parent exited. The resistant-descendant test observed the child still alive after 500 ms and killed that fixture child during cleanup. Log: /tmp/perry-process-resistant-child-before-20260831.log.

A shell that handled SIGTERM by exiting zero returned a successful result after Perry terminated it for exceeding its deadline. The regression failed with exit code zero in /tmp/perry-timeout-zero-before.log. A timeout must remain a failure regardless of the termination handler's exit status.

## Current behavior

CLIRuntime.runProcess checks cancellation before launch and retains one reader per output stream. The readers report EOF and overflow through locked buffers; the process runner no longer performs a blocking final read. A successful result requires the parent to exit and both streams to reach EOF.

Each stream defaults to a 16 MiB capture limit. Overflow fails with a fixed error rather than returning truncated planner output. Invalid UTF-8 also fails instead of silently becoming an empty string. The limit applies to retained bytes, not total process RSS or subsequent string allocations.

The monotonic timeout covers process execution and output draining. Reaching the deadline without a complete result throws an execution or output timeout; the error path stops the owned processes, allowing up to 250 ms before forced termination. The runner never accepts output from a command it terminated for timeout, even if its termination handler exits zero. Cancellation follows the same owned-process cleanup path.

When the newly launched process is observed leading its own process group, Perry records that group. Cleanup targets that group and escalates surviving members even after the parent exits. Signal failures are reported rather than treated as successful cancellation. The runner does not scan or signal unrelated processes.

The existing FileHandle readers remain the only stream consumers. Apple documents that [clearing the readability handler cancels its dispatch source](https://developer.apple.com/documentation/foundation/filehandle/readabilityhandler); cleanup now does so on every exit. Apple also documents [termination of a process and its subtasks](https://developer.apple.com/documentation/foundation/process/terminate()). The resistant-child fixture demonstrates why a bounded escalation step is still necessary.

## Tests and limits

Thirteen CLIProcessLifetimeTests cover pre-cancellation, timeout followed by a zero exit, natural completion observed after the deadline, inherited descriptors, exact trailing bytes on both streams, exact-limit output, overflow on either stream, invalid UTF-8, direct-worker termination and reaping, process-group identity, cooperative descendants, SIGTERM-resistant descendants, and recovery from a failed termination signal. Cancellation timing assertions include child disappearance within 500 ms.

Independent review found that accepting EOF before checking the deadline still allowed a naturally exiting process to return late success. A 3 ms sleep under a 1 ms deadline reproduced that failure in /tmp/perry-timeout-natural-before.log. Deadline checking now precedes result acceptance. The runtime suite then passed 143 tests, skipped ten live tests, and had zero failures (153 total), recorded in /tmp/perry-timeout-reviewed-runtime.log. The bound applies to when Perry observes completion; scheduling delays can therefore reject a process that exited earlier.

The reviewer confirmed the corrected ordering. The small-timeout fixture can also pass because launch setup exhausts its deadline; it reproduced the old bug on this machine but does not deterministically isolate that poll interleaving on every run.

After the timeout correction, the runtime package suite passed 142 tests, skipped ten opt-in live tests, and had zero failures (152 total). Log: /tmp/perry-timeout-final-runtime.log. The ordinary sleep timeout test also requires an execution error rather than a termination exit code.

The app regression run after that correction passed 230 tests, skipped two live Cua tests, and had zero failures (232 total). Evidence: Test-Perry-2026.08.31_12-32-47-+0100.xcresult and /tmp/perry-timeout-final-app.log. This was an unsigned Debug run in the development checkout; the earlier Release build below predates the timeout correction.

The resistant-child fixture passed in 0.279 seconds after escalation was added; the inherited-pipe fixture passed in 0.113 seconds. These are individual fixture durations, not latency percentiles or cross-machine benchmarks. Log: /tmp/perry-process-lifetime-group-20260831.log.

Independent review found that an error sending SIGTERM could skip forced cleanup. Cleanup now records signal failures and still attempts SIGKILL. A test rejects SIGTERM through an injected signal function, permits the real SIGKILL, and requires the worker to stop. If the final cleanup fails, that failure intentionally takes precedence over cancellation so Perry cannot imply that execution stopped. Fixture teardown cancels and awaits each worker before directory deletion.

The full runtime package suite passed 141 tests, skipped ten opt-in live tests, and had zero failures (151 total). Log: /tmp/perry-process-lifetime-final-runtime-20260831.log. The app suite passed 230 tests, skipped two live Cua tests, and had zero failures in Test-Perry-2026.08.31_12-25-00-+0100.xcresult. Log: /tmp/perry-process-lifetime-final-app-20260831.log.

The reviewer confirmed the cleanup fix with no remaining blocker in this scope. The descendant tests observe disappearance within the total cancellation budget; they do not establish that every descendant is already reaped at the instant the runner returns.

Unsigned arm64 Release verification passed, including runtime pins, Sparkle lock, privacy manifest, and bundle-size checks. Log: /tmp/perry-process-lifetime-release-20260831.log. This remains an unsigned dirty-worktree build, not a notarized release.

The tests do not prove termination of deliberately detached descendants or a parent that exits before its group can be observed. They also do not bound kernel launch/wait latency or measure production memory peaks, authenticated-provider cancellation, macOS 14 compatibility, or clean-checkout reproduction. Those remain M4 release gates. No runtime receives broader execution authority from this change.
