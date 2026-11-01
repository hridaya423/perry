#!/usr/bin/env python3
"""Time agent-desktop operations the way Perry runs them.

Usage: driver-bench.py --label <name> --out <json> [--repeats 20] [--ops cold,warm,click,type]

cold lists windows from a brand-new session, so every sample starts a command host.
warm snapshots the TextEdit bench window from a live session. click presses a
Calculator button by ref. type types into a TextEdit document the bench creates
and closes unsaved; it refuses to run if that document cannot be found by name.
"""

import argparse
import json
import os
import platform
import statistics
import subprocess
import sys
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agent_desktop as ad


def osa(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True).stdout.strip()


def stats(samples):
    if not samples:
        return {"n": 0}
    ordered = sorted(samples)

    def pct(p):
        return ordered[min(len(ordered) - 1, round(p * (len(ordered) - 1)))]

    return {"n": len(ordered), "p50": pct(0.5), "p95": pct(0.95), "max": ordered[-1],
            "min": ordered[0], "mean": statistics.fmean(ordered), "samples": samples}


def stop_hosts(prefix):
    listing = subprocess.run(["ps", "-Eww", "-o", "pid=,command="], capture_output=True, text=True).stdout
    for line in listing.splitlines():
        if "AGENT_DESKTOP_INTERNAL_COMMAND_HOST=1" in line and f"AGENT_DESKTOP_SESSION={prefix}" in line:
            subprocess.run(["kill", line.split()[0]], check=False)


def timed(*arguments):
    started = time.perf_counter()
    ad.call(*arguments)
    return (time.perf_counter() - started) * 1000


def bench_document():
    name = f"perry-driver-bench-{uuid.uuid4().hex[:8]}"
    osa(f'tell application "TextEdit" to make new document with properties {{name:"{name}"}}')
    osa('tell application "TextEdit" to activate')
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        for window in ad.windows(app_name="TextEdit"):
            if window.get("title", "").startswith(name):
                return name, window
        time.sleep(0.3)
    osa(f'tell application "TextEdit" to close (every document whose name is "{name}") saving no')
    raise SystemExit("driver-bench: the bench TextEdit document never appeared; refusing to type anywhere else")


def calculator_button():
    subprocess.run(["open", "-b", "com.apple.calculator"], check=False)
    time.sleep(1.5)
    window = next(iter(ad.windows(app_name="Calculator")), None)
    if not window:
        raise SystemExit("driver-bench: Calculator has no window")
    for wanted in ("5", "Five", "All Clear", "Clear"):
        node = ad.find(window["id"], wanted, "button")
        if node:
            return node["ref_id"]
    raise SystemExit("driver-bench: no Calculator button to click")


def run(args):
    ops = args.ops.split(",")
    report = {"label": args.label, "machine": platform.node(), "repeats": args.repeats,
              "driver": ad.DRIVER, "ops": {}, "errors": {}}

    def sample(op, *arguments):
        try:
            report["ops"].setdefault(op, []).append(timed(*arguments))
        except ad.DriverError as error:
            report["errors"].setdefault(op, []).append(str(error))

    name = None
    try:
        if "warm" in ops or "type" in ops:
            name, window = bench_document()
            field = next((n["ref_id"] for n in ad.nodes(window["id"]) if n.get("role") in ("textfield", "textarea")), None)
            if not field:
                raise SystemExit("driver-bench: the bench document has no text area")
        for _ in range(args.repeats):
            if "cold" in ops:
                ad.SESSION = f"bench-cold-{uuid.uuid4().hex[:8]}"
                sample("cold", "list-windows")
                ad.SESSION = "perry-bench"
            if "warm" in ops:
                sample("warm", "snapshot", "--window-id", window["id"], "--include-bounds", "--max-depth", "12", "-i")
            if "type" in ops:
                sample("type", "type", field, "perry ")
        if "click" in ops:
            ref = calculator_button()
            for _ in range(args.repeats):
                sample("click", "click", ref)
    finally:
        stop_hosts("bench-")
        stop_hosts("perry-bench")
        if name:
            osa(f'tell application "TextEdit" to close (every document whose name is "{name}") saving no')
    report["ops"] = {op: stats(samples) for op, samples in report["ops"].items()}
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--repeats", type=int, default=20)
    parser.add_argument("--ops", default="cold,warm,click,type")
    args = parser.parse_args()
    ad.SESSION = "perry-bench"
    report = run(args)
    with open(args.out, "w") as handle:
        json.dump(report, handle, indent=2)
    print("| op | n | p50 ms | p95 ms | max ms | errors |")
    print("|---|---|---|---|---|---|")
    for op, row in report["ops"].items():
        if row["n"]:
            print(f"| {op} | {row['n']} | {row['p50']:.0f} | {row['p95']:.0f} | {row['max']:.0f} | {len(report['errors'].get(op, []))} |")


if __name__ == "__main__":
    main()
