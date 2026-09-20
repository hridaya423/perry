# Distribution signature verification

Read-only inspection of the pinned Cua executable produced this `codesign -dv --verbose=4` line:

```text
CodeDirectory v=20500 size=58934 flags=0x10000(runtime) hashes=1831+7 location=embedded
```

The distribution verifier previously required a line beginning `flags=` and ending after the flag list. That pattern rejected the observed valid runtime flag. It also accepted an unrelated standalone flags line in a controlled fixture.

The verifier now requires the `CodeDirectory` line and an exact `runtime` flag token, allowing other flags and trailing fields. Six initial subprocess tests reproduced three failures before the fix; eight tests pass after the fix, including additional flag-order and partial-name cases. The tests invoke the production shell verifier against a fixture bundle and injected `codesign` output. They also reject a mismatched team, a failed strict verification, and a missing Cua executable.

Independent review reproduced all eight passing tests and passed shell syntax validation. The release automation suite also passes with these tests included. Metadata regeneration checks and the 11-entry artifact manifest check pass on the dirty development worktree.

The packaging workflow now calls `sign-distribution.sh` before verification. It preflights the required code paths, signs the runtimes and framework helpers before their containing bundles, and signs Perry last. Downloader retains its entitlements; Perry receives its explicit entitlement file. No signing command uses `--deep`. This follows [Sparkle's documented manual signing sequence](https://sparkle-project.org/documentation/sandboxing/) for workflows that do not use Xcode's archive-and-export path.

Three signing tests verify the nine-call order and arguments, failure before app sealing, and rejection of missing code before any signing begins. The parent ran these tests and the full release automation suite successfully. The tests inject `codesign`; they do not sign real code.

The fixture now models Sentry's `Current -> A` and Sparkle's `Current -> B` version links. A fourth test rejects a broken version link before signing begins. All four signing tests pass.

The parent also ran the signing script with an ad-hoc identity against a disposable copy of the built Debug app. All nine signing operations succeeded. Strict verification passed for Codex and Cua; deep strict verification passed for Sparkle and Sentry. Whole-app deep verification failed in the bundled `Testing.framework`. The untouched original framework failed strict verification too, so this result does not identify a regression in the new signer. The Debug test host is not a distribution artifact. The disposable copy was not launched.

This validates the signing and verification scripts, not distribution readiness. No Perry Developer ID signing, notarization, Gatekeeper acceptance, or rollback rehearsal occurred in this run. Nested framework signing ultimately needs verification against a Developer ID-signed release artifact.
