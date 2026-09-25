# Phase 0 idle baseline

Date: 2026-09-25 (UTC). Build: `build/debug-p1` Debug, macOS 27 arm64.

Command:

```sh
scripts/lab/perry-drive.sh launch        # pid 62455, PERRY_PERFORMANCE_EVENT_LOG set
scripts/lab/idle-probe.sh --seconds 60
```

Result (60 samples, no interaction, session panel dismissed):

| metric | value | budget | verdict |
|---|---|---|---|
| avg CPU | 0.000% | ≤0.5% | PASS |
| max CPU | 0.000% | n/a | n/a |
| max RSS | 310.1 MB | ≤180 MB | FAIL |

CSV: `docs/evidence/perf/idle-20260925T211517Z.csv`.

Notes:

- Idle CPU is clean; RSS at ~310 MB exceeds the 180 MB budget by ~1.7×.
  Debug build, post-session (panel was opened and dismissed before the probe).
- Marker pipeline verified live in the same run:
  `invoke.keydown → panel.visible` = 133 ms (n=1), via
  `docs/evidence/lab/perf-20260925T211332Z.jsonl.markers.jsonl` and
  `scripts/lab/latency-report.py`.
