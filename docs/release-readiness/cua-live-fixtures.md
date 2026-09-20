# Live Cua capture fixtures

The `PerryCuaLive` scheme runs read-only checks against the production Cua client and a seeded TextEdit document. The test code performs no document writes or model calls; it decodes returned screenshots in memory. Ordinary `Perry` test runs skip these tests unless `PERRY_LIVE_CUA=1` is present in the test host environment.

Before running, open [Perry-Cua-Fixture.txt](fixtures/Perry-Cua-Fixture.txt) in TextEdit. Keep its title unchanged and its first line visible. Grant Accessibility and Screen Recording to the built Perry app through System Settings. The fixture must be a local document, not a private working file. An explicitly enabled live run fails when permissions, driver discovery, or the fixture are unavailable; it does not convert those failures into skips.

Generate the project and run the selected scheme from the repository root:

```sh
scripts/fetch-xcodegen.sh --check
build/tools/xcodegen/bin/xcodegen generate --spec project.yml
xcodebuild test -quiet -project Perry.xcodeproj -scheme PerryCuaLive -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO
```

The scheme sets the test-host environment and selects only `CuaLiveTests`, using XcodeGen's [test-target selection and environment configuration](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md#test-action).

The first check captures the exact TextEdit fixture window, decodes the returned image, and recognizes the fixture marker from its pixels. It restarts Cua, checks that the old session target is gone, then recaptures the same process/window identity under a newer connection generation. The second check requests a nonexistent exact window ID and requires a refusal, with no target stored for that session.

These checks do not prove GUI action execution, click-advanced guides, overlay exclusion, protected-content handling, multiple displays, latency budgets, or clean-account onboarding. Those M2 gates remain separate. Record the result bundle and machine details for every live run; a skipped default test run is not live evidence.

## Prerequisite inspection on 31 August 2026

The newly built Debug app showed onboarding step 2, with Accessibility missing and Continue disabled. Retry left that gate disabled. No security permission was changed. The seeded TextEdit document was opened and its exact title and marker were observed through the computer-use tool; that observation is fixture setup, not a passed Cua capture test.

The 10:28 ordinary app run compiled the live suite and finished with 211 tests passed, two live tests skipped, and zero failures. Its result bundle is `Test-Perry-2026.08.31_10-28-12-+0100.xcresult` under Perry's DerivedData `Logs/Test` directory; its log is `/tmp/perry-cua-identity-app-20260831.log`. The skipped tests provide no live capture evidence.

The explicitly enabled `PerryCuaLive` run at 10:28:56 finished with two failures, zero passes, and zero skips. Both tests stopped at the production client's permission probe with `Cua Driver needs Accessibility and Screen Recording permission in System Settings.` Neither reached screenshot capture. Its result bundle is `Test-PerryCuaLive-2026.08.31_10-28-56-+0100.xcresult`; its log is `/tmp/perry-cua-live-preflight-20260831.log`. Rerunning after the required grants is still necessary.

The real embedded-worker lifetime check passed against the Debug app built by the 10:08 app test run:

```sh
scripts/test-cua-host-lifecycle.sh /Users/hridyaagrawal/Library/Developer/Xcode/DerivedData/Perry-dbedeyvgtejrpvaqzbsiwlrlfdhq/Build/Products/Debug/Perry.app
```

It returned `Cua worker exited with its host` with exit status zero. The script creates its own host process, locates that host's direct Cua child, kills only that host, and requires the child to exit within its polling deadline. The log is `/tmp/perry-cua-host-lifecycle-20260831.log`. This is live process-lifetime evidence, not a passed screenshot, permission, or GUI-action check. The existing interactive Perry process remained running afterward.

The source driver's pinned digest check passed. A read-only signing-identity lookup found an Apple Development identity but no Developer ID Application identity, so distribution-chain validation remains unavailable on this account.

## Failed-retarget regression

The deterministic client test `testFailedRetargetRetiresPreviousWindowBeforeAnotherAction` reproduced a stale-target defect: after capturing window 1001, requesting nonexistent window 9999 failed but left window 1001 available for a key action. The red result is `Test-Perry-2026.08.31_10-30-53-+0100.xcresult`, with its log at `/tmp/perry-cua-retarget-red-20260831.log`.

Capture now clears the session's previous target before resolving a replacement. The test requires the failed replacement to leave no target and send no `press_key` request. The full app run at 10:37 passed 212 tests, skipped the two opt-in live tests, and had zero failures. Its result is `Test-Perry-2026.08.31_10-37-02-+0100.xcresult`; its log is `/tmp/perry-cua-resumed-green-20260831.log`. This verifies the client policy with the stub driver, not real-window action behavior. The earlier green attempt exited 74 before running tests and supplies no passing evidence.

## Manifest containment and signing review

Independent review found that discovery accepted a capability manifest symlink pointing outside the app, then passed that path to Cua as approved. `testDiscoveryRejectsManifestSymlinkEscapingHost` reproduced acceptance through both bundled and registered driver selection. The red result is `Test-Perry-2026.08.31_10-39-50-+0100.xcresult`; its log is `/tmp/perry-cua-manifest-red-20260831.log`.

Discovery now resolves the manifest path, requires containment inside the resolved host bundle, checks readability, and retains the resolved path. The full app suite passed 213 tests, skipped two opt-in live tests, and had zero failures in `Test-Perry-2026.08.31_10-40-24-+0100.xcresult`, logged at `/tmp/perry-cua-manifest-green-20260831.log`. The independent reviewer found no concrete defect in this guard or its regression test. These are development-worktree tests, not clean-checkout or signed-release verification.

The reviewer withdrew a separate finding that compared the host signing identifier with `CFBundleIdentifier`: their inequality does not establish a bypass. The bundled re-signed path validates the host seal and Developer ID identity, checks driver containment, and requires matching host/driver teams plus the driver's `cua-driver` identifier. Actual Developer ID distribution proof remains outstanding.

The updated app passed an unsigned Release build (`/tmp/perry-cua-manifest-release-20260831.log`) and the complete `scripts/verify-release.sh` check with `PERRY_DERIVED_DATA_PATH` pointing to the existing Perry DerivedData directory (`/tmp/perry-cua-release-verifier-20260831.log`). The verifier checked pinned inputs, arm64 output, embedded runtime digests, the upstream Cua signature, Sparkle lock, privacy declarations, sound inventory, and bundle size limits. It reused the development checkout and build cache; it does not prove a clean build, Perry's distribution signature, notarization, or Gatekeeper acceptance.

The release signer also resolves and checks the capability manifest before invoking any signing command. Its ten fixture tests passed in both the builder's run and an independent parent run, covering missing files, external file and directory symlinks, path-prefix collisions, directory manifests, accepted internal symlinks, and signing order/failure behavior. The separate eight-test signature-verifier suite and shell syntax check passed. The tests replace `codesign` with a recorder; no real distribution artifact was signed.

## Permission recheck at 23:02

The explicit `PerryCuaLive` scheme was rerun on August 31, 2026 after reopening the seeded TextEdit fixture. Both tests failed before capture at `CuaLiveTests.swift:72` because the production permission probe still reported missing Accessibility and Screen Recording grants. The run had two failures and no skips; its log is `/tmp/perry-cua-live-20260831-2303.log`, and its result bundle is `Test-PerryCuaLive-2026.08.31_23-02-33-+0100.xcresult`. This confirms that TCC still blocks the live gate on this host and supplies no screenshot or exact-window evidence.
