# Phase 0 spike results

Date: 2026-09-25. Machine: M4 Pro, macOS 27, Xcode 26.6.

## Spike 1: Codex app-server (`scripts/lab/codex-appserver-spike.swift`)

Drives the bundled `codex app-server` (0.132.0) over stdio JSON-RPC:
initialize → account/read → model/list → thread/start (ephemeral) →
turn/start (text + `localImage`). Auth: reused `~/.codex` (ChatGPT account,
prolite) read-only, plus a clean home with only `auth.json` copied in.

Measured:

| setup | spawn→initialized | turn/start→first agent text |
|---|---|---|
| `~/.codex` (user config: 7 MCP servers, skills) | 342–1125 ms | 8.7 s; 16.6 s |
| clean home (auth.json only), gpt-5.5 default effort | 304–899 ms | 34.1 s; 12.6 s |
| clean home, gpt-5.5 `--effort low` | 87 ms | 15.6 s; 17.4 s |

Findings:

- ChatGPT sign-in works; `account/read` returns the account, and
  `account/rateLimits/updated` notifications arrive free (prolite, primary
  window 84% used during measurement; may inflate latency).
- `model/list` offers gpt-5.5, gpt-5.4, gpt-5.4-mini, gpt-5.3-codex, gpt-5.2,
  but under ChatGPT auth **only gpt-5.5 ran**; gpt-5.4 and gpt-5.4-mini were
  rejected: "not supported when using Codex with a ChatGPT account."
- `--effort minimal` is rejected while built-in `image_gen`/`web_search`
  tools are attached; `low` works.
- `thread/start` in 0.132.0 has no top-level `dynamicTools` param;
  `DynamicToolSpec` exists in the schema, likely behind
  `capabilities.experimentalApi` (which the spike already sends). Phase 1 must
  confirm the exact wire path for dynamic tools.
- Image input works (`localImage` accepted, attached to the turn).

**Decision gate (plan §7.0.4): first-delta p50 > 1.5 s → CONFIRMED.** Best
observed was ~6.4 s; typical 12–34 s. The Talk fast path must use Apple
Foundation Models / on-device for acknowledgement + draw, with Codex
streaming the substance, as the plan's gate prescribes. Note: measured on an
account at 84% of its weekly rate window; per-machine numbers should be
re-measured after the user signs Perry in to its own CODEX_HOME, but the gate
outcome is unlikely to flip (best case is still >4× over).

## Spike 2: deixis feasibility

- `SpeechAnalyzer` (macOS 26+): compiles and typechecks against the 26.5 SDK
  (`swiftc -typecheck` pass); the streaming-STT path exists.
- `SFTranscriptionSegment.timestamp`/`duration`: already shipping;
  DictationController uses SFSpeechRecognizer (it reads
  `bestTranscription.formattedString`, not segments yet). A live word-timing
  probe (`scripts/lab/sfstt-timestamps.swift`, file-based recognition via
  `say` output, no mic needed) was **TCC-killed**: a bare `swift` process has
  no `NSSpeechRecognitionUsageDescription`, so `requestAuthorization` aborts
  (`__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`). Runtime verification of
  populated word timestamps must run inside Perry.app (entitled), cheap to
  add when `SpeechInput` lands in Phase 2.
- AX hit-test at 60 Hz: `get_window_state` through the bundled driver's MCP
  path took **4.0–5.5 s per call** (3 samples, Finder window; the call itself
  includes an AX walk + capture attempt). Per-frame IPC is impossible by two
  orders of magnitude. The plan's preferred design is confirmed: **one cached
  element tree per observation + a local geometric hit-test on the
  pointer-trace recorder**, refreshed per utterance, not per frame.

## Spike 3: reach (bundled cua-driver 0.22.1, `capabilities.yaml`)

Driven exactly as Perry drives it: `cua-driver mcp --direct --embedded` with
`CUA_DRIVER_CAPABILITY_MANIFEST_FILE` + `CUA_DRIVER_PERMISSION_MODE=bounded`
(via `scripts/lab/cua-mcp.py`).

- Stock manifest: `list_windows` refused outright (`desktop.display: false`),
  `get_window_state` on ChatGPT (pid 686) refused
  `bounded_resource_outside_manifest`; the allowlist is enforced. ✔
- `desktop.display: true` unlocks `list_windows` (71 windows enumerated). ✔
- `apps` as scalar `any` → manifest rejected, driver never answers
  initialize. `bundle_id: "*"` → parses but still refuses (no wildcard
  semantics). Omitting `apps` → refused. Binary strings confirm the grammar:
  each app resource needs `bundle_id` or `executable`.
- **Conclusion: 0.22.1 has no any-app manifest mode.** Perry must generate
  the `apps:` allowlist dynamically from `list_apps` at session start, minus
  the Perry-side blocklist, the plan §6.5 fallback path. The blocklist check
  runs in `GuideTargetValidator.requireUnprotected` before any capture call.

## Not done this round (user blockers)

- TCC grants for the Perry.app build (Screen Recording + Accessibility):
  embedded-driver AX reads return `degraded` / `element_count: 0` and window
  capture errors `px_capture_unavailable` until granted.
- HeyClicky install + sign-in for the §9 baseline scorecard.
