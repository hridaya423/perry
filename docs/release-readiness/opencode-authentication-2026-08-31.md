# CLI credential inspection

Perry's pinned OpenCode 1.18.25 exposes `auth` as an alias for `providers`. Its list command reads stored credential entries and prints their count; it does not verify them against a provider. See the [pinned command implementation](https://github.com/anomalyco/opencode/blob/v1.18.25/packages/opencode/src/cli/cmd/providers.ts).

The previous AppController implementation treated any output containing `credentials`, but not `0 credentials`, as authenticated. That both overstated the evidence and misclassified counts such as 10, 20, and 100. The OpenCode adapter now owns the bounded three-second inspection and its output parser. A single recognized positive count means `configured`; zero means `missing`; unsuccessful or unrecognized output means `unknown`. Stored entries never establish `authenticated` through this probe.

Runtime setup keeps configured providers available for planning through the same authentication-usability policy used by the router. It does not mark them ready on that evidence alone. Both official sign-in and sign-out commands remain available for configured credentials. An unverified installation has no authentication result and offers neither selection nor login commands.

## Evidence

The six focused OpenCode adapter tests passed, including numeric counts, styled output, missing entries, malformed summaries, duplicate summaries, overflow, unsuccessful exits, and existing planning behavior. Log: `/tmp/perry-opencode-auth-tests-20260831.log`.

The complete runtime suite passed 110 tests and skipped eight opt-in live tests, with zero failures (118 total). Log: `/tmp/perry-opencode-auth-runtime-20260831.log`.

The explicitly enabled `LiveRuntimePlanningSmokeTests.testOpenCodeCredentialInspection` passed against the installed executable after checking its SHA256 against the pinned binary digest. It called the production adapter and required a recognized configured-or-missing result, finishing in 0.508 seconds. Log: `/tmp/perry-opencode-live-auth-20260831.log`. This checks the real CLI output contract, not provider authentication or planning. It does not read the credential file directly or log its entries.

The first app run after moving the probe passed 213 tests and skipped two live Cua tests, with zero failures. Result: `Test-Perry-2026.08.31_10-49-12-+0100.xcresult` in Perry's DerivedData `Logs/Test` directory. Log: `/tmp/perry-opencode-auth-app-20260831.log`.

The later run, including configured-provider selection and sign-out tests, passed 215 tests and skipped two live Cua tests, with zero failures. Result: `Test-Perry-2026.08.31_10-51-29-+0100.xcresult`; log: `/tmp/perry-opencode-readiness-app-20260831.log`.

## Codex and Claude adapters

Codex 0.132.0 writes its login status to stderr, including successful status, while Perry previously inspected stdout. The adapter now parses the pinned status messages and exit codes, rejects contradictory results, and uses only Perry's supplied runtime home. The [pinned source](https://github.com/openai/codex/blob/rust-v0.132.0/codex-rs/cli/src/login.rs) defines that output contract. Masked API-key text is never copied into Perry's status or error messages.

Claude's adapter now decodes a required JSON boolean instead of casting an untyped dictionary value. It requires exit 0 with `loggedIn: true` or exit 1 with `loggedIn: false`, following the [CLI exit-status contract](https://code.claude.com/docs/en/cli-usage). Malformed and contradictory output remains unknown.

All three probes preserve cancellation as `CancellationError`. Tests cancel their owning task before invocation and require propagation instead of an authentication result. App publication sites also reject canceled results. AppController retains separate foreground-refresh and background-prompt tasks, cancels each when replaced, and cancels both before shutdown. The background prompt uses its own choices without publishing them into the foreground picker. Independent review found no remaining blocking issue in that ownership diff; background task execution still re-resolves its selected provider.

Settings retains a `RuntimeSettingsState` through `@StateObject`. The state owns the refresh task and publishes runtime setup and Cua status together. Starting a refresh cancels its predecessor; leaving the Runtimes tab cancels pending work. A late result from a canceled load cannot publish, even if the load ignores cancellation. The pending task weakly references the state, so it cannot keep a closed Settings state alive.

Four `RuntimeSettingsStateTests` cover out-of-order completion, cancellation with retention of the last published status and a subsequent refresh, cancellation before probes start, and release during a pending load. They passed in `Test-Perry-2026.08.31_11-13-10-+0100.xcresult`. Removing replacement cancellation reproduced two failing assertions: the old load did not observe cancellation and its stale runtime/driver status replaced the newer status. That mutation run's test stdout survives under `Test-Perry-2026.08.31_11-13-59-+0100.xcresult/Staging`, but Xcode crashed while saving verbose diagnostics on the nearly full disk. Its result bundle is incomplete and is not a successful verification artifact. The cancellation call was restored immediately. Real window-disappearance behavior and AppController overlap still need their own integration coverage.

The full app suite after restoration passed 219 tests, skipped two live Cua tests, and had zero failures (221 total). Result: `Test-Perry-2026.08.31_11-15-05-+0100.xcresult`. This run disabled verbose failure diagnostics with Xcode's `-collect-test-diagnostics never` option; it did not change the test assertions. It remains a dirty-worktree run.

Independent review found no blocking defect in the Codex and Claude adapter changes or their four AppController callsites. It identified missing deterministic process-boundary coverage for wrong-stream output, secret-bearing process failures, and cancellation after launch. The live inspection results below do not replace those failure tests.

The added process fixtures now exercise those paths through the real authentication methods. Codex rejects valid login text on stdout; Claude rejects valid login JSON on stderr; OpenCode accepts its credential listing on stderr because its command adapter combines both streams. Each adapter keeps seeded output from a failed process out of its status, returns a fixed message when an executable path containing a seeded secret cannot launch, and propagates cancellation after the fixture writes its launch marker. Fixtures invoke only generated test scripts, not installed CLIs or provider accounts. Cleanup errors fail test teardown instead of being swallowed.

The focused CLI suite passed 60 tests with zero failures. Independent review of the Settings state and its integration found no blocking issue, while explicitly leaving real `onDisappear` behavior unverified.

The complete runtime suite then passed 128 tests, skipped ten opt-in live tests, and had zero failures (138 total). Log: `/tmp/perry-cli-auth-process-boundary-20260831.log`. The build emitted no warnings or errors. These process-boundary fixtures do not establish authenticated provider planning or completion of M4.

Independent review found no blocking production issue in the process fixtures, but identified two limits: the impossible-path pre-cancellation tests do not independently observe that no launch was attempted, and cancellation propagation plus directory cleanup does not prove that every child process was reaped. Those checks remain outstanding.

## Executable verifier cancellation

The shared executable verifier now propagates cancellation through its hash worker and CLI version probes. Hashing checks cancellation before opening the file and before each 1 MiB read, forwards parent cancellation to its detached worker, and explicitly closes the handle when reading or cancellation throws. Codex, Claude, and OpenCode retain their existing checksum, signature, and version requirements. AppController stops building a runtime or readiness result when verification is canceled.

Eight verifier tests passed, including the existing real pinned-artifact checks, pre-cancellation across all three verifiers and the hash worker, a known SHA256 vector, and unreadable input. Result: `Test-Perry-2026.08.31_11-24-06-+0100.xcresult`. The full app suite after the final cancellation checks passed 221 tests, skipped two live Cua tests, and had zero failures (223 total). Result: `Test-Perry-2026.08.31_11-25-46-+0100.xcresult`.

The 500 ms cancellation budget remains unmeasured for filesystem reads and macOS signature verification. Signature verification is synchronous, and a cancellation check after it completes does not make it interruptible. Readiness and routing now use the [shared runtime inventory](runtime-inventory/synthesis.md); its deterministic tests do not establish that latency budget.

Independent review of the verifier, its tests, and all six AppController callsites found no blocking regression in cancellation handling or executable trust requirements. It did not reproduce the tests from a clean checkout or establish the latency budget.

After the AppController task-ownership changes, the complete app suite passed 215 tests and skipped two live Cua tests, with zero failures. Result: `Test-Perry-2026.08.31_11-08-56-+0100.xcresult`. This is a dirty-worktree regression run, not clean-checkout reproduction or proof of overlapping-refresh behavior.

The app run after adapter migration passed 215 tests and skipped two live Cua tests, with zero failures. Result: `Test-Perry-2026.08.31_10-59-42-+0100.xcresult`; log: `/tmp/perry-cli-adapter-auth-app-20260831.log`. The final runtime suite passed 116 tests and skipped ten live tests, with zero failures (126 total); log: `/tmp/perry-cli-auth-final-runtime-20260831.log`.

The explicit Codex inspection passed against the hash-verified bundled executable and Perry's private runtime home in 0.167 seconds; log: `/tmp/perry-codex-live-inspection-20260831.log`. Claude inspection passed in 0.319 seconds after checking Anthropic's signing requirement; log: `/tmp/perry-claude-live-inspection-fixed-20260831.log`. The first Claude attempt failed because the test omitted the inline-requirement prefix for `codesign -R`, not because the executable failed a correctly specified identity check. The corrected test did not weaken the production trust policy.

These live tests require recognized CLI login states, whether signed in or missing. They do not assert that credentials are usable for a provider request, and they perform no planning or credential-file scraping. Readiness copy and provider assembly now reside in the shared inventory. This slice does not complete M1 or M4; authenticated planning, clean-checkout reproduction, and release-proven runtime behavior remain separate gates.
