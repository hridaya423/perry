# Is there a faster or more reliable macOS computer-use driver than cua-driver 0.38?

Researched 2026-10-28. Source clones are on the Mac mini under `~/Honey/research/` (shallow, source only, about 545 MB). Nothing was built into Perry, no driver ran against a real window, and nothing under `~/Honey/perry` or `~/PerryBench` on the mini was touched.

Evidence tags used throughout:

- **[S]** verified from source I read (repo, commit, file:line).
- **[D]** verified from docs, README, changelog, issue or PR text I read. A PR or issue page fetched through a summarising tool is marked **[D~]**.
- **[M]** measured by someone else, with the method stated where known.
- **[U]** unverified. A guess or a claim I could not check.

Commits read: cua `df2af4f` (main, 2026-10-28), Peekaboo `653645c` (2026-10-27), munim-computer-use `ac7d1bc`, computer-use-mcp `82dd809`, mac-computer-use-mcp `81f4235`, macos-harness `43d9edf`. File paths below are relative to those repos.

## Verdict

**Keep cua. Do not switch. Change how Perry calls it, and borrow two techniques instead of swapping drivers.**

1. No candidate beats cua on the thing that costs Perry the most, and none is a drop-in.
   - The one serious challenger, Peekaboo, uses the same private SPI cua uses for background keys (`SLEventPostToPid`, `Core/PeekabooAutomationKit/.../Services/UI/BackgroundInputDriver.swift:1663`) [S]. It differs on the read path: one batched `AXUIElementCopyMultipleAttributeValues` per node (`AXDescriptorReader.swift:210`) [S] and a 1.5 s tree cache (`ElementDetectionCache.swift:57`) [S].
   - Peekaboo's own changelog says its batching cut element detection from 205 ms to 176 ms (about 14%) on a small test app [D]. cua issue #4761 reports about 25% from batching on cua itself [D~]. Neither supports a 5x read speedup.
   - No candidate publishes a macOS number for a 900-node Finder window. The only cross-driver benchmark found (munim) is vendor-run and Windows-only. There it measured cua 0.38.0 at 0.19 s against its own 0.14 s [D].
2. Perry's trust model leans on cua's immutable `bounded` mode and host-launched capability manifest (`App/CuaCapabilityManifest.swift`, `App/CuaDriverClient.swift:984-991`). I found no equivalent in any other candidate. Peekaboo has tool allow/deny lists (`docs/security.md`) and munim has an app policy file (`macos/Sources/Policy.swift`), but neither is a signed manifest ceiling fixed at launch [S/D]. Switching means rebuilding that boundary.
3. Roughly half of a 13–16 s rename is driver time, and most of that is `get_window_state` (6 × 960 ms). The cua knobs the survey named are real, but they remove only about 300 ms per action. They do not touch the read. The read shrinks only with fewer or smaller reads, or with batched AX reads inside the driver.
4. The biggest levers are on Perry's side:
   - Collapse each action plus its follow-up read into one `run_steps` call with `observe`. This also removes model turns (about 1.2 s each).
   - Stop forcing `delivery_mode: foreground` for every Finder action, and try `set_value` on the rename field.
   - Stop issuing a second full walk just to turn a label into a token.

**Combine, narrowly.**
- Take the nightly `post_action_wait: "none"` once it ships in a tagged build.
- Ask cua to take batched reads and `AXVisibleRows` pruning. Issue #4761 is open and assigned. cua is MIT and Perry is AGPL, so a patch is allowed.
- Spike Peekaboo's `PeekabooAutomationKit` as an in-process read-only Finder walker only if the benchmark below clears the stated threshold. See "A/B benchmark plan".

## Surprises worth knowing

- The `cua-driver` in the MacBook working tree (`App/Resources/CuaDriver/bin/cua-driver`) prints `cua-driver 0.22.1`. `scripts/cua-driver.lock` pins 0.38.0, and the mini's copy prints `0.38.0`. The bundled binary here is stale (dated Aug 27). Do not benchmark from it.
- The pacing knobs the survey named are split across two releases. `CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS`, `CUA_DRIVER_KEY_GAP_MS`, `run_steps`, `run_script` and `since` diff reads are in the **0.38.0 tag** (checked with `git cat-file` against `cua-driver-rs-v0.38.0`). `post_action_wait` is **not**: it first appears in nightly `0.38.1-nightly.20261028`. There is no stable release after 0.38.0 (`git ls-remote --tags`) [S].
- cua's docs and source disagree on one default. `EMBEDDING.md:223` says the window poll is 50 ms; `window_change_detector.rs:225` says 25 ms [S].
- The mini has about 4 GB free (98–99% used) and shrank while I worked. Keep new clones small.

## Comparison

| Candidate | Lang / licence | Maintained | AX read strategy | Background input | Screenshot | Fits Perry? |
| --- | --- | --- | --- | --- | --- | --- |
| **cua-driver 0.38.0** (`trycua/cua`, `libs/cua-driver/rust`) | Rust / MIT | Pushed daily; 0.38.0 tagged 2026-10-21; nightlies to 2026-10-28; 1,328 open issues [D] | Serial recursive walk, about 10 single-attribute IPCs per node, window-scoped, budgeted by `timeout_ms` and `max_elements`. No batching, no `AXVisibleRows` [S] | `SLEventPostToPid` plus AX actions, with a foreground rung [S] | `SCScreenshotManager` per window, overlapped with the AX walk [S] | Already integrated |
| **Peekaboo 4.9.7** (`steipete/Peekaboo`, now `openclaw/Peekaboo`) | Swift 6.2 / MIT | v4.9.7 on 2026-10-23, commit 2026-10-27, 10 open issues [D] | One batched read of 14 attributes per node, role-gated action probes, 1.5 s tree cache, window-scoped [S] | `SLEventPostToPid`, `CGEvent.postToPid`, AX actions first [S] | ScreenCaptureKit and CoreGraphics paths [D] | Swift package, macOS 14+. Large surface and a different safety model. No signed manifest [S/D] |
| **munim-computer-use 0.9.0** | Rust + Swift / Apache-2.0 | Created 2026-09-05, pushed 2026-10-28, 20 stars [D] | Batched reads, on-screen clipping, `AXVisibleRows`/`AXVisibleChildren` for lists [S] | `SLEventPostToPid`, `SLPSPostEventRecordTo` [S] | ScreenCaptureKit [S] | MCP server and Node/Rust stack. Too young. Benchmarks are Windows only |
| **computer-use-mcp** (`minghinmatthewlam`) | Swift / MIT | Last push 2026-08-17 [D] | Single reads (no `CopyMultiple` in the tree) [S] | Ladder: AX action, per-window event, per-PID event; SkyLight rung is opt-in via `COMPUTER_USE_MCP_SKYLIGHT=1` [D] | ScreenCaptureKit [S] | MCP daemon. Stale |
| **mac-computer-use-mcp** (`guillaume-gonano`) | Swift / MIT | Created 2026-10-15, 0 stars [D] | Single reads, diff after first call [D] | Public `CGEventPostToPid` only [S] | ScreenCaptureKit [S] | Too new to trust |
| **macOS Harness** (`browser-use`) | Python (PyObjC) / MIT | Pushed 2026-10-23, 971 stars [D] | PyObjC AX reads [S] | Public `CGEventPostToPid` [S] | `/usr/sbin/screencapture` subprocess [S] | No. PyObjC and a subprocess screenshot will not beat a native walker |
| **open-codex-computer-use** (`OpenCodexLabs`) | Swift / MIT | Last push 2026-05-12, alpha [D] | Single reads [S] | `postToPid` [S] | ScreenCaptureKit / `screencapture` [S] | Stale |
| **Ghost OS** (`ghostwright/ghost-os`) | Swift / MIT | Last push 2026-03-23, release v2.2.1 [D] | Not read | Not read | Local vision fallback [D] | Stale; not examined |
| **Macbeth** (`wende/macbeth`) | TypeScript + Swift daemon / MIT | Pushed 2026-09-20, 4 stars [D] | Not read | Not read | Not read | Too small; not examined |
| **mac-control-mcp** (`AdelElo13`) | Swift / MIT | Pushed 2026-10-16, 18 stars [D] | PR #18 adds `AXUIElementCopyMultipleAttributeValues` [D~] | Not read | `SCShareableContent` cache [D~] | Not examined; technique only |
| **MacosUseSDK** (`mediar-ai`) | Swift / MIT | Last push 2026-04-26 [D] | Single reads (16 call sites, no `CopyMultiple`) [S] | Not read | Not read | Stale |
| **Hammerspoon `hs.axuielement`** | Objective-C + Lua / MIT | v1.1.1 on 2026-02-26 [D] | Exposes `allAttributeValues` over `AXUIElementCopyMultipleAttributeValues` (`libaxuielement.m:341`) [S] | AX actions; no pid-routed events | None | A scripting host, not a driver |
| UI-TARS Desktop, Agent S, OpenCUA | TS / Python / Python; Apache-2.0 / Apache-2.0 / MIT | Active | None: screenshot plus vision model, or a model and dataset [D] | Not documented | Screenshots | Not drivers |
| OpenAdapt | Python / MIT | Active | Uses macOS Accessibility to compile recorded flows [D] | Not documented | Not documented | A replay compiler, not a driver |
| macctl, "Leap" | none found | — | — | — | — | Skipped. macctl appears only on a Glama listing; "Leap" matched no computer-use project |

Stars are in the notes only where they help place a project's age. They are not evidence.

## Findings per candidate

### cua-driver (incumbent)

**Read path.** `get_window_state` walks the AX tree serially. `walk_element` (`libs/cua-driver/rust/crates/platform-macos/src/ax/tree.rs:432`) reads each attribute with its own `AXUIElementCopyAttributeValue`:

- `AXRole`, then `AXTitle` (:493), `AXValue`, `AXPlaceholderValue`, `AXDescription`, `AXIdentifier`, `AXHelp`, action names (:507), and for actionable nodes `AXEnabled`, frame (:556) and four control-state attributes.
- That is roughly 10–14 cross-process calls per node.
- Perry's measured ~830 ms for ~900 Finder nodes is about 0.92 ms per node, or about 80 µs per IPC if the count is 11. This is my arithmetic, not a measurement of the IPC count **[U]**.

`grep -rn "CopyMultipleAttributeValues\|AXVisibleRows"` across `platform-macos/src` returns nothing **[S]**. So cua has neither batching nor virtual-row pruning today.

Three more facts from the same files:

- `query` filters the markdown after the walk (`tree.rs:339`). It does not shorten the walk **[S]**.
- `since` diff reads still walk. `focused_element_description` (`tools/get_window_state.rs:933`) takes the walk's tree **[S]**. Diffs save model tokens, not driver time.
- The screenshot runs concurrently with the walk (`prefetch_capture`, `get_window_state.rs:106-111`), using `SCScreenshotManager` (`capture.rs:1-16`) **[S]**. Dropping the screenshot from a read therefore saves payload, not wall time.

The walk is bounded only by `max_elements`, `max_depth` and `timeout_ms` (`walk_budget.rs`, `admit()`; per-element AX timeout 2 s at `tree.rs:44`) **[S]**. cua's own issue #4761 ("Reduce repeated macOS AX attribute reads") is open and assigned. Its author measured 91.7 → 68.1 ms and 185.7 → 139.5 ms for screenshot-free observation with batching, 20 alternating repeats, on small AppKit forms, and says the numbers should not be read as a full-task speedup **[D~]**.

**Action path.** Where an action's time goes, by file:

- *Window-change watch.* `window_change_detector.rs:222-233`: the observation deadline defaults to 1000 ms, polled every 25 ms, and the action's result waits up to `REPORT_WINDOW` = 300 ms **[S]**. This matches the 311 ms the earlier 0.22.1→0.38.0 benchmark saw when the watch was set to 0 (`docs/evidence/cua-upgrade/README.md`) **[M]**.
- *Key pacing.* `keyboard.rs:18` defaults the key gap to 8 ms. `key_pacing.rs:20-42` reads `CUA_DRIVER_KEY_GAP_MS`, clamped 2–100 ms **[S]**. It only matters on the physical key path. The AX path writes `AXSelectedText` in one call (`type_text.rs:3`) **[S]**.
- *Finder item clicks.* When `AXPress` is refused on a Finder icon or row, `click.rs:745-760` falls into a read-back with `SELECTION_READBACK_SETTLE` = 200 ms and `SELECTION_READBACK_STABILITY` = 250 ms (`click.rs:131-134`, used at :1651 and :1664) **[S]**. These are constants, not settings. That is about 450 ms of Finder-specific verification inside Perry's 540 ms click.
- *Foreground typing.* `type_text` on the foreground rung adds `foreground_settle_ms` of 20 or 200 ms (`type_text.rs:898`, used at :1440) and `await_front_settled` (:1192-1212), which needs the window to stay front for `FRONT_SETTLE_STABLE` = 250 ms, capped at 1500 ms **[S]**.

Perry forces that foreground rung for Finder: `App/CuaDriverClient.swift:481` (`foregroundOnlyBundleIDs = ["com.apple.finder"]`) and :1300-1306. Adding the 300 ms watch and the read-back, the sum (about 20–200 + 250 + 300 + readback) is the right size for the measured 970 ms Finder `type_text`. That is an inference from source, not a measurement **[U]**. The benchmark separates it.

`ax/tree.rs:516` carries a comment that Finder's transient inline-rename field is the case the `set_value` addressing exists for: the field exposes a settable `AXValue` but no action names **[S]**. So `set_value` on the rename field is a supported path that skips key synthesis, foreground activation and the settle waits. Whether it works reliably on Finder in Perry's setup is **[U]** until the benchmark runs.

**The survey's claims, checked.**

| Claim | Verdict | Evidence |
| --- | --- | --- |
| `CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS` exists | Verified, in 0.38.0 | `window_observation.rs:24`, `EMBEDDING.md:222` [S/D]. Default 1000, range 0–10000. Daemon env only; no per-call override |
| `CUA_DRIVER_KEY_GAP_MS` exists | Verified, in 0.38.0 | `key_pacing.rs:20`, `EMBEDDING.md:321`. Default 8, range 2–100 [S/D] |
| `post_action_wait: "none"` exists | Verified, **nightly only** | `cua-driver-core/src/post_action_wait.rs:28`. `cua-driver 0.38.1-nightly.20261028` prints it in `describe click` on the mini (checksum matched `checksums.txt`; signed `cua-driver`, team `YCK386LBJ7`). Absent from the 0.38.0 tag [S] |
| `run_steps` / `run_script` batching | Verified, in 0.38.0 | `cua-driver-core/src/batch_tools.rs:32-50` (10 batchable tools, 64 steps), `script_tool/`. Batched non-final steps wait at most 120 ms for the cursor and 100 ms for the window watch (`step_pacing.rs:27-33`) [S] |
| Calculator background click 1153 ms → 78 ms | Verified as a documented number, not reproduced | `EMBEDDING.md:261`: 1153 ms default, 325 ms at 200, 78 ms at 0, Calculator in background, Terminal frontmost [D]. Perry's own run saw 498 → 187 ms on 0.38.0 [M] |
| `post_action_wait` per-call timing | Documented | `EMBEDDING.md:304`: `element_token` click 570–750 ms → 250–350 ms (macOS 26, Calculator) [D] |

**A difference that matters for the choice between the env var and the argument.** The env var set to 0 releases the focus-steal lease as soon as the action returns, so a late-activating app stays frontmost (`EMBEDDING.md:239-250`) [D]. `post_action_wait: "none"` returns early but leaves the watch and the lease running detached for the full deadline, so focus protection is unchanged (`post_action_wait.rs:1-17`, `EMBEDDING.md` "Skipping the report wait per call") [S/D]. That makes the argument the better tool for Perry. It is available only in nightlies today.

### Peekaboo 4.9.7 (`steipete/Peekaboo`, redirects to `openclaw/Peekaboo`)

- **Exists, active, MIT** [D]. Releases 4.9.4 to 4.9.7 between 2026-10-16 and 2026-10-23. It builds as a Swift 6.2 package with a CLI, an MCP server, a bridge daemon and a menu-bar app.
- **Reads.** `AXTreeCollector.swift` walks window-scoped. Per node it makes one `AXUIElementCopyMultipleAttributeValues` call for 14 attributes (`AXDescriptorReader.swift:130-145`, :210), with a single-read fallback. Action and keyboard-shortcut probes run only for roles that can use them (`AXTreeCollector.swift:343-370`) **[S]**. Defaults are depth 12, 1000 elements, 250 children per node (`docs/commands/see.md:129-131`) **[D]**.
- **Cache.** `ElementDetectionCache` has a 1.5 s TTL and is used only when the traversal budget is the default. `--fresh` bypasses it **[S/D]**. A cache hit would be a stale read of a window the agent just changed; Perry would need `--fresh` after every action.
- **Screenshots.** ScreenCaptureKit and CoreGraphics paths; `--capture-engine auto|modern|sckit|classic|cg` (`see.md:116`) **[D]**.
- **Acting.** Background by default when a pid is known. Single left clicks prefer AX actions. Keys go as pid-routed `CGEvent`s through `SLEventPostToPid` (`BackgroundInputDriver.swift:1656-1674`). Pixel right and double clicks use window-routed events (`WindowRoutedPointerDriver.swift:937-954`) **[S]**. `set-value` writes `AXValue` directly (`docs/commands/set-value.md`) **[D]**. `type --clear` prefers one `AXValue` replacement on native targets (`type.md:50`) **[D]**.
- **Safety semantics.** Peekaboo is strict about retry safety. After an accepted or possibly dispatched action it stops rather than replay, and it reports unverified outcomes (`docs/automation.md:55-59`, `docs/focus.md`) **[D]**. That is attractive for reliability and different from cua's `effect` field, so Perry's verifier would need rework.
- **Published numbers.** `CHANGELOG.md:1553-1563` [D]:
  - "warm Playground screenshot-plus-AX calls from about 844ms to 759ms";
  - element detection "about 205ms to 176ms" from batching, and "roughly 180-190 ms" after role gating;
  - "`peekaboo see --app Playground` ... in about 0.50s".

  Playground is Peekaboo's own small test app. No Finder or 900-node figure exists.
- **Gaps against Perry's needs.** No signed capability manifest or immutable launch mode (tool allow/deny lists only, `docs/security.md`) **[D]**. Element handles are snapshot-bound (`ps1_` plus 32 hex digits, `click.md:23`) rather than cua's `<snapshot_id>:N` **[D]**. Multi-window targeting by `--pid` and `--window-id` exists (`see.md:110-111`) **[D]**. Menus, dialogs and drag are covered.
- **Integration cost.** `PeekabooAutomationKit` is a SwiftPM library (macOS 14+, depends on `AXorcist` in-tree and `swift-algorithms`) **[S]**. Perry already uses local packages, so it could link in-process. That adds a third-party dependency (Perry's AGENTS.md requires approval), a very large API surface (about 100 files under `Services/UI`), and TCC would attach to Perry itself instead of the signed cua helper. The CLI/daemon route keeps Perry's process clean but needs its own Accessibility and Screen Recording grants for the Peekaboo binary. I did not automate or answer those prompts.
- **Verdict.** The one candidate worth measuring. Not a replacement on current evidence.

### munim-computer-use 0.9.0

- Created 2026-09-05, pushed 2026-10-28, Apache-2.0, 20 stars, no open issues **[D]**. Young.
- The macOS reader is the most aggressive of any candidate I read: `macos/Sources/Perception.swift:8-60` batches 11 attributes plus children into one call; `:154-263` clips descendants to scroll areas and web areas and drops off-screen nodes; `:274-287` reads `AXVisibleRows`/`AXVisibleChildren` for list roles and counts what it skipped **[S]**. That is the technique that could make a Finder list cheap. It is also the one most likely to hide rows an agent needs, so treat it as a design to copy, not a library to adopt.
- Background input via `SLEventPostToPid` and `SLPSPostEventRecordTo` **[S]**; settles on AX notifications instead of a fixed pause (`README.md:227`) **[D]**.
- Benchmark in `README.md:154-190`: Windows 11 only, vendor-run, 5 timed calls after a warm-up, File Explorer. munim 0.13–0.16 s, cua 0.38.0 0.18–0.20 s with `include_screenshot:false`. Five Calculator clicks 1.70 s against cua's 2.32 s **[M]**. Note that the vendor's own result is cua at about 1.3–1.4x its read time on Windows.
- Not a fit: another MCP server with its own permission model, 5 weeks old, and no macOS figures.

### computer-use-mcp, mac-computer-use-mcp, open-codex-computer-use, macpilot-mcp, macos-harness

I read each repo's AX and input calls by grep, plus the README claims (`README.md:80-81,247-250,429` for computer-use-mcp).

- **computer-use-mcp** (`minghinmatthewlam`): single-attribute reads, a layered input ladder, a `delivery_tier` and `fallback_reasons` telemetry field **[D]**. Last push 2026-08-17. The ladder idea is good; the project is stale.
- **mac-computer-use-mcp** (`guillaume-gonano`): public `CGEventPostToPid` only, diff after the first read **[S/D]**. Created 2026-10-15. Too new.
- **open-codex-computer-use**, **macpilot-mcp**: stale (May and April 2026). Single reads.
- **macos-harness**: PyObjC, public `CGEventPostToPid` (`src/macos_harness/events.py:158`), screenshots through `/usr/sbin/screencapture` (`screenshot.py:33`) **[S]**. Not a performance candidate.

### Others

- **Ghost OS**: Swift, MIT, last push 2026-03-23, so about seven months stale. Not examined beyond metadata and listings **[D]**.
- **Macbeth**: TypeScript with a Swift daemon, 4 stars, last push 2026-09-20. Not examined **[D]**.
- **mac-control-mcp** (`AdelElo13`): PR #18 reports Chrome `get_ui_tree` going from 1177 ms to 31.5 ms, and 3,774 IPC calls to 422 on a 422-node walk (about 65 ms to 26 ms), via batched reads. The PR bundles a lower node cap (5000 → 2000), a shared window-server list and cached `SCShareableContent`, so the 37x is not from batching alone **[D~]**. Hardware and OS are not stated. It supports batching as a real gain, about 2.5x on that walk (65 → 26 ms, 422 Chrome nodes), though the PR does not say which hardware.
- **Hammerspoon**: exposes `hs.axuielement:allAttributeValues()` over the batched call (`extensions/axuielement/libaxuielement.m:315-358`) **[S]**. It is a Lua scripting host, not something to embed.
- **UI-TARS Desktop, Agent S, OpenCUA, OpenAdapt**: agent frameworks, models, datasets and replay compilers. UI-TARS's README says "screenshot and visual recognition" and mentions no accessibility tree or background input. Agent S says it uses an "agent-computer interface" and "looks at the screen". OpenCUA is models plus the AgentNet dataset. OpenAdapt compiles recorded flows and uses Accessibility on macOS, but is not a driver API **[D]**. None replaces a driver.
- **macctl** and **"Leap"**: no repository found. I skipped them rather than guess.

## Changes to make to cua usage, with evidence

Ranked by expected effect on a 13–16 s rename (about 7 s of driver time, about 6 s of model turns and Perry overhead). The savings are my estimates from the cited measurements, not new measurements **[U]**.

| # | Change | What cua does | Expected effect | Where in Perry | Risk |
| --- | --- | --- | --- | --- | --- |
| 1 | Send action plus follow-up read as one `run_steps` call with `observe` (default `since:"latest"` diff) | Runs steps in order, stops at first failure, one bounded read after the last step. Non-final steps wait at most 120 ms (glide) and 100 ms (watch) (`batch_tools.rs:32-50,162-190`, `step_pacing.rs:27-33`) [S] | Saves one MCP round trip and one full read per action, and lets the model plan 3–4 actions per turn. At ~1.2 s per model turn this is the largest lever [U] | Needs a batch tool in `App/Tools/UITools.swift`; `run_steps` is not in `toolAllowList` (`App/CuaCapabilityManifest.swift:11-24`). Rename-field token is unknown before the first Return, so steps there must type into the focused field or use name locators | A design change to the agent's tool surface |
| 2 | Add `post_action_wait: "none"` to Perry's own `click`, `type_text`, `press_key`, `set_value` when a read follows | Returns when input is delivered; watch and focus lease keep running detached (`post_action_wait.rs:1-17`) [S] | About −300 ms per action on TextEdit and Calculator in the earlier benchmark (click 498 → 187, type 638 → 280 at env 0) [M]; Finder unmeasured | `callTool` in `App/CuaDriverClient.swift:1291` | Needs a nightly now. Re-pin to the first tagged build that includes PR #6033 |
| 3 | Until then, `CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS=0` in `embeddedEnvironment` (`App/CuaDriverClient.swift:984`) | Same −300 ms per action, but the focus lease ends when the action returns (`EMBEDDING.md:239-250`) [D] | Same as #2 | One line | Loses cross-app activation reversal and "opened new window" suffixes. A product decision, not a free win |
| 4 | Try `set_value` on the Finder rename field instead of foreground `type_text` | `tree.rs:516` makes the rename field addressable for `set_value`. `type_text` foreground adds up to ~700 ms of settle, front-wait and watch (`type_text.rs:898,1192-1212`) [S] | Could remove most of the 970 ms [U] | `ui.setValue` already exists (`App/Tools/UITools.swift:291`); `set_value` is already allowed | Reliability on Finder untested here |
| 5 | Re-test `delivery_mode: background` for Finder | Perry forces foreground (`CuaDriverClient.swift:481,1300-1306`) | Removes front-settle waits if background works for the specific field [U] | Perry's own override list | Why Finder was forced foreground is in git history I did not trace |
| 6 | Stop the label-to-token second walk | `queryElementToken` issues a full `get_window_state` with `query` just to find a token (`CuaDriverClient.swift:1254-1290`); `query` does not shorten the walk (`tree.rs:339`) [S] | Saves one ~830 ms Finder walk each time it fires. Not measured how often | Prefer tokens from the last read, or cua's name locators inside `run_steps` | Needs a trace to count how often it fires |
| 7 | Cut read size: `max_depth`, `max_elements`, `timeout_ms` | These are the only inputs that bound the walk (`walk_budget.rs`, `get_window_state.rs:340`) [S] | Proportional to nodes skipped; ~0.9 ms per Finder node | `CuaDriverClient.swift:567-573,1256-1263` | Hides controls. Test with the Finder guide |
| 8 | `CUA_DRIVER_KEY_GAP_MS=2`, drop Perry's `delay_ms: 10` | Applies only to the physical key path (`keyboard.rs:18-25`); doc figure 3650 → 980 ms for 185 chars (`EMBEDDING.md:333`) [D] | At most ~100 ms for a 7-char name; not the cause of 970 ms [U] | `embeddedEnvironment`, :1297 | Dropped keys on loaded targets; read the field back |

What not to do: adding `since` to reads (saves model tokens, not driver time, see above), or dropping the screenshot from reads for speed (it runs concurrently with the walk).

## A/B benchmark plan

**Goal.** Decide on the same Finder window, with the same fixture, whether any change beats cua 0.38.0 as shipped, and whether Peekaboo's read path justifies a spike.

**Files, all in `docs/research/`.**

- `2026-10-28-computer-use-drivers-bench.py`: the driver. Reuses the `Driver` class from `scripts/lab/cua-bench.py`, so it spawns cua exactly as Perry does (`mcp --direct --embedded --host-bundle-id dev.perry.Perry`).
- `2026-10-28-computer-use-drivers-bench.sh`: the matrix runner. Runs arms A–D and F in alternating order across two rounds, then the AX micro benchmark.
- `2026-10-28-ax-walk-micro.swift`: times three walks of the same Finder window in-process. Type-checked on the mini with Xcode 27 (`swiftc -typecheck`, no errors) but not run.

**What was and was not verified.** I ran the Python script end to end against a fake MCP driver that implements the Finder rename state machine and really renames files. It restored the fixture and recorded timings for every op. `sh -n` and `py_compile` pass. The Peekaboo arm is **[U]**: its flags come from `docs/commands/*.md` (`see`, `click`, `press`, `type`, `set-value`), and the JSON field names it looks for (`id`, `snapshot_id`, element `label`) are guesses. Run it once with `--repeats 1` and fix the parsing against the real JSON before the full run. Nothing here has touched a real window.

**Fixture.**

- A folder with enough files that its list-view Finder window reports 800+ elements in `get_window_state` (record `notes.read_perry.elements` in the output).
- One window, fixed size, Stage Manager off, nothing else on the screen.
- `FIXTURE_FILE` is a plain file the rename ops may rename to `<stem>-bench<ext>` and back. The script checks the filesystem after every rename.

**Arms.**

| Arm | Driver | Settings | Tests |
| --- | --- | --- | --- |
| A | 0.38.0 | Perry's flags; foreground delivery (as Perry forces for Finder) | Baseline |
| B | 0.38.0 | + `CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS=0`, `CUA_DRIVER_KEY_GAP_MS=2` | Knobs in the shipped build |
| C | nightly 20261028 | `post_action_wait: "none"` on every action | The per-call argument |
| D | nightly 20261028 | as C, `delivery_mode: background` | Whether Finder needs foreground |
| F | Peekaboo 4.9.7 CLI | `see --fresh --tree --no-screenshot`, `click`, `press`, `type`, `set-value` | The challenger's read and act path |
| G | none | `ax-walk-micro`: `single` (cua-style), `batched`, `batchedVisible` | Whether batching or `AXVisibleRows` pruning is worth it |

**Operations per arm** (the script's `--ops`):

- `read`: Perry's exact read; no screenshot; screenshot only; `max_depth` 6; `query`; `since:"latest"`. This shows what each parameter does to wall time.
- `click`: element-token click on the file row.
- `rename-type`: click, Return, read for the field, `type_text`, Return, with each step timed separately plus the total.
- `rename-setvalue`: the same with `set_value`.
- `batch`: the same rename as one `run_steps` call.

**Protocol.**

1. Mini only. The mini must be idle: the earlier run saw load average 5–10 from another session and 15% round-to-round drift (`docs/evidence/cua-upgrade/README.md`). Check `uptime` before and after.
2. Run through the LaunchAgent harness `docs/evidence/cua-upgrade/harness/run-agent.sh` and use `CuaDriver.app/Contents/MacOS/cua-driver` from each tarball, so the process inherits the grants the mini already holds. Plain ssh reports `accessibility:false` (same README). The nightly tarball is already on the mini, checksum-verified, at `~/Honey/research/cua-nightly-20261028/x/*/CuaDriver.app/Contents/MacOS/cua-driver`.
3. Two rounds, second in reverse order (the script does this). `REPEATS=10` gives n=20 pooled per cell. Report p50, p95 and max. Treat anything under 15% as noise.
4. Peekaboo and the Swift micro benchmark each need their own Accessibility (and Screen Recording for Peekaboo's screenshot) grant. The user grants those in System Settings. I did not trigger or answer any permission prompt.

**Run it.**

```sh
export CUA_038=/path/to/0.38.0/CuaDriver.app/Contents/MacOS/cua-driver
export CUA_NIGHTLY="$(ls -d ~/Honey/research/cua-nightly-20261028/x/*/CuaDriver.app/Contents/MacOS/cua-driver)"
export FIXTURE_DIR=/path/to/fixture FIXTURE_FILE=report.txt
export DEVELOPER_DIR=~/Applications/Xcode-27.app/Contents/Developer
export PEEKABOO=/path/to/peekaboo
sh docs/research/2026-10-28-computer-use-drivers-bench.sh
```

The bench script prints a p50/p95/max table per op and writes the raw samples to `bench-out/*.json`. Peekaboo's release binary is `peekaboo-macos-arm64.tar.gz` (15.5 MB) on its 4.9.7 GitHub release.

**Decision rules, set before running.**

- **Keep cua and adopt the changes** if no arm beats A by more than noise on `read_perry` and `rename_*_total` other than through knobs and call patterns (B, C, D, `batch`).
- **Ask cua for batched reads and `AXVisibleRows`** if `ax-walk-micro` shows `batched` at 0.5x `single` or better, or `batchedVisible` at 0.4x or better. The cua walk shape, not the driver choice, would then be the problem.
- **Spike Peekaboo as an in-process read-only walker** only if its `see_tree_fresh` p50 is at most half of `read_no_screenshot` p50 on the same window **and** the micro benchmark does not already explain the gap. Even then, keep cua for acting, because of the manifest and verification model.
- **Switch** only if a challenger meets all of: rename total at most 0.7x of the best cua arm, equal success count over the repeats, and a way to keep Perry's immutable-ceiling guarantee. I do not expect any candidate to meet the third condition today.

## Gaps and follow-ups

- I did not run any driver on a real window, by constraint. Every latency figure for Finder in this report is either Perry's earlier measurement or an explicit inference.
- The cua IPC count per node is estimated from reading `walk_element`, not traced. `sample`, Instruments or a counting shim around the `AXUIElementCopyAttributeValue` binding would settle it.
- Ghost OS and Macbeth were checked by metadata only. Neither is recent or active enough to change the verdict.
- macctl and "Leap" could not be located. If either was a real project, a repo link would let me read it.
- Why Perry forces foreground for Finder (git history around `foregroundOnlyBundleIDs`) is not traced here. It decides whether change 5 is safe.
- Before the next pin, check whether PR #6033 has reached a tagged `cua-driver-rs` release. As of 2026-10-28 the newest tag is still `cua-driver-rs-v0.38.0`.
