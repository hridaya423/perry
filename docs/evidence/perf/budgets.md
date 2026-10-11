# §8 Absolute budgets — consolidated scorecard (2026-10-11)

Every measured row cites its artifact. "Blocked" rows name the exact
user-owned action that unblocks them — nothing is claimed without a
measurement.

Since 2026-10-11 the talk drill (`scripts/lab/talk-drill.sh`) exercises
the real ⌃⌥ Talk path end to end: real `ModifierHoldMonitor` seam via a
DEBUG-only distributed notification (the TCC session tap is unavailable
to unsigned lab launches), real capture (now via `LocalTalkObserver` —
local window list + AX hit-test + bounded index + ScreenCaptureKit — with
the embedded Cua Driver as fallback), scripted/WAV speech input,
bundled-Codex provider on persistent threads, DrillTarget keypad fixture
(`scripts/lab/drill-target.swift` — deterministic AX buttons; Calculator
cannot reliably reopen a window under Stage Manager).

| Metric | Budget | Result | Evidence |
|---|---|---|---|
| Key-down → visible listening | ≤50 ms p95 | **PASS — p50 3.5–8 ms, p95 ≤36 ms** (n=13, ⌃⌥ drill) | `talk.keydown → talk.listening`, `perf-20261011T125141Z`, `perf-20261011T130215Z` markers |
| Hold → commit threshold | ~120 ms design | p50 135–140 ms (n=13) | `talk.keydown → talk.hold_commit`, same runs |
| Key-down → capture done | (no set budget) | **p50 270–308 ms, max 397 ms** (n=10, local path). Was p50 3.4–5.5 s through the driver tree walk | `talk.keydown → capture.done`, `talk.capture_local` marks, `perf-20261011T153845Z` |
| Release → first text | ≤700 ms p50 / ≤1.5 s p95 | **FAIL — p50 1.8–3.7 s** across fixture drills (n=10, bundled Codex persistent thread, gpt-5.6-terra effort=none). Was p50 5.8 s / p95 14.4 s on fresh threads. Spike floor ~1.5 s warm | `talk.keyup → answer.first_text`, `perf-20261011T160851Z`, `perf-20261011T161438Z` |
| Release → first audio | ≤1.0 s p50 realtime / ≤1.4 s system | **FAIL — p50 2.0–4.3 s** (system voice; audio lands ~180 ms after first text, so the gap is provider, not TTS) | `talk.keyup → talk.first_audio`, same runs |
| Release → first ink on target | ≤1.5 s p50 | **FAIL — p50 6.6 s** (n=3; model emits ink in ~⅓ of answers) | `talk.keyup → ink.first_draw`, `perf-20261011T125141Z` |
| Deixis: "this" → pointed element | ≥90% | **36/36 element-bound** on answered runs where the pointer rested on a real target element (fixture keypad: 6/6, 3/3 + 1 point; Calculator: 27/27 earlier) | `deixis.element` markers, all drill runs |
| Cancelled turn must not poison provider | cancels never mark provider down | **PASS** — `HealthReportingStream` no longer reports failure on consumer cancel (cancelling a task for-awaiting an AsyncThrowingStream ends iteration with nil, previously counted as an unterminated stream; two drill cancels used to blacklist Codex for 60 s → instant router `notConfigured` on the next hold) | `ProviderRouterTests.testCancelledStreamDoesNotMarkProviderDown`, `perf-20261011T155201Z` (incident) |
| Screenshot reaches the model | every answered turn carries its image | **PASS post-fix** — the app-server decodes every attachment as PNG regardless of declared type; JPEG screenshots were silently dropped all day (`failed to decode image … decoding Png` in `logs_2.sqlite`). Provider now transcodes to PNG at the wire | `CodexAppServerProviderTests.testPNGWireData*`, CodexRuntime `logs_2.sqlite` WARN rows |
| Capture failure isolation | one failure must not kill later turns | **PASS** — pre-fix, one hung operation wedged claims (`resourceBusy`) or the scope slot (`capacityReached`) for every later turn; post-fix, runs after a `capture_failed` answer again | `perf-20261011T131239Z` (wedge), `perf-20261011T132351Z` (recovery) |
| Cursor follow lag | ≤1 frame | 16 ms timer poller, same-frame; 120 Hz recording leg not rerun | `docs/evidence/phase-3/README.md` |
| Barge-in → silence | ≤150 ms | **PASS — p50 2 ms, max 3 ms** (n=3, real press during playback; previously measured only shutdown cancels) | `talk.bargein → bargein.silence`, `perf-20261011T130215Z` |
| Idle CPU avg / max RSS | ≤0.5% / ≤180 MB | **0.0% / ~114–131 MB** across partial soaks; 8-h run in progress | `docs/evidence/perf/idle-*.csv` |
| Home hover → peek | ≤120 ms | **p50 113 / p95 117.5 / max 119 ms** (n=6, tolerance=0 timer) | `docs/evidence/phase-5/README.md` |
| Dictation release → text | ≤450 ms (26+) | BLOCKED — mic + speech TCC | — |
| First run → answer / done | ≤90 s / ≤3 min | BLOCKED — onboarding TCC acceptance is user-owned | — |
| Stuck states | 0; exit ≤10 s | **PASS** — `SessionExitAuditTests` enumerates SessionController states × events | PerryTests suite green |
| Per-turn tool calls | ≤60 calls / ≤20 min | Enforced in agent loop (unit-tested) | PerryBrain suite |
| 8-h soak + 200 Talk turns | no leaks; <30 MB growth; ≤0.5% CPU | Soak running (pid 97513); 200-turn leg needs composer focus (AX-walled) | `idle-20261001T174951Z.csv` |

## What the drill exposed

- **Provider path is now the only missing row's blocker.** Capture went
  from p50 3.4–5.5 s (driver tree walk, 6–11 s per `get_window_state`
  call under load) to p50 ~300 ms via the local observer: CGWindowList
  window pick, AXUIElement hit-test at the pointer, a bounded index of
  the pointed element + parent + ≤30 siblings, ScreenCaptureKit JPEG —
  all inside a 4 s timeout with the driver as fallback. Remaining gap is
  Codex first-token latency itself: `capture.done → answer.first_text`
  p50 3.4–5.4 s on persistent `gpt-5.6-terra` threads, matching the
  spike's cold-turn range (warm floor ~1.5 s measured in the matrix).
  The ≤700 ms release→text budget cannot be met on this provider.
- **Launch attribution decides whether capture works.** Launched through
  `open`/LaunchServices, the embedded Cua Driver cannot confirm Perry's
  Screen Recording/Accessibility grants and capture fails; launched
  directly from a trusted terminal chain it succeeds. Onboarding must
  verify Perry's own grants under the app's real launch path — an
  external driver's green TCC status proves nothing.
- **The worker pool used to wedge on one bad operation.** An operation
  that ignored cancellation left its claims (`resourceBusy`) or its
  scope slot (`capacityReached`) held forever — one Codex error turned
  Talk permanently dead until relaunch. `CuaWorkerService` now drops
  the entry whenever retirement has run. The local capture path claims
  no worker at all, so this failure class cannot reach Talk.
- **Deixis is correct on a still pointer.** Parked on Calculator's "5"
  button, "what's this?" binds the element 11/11 and answers "That's the
  5 key."
- **Barge-in is real now.** The turn stays active until playback drains;
  a mid-speech press cuts audio in ~2 ms. It also exposed two adjacent
  bugs now fixed: cancelled turns used to feed the router's health
  circuit (two cancels → 60 s provider blackout), and Codex silently
  dropped every JPEG attachment, so answers were generated blind.
- **Stray input is correctly hostile.** A real keyDown during a hold
  cancels it as a chorded shortcut (`talk.cancel.chord.key*`) — drills
  need a quiet machine; human typing mid-drill produced those cancels.

## How to unblock each blocked row

- **Dictation/first-run**: grant Microphone + Speech Recognition.
- **200 Talk turns**: needs one focused composer session — drive the
  panel with the cursor when the machine is idle.
- **BT preroll** (`audio.preroll.bt`): connect AirPods, trigger a
  reply, switch route mid-utterance.
- **Real-tap Talk holds** (physical ⌃⌥ instead of the drill's
  notification seam): grant Perry Input Monitoring + Accessibility under
  the app's own launch attribution, then hold the keys.
