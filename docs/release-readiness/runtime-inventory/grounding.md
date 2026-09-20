# Shared runtime inventory

## Current paths

`AppController.makeRuntime` builds direct-provider, Codex, Claude, OpenCode, and local-planner entries before passing a registry to `ProductionRuntimeSelector`. Each CLI branch locates an executable, verifies it, checks its official login state, and constructs a provider descriptor. A canceled verification or login probe returns no selection.

`currentRuntimeSetup` separately locates each CLI, calls a provider-specific readiness method that locates it again, and constructs its login/logout commands. `availableRuntimeChoices` derives CLI choices from those setup records but separately reads the direct-provider credential. The demo preflight calls the three readiness methods directly. This duplicates inventory policy across routing, Settings, picker choices, and the demo.

`RuntimeExecutableVerifier` owns checksum, signature, and version validation. Runtime adapters own CLI login probes. `RuntimeProviderRegistry` owns eligibility and fallback decisions. `RuntimeSettingsState` owns cancellation and publication for Settings. These existing boundaries should remain; the missing boundary is one inventory that feeds their consumers.

`App/RuntimeSetup.swift` now owns the existing readiness, setup record/snapshot, picker choice, and authentication command types. Their declarations were moved unchanged from AppController. A characterization test in `ProductionRuntimeSelectorTests.testVerifiedRuntimeAuthenticationStatesPreserveRecoveryCommands` preserves sign-in controls for missing, invalid, and unknown authentication and sign-out controls for authenticated runtimes. The full app suite after extraction passed 222 tests, skipped two live Cua tests, and had zero failures (224 total): `Test-Perry-2026.08.31_11-32-26-+0100.xcresult`.

`scripts/verify-release.sh` then passed using the existing DerivedData directory. It built unsigned arm64 Release and checked the pinned runtime artifacts, Sparkle lock, privacy manifest, and bundle contents and size budgets. Log: `/tmp/perry-runtime-inventory-release-20260831.log`. This used the dirty worktree and cached build products; it does not establish reproducibility, Developer ID signing, notarization, or Gatekeeper acceptance.

## Required behavior

- Preserve Codex and OpenCode artifact pins and Claude's Anthropic signing requirement. Never launch login or version commands before the applicable identity check.
- Reuse the exact located executable within an inspection. Do not locate once for verification and again for a copied login command or runtime factory.
- Codex uses Perry's private runtime home. Claude and OpenCode remain planning-only; do not enable delegated execution during this refactor.
- Configured credentials remain selectable for planning without becoming authenticated or ready. Unverified executables offer neither planning eligibility nor login commands.
- Preserve explicit per-task provider preference, configured direct-provider preference, CLI ordering, and the local-planner fallback. Preserve route explanations.
- Cancellation propagates through verification and authentication. Do not publish partial inventory after cancellation.
- Inspect again when starting a task rather than treating a previous Settings snapshot as an authorization grant.
- Do not read another CLI's credential files. No new provider network calls, downloads, background polling, persistence, or global cache are needed for inventory assembly.

## Candidate rubric

Each candidate must show the Settings, picker, and task-routing callsites; place provider-specific knowledge in one location; preserve exact executable identity and cancellation; allow deterministic tests at the inventory boundary; and reduce total policy duplication without adding a chain of pass-through layers. The selected design must reuse `RuntimeProviderRegistry` rather than replace its routing algorithm.

## Evidence boundary

The flow above is source inspection, not an account of the original author's intent. The release specification supplied in this thread is the product contract. Historical rationale searches are recorded separately. No shared inventory is implemented by this document, and M1/M4 remain incomplete.
