# §8 Absolute budgets — consolidated scorecard (2026-10-11)

Every measured row cites its artifact. "Blocked" rows name the exact
user-owned action that unblocks them — nothing is claimed without a
measurement.

Since 2026-10-11 the talk drill (`scripts/lab/talk-drill.sh`) exercises
the real ⌃⌥ Talk path end to end: real `ModifierHoldMonitor` seam via a
DEBUG-only distributed notification (the TCC session tap is unavailable
to unsigned lab launches), real capture through the embedded Cua Driver,
scripted/WAV speech input, bundled-Codex provider, Calculator target.

| Metric | Budget | Result | Evidence |
|---|---|---|---|
| Key-down → visible listening | ≤50 ms p95 | **PASS — p50 3.5–8 ms, p95 ≤36 ms** (n=13, ⌃⌥ drill) | `talk.keydown → talk.listening`, `perf-20261011T125141Z`, `perf-20261011T130215Z` markers |
| Hold → commit threshold | ~120 ms design | p50 135–140 ms (n=13) | `talk.keydown → talk.hold_commit`, same runs |
| Key-down → capture done | (no set budget) | p50 3.4 s, max 9.9 s (n=8); a later session measured p50 5.5–10.5 s — high variance, worker-side | `talk.keydown → capture.done` |
| Release → first text | ≤700 ms p50 / ≤1.5 s p95 | **FAIL — p50 5.8 s, p95 14.4 s, max 14.9 s** (n=8, bundled Codex, fresh thread per turn + full-size PNG) | `talk.keyup → answer.first_text`, `perf-20261011T125141Z` |
| Release → first audio | ≤1.0 s p50 realtime / ≤1.4 s system | **FAIL — p50 6.5 s, max 15.1 s** (n=8, system voice; audio lands ~180 ms after first text, so the gap is provider, not TTS) | `talk.keyup → talk.first_audio`, same run |
| Release → first ink on target | ≤1.5 s p50 | **FAIL — p50 6.6 s** (n=3; model emits ink in ~⅓ of answers) | `talk.keyup → ink.first_draw`, same run |
| Deixis: "this" → pointed element | ≥90% | **11/11 element-bound** (n=11 answered runs) | `deixis.element` markers, both runs |
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

- **Provider path dominates every missing row.** First text lands ~5–15 s
  after release on bundled Codex: each turn opens a fresh Codex thread,
  resends history as one JSON blob, and ships a full-size screenshot PNG.
  Audio/ink arrive ~0.2–0.6 s after first text, so TTS and drawing are
  not the problem. This is the Phase 1 fast-brain work.
- **Launch attribution decides whether capture works.** Launched through
  `open`/LaunchServices, the embedded Cua Driver cannot confirm Perry's
  Screen Recording/Accessibility grants and capture fails; launched
  directly from a trusted terminal chain it succeeds. Onboarding must
  verify Perry's own grants under the app's real launch path — an
  external driver's green TCC status proves nothing.
- **Deixis is correct on a still pointer.** Parked on Calculator's "5"
  button, "what's this?" binds the element 11/11 and answers "That's the
  5 key."
- **Barge-in is real now.** The turn stays active until playback drains;
  a mid-speech press cuts audio in ~2 ms.

## How to unblock each blocked row

- **Dictation/first-run**: grant Microphone + Speech Recognition.
- **200 Talk turns**: needs one focused composer session — drive the
  panel with the cursor when the machine is idle.
- **BT preroll** (`audio.preroll.bt`): connect AirPods, trigger a
  reply, switch route mid-utterance.
- **Real-tap Talk holds** (physical ⌃⌥ instead of the drill's
  notification seam): grant Perry Input Monitoring + Accessibility under
  the app's own launch attribution, then hold the keys.
