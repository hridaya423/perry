#!/usr/bin/env python3
"""Summarize Perry lab latency marks.

Reads a markers JSONL (PerformanceSampleLog's ``*.markers.jsonl`` rows:
``{"name": ..., "captured_at": <ISO8601>}``), pairs each ``end`` marker with the
most recent preceding unconsumed ``start`` marker, and prints n/p50/p95/max in
milliseconds per pair.

Usage: latency-report.py <markers.jsonl> [--pair start:end ...] [--json]
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

DEFAULT_PAIRS = [
    ("invoke.keydown", "panel.visible"),
    ("talk.keyup", "answer.first_text"),
    ("talk.keyup", "ink.first_draw"),
    ("capture.done", "answer.first_text"),
]


def parse_timestamp(raw: str) -> datetime:
    return datetime.fromisoformat(raw.strip().replace("Z", "+00:00"))


def load_markers(path: Path) -> list[tuple[datetime, str]]:
    markers = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        markers.append((parse_timestamp(row["captured_at"]), str(row["name"])))
    return markers


def durations_ms(
    markers: list[tuple[datetime, str]], start: str, end: str
) -> list[float]:
    durations = []
    pending_start = None
    for timestamp, name in markers:
        if name == start:
            pending_start = timestamp
        elif name == end and pending_start is not None:
            durations.append((timestamp - pending_start).total_seconds() * 1000.0)
            pending_start = None
    return durations


def percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = pct / 100.0 * (len(ordered) - 1)
    low = int(rank)
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (ordered[high] - ordered[low]) * (rank - low)


def summarize(durations: list[float]) -> dict:
    return {
        "n": len(durations),
        "p50_ms": percentile(durations, 50),
        "p95_ms": percentile(durations, 95),
        "max_ms": max(durations) if durations else None,
    }


def parse_pair(raw: str) -> tuple[str, str]:
    start, sep, end = raw.partition(":")
    if not sep or not start or not end:
        raise argparse.ArgumentTypeError(f"bad --pair {raw!r}; expected start:end")
    return start, end


def fmt_ms(value: float | None) -> str:
    return "-" if value is None else f"{value:.1f}"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("markers", type=Path, help="markers JSONL file")
    parser.add_argument(
        "--pair",
        action="append",
        type=parse_pair,
        default=None,
        metavar="START:END",
        help="marker pair to measure (repeatable); defaults to the lab set",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON")
    options = parser.parse_args(argv)

    if not options.markers.is_file():
        print(f"latency-report: no such file: {options.markers}", file=sys.stderr)
        return 2
    pairs = options.pair or DEFAULT_PAIRS
    markers = load_markers(options.markers)
    results = {
        f"{start} -> {end}": summarize(durations_ms(markers, start, end))
        for start, end in pairs
    }

    if options.json:
        print(json.dumps(results, indent=2, sort_keys=True))
    else:
        print("| pair | n | p50 ms | p95 ms | max ms |")
        print("|---|---|---|---|---|")
        for pair, stats in results.items():
            print(
                f"| {pair} | {stats['n']} | {fmt_ms(stats['p50_ms'])}"
                f" | {fmt_ms(stats['p95_ms'])} | {fmt_ms(stats['max_ms'])} |"
            )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
