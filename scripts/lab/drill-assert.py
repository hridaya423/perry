#!/usr/bin/env python3
"""Assert talk-drill budgets against a markers JSONL.

Runs latency-report.py for the gated pairs, counts outcome markers, and
prints PASS/FAIL per check. Exit 1 on any failure. Budgets come from the
environment — only set variables are enforced:

    ASSERT_FIRST_TEXT_P50 / _P95  ms, talk.keyup -> answer.first_text
    ASSERT_CAPTURE_P50            ms, talk.keyup -> capture.done
    ASSERT_BARGE_P50              ms, talk.bargein -> bargein.silence
    ASSERT_DEIXIS_PCT             % of deixis outcomes bound to an element
    ASSERT_ANSWERED_PCT           % of holds that produced an answer

Usage: drill-assert.py <markers.jsonl> <runs>
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

PAIRS = [
    "talk.keyup:answer.first_text",
    "talk.keyup:capture.done",
    "talk.bargein:bargein.silence",
]


def report_for(markers: Path) -> dict:
    report = Path(__file__).with_name("latency-report.py")
    argv = [sys.executable, str(report), str(markers), "--json"]
    for pair in PAIRS:
        argv += ["--pair", pair]
    return json.loads(subprocess.run(argv, check=True, capture_output=True, text=True).stdout)


def marker_counts(markers: Path) -> dict[str, int]:
    counts: dict[str, int] = {}
    for line in markers.read_text().splitlines():
        if not line.strip():
            continue
        try:
            name = json.loads(line)["name"]
        except (json.JSONDecodeError, KeyError):
            continue
        counts[name] = counts.get(name, 0) + 1
    return counts


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    markers = Path(argv[1])
    runs = int(argv[2])
    if not markers.is_file():
        print(f"drill-assert: no such file: {markers}", file=sys.stderr)
        return 2

    report = report_for(markers)
    checks: list[tuple[bool, str]] = []

    def expect(label: str, pair: str, stat: str, budget_var: str) -> None:
        budget = os.environ.get(budget_var)
        if budget is None:
            return
        value = (report.get(pair) or {}).get(stat)
        ok = value is not None and value <= float(budget)
        shown = f"{value:.1f}" if value is not None else "no samples"
        checks.append((ok, f"{label}: {shown} <= {budget}"))

    expect("first_text p50", "talk.keyup -> answer.first_text", "p50_ms", "ASSERT_FIRST_TEXT_P50")
    expect("first_text p95", "talk.keyup -> answer.first_text", "p95_ms", "ASSERT_FIRST_TEXT_P95")
    expect("capture p50", "talk.keyup -> capture.done", "p50_ms", "ASSERT_CAPTURE_P50")
    expect("bargein p50", "talk.bargein -> bargein.silence", "p50_ms", "ASSERT_BARGE_P50")

    counts = marker_counts(markers)
    deixis = sum(counts.get(f"deixis.{k}", 0) for k in ("element", "point", "window", "none"))
    if deixis and os.environ.get("ASSERT_DEIXIS_PCT"):
        pct = 100.0 * counts.get("deixis.element", 0) / deixis
        checks.append((
            pct >= float(os.environ["ASSERT_DEIXIS_PCT"]),
            f"deixis.element: {pct:.0f}% >= {os.environ['ASSERT_DEIXIS_PCT']}%",
        ))
    if os.environ.get("ASSERT_ANSWERED_PCT"):
        pct = 100.0 * counts.get("answer.first_text", 0) / runs
        checks.append((
            pct >= float(os.environ["ASSERT_ANSWERED_PCT"]),
            f"answered: {pct:.0f}% >= {os.environ['ASSERT_ANSWERED_PCT']}%",
        ))

    if not checks:
        print("drill-assert: no ASSERT_* budgets set — nothing checked", file=sys.stderr)
        return 2

    failed = False
    for ok, line in checks:
        print(("PASS " if ok else "FAIL ") + line)
        failed |= not ok
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
