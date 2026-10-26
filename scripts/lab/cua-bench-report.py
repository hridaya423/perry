#!/usr/bin/env python3
"""Print markdown tables from cua-bench.py JSON files.

Usage: cua-bench-report.py <dir-with-r*-*.json>

Files are named r<round>-<label>.json. Each column is one label; the cells are
p50 / p95 / max in milliseconds, per round and pooled over all rounds.
"""

import json
import sys
from pathlib import Path

OPERATIONS = [
    ("cold_spawn_plus_first_get_window_state", "cold spawn + first get_window_state"),
    ("cold_spawn_and_initialize", "  spawn + initialize"),
    ("cold_first_get_window_state", "  first get_window_state"),
    ("warm_get_window_state", "warm get_window_state"),
    ("click_calculator_button", "click"),
    ("type_text_textedit", "type_text"),
]


def load(directory):
    runs = {}
    for path in sorted(Path(directory).glob("r*-*.json")):
        round_name, label = path.stem.split("-", 1)
        runs.setdefault(round_name, {})[label] = json.loads(path.read_text())
    return runs


def summarize(samples):
    ordered = sorted(samples)
    if not ordered:
        return "n/a"

    def pct(p):
        return ordered[max(0, min(len(ordered) - 1, round(p / 100.0 * (len(ordered) - 1))))]

    return f"{pct(50):.0f} / {pct(95):.0f} / {ordered[-1]:.0f} (n={len(ordered)})"


def cell(reports, key):
    samples = []
    for report in reports:
        row = report["results"].get(key)
        if row:
            samples += row.get("samples_ms", [])
    return summarize(samples)


def main():
    runs = load(sys.argv[1])
    labels = sorted({label for reports in runs.values() for label in reports})
    sections = [(name, {label: [reports[label]] for label in labels if label in reports}) for name, reports in runs.items()]
    sections.append(("pooled", {label: [r[label] for r in runs.values() if label in r] for label in labels}))
    for name, by_label in sections:
        print(f"### {name}: p50 / p95 / max ms\n")
        print("| operation | " + " | ".join(labels) + " |")
        print("| --- | " + " | ".join("---" for _ in labels) + " |")
        for key, title in OPERATIONS:
            print(f"| {title} | " + " | ".join(cell(by_label.get(label, []), key) for label in labels) + " |")
        print()


if __name__ == "__main__":
    main()
