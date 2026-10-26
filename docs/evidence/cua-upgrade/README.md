# cua-driver 0.22.1 to 0.38.0: measured per-action latency

Measured 2026-10-26 on the Mac mini (Mac16,10, Apple M4, 10 cores, macOS 27.0.1). Nothing was built, downloaded or driven on the MacBook.

## Result

| p50 / p95 ms (pooled, n=60) | 0.22.1 | 0.38.0 | p50 change | p95 change |
| --- | --- | --- | --- | --- |
| cold spawn + first `get_window_state` | 700 / 937 | 345 / 367 | 2.0x faster | 2.6x faster |
| warm `get_window_state` | 482 / 587 | 83 / 99 | 5.8x faster | 5.9x faster |
| `click` (Calculator button, AX token) | 1440 / 1534 | 498 / 523 | 2.9x faster | 2.9x faster |
| `type_text` (TextEdit, 6 chars) | 1492 / 1520 | 638 / 686 | 2.3x faster | 2.2x faster |
| `click` with `CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS=0` | n/a | 187 / 198 | 7.7x faster | 7.8x faster |
| `type_text` with `CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS=0` | n/a | 280 / 303 | 5.3x faster | 5.0x faster |

Both columns use Perry's configuration: bounded permission mode, an approved capability manifest listing 100 installed apps, `mcp --direct --embedded --host-bundle-id dev.perry.Perry`.

The 0.22.1 action times are bimodal. Of its 60 full-manifest `click` samples, 43 took more than 1 s (about 1.45 s); the other 17 took a median of 563 ms, which is what 0.38.0 does every time. For `type_text`, 33 of 60 took more than 1 s and the rest had a median of 683 ms. In the small-manifest runs 0.22.1 was almost always slow (58 of 60 clicks, 60 of 60 types). So the p50 gain depends on which mode the old driver lands in; the robust gains are the tail (0.22.1 maximum 1.56 s, 0.38.0 maximum 0.53 s for click) and the consistency. I did not find what decides the mode.

One regression: spawn plus `initialize` went from 33 ms to 80 ms (the binary grew from 62 MB to 80 MB). The first `get_window_state` after spawn fell from 669 ms to 263 ms, so the cold total still halves.

## Versions

| | 0.22.1 (current pin) | 0.38.0 (latest stable) |
| --- | --- | --- |
| Release tag | `cua-driver-rs-v0.22.1` | `cua-driver-rs-v0.38.0` |
| Published | 2026-08-25 | 2026-10-21 |
| Source revision | `c60ef6ad2db8774fb342938843e2f17f26c68240` | `85e2b1318bd77ccf3cfa88ccdf875a4bb7eaed19` |
| Archive SHA-256 | `1ef80b48b0b4ccd3b2eadd72c3c66735a65e15306db92816fb04f963d202155d` | `5f71191c082ca07c9dfc13b7c9a6eec60a82818c245a93534cc0eb7911471d72` |
| Archive member SHA-256 | `3bb9fb04c147cefa92bb5e83365b233110762b0d2a295a3f761d66147f88486d` | `92067848d0eeb9de76929fbd06a137af801b0ff6caedbb3109bd7a6cc84a1f9f` |
| arm64 slice SHA-256 | `c8343fb4ce61af8091bd3a08d8c6c812b5b45488f78a72d110685e5eb2b80cc9` | `6320105f0df8174175f75b68e59523fece754b83e62936ee9fbdead98fe15d9c` |
| Binary size | 62 MB | 80 MB |
| Signing | Developer ID Application: Cua AI, Inc. (`YCK386LBJ7`), identifier `cua-driver`, hardened runtime | same |
| Designated requirement | identical in both: `identifier "cua-driver" and anchor apple generic and ... leaf[subject.OU] = YCK386LBJ7` | |

Checked on the mini: the 0.22.1 archive hash matches the lock; the 0.38.0 archive hash matches the release `checksums.txt`; `codesign --verify --strict` passes on both; the arm64 slice of 0.22.1 reproduces the lock's distribution hash.

"Latest stable": every `cua-driver-rs-v*` release on GitHub is flagged prerelease, including the current pin, and GitHub's "latest" points at an unrelated `cua-spaces` release. I took the newest non-nightly tag. Nightly builds (`nightly-cua-driver-rs-v0.38.1-nightly.*`) exist and were not considered. Sigstore bundles were not verified.

## What was measured, and how

`scripts/lab/cua-bench.py` spawns the driver as Perry does and times MCP calls with `perf_counter` from request write to response arrival. 30 repeats per operation, two rounds in opposite variant order (`harness/matrix.sh`), pooled to n=60. Raw samples are in `raw/`. `scripts/lab/cua-bench-report.py raw` regenerates the tables below.

- cold: spawn the process, `initialize`, first `get_window_state`, kill. Repeated 30 times.
- warm: 30 `get_window_state` calls on one process, after one discarded call. Arguments are Perry's: screenshot on, `max_elements` 300, `max_depth` 12.
- click: fresh `get_window_state` of Calculator, then a timed `click` by `element_token` (`delivery_mode: background`). The read is not in the timing.
- type: timed `type_text` of `"perry "` into TextEdit, no element token, as `insertText` calls it. Every call returned `effect: "confirmed"` with a `value_readback`, which is what `CuaDriverClient.actionWasVerified` requires.
- Variants: `*-full-manifest` is Perry's shape (100 apps); `*-small-manifest` lists only TextEdit and Calculator; `new-...-wait0` adds `CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS=0`; `new-...-standard-no-manifest` uses `CUA_DRIVER_PERMISSION_MODE=standard` with no manifest. `capabilities-full.yaml` is the manifest used, generated with the same rules as `CuaCapabilityManifest.materialize`.

### Not measured

- Perry end to end, or any real Perry action. Perry's own driver spawn path (signing, responsibility chain) was not exercised by the timings.
- The binary Perry ships (the tarball's root `cua-driver`, identifier `cua-driver`). It holds no TCC grant, so I timed the `CuaDriver.app/Contents/MacOS/cua-driver` binary from each tarball instead (see TCC). Same release, different file, same flags and environment. I did not diff the two binaries' code.
- Large or slow apps (Safari, Chrome, Electron). Only TextEdit and Calculator.
- Perry's Swift manifest generation cost (the scan of installed apps).
- Whether the cursor overlay adds to click time. It was left at the driver default for both versions.
- Intermediate `CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS` values. Only the default and `0`.
- `post_action_wait` (see below).

### Conditions that limit the numbers

- The mini was not idle. Load average was 5 to 10 on 10 cores from another agent's builds during the runs. Round 1 and round 2 differ by more than 15% in 4 of 30 p50 cells: the bimodal 0.22.1 click and type cells, 0.38.0 small-manifest type, and 0.38.0 wait0 warm read (`raw/` has both rounds).
- Stage Manager is on. TextEdit had a normal 656x422 window. Calculator was a Stage Manager thumbnail (40x103), so Calculator reads are cheap; the AX click path does not depend on window size.
- Different tree sizes. 0.22.1 returns 236 elements for the TextEdit window, 194 of them `AXMenuItem` and 27 `AXMenu` from the menu bar's menus. 0.38.0 returns 18: the menu bar items but no menu contents. Part of the warm-read gain is that work no longer being done. This is also a behaviour change for Perry (below).
- TextEdit's text grew by about 6 characters per `type_text` across the whole session, roughly 3,000 characters by the end. The value is part of the tree, in both versions.

## Timing tables

p50 / p95 / max in ms.

### Pooled over both rounds (n=60 each)

| operation | 0.22.1 full manifest | 0.38.0 full manifest | 0.38.0 wait=0 | 0.38.0 standard, no manifest | 0.22.1 small manifest | 0.38.0 small manifest |
| --- | --- | --- | --- | --- | --- | --- |
| cold spawn + first get_window_state | 700 / 937 / 1006 | 345 / 367 / 385 | 336 / 358 / 456 | 310 / 317 / 318 | 679 / 865 / 1740 | 356 / 396 / 401 |
| spawn + initialize | 33 / 46 / 50 | 80 / 89 / 95 | 76 / 83 / 115 | 75 / 76 / 78 | 31 / 37 / 88 | 81 / 87 / 92 |
| first get_window_state | 669 / 891 / 958 | 263 / 285 / 293 | 260 / 274 / 372 | 235 / 242 / 243 | 648 / 827 / 1651 | 273 / 308 / 315 |
| warm get_window_state | 482 / 587 / 634 | 83 / 99 / 124 | 94 / 169 / 180 | 60 / 67 / 68 | 465 / 515 / 532 | 82 / 108 / 126 |
| click | 1440 / 1534 / 1560 | 498 / 523 / 532 | 187 / 198 / 221 | 491 / 510 / 531 | 1434 / 1492 / 1513 | 500 / 532 / 562 |
| type_text | 1492 / 1520 / 1567 | 638 / 686 / 695 | 280 / 303 / 308 | 562 / 577 / 581 | 1440 / 1475 / 1564 | 613 / 682 / 704 |

Per-round tables are in `tables.md`.

### Reading the table

- Manifest size does not matter to the driver. Full (100 apps) against small (2 apps) differs by less than the round-to-round noise on both versions. Regenerating a large manifest per spawn costs the driver nothing measurable. The Swift scan was not timed.
- `click` and `type_text` fell by about 940 ms and 850 ms at p50. With the wait env var at 0, 0.38.0 falls a further 311 ms on click and 358 ms on type. The 0.38.0 guide says the action's result waits at most the first 300 ms of the window-change watch; that matches the 311 ms. 0.22.1 has no such variable (the string is absent from its binary). That the old time is mostly an uncapped watch is my inference from these numbers, not something I tested.
- The 0.22.1 click and type cells are a mixture of two modes (see Result), so their p50s move a lot between rounds: full-manifest click p50 was 1444 ms in round 1 and 899 ms in round 2, type was 691 ms and 1507 ms. The 0.38.0 cells moved by under 15% apart from the wait0 warm read (79 ms and 112 ms).

## `post_action_wait: "none"`

It does not exist in 0.38.0. The `click` and `type_text` input schemas have no such property (checked with `cua-driver describe`). PR #6033 (`post_action_wait` argument for the macOS input tools) merged 2026-10-26T10:08Z. The newest published build is the 2026-10-26T05:25Z nightly, so no published binary has it yet.

What 0.38.0 does have is a host-level setting, `CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS` (default 1000 on macOS, 0 to 10000), set in the driver's environment at spawn. `0` is what the wait0 column measures. Perry's `embeddedEnvironment` is an explicit allowlist, so adding it is one line. Not adopted: the guide lists the cost. With 0 the driver stops reverting cross-app activations after an action, and a window that opens after an action is not reported. That is a product decision.

## TCC: what the mini allowed

- Over plain `ssh`, embedded mode reports `accessibility: false, screen_recording: false` (`check_permissions.source.attribution: "host"`, the responsible process is `sshd`). `get_window_state` returns no elements, `type_text` is refused with `off_space_or_ax_unresolved`, and no click target can be found. `ssh-denied/probe-0.38.0-over-ssh.json` is that run. No numbers from it are used.
- `launchctl asuser` is refused for a non-root user.
- What worked: a LaunchAgent bootstrapped into `gui/501` over ssh (`harness/run-agent.sh`). It runs inside the user's login session. Using the `CuaDriver.app/Contents/MacOS/cua-driver` binary from each tarball (bundle id `com.trycua.driver`, team `YCK386LBJ7`), the process inherits the grants the mini already holds for `/Applications/CuaDriver.app`, because the designated requirement matches. `check_permissions` then reports both permissions true and `click`, `type_text` and `get_window_state` all succeed with Perry's exact flags and environment. All timings above come from this path.
- The mini's installed driver is 0.33.4, with its daemon running. It was not used.
- Nothing was granted or changed in System Settings. Calculator and TextEdit were quit and relaunched in the foreground once so TextEdit had a normal window.

## "Any app" manifest mode

There is none in 0.38.0, so the per-spawn manifest regeneration stays.

- Manifest v3 application resources must name exactly one of `bundle_id` or `executable`, matched by equality (`session_manifest.rs`, `validate_applications` and `bundle_grant_matches`, at tag `cua-driver-rs-v0.38.0`). There is no wildcard.
- The only way to drop the manifest is `standard` permission mode, where a manifest is optional. It worked in the benchmark: all actions succeeded with no manifest, and it was the fastest cold and warm variant (310 ms cold, 60 ms warm). It also removes the bounded profile's deny-by-default ceiling and its "no runtime approval path" guarantee. I did not make that change: it is a security-posture decision, not a simplification.

## Breaking changes found, 0.22.1 to 0.38.0

The release notes list none. I diffed the `describe` schemas of every tool in Perry's allow-list and ran the calls.

1. `get_window_state` defaults to `tree_format: "markdown"`, which omits the `elements` array. Perry reads `elements` and `tree_markdown`. Perry must send `tree_format: "both"` (capture) or `"elements"` (token lookup). 0.22.1 rejects the argument, so this ships with the pin bump.
2. `get_window_state` walk budget: `timeout_ms` defaults to 1000, and a walk that runs out returns a partial tree flagged `truncated: true`. Default `max_elements` is 250; Perry passes 300. Not changed.
3. Menu contents are no longer in the tree (236 to 18 elements on TextEdit). Anything that clicked a menu item by token from a snapshot would break; `invoke_menu` is the supported path. I found no such use in `App/`.
4. `element_index` and `snapshot_id` were removed from `click`, `right_click`, `double_click`, `scroll`, `type_text`, `press_key`, `hotkey` and `set_value`. Perry sends only `element_token`.
5. `set_value` now requires only `value`; `right_click` and `double_click` no longer require `pid`.
6. `list_windows` with a `pid` returned 1 window for TextEdit instead of 2 and 1 for Calculator instead of 5: hidden helper windows are gone.
7. `type_text` results gain `hint` and `summary`; `effect: "confirmed"` is unchanged.
8. New tools Perry does not use: `run_steps`, `run_script`, `get_guide`, `browser_select`, `parse_visual_regions`, `install_extension`.

Unchanged: capability manifest format (v3, the 100-app manifest loaded without change), signing team and identifier, designated requirement, `element_token` format (`s<8 hex>:<row>`), MCP flags `mcp --direct --embedded --host-bundle-id`.

## Pin bump to 0.38.0

0.38.0 is compatible with small adapter changes, so the pin moved.

Changes:

- `scripts/cua-driver.lock`: version, tag, asset, URL, the three hashes and the source revision. Signing identifier and team are unchanged.
- `App/CuaDriverClient.swift`: `get_window_state` now sends `tree_format: "both"` (capture) and `"elements"` (token lookup).
- `AppTests/CuaDriverClientTests.swift`: `testCaptureAsksForBothTreeFormatsBecauseTheDriverDefaultsToMarkdown`. It passes with the change and fails without it (verified by removing the line on the mini).
- `scripts/test-cua-driver.sh`, `scripts/test-release-automation.sh`, `docs/release-readiness/{cua-driver.md,sbom.cdx.json,third-party-licenses.json}`: the same version, hash and revision values, replaced in place.
- `App/CuaCapabilityManifest.swift`: the doc comment now says 0.38.0 still has no any-app mode.

Verification, all on the mini in `~/Honey/perry-cua` with `DEVELOPER_DIR=~/Applications/Xcode-27.app/Contents/Developer`. Logs are in `verify/`.

| check | result |
| --- | --- |
| `fetch-cua-driver.sh --check-lock`, `--fetch`, `--check` | pass; the real 0.38.0 archive matched the lock and the signature check passed |
| `scripts/test-cua-driver.sh` | pass |
| `scripts/test-cua-host-lifecycle.sh` against the built Debug `Perry.app` | pass ("Cua worker exited with its host") |
| xcodegen 2.46.0 generate, `xcodebuild build` Debug arm64 with `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=` | BUILD SUCCEEDED |
| `xcodebuild test -only-testing:PerryTests` | 677 tests, 7 skipped, 0 failures (676 and 0 failures before the new test was added) |
| `swift test` PerryCore | 94 tests, 0 failures |
| `swift test` PerryOverlay | 10 tests, 0 failures |
| `swift test` PerryCapture | 6 tests, 0 failures |
| `swift test` PerryRuntimes | 106 tests, 0 failures |
| `swift test` PerryGuide | 266 tests, 1 failure: `HardwareAndKeysTests.testKeychainRoundTrip`, `unhandled(-25308)` (`errSecInteractionNotAllowed`). The keychain is not usable from an ssh session. The package does not touch the Cua driver. |

Two repo checks fail at `HEAD` before my changes, so they could not confirm the bump end to end. I ran both against a `git archive HEAD` copy on the mini:

- `scripts/generate-release-metadata.sh --check` fails with `third-party package is not pinned: perrycore` at `HEAD` and after. The SBOM and license files were therefore edited by value substitution, not regenerated.
- `scripts/test-release-automation.sh` fails at `HEAD` with `features[10].evidence[0] names a missing file: App/RealtimeVoiceSession.swift`, before it reaches the Cua checks. In my copy it stops earlier, on a `docs/evidence` file the rsync excludes.

Not done: no real-driver run of the whole Perry app. `PerryTests` and the lifecycle script use fake drivers. The real-driver evidence is the benchmark above, which exercised `check_permissions`, `list_apps`, `list_windows`, `get_window_state` with `tree_format: both`, `click` and `type_text` against 0.38.0 with Perry's flags, manifest and environment. `start_session`, `end_session`, `verify_state`, `invoke_menu`, `launch_app` and the browser tools were checked against the schemas only.

Follow-ups worth a decision:

- `CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS`: 300 ms of the remaining click time and 358 ms of type time, at the cost of focus protection.
- `timeout_ms` on `get_window_state` (new default 1000): Perry's 6 s read timeout is far above it, so heavy windows will now come back truncated instead of slow.
- Move to the `post_action_wait` tool argument when a build with PR #6033 ships. It is per call, so Perry could skip the wait only on reads it makes itself.
- The `standard`-mode no-manifest option, as a security call.
