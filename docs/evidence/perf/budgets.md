# §8 Absolute budgets — consolidated scorecard (2026-10-01)

Every measured row cites its artifact. "Blocked" rows name the exact
user-owned action that unblocks them — nothing is claimed without a
measurement.

| Metric | Budget | Result | Evidence |
|---|---|---|---|
| Key-down → visible listening | ≤50 ms p95 | **31 ms** (n=1) | `invoke.keydown → panel.visible`, `docs/evidence/lab/perf-20261001T174941Z.jsonl.markers.jsonl` |
| Release → first text | ≤700 ms p50 / ≤1.5 s p95 | BLOCKED — needs physical ⌥⌘Space hold (Input Monitoring ungranted on adhoc build) | `ptt.capture.fallback` marker; Settings row renders live |
| Release → first audio | ≤1.0 s p50 realtime / ≤1.4 s system | BLOCKED — same PTT path | — |
| Release → first ink on target | ≤1.5 s p50 | BLOCKED — same | — |
| Cursor follow lag | ≤1 frame | 16 ms timer poller, same-frame; 120 Hz recording leg not rerun | `docs/evidence/phase-3/README.md` |
| Barge-in → silence | ≤150 ms | **1 / 6 / 1 ms** (3 firings — all shutdown/launch cancels, not user barge) | `talk.bargein → bargein.silence`, `perf-20261001T174941Z` + earlier logs |
| Idle CPU avg / max RSS | ≤0.5% / ≤180 MB | **0.0% / ~114–131 MB** across partial soaks; 8-h run in progress | `docs/evidence/perf/idle-*.csv`; current: `idle-20261001T174951Z.csv` |
| Home hover → peek | ≤120 ms | **p50 113 / p95 117.5 / max 119 ms** (n=6, tolerance=0 timer) | `docs/evidence/phase-5/README.md` |
| Dictation release → text | ≤450 ms (26+) | BLOCKED — mic + speech TCC | — |
| First run → answer / done | ≤90 s / ≤3 min | BLOCKED — onboarding TCC acceptance is user-owned | — |
| Stuck states | 0; exit ≤10 s | **PASS** — `SessionExitAuditTests` enumerates SessionController states × events | PerryTests suite green |
| Per-turn tool calls | ≤60 calls / ≤20 min | Enforced in agent loop (unit-tested) | PerryBrain suite |
| 8-h soak + 200 Talk turns | no leaks; <30 MB growth; ≤0.5% CPU | Soak running (pid 97513); 200-turn leg needs composer focus (AX-walled) | `idle-20261001T174951Z.csv` |

## How to unblock each blocked row

- **PTT rows**: grant Perry Input Monitoring (Settings → Permissions →
  Input Monitoring, then physically hold ⌥⌘Space). `ptt.capture.eventtap`
  replaces `ptt.capture.fallback` when the tap creates.
- **Dictation/first-run**: grant Microphone + Speech Recognition.
- **200 Talk turns**: needs one focused composer session — drive the
  panel with the cursor when the machine is idle.
- **BT preroll** (`audio.preroll.bt`): connect AirPods, trigger a
  reply, switch route mid-utterance.
