# Shared inventory decision

## Usage

Every consumer requests a fresh `RuntimeInventoryInspector.inspect(workingDirectory:)` result. Settings reads `setup`, the picker reads `choices`, and demo preflight reads `hasReadyCLIPlanner`. Task startup passes `registry` and its explicit preference or `automaticPreference` to the existing `ProductionRuntimeSelector`. Display snapshots never authorize later tasks.

## Selection

The catalog candidate is the base. Both the parent and independent Luna reviewer preferred its single inspection path and test seam. The reviewer scored catalog versus resolved at 5/5 versus 5/5 for caller coverage, 3/5 versus 4/5 for provider ownership, 5/5 versus 4/5 for identity and cancellation, 4/5 versus 2/5 for deterministic tests, and 3/5 versus 2/5 for interface depth. These are design judgments, not runtime evidence.

The parent also found the catalog's independent installation, authentication, and factory-input enums too permissive. The implementation narrows the catalog to coherent CLI definitions: a locator, verifier, official authentication probe, runtime constructor, and command metadata. Direct providers and the local planner are assembled directly; they do not pretend to have executable authentication stages.

From the resolved candidate, retain the distinction between verified and rejected CLI inspections. A rejected inspection has no usable authentication and yields no login commands. Do not retain its six-case runtime enum or whole-provider probe protocol: the former repeats the registry's identity data, and the latter cannot test that verification precedes authentication.

## Shape and ownership

`App/RuntimeInventory.swift` owns the inspector, immutable inventory result, CLI definitions, and inspection result. Each inspection resolves a CLI URL once and uses it for verification, authentication, runtime construction, and command construction. Injected definitions exercise the same sequence as production. Cancellation throws before returning an inventory.

`RuntimeExecutableVerifier` keeps artifact and signing policy. Runtime adapters keep official authentication behavior. `RuntimeProviderRegistry` keeps eligibility and fallback. `RuntimeSetup.swift` keeps existing presentation types. AppController supplies preferences and credentials and adapts failures to the existing presentation boundaries.

The inventory retains rejected providers in the registry for route explanations but excludes them from usable choices. Configured credentials remain planning-eligible without becoming authenticated or ready. Codex retains its private home and workspace execution; Claude and OpenCode remain planning-only.

## Rejected additions

There is no global cache, polling, download, new provider network probe, credential-file reader, or extra routing algorithm. Persisted history display names are outside this migration because absent providers still need historical labels. No candidate dropped out.

## Validation

The inventory and its four AppController consumers are implemented. The migrated app passed an unsigned arm64 Debug build, followed by 17 existing routing and Settings tests in `Test-Perry-2026.08.31_11-52-16-+0100.xcresult`. The runtime package suite passed 130 tests and skipped ten opt-in live tests, with zero failures; log: `/tmp/perry-inventory-runtime-tests-20260831.log`. These results precede the new inventory tests and subsequent private-home guard.

Ten inventory tests passed in `Test-Perry-2026.08.31_12-03-35-+0100.xcresult`. They cover one executable resolution, verification before authentication, rejected commands, cancellation without partial results, fresh inspection, direct/custom/local ordering, explicit preference, fallback reasons, and planning-only adapters. After adding recovery copy to the private-home case, the full app suite passed 230 tests, skipped two live Cua tests, and had zero failures in `Test-Perry-2026.08.31_12-05-02-+0100.xcresult`. Log: `/tmp/perry-inventory-full-app-final-20260831.log`.

Inspection also exposed an existing failure path: an unavailable support directory produced a nil Codex home, which selected the CLI's standard profile. The production Codex definition now rejects that configuration before authentication instead of consulting the user's default Codex profile. Its regression test checks rejection, absence of login commands, and storage/permission recovery copy.

Independent implementation review found that an ordinary thrown verifier or authentication error could abort the whole inventory, losing the local fallback. The inspector now converts those failures into fixed per-provider statuses and preserves cancellation. The reviewer confirmed the fix; an injected-error test covers both phases and checks that seeded error text stays out of the returned status. Current production adapters already normalize most ordinary probe failures, but the throwing inventory boundary now handles them too.

These runs use the dirty worktree. Exact-URL fixture coverage does not prove filesystem replacement resistance, authenticated provider planning, live UI behavior, or cancellation latency. Clean-checkout verification, provider-lab smoke tests, and release evidence remain outstanding; M1 and M4 are incomplete.

Independent test review found that the probe-error test did not pin the exact failure classifications; it now requires the fixed unverified-installation reason or unknown-authentication reason. The missing-home test also exercises the real bundled executable locator, so that assertion requires the app test bundle's Codex resource. It checks returned rejection and recovery controls, not independent observation of process non-invocation. The separate injected rejected-installation test observes that authentication is skipped.

The full suite after tightening those assertions passed 230 tests, skipped two live Cua tests, and had zero failures in `Test-Perry-2026.08.31_12-08-09-+0100.xcresult`. Log: `/tmp/perry-inventory-reviewed-app-20260831.log`.

The final unsigned arm64 Release verification passed after the recovery-copy and exception-isolation changes. It checked the pinned runtime artifacts, Sparkle lock, privacy manifest, and bundle contents and size. Log: `/tmp/perry-inventory-release-final-20260831.log`. The build reported the existing App Intents metadata warning because the app has no AppIntents framework dependency. This is not a Developer ID–signed or notarized artifact.
