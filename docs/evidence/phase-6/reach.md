# Phase 6.5 evidence — Cua reach (generated capability manifest)

Date: 2026-10-01 (live, main machine). Commits: `193dd68`, `04ec096`,
`d5ff030`, `2b48ce8`, `2d1176a`, `499595f`.

## What shipped

- `App/CuaCapabilityManifest.swift` generates the driver manifest at each
  worker spawn (effectively per session): installed + running app bundle
  IDs minus `TrustGuard.defaultBlockedBundleIDs`, explicit `bundle_id`
  entries (driver 0.22.1 has no `apps: any` — verified in the phase-0
  spike), `desktop.display: true`, and the §6.5 tool list
  (`get_desktop_state`, `zoom`, `set_value`, `invoke_menu`, `launch_app`,
  `browser_*`, `clipboard_*`, `get_cursor_position`, …). Output:
  `~/Library/Application Support/Perry/CuaDriver/capabilities.yaml`.
- Wired into `CuaDriverConfiguration.resolvedConfiguration()`; the bundled
  six-app manifest remains the fallback if generation fails.
- `browser_readback` was emitted initially and removed — the bundled driver
  rejects unreviewed tool names at manifest load.
- `PerryErasureErasers` erases `CuaDriver/` with the other Cua artifacts
  (`d5ff030`); the seeded-profile erasure test covers it automatically.

## Live verification

- Generated manifest: 193 app entries on this machine; parses on bundled
  driver 0.22.1 (`cua-driver` starts clean with
  `CUA_DRIVER_CAPABILITY_MANIFEST_FILE` pointed at it).
- Raw driver under a granted terminal identity: `list_windows` → 53
  windows; `get_window_state` → 1.1 MB screenshot + AX tree (Helium
  `net.imput.helium`, Windsurf `com.exafunction.windsurf`).
- Through Perry's own MCP socket (`tools/call screen.observe` with an
  explicit `bundleID`): the previous capability refusal is gone; the call
  reaches the driver's `get_window_state`, returns AX data, and fails only
  on pixels — `Cua Driver returned no target-window screenshot`.

## TCC attribution findings (tccd log)

- `dev.perry.Perry` held **no** grants: `kTCCServiceScreenCapture`,
  `kTCCServiceMicrophone`, `kTCCServiceAudioCapture` all return
  `Auth Right: Unknown` — the app only ever preflighted; nothing had ever
  called `CGRequestScreenCaptureAccess`.
- `193dd68` wired `requestScreenRecording`/`requestAccessibility` into the
  onboarding `.screenAccess` beat; `2d1176a` added Settings → General →
  Permissions with live status + Enable buttons. Tapping Enable produced a
  real `TCCAccessRequest` (preflight=no) in tccd.
- `kTCCServiceListenEvent` (macOS "Device Control and Data Access") had 80+
  requests attributed to Perry; the system prompt "Perry would like to
  control this Mac and access your data" was pending on screen. This grant
  is a user action; it and Screen Recording are the last blockers for
  in-app pixel capture.
- Adhoc rebuilds change the code requirement — prior grants do not carry
  over ("Failed to match existing code requirement" in tccd). Distribution
  signing will fix this; lab builds re-prompt.

## Test isolation fix found during verification

- Hosted `xcodebuild test` boots the app and the delayed MCP start
  unlinked/rebound the real `perry-mcp.sock`, orphaning a live instance's
  listener. `2b48ce8` guards the auto-start on
  `XCTestConfigurationFilePath` — verified: a suite run leaves the running
  Release socket intact (listener fd + path mtime unchanged, socket still
  answers `tools/list`).

## Perf evidence this session

- `idle-20261001T002519Z.csv` / `idle-20261001T003555Z.csv` — two ~8–10 min
  fragments, ~85.7 MB flat RSS, ~0.0% CPU (instances restarted for the
  fixes above).
- `idle-20261001T004529Z.csv` — the live 8 h soak on Release pid 86438;
  running at handoff (~132 MB with Settings materialized, 0.0% CPU).
