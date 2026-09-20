# Integration write revocation

The integration client rechecks the provider's write permission immediately before dispatching a typed write. The same check runs after a 401 response triggers token refresh. Read-only POST requests do not require write permission.

`RemoteIntegrationClientTests.testDisablingWritesDuringRefreshPreventsDispatchAndUnauthorizedRetry` disables writes inside the injected token-refresh transport. It covers an initially expired credential and a credential rejected by the first API request. The expected outcomes are `writesDisabled`, one refresh request, and respectively zero or one API requests. All credentials and responses are fixtures; the test makes no provider network requests.

Before the fix, the regression failed in `Test-Perry-2026.08.31_08-25-33-+0100.xcresult`. After the fix, it passed in `Test-Perry-2026.08.31_08-28-49-+0100.xcresult`. Both results are under `~/Library/Developer/Xcode/DerivedData/Perry-dbedeyvgtejrpvaqzbsiwlrlfdhq/Logs/Test/` on the development machine.

The latter run compiled the dirty working tree and passed 194 of 195 tests on arm64 macOS 26.5.1. The remaining test, `RealtimeVoiceSessionTests.testActualReceiverDropsLateAssistantTranscriptAfterCancellation`, crashed with SIGABRT. This is not a green full-suite result or a clean-checkout verification.

This check cannot retract a request already dispatched. Live provider behavior, credential revocation during refresh, and independent clean-checkout verification remain outside this evidence. No capability is promoted to live-tested or release-proven by this result.

After the voice crash was repaired, `Test-Perry-2026.08.31_08-33-50-+0100.xcresult` passed all 195 app tests with no failures or skips on the same dirty development worktree. Independent read-only review found no actionable issues in the dispatch guard or its regression test; the reviewer did not run a clean-checkout verification.
