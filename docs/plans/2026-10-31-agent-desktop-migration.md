# agent-desktop Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `executing-plans` to implement task-by-task.

**Goal:** Replace the bundled cua-driver with agent-desktop as Perry's only screen-control driver, and remove cua entirely.

**Architecture:** A new `AgentDesktopClient` actor keeps the public surface of `CuaDriverClient` (`health`, `resolveTarget`, `capture`, `execute`, `insertText`, `shutdown`, `retire`, `reloadConfiguration`). It runs the bundled `agent-desktop` CLI once per call with `--session <worker allocation>`. agent-desktop keeps a private command host per session, so calls stay warm. `CuaWorkerService` swaps clients behind its existing seam; tools, routing and verification above it do not change. Pixel input (coordinate clicks, drags, double-click without `AXOpen`) moves to the foreground lease, because agent-desktop posts mouse events at the HID tap and cannot deliver them in the background.

**Tech Stack:** Swift 6 / AppKit, agent-desktop 1.0.2 (Apache-2.0, Rust, arm64 release archive), XcodeGen, bash release scripts.

## Context and decisions

- **Evidence:** `docs/evidence/lab/agent-desktop-2026-10-31/` (chart.html, chart-light.png, chart-dark.png). The 20-run medians in milliseconds were: type 37 vs 615, click 71 vs 525, cold start 217 vs 942, warm read 122 vs 146.
- **Owner decision, 2026-10-31:** "Foreground, drop cua." Pixel actions run only under the foreground lease, with the visible cursor. No cua fallback ships. This also counts as approval of the new third-party dependency, which `AGENTS.md` requires.
- **Background capability, checked in agent-desktop's source at 893a414:**
  - Ref actions run through Accessibility in the background.
  - Keys go to the target process (`CGEventPostToPid`, `crates/macos/src/system/key_dispatch.rs`).
  - `mouse-click --xy` and `drag` return `POLICY_DENIED` without `--headed`. Mouse events post at `CGEventTapLocation::HID` (`crates/macos/src/input/mouse/mod.rs`).
  - `double-click` tries `AXOpen` headless and fails closed otherwise (`crates/core/src/commands/double_click.rs`).
- **Window ids:** agent-desktop formats them as `w-<CGWindowNumber>` (`crates/macos/src/system/window/cg_window.rs:31`), so Perry's `windowID: Int64` maps one to one.
- **State:** agent-desktop writes to `~/.agent-desktop` unless `AGENT_DESKTOP_HOME` is set (`crates/core/src/storage/state_root.rs`). Perry sets it to `~/Library/Application Support/Perry/AgentDesktop` and erases that directory.
- **Safety:** The cua capability manifest goes away. Every target already passes `TrustGuard` in `ensureTargetAllowed` (`App/CuaDriverClient.swift:629`), and Perry issues only the operations in `ComputerAction.Operation`. The new client keeps both gates and runs them before spawning any process.
- **Effect confirmation:** cua confirmed each action by reading the value back. Perry already re-observes in `CompositeActionVerifier`. Only `insertText` relies on driver confirmation (`App/CuaDriverClient.swift:268`), so the new client reads the value back with `get <ref> value` for that one path.
- **Where to run:** all builds, tests and drills run on the mini (`ssh mac-tailscale`, Xcode 27 at `~/Applications/Xcode-27.app`), per the repo memory. The 2026-10-31 MacBook bench was a one-off the owner asked for.
- **Test targets:** benches never type into an existing document. They create and close their own TextEdit document. This rule comes from the 2026-10-31 incident, where the bench typed into the owner's open file.

## Phase 0: Spike (go / no-go gate)

### Task 0: Prove the six unknowns on the mini

**Files:** Create `scripts/lab/agent-desktop-spike.sh` and `docs/evidence/lab/agent-desktop-spike-<date>.md`.

**Step 1:** Fetch agent-desktop 1.0.2 and its helper, checking the sha256 from the release's `checksums.txt`. Copy both into a debug `Perry.app` at `Contents/Resources/AgentDesktop/bin/`. Re-sign inside-out with the debug identity.

**Step 2:** Prove each of these and record the observed output:

1. **TCC:** launched from Perry with `Process`, the CLI and its macOS command host use Perry's Accessibility and Screen Recording grants. Pass: `agent-desktop permissions` reports both `granted`, and `CuaDriverClient` is not running. **This is the gate.** If the host is attributed to its own binary, stop and report back.
2. **Window mapping:** `list-windows` returns pid, bundle id or app name, `w-<n>`, bounds and on-screen state. Record which fields are missing, and map them through `NSRunningApplication(processIdentifier:)`.
3. **Screenshots:** `screenshot --window-id w-<n> <path>` works for a background window. Record its pixel size against the window bounds to get the backing scale.
4. **Typing with no target:** without a target ref, find the focused field with `snapshot --surface focused -i`, then use `type`.
5. **Session lifecycle:** find how a session's host is ended (`session` subcommand or a process signal), so `retire()` leaves no orphan.
6. **Latency through Perry:** capture plus click, timed in-process. Expect results within 1.5× of the CLI bench.

**Step 3:** Commit the script and evidence: `git commit -m "Spike agent-desktop inside Perry"`.

**Gate:** All six pass, or the evidence names a workaround. Otherwise stop and bring the evidence to the owner.

## Phase 1: Bundle the driver

### Task 1: Lock and fetch

**Files:**
- Create `scripts/agent-desktop.lock` and `scripts/fetch-agent-desktop.sh`, modeled on `scripts/fetch-cua-driver.sh`.
- Create `scripts/test-agent-desktop.sh`, modeled on `scripts/test-cua-driver.sh`.
- Modify `project.yml:77`, where a new prebuild step sits beside FetchCuaDriver for now.

**Step 1:** Write the failing test. A fake archive and fake curl prove that fetch writes `AgentDesktop/bin/agent-desktop` and `agent-desktop-macos-helper` and the `.version` marker. A wrong archive sha256 must abort, and an arm64-only check must pass.
**Step 2:** Run `scripts/test-agent-desktop.sh`. Expect it to FAIL because the fetch script is missing.
**Step 3:** Write the minimal fetch script. The lock keys are `AGENT_DESKTOP_VERSION`, `_ASSET_URL`, `_ARCHIVE_SHA256`, `_BINARY_SHA256` and `_HELPER_SHA256`. Support `--fetch`, `--check` and `--check-lock`, the same flags as the cua script.
**Step 4:** Run it again. Expect `agent-desktop 1.0.2 arm64 driver verified`.
**Step 5:** Regenerate with xcodegen and build on the mini. Confirm the binary and helper are inside `Perry.app`.
**Step 6:** Commit: `Bundle agent-desktop 1.0.2`.

## Phase 2: The client

### Task 2: Command runner and error mapping

**Files:**
- Create `App/AgentDesktopCommand.swift`.
- Test `AppTests/AgentDesktopCommandTests.swift`.

**Step 1:** Write the failing tests. A fake executable (a shell script in the test bundle's temp directory) prints fixed envelopes. Assert this mapping into the existing `CuaDriverError`:

| Envelope | Error |
|---|---|
| `ok:true` | decoded `data` |
| `STALE_REF`, `ELEMENT_NOT_FOUND` | `.targetNotFound` (`isStaleTarget` true) |
| `WINDOW_NOT_FOUND`, `AMBIGUOUS_TARGET` | `.noTargetWindow` |
| `PERM_DENIED` | `.unavailable` |
| `POLICY_DENIED` | `.unsupportedAction` |
| `APP_UNRESPONSIVE` with `retry: unsafe` | `.actionUnanswered` |
| process exceeds deadline | `.requestTimedOut`, process killed |
| unparseable stdout | `.protocolFailure` |

Also assert that the environment holds only `AGENT_DESKTOP_HOME`, `TMPDIR` (per-user, mode 0700), `HOME` and `PATH`.

**Step 2:** Run `xcodebuild test … -only-testing:PerryTests/AgentDesktopCommandTests` on the mini. Expect FAIL.
**Step 3:** Implement `struct AgentDesktopCommand: Sendable` with `func run(_ arguments: [String], session: String, deadline: Duration) async throws -> JSONValue`. It reuses the `JSONValue` type that `JSONRPCConnection` already uses. Each call is one `Process`, and output is read to EOF.
**Step 4:** Run it. Expect PASS.
**Step 5:** Commit: `Run agent-desktop commands and map their errors`.

### Task 3: Snapshot decoding

**Files:**
- Create `App/AgentDesktopSnapshot.swift`, which replaces `App/CuaWindowState.swift`.
- Test `AppTests/AgentDesktopSnapshotTests.swift`, using fixtures captured in the spike under `AppTests/Fixtures/agent-desktop/`.

**Step 1:** Write the failing tests. A recorded `snapshot --include-bounds` of TextEdit and of Calculator must produce:
- `actionTokens`: the text Perry's planner reads, with one line per ref, in the same layout as `CuaWindowState.actionTokens`.
- `labels`: ref to name.
- `details`: ref to value and pressable.
- `guideSnapshot(target:)`: an `AXSnapshot` whose element frames are window-local.
- `treeComplete`: copied from `complete`.

**Step 2:** Run the tests. Expect FAIL.
**Step 3:** Implement the decoder by walking `tree.children`. Refs stay in the `@<snapshot>:eN` form, and the snapshot id is the part before the colon.
**Step 4:** Run them. Expect PASS.
**Step 5:** Commit: `Decode agent-desktop snapshots`.

### Task 4: AgentDesktopClient

**Files:**
- Create `App/AgentDesktopClient.swift`.
- Test `AppTests/AgentDesktopClientTests.swift`, ported case by case from `AppTests/CuaDriverClientTests.swift` and using the fake executable.

**Step 1:** Port the failing tests. Every case in `CuaDriverClientTests` that covers target resolution, session mismatch, protected targets, stale-token refresh, retire and generation handling becomes a case here, plus these new ones:
- A point click, drag or headless double-click on a background worker throws `.unsupportedAction` without spawning `--headed`.
- With `allowsForegroundInput`, the same actions run with `--headed`. Window-local screenshot pixels convert to screen points as `windowOrigin + pixel / backingScale`.
- Calling `insertText` reads the value back. A mismatch throws `toolRejected("I couldn’t confirm the text went into the field.")`.
- A blocked window (`TrustGuard`) throws `.protectedTarget`, and the fake records zero spawns.

**Step 2:** Run the tests. Expect FAIL.
**Step 3:** Implement the API of `CuaDriverClient`, with these operations:

| Perry operation | agent-desktop |
|---|---|
| list windows | `list-windows` → `CuaWindowTarget` |
| capture | `snapshot --window-id w-N --include-bounds --max-depth 12`, and `screenshot --window-id w-N <tmp>` concurrently when a screenshot is wanted |
| label query | `find --window-id w-N --name <label> --first` |
| click / right-click with a ref | `click` / `right-click <ref>` |
| double-click with a ref | `double-click <ref>`; on `POLICY_DENIED`, retry with `--headed` only if foreground |
| typeText | `type <ref> <text>`; with no ref, the focused-field ref from Task 0 item 4 |
| setValue | `set-value <ref> <value>` |
| scroll | `scroll <ref>`, using the flags recorded in the spike |
| pressKey / hotkey | `press <combo> --window-id w-N` |
| point click | `mouse-click --xy --headed`, foreground only |
| drag | `drag --from-xy --to-xy --headed`, foreground only |
| steps | sequential calls that stop at the first failure, with the 300 ms delay `run_steps` used |
| health | `permissions` and `version` |
| retire / shutdown | end the session host, using the mechanism from the spike |

Keep `foregroundOnlyBundleIDs` (Finder) unchanged.
**Step 4:** Run the tests. Expect PASS.
**Step 5:** Commit: `Add AgentDesktopClient behind the driver seam`.

### Task 5: Swap the worker service

**Files:**
- Modify `App/CuaWorkerService.swift:94`, which constructs the client, and the configuration type it takes.
- Modify `App/EnvironmentProbe.swift` and `App/LaunchOverrides.swift:11`.
- Test `AppTests/CuaWorkerServiceTests.swift` and `AppTests/CuaWorkerProcessTests.swift`.

**Step 1:** Point the existing worker tests at the agent-desktop fake. Expect FAIL until the swap.
**Step 2:** Introduce `AgentDesktopConfiguration`, which discovers the binary in the bundle and verifies its signing identity, following `CuaDriverConfiguration.discover`. Construct `AgentDesktopClient` with it.
**Step 3:** Run all `Cua*` and `Worker*` suites. Expect PASS.
**Step 4:** Build on the mini. Run `scripts/lab/guide-drill.sh` and `scripts/lab/routine-drill.sh` against TextEdit, in a document the drill creates itself. Expect PASS.
**Step 5:** Commit: `Run screen control on agent-desktop`.

## Phase 3: Product behavior

### Task 6: Pixel actions take the foreground

**Files:**
- Modify `App/Tools/UITools.swift`, around the `ui.doubleclick` entry at line 81 and `ui.drag` at line 202.
- Modify `App/TypedActionRouter.swift` and `App/Tools/ForegroundWorkerLease.swift`.
- Test the matching AppTests suites.

**Step 1:** Write failing tests:
- On a background worker, `ui.drag` and a coordinate `ui.click` ask for the foreground lease. Perry's existing review copy appears.
- An element click never takes the lease.

**Step 2:** Run the tests. Expect FAIL.
**Step 3:** Route `.drag`, `.point` targets and the double-click retry through the foreground lease. The description of `ui.drag` gets one added sentence: "Moves the real cursor."
**Step 4:** Run the tests. Expect PASS.
**Step 5:** Commit: `Run pixel input under the foreground lease`.

### Task 7: Settings, erasure, preferences

**Files:**
- Modify `App/Settings/BrainSettingsPage.swift:7-90` to remove the custom driver path field and keep the status line.
- Modify `App/PerryPreferences.swift` to remove `cuaDriverPath`.
- Modify `App/PerryErasureErasers.swift:35-39` to add `Application Support/Perry/AgentDesktop` and keep the old Cua paths for one release so upgraded users get cleaned.
- Test the erasure suite.

**Step 1:** Write a failing erasure test asserting the AgentDesktop directory is erased.
**Step 2:** Implement the change.
**Step 3:** Run the test. Expect PASS.
**Step 4:** Commit: `Erase agent-desktop state; drop the driver path setting`.

## Phase 4: Release and lab tooling

### Task 8: Signing and release scripts

**Files:**
- Modify `scripts/sign-distribution.sh` and `scripts/verify-distribution-signatures.sh`, plus their tests.
- Modify `scripts/package-release.sh`, `scripts/verify-bundle-contents.sh` and `scripts/test-bundle-contents.sh`.
- Modify `scripts/verify-artifact-manifest.sh`, `scripts/test-artifact-manifest.sh`, `scripts/generate-release-metadata.sh`, `scripts/release_metadata.py`, `scripts/verify-release.sh` and `scripts/test-release-automation.sh`.

**Step 1:** Update the tests first:
- Expected bundle contents list `AgentDesktop/bin/agent-desktop` and the helper, and no `CuaDriver/`.
- Both binaries are signed with Perry's Developer ID, hardened runtime, inside-out.

**Step 2:** Run `scripts/test-bundle-contents.sh`, `python3 scripts/test_sign_distribution.py` and `scripts/test-release-automation.sh`. Expect FAIL.
**Step 3:** Update the scripts.
**Step 4:** Run them. Expect PASS.
**Step 5:** Commit: `Sign and ship agent-desktop in release builds`.

### Task 9: Lab drivers

**Files:**
- Modify `scripts/lab/perry-drive.sh`, `guide-drill.sh`, `routine-drill.sh`, `talk-drill.sh` and `teach-bench.py`.
- Create `scripts/lab/driver-bench.py`, which replaces `cua-bench.py` and `cua-bench-report.py`.
- Delete `scripts/lab/cua-mcp.py` and `scripts/lab/cua-schema.py`.

**Step 1:** Port `driver-bench.py` from the 2026-10-31 bench. It opens a new TextEdit document with AppleScript, targets it by window id, closes it without saving, and refuses to run when the only TextEdit window belongs to an existing file.
**Step 2:** Switch the drills to the agent-desktop CLI.
**Step 3:** Run every drill on the mini. Expect PASS.
**Step 4:** Commit: `Drive lab drills with agent-desktop`.

## Phase 5: Remove cua

### Task 10: Delete cua and rename the seam

**Files:**
- Delete `App/CuaDriverClient.swift`, `App/CuaDriverConfiguration.swift`, `App/CuaWindowState.swift` and `App/CuaCapabilityManifest.swift`.
- Delete `App/Resources/CuaDriver/` and `scripts/fetch-cua-driver.sh`, `scripts/cua-driver.lock`, `scripts/test-cua-driver.sh` and `scripts/test-cua-host-lifecycle.sh`.
- Delete `AppTests/CuaCapabilityManifestTests.swift` and `AppTests/CuaDriverClientTests.swift`.
- Turn `AppTests/CuaLiveTests.swift` into `AgentDesktopLiveTests.swift`.
- Modify `project.yml` to drop FetchCuaDriver.

**Step 1:** Delete the files and regenerate the project. Build. Expect it to compile.
**Step 2:** As its own commit, rename the remaining `Cua*` types to `Screen*` (`CuaTargetHint` → `ScreenTargetHint`, `CuaWorkerService` → `ScreenWorkerService` and so on). This is a mechanical rename with no behavior change.
**Step 3:** Run `rg -i 'cua' App AppTests Packages scripts project.yml`. Expect only the erasure paths kept for upgrades.
**Step 4:** Commit: `Remove cua-driver` and then `Rename the screen-control seam`.

## Phase 6: Verification gate

### Task 11: Prove it on the mini

**Step 1:** Run `scripts/ci.sh`. Expect all package tests and `PerryTests` to be green.
**Step 2:** Run `scripts/lab/driver-bench.py` 20 times per operation. Gate: the medians are no worse than in the chart, through Perry.
**Step 3:** Run `scripts/lab/idle-probe.sh --seconds 60`. Gate: average CPU at or below 0.5% and maximum RSS at or below 180 MB, counting the agent-desktop host. The host must exit or idle within budget.
**Step 4:** Rebuild twice and confirm the Accessibility and Screen Recording grants survive.
**Step 5:** Record a guide drill with `scripts/lab/record.sh agent-desktop-guide 60` and watch it. Pixel actions must show the cursor only under the foreground lease.
**Step 6:** Update `progress.md` with the evidence paths. Commit: `Verify the agent-desktop migration`.

## Risks

- **TCC attribution of the command host:** the Phase 0 gate. If it fails, the CLI design fails, and the in-process FFI library becomes the fallback design.
- **AX-press behavior:** apps whose buttons ignore `AXPress` used to work through cua's background click. They now need the foreground lease. The drills will show how often this happens.
- **Upstream pace:** agent-desktop has weekly releases and a 2.x envelope. Pin the version and checksums in the lock file, and upgrade deliberately, as with cua today.
