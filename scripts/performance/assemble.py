#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import math
import platform
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import evaluate


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_METRICS_PATH = REPO_ROOT / "docs/release-readiness/performance/budgets.json"
REGISTERED_COLLECTORS = {
    "idle.cpu": {"perry.process-sampler.idle.v1"},
    "voice.session_memory_growth": {"perry.process-sampler.voice-endurance.v1"},
    "voice.realtime_first_audio": {"perry.app.realtime-first-audio.v1"},
    "voice.barge_in_cancel": {"perry.acoustic-barge-in.v1"},
    "dictation.speech_end_to_insert": {"perry.app.cua-dictation-insert.v1"},
}


class AssemblyFailure(Exception):
    pass


def fail(message: str) -> None:
    raise AssemblyFailure(message)


def read_events(
    paths: list[Path],
    metrics: dict[str, dict[str, Any]],
    registered_collectors: dict[str, set[str]] = REGISTERED_COLLECTORS,
) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for path in paths:
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError as error:
            fail(f"could not read event log {path}: {error}")
        for line_number, line in enumerate(lines, start=1):
            if not line.strip():
                continue
            label = f"{path}:{line_number}"
            try:
                event = json.loads(line)
            except json.JSONDecodeError as error:
                fail(f"{label} contains invalid JSON at column {error.colno}")
            if not isinstance(event, dict):
                fail(f"{label} must contain an object")
            expected = {"metric_id", "collector", "unit", "value", "scenario", "captured_at"}
            if set(event) != expected:
                fail(f"{label} must contain exactly {', '.join(sorted(expected))}")
            metric_id = event["metric_id"]
            if not isinstance(metric_id, str) or metric_id not in metrics:
                fail(f"{label} names an unpublished metric: {metric_id}")
            collector = event["collector"]
            if collector not in registered_collectors.get(metric_id, set()):
                fail(f"{label} uses an unregistered collector for {metric_id}: {collector}")
            unit = event["unit"]
            if unit != metrics[metric_id]["unit"]:
                fail(f"{label} uses {unit} but {metric_id} requires {metrics[metric_id]['unit']}")
            value = event["value"]
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                fail(f"{label}.value must be a finite non-negative number")
            scenario = event["scenario"]
            if not isinstance(scenario, str) or not scenario.strip():
                fail(f"{label}.scenario must be a non-empty string")
            try:
                evaluate.require_timestamp(event["captured_at"], f"{label}.captured_at")
            except evaluate.EvaluationFailure as error:
                fail(str(error))
            events.append(event)
    if not events:
        fail("event logs contain no measurements")
    return events


def group_measurements(events: list[dict[str, Any]], metrics: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for event in events:
        grouped.setdefault(event["metric_id"], []).append(event)
    missing = sorted(set(metrics) - set(grouped))
    if missing:
        fail(f"event logs are missing metrics: {', '.join(missing)}")
    measurements = []
    for metric_id in metrics:
        metric_events = grouped[metric_id]
        scenarios = {event["scenario"] for event in metric_events}
        collectors = {event["collector"] for event in metric_events}
        if len(scenarios) != 1:
            fail(f"{metric_id} mixes scenarios: {', '.join(sorted(scenarios))}")
        if len(collectors) != 1:
            fail(f"{metric_id} mixes collectors: {', '.join(sorted(collectors))}")
        measurements.append({
            "metric_id": metric_id,
            "collector": collectors.pop(),
            "unit": metrics[metric_id]["unit"],
            "scenario": scenarios.pop(),
            "samples": [event["value"] for event in metric_events],
        })
    return measurements


def command_output(arguments: list[str], cwd: Path | None = None) -> str:
    completed = subprocess.run(arguments, check=True, capture_output=True, text=True, cwd=cwd)
    return completed.stdout.strip()


def machine_metadata() -> dict[str, Any]:
    return {
        "model": command_output(["/usr/sbin/sysctl", "-n", "hw.model"]),
        "architecture": platform.machine(),
        "os": "macOS",
        "os_version": platform.mac_ver()[0],
        "memory_gb": int(command_output(["/usr/sbin/sysctl", "-n", "hw.memsize"])) / 1_073_741_824,
    }


def git_revision() -> str:
    revision = command_output(["/usr/bin/git", "rev-parse", "HEAD"], cwd=REPO_ROOT)
    dirty = command_output(["/usr/bin/git", "status", "--porcelain"], cwd=REPO_ROOT)
    return f"{revision}+dirty" if dirty else revision


def build_document(options: argparse.Namespace, measurements: list[dict[str, Any]]) -> dict[str, Any]:
    network: dict[str, Any] = {
        "mode": options.network_mode,
        "internet_reachable": options.internet_reachable,
    }
    if options.network_rtt_ms is not None:
        network["rtt_ms"] = options.network_rtt_ms
    return {
        "schema_version": 2,
        "kind": "perry.performance.raw_measurements",
        "run": {
            "id": options.run_id,
            "captured_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "provenance": {
                "kind": "live",
                "collector": "scripts/performance/assemble.py",
                "command": " ".join(sys.argv),
                "synthetic": False,
            },
            "machine": machine_metadata(),
            "build": {
                "version": options.build_version,
                "commit": git_revision(),
                "configuration": options.configuration,
                "toolchain": command_output(["/usr/bin/xcodebuild", "-version"]).replace("\n", " "),
            },
            "network": network,
        },
        "measurements": measurements,
    }


def parse_boolean(value: str) -> bool:
    if value == "true":
        return True
    if value == "false":
        return False
    raise argparse.ArgumentTypeError("expected true or false")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Assemble Perry performance events into a live evidence run")
    parser.add_argument("--event-log", type=Path, action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--build-version", required=True)
    parser.add_argument("--configuration", choices=("Debug", "Release"), default="Release")
    parser.add_argument("--network-mode", choices=("offline", "ethernet", "wifi", "cellular", "unknown"), required=True)
    parser.add_argument("--internet-reachable", type=parse_boolean, required=True)
    parser.add_argument("--network-rtt-ms", type=float)
    parser.add_argument("--metrics", type=Path, default=DEFAULT_METRICS_PATH)
    return parser


def main(arguments: list[str] | None = None) -> int:
    options = build_parser().parse_args(arguments)
    try:
        if options.output.exists():
            fail(f"output already exists: {options.output}")
        _, metrics = evaluate.load_metrics(options.metrics)
        events = read_events(options.event_log, metrics)
        measurements = group_measurements(events, metrics)
        document = build_document(options, measurements)
        options.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    except (AssemblyFailure, evaluate.EvaluationFailure, OSError, subprocess.SubprocessError) as error:
        print(f"performance assembly failed: {error}", file=sys.stderr)
        return 1
    print(f"performance evidence assembled: {options.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
