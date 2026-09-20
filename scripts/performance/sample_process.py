#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path


TASK_SNAPSHOT_KEYS = {
    "sequence",
    "session_generation",
    "utterance_generation",
    "active",
    "started",
    "finished",
    "active_by_role",
    "started_by_role",
    "finished_by_role",
    "captured_at",
}


class SamplingFailure(Exception):
    pass


def fail(message: str) -> None:
    raise SamplingFailure(message)


def read_process(pid: int) -> tuple[float, float, str]:
    completed = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "rss=", "-o", "%cpu=", "-o", "comm="],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0 or not completed.stdout.strip():
        fail(f"process {pid} is not running")
    fields = completed.stdout.strip().split(maxsplit=2)
    if len(fields) != 3:
        fail(f"could not parse process sample for {pid}")
    try:
        rss_kib = float(fields[0])
        cpu_percent = float(fields[1])
    except ValueError:
        fail(f"process {pid} returned non-numeric resource data")
    if not all(math.isfinite(value) and value >= 0 for value in (rss_kib, cpu_percent)):
        fail(f"process {pid} returned invalid resource data")
    return rss_kib, cpu_percent, fields[2]


def ambient_wake_enabled() -> bool:
    completed = subprocess.run(
        ["/usr/bin/defaults", "read", "dev.perry.Perry", "perry.wakeWord.enabled"],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        return False
    return parse_boolean_setting(completed.stdout)


def parse_boolean_setting(raw_value: str) -> bool:
    value = raw_value.strip().lower()
    if value in {"1", "true", "yes"}:
        return True
    if value in {"0", "false", "no"}:
        return False
    fail(f"could not interpret Perry's ambient wake setting: {value}")


def memory_growth_percentages(samples: list[float]) -> list[float]:
    if not samples or samples[0] <= 0:
        fail("memory samples require a positive post-warm-up baseline")
    baseline = samples[0]
    return [max(0, (sample - baseline) / baseline * 100) for sample in samples]


def append_events(path: Path, events: list[dict]) -> None:
    if not path.is_absolute():
        fail("event log path must be absolute")
    if not path.parent.is_dir():
        fail(f"event log directory does not exist: {path.parent}")
    with path.open("a", encoding="utf-8") as handle:
        for event in events:
            handle.write(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def event(metric_id: str, collector: str, unit: str, value: float, scenario: str) -> dict:
    return {
        "metric_id": metric_id,
        "collector": collector,
        "unit": unit,
        "value": value,
        "scenario": scenario,
        "captured_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }


def require_duration(mode: str, duration: float, warmup: float, interval: float) -> None:
    if not all(math.isfinite(value) for value in (duration, warmup, interval)):
        fail("duration, warm-up, and interval must be finite")
    minimum_duration = 1_800 if mode == "voice-endurance" else 300
    if duration < minimum_duration:
        fail(f"{mode} requires at least {minimum_duration} seconds")
    if warmup <= 0 or warmup >= duration:
        fail("warm-up must be greater than zero and shorter than the run")
    if interval <= 0 or interval > warmup:
        fail("sample interval must be greater than zero and no longer than the warm-up")


def parse_timestamp(value: object) -> datetime:
    if not isinstance(value, str):
        fail("task snapshot captured_at must be a timestamp")
    try:
        timestamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        fail(f"task snapshot has an invalid captured_at timestamp: {value}")
    if timestamp.utcoffset() is None:
        fail("task snapshot captured_at must include a UTC offset")
    return timestamp


def read_task_snapshots(path: Path) -> list[dict]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        fail(f"could not read task log: {error}")
    snapshots = []
    for line_number, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        try:
            snapshot = json.loads(line)
        except json.JSONDecodeError:
            fail(f"task log line {line_number} is not valid JSON")
        if not isinstance(snapshot, dict) or set(snapshot) != TASK_SNAPSHOT_KEYS:
            fail(f"task log line {line_number} does not match the task snapshot schema")
        snapshots.append(snapshot)
    return snapshots


def validate_role_counts(value: object, field: str) -> dict[str, int]:
    if not isinstance(value, dict):
        fail(f"task snapshot {field} must be an object")
    for role, count in value.items():
        if not isinstance(role, str) or not role or not isinstance(count, int) or isinstance(count, bool) or count < 0:
            fail(f"task snapshot {field} contains an invalid role count")
    return value


def validate_task_snapshots(
    snapshots: list[dict],
    run_started_at: datetime,
    warmup_seconds: float,
    run_ended_at: datetime,
) -> dict:
    validated = []
    previous_sequence = 0
    for snapshot in snapshots:
        captured_at = parse_timestamp(snapshot["captured_at"])
        if captured_at < run_started_at or captured_at > run_ended_at:
            continue
        scalar_fields = ("sequence", "session_generation", "utterance_generation", "active", "started", "finished")
        if any(
            not isinstance(snapshot[field], int)
            or isinstance(snapshot[field], bool)
            or snapshot[field] < 0
            for field in scalar_fields
        ):
            fail("task snapshot counters must be non-negative integers")
        if snapshot["sequence"] <= previous_sequence:
            fail("task snapshot sequence must increase strictly during the run")
        previous_sequence = snapshot["sequence"]
        active_by_role = validate_role_counts(snapshot["active_by_role"], "active_by_role")
        started_by_role = validate_role_counts(snapshot["started_by_role"], "started_by_role")
        finished_by_role = validate_role_counts(snapshot["finished_by_role"], "finished_by_role")
        if snapshot["started"] - snapshot["finished"] != snapshot["active"]:
            fail("task snapshot total counters are unbalanced")
        if sum(active_by_role.values()) != snapshot["active"]:
            fail("task snapshot active role counts do not match the total")
        if sum(started_by_role.values()) != snapshot["started"]:
            fail("task snapshot started role counts do not match the total")
        if sum(finished_by_role.values()) != snapshot["finished"]:
            fail("task snapshot finished role counts do not match the total")
        roles = set(active_by_role) | set(started_by_role) | set(finished_by_role)
        for role in roles:
            if started_by_role.get(role, 0) - finished_by_role.get(role, 0) != active_by_role.get(role, 0):
                fail(f"task snapshot role counters are unbalanced for {role}")
        validated.append((captured_at, snapshot))
    warmup_ended_at = run_started_at + timedelta(seconds=warmup_seconds)
    post_warmup = [snapshot for captured_at, snapshot in validated if captured_at >= warmup_ended_at]
    if len(post_warmup) < 2:
        fail("task log has fewer than two post-warm-up snapshots from this run")
    baseline = post_warmup[0]
    final = post_warmup[-1]
    commit_starts = final["started_by_role"].get("commit", 0) - baseline["started_by_role"].get("commit", 0)
    commit_finishes = final["finished_by_role"].get("commit", 0) - baseline["finished_by_role"].get("commit", 0)
    if commit_starts < 10 or commit_finishes < 10:
        fail("voice endurance run must complete at least 10 post-warm-up commit cycles")
    maximum_active = max(snapshot["active"] for snapshot in post_warmup)
    if maximum_active > 8:
        fail(f"voice endurance run exceeded the owned-worker limit: {maximum_active}")
    if final["active"] > baseline["active"]:
        fail("owned realtime worker count grew after warm-up")
    if final["active_by_role"].get("commit", 0) > baseline["active_by_role"].get("commit", 0):
        fail("a commit worker remained active at the end of the endurance run")
    return {
        "post_warmup_snapshots": len(post_warmup),
        "baseline_active": baseline["active"],
        "final_active": final["active"],
        "maximum_active": maximum_active,
        "commit_starts": commit_starts,
        "commit_finishes": commit_finishes,
        "first_sequence": post_warmup[0]["sequence"],
        "last_sequence": post_warmup[-1]["sequence"],
    }


def require_paths(event_log: Path, diagnostics: Path, task_log: Path | None, mode: str) -> None:
    for label, path in (("event log", event_log), ("diagnostics", diagnostics)):
        if not path.is_absolute():
            fail(f"{label} path must be absolute")
        if not path.parent.is_dir():
            fail(f"{label} directory does not exist: {path.parent}")
    if diagnostics.exists():
        fail(f"diagnostics output already exists: {diagnostics}")
    if mode == "voice-endurance":
        if task_log is None or not task_log.is_absolute():
            fail("voice-endurance requires an absolute task log path")
        if not task_log.is_file():
            fail(f"task log does not exist: {task_log}")


def sample(options: argparse.Namespace) -> tuple[list[dict], dict]:
    require_duration(options.mode, options.duration_seconds, options.warmup_seconds, options.interval_seconds)
    if options.mode == "idle" and ambient_wake_enabled():
        fail("idle sampling requires Perry's ambient wake setting to be off")
    rss_samples: list[float] = []
    cpu_samples: list[float] = []
    run_started_at = datetime.now(timezone.utc)
    started = time.monotonic()
    next_sample = started
    command = ""
    while True:
        now = time.monotonic()
        if now < next_sample:
            time.sleep(next_sample - now)
            now = time.monotonic()
        elapsed = now - started
        rss_kib, cpu_percent, command = read_process(options.pid)
        if Path(command).name != "Perry":
            fail(f"process {options.pid} is {command}, not Perry")
        if elapsed >= options.warmup_seconds:
            rss_samples.append(rss_kib)
            cpu_samples.append(cpu_percent)
        if elapsed >= options.duration_seconds:
            break
        next_sample += options.interval_seconds
    run_ended_at = datetime.now(timezone.utc)
    if len(rss_samples) < 2:
        fail("run produced fewer than two post-warm-up samples")
    if options.mode == "idle" and ambient_wake_enabled():
        fail("Perry's ambient wake setting was enabled before idle sampling finished")
    if options.mode == "voice-endurance":
        scenario = f"30-minute duplex voice RSS after {options.warmup_seconds:g}-second warm-up"
        events = [
            event("voice.session_memory_growth", "perry.process-sampler.voice-endurance.v1", "percent", value, scenario)
            for value in memory_growth_percentages(rss_samples)
        ]
    else:
        scenario = f"ambient-wake-off idle CPU after {options.warmup_seconds:g}-second warm-up"
        events = [event("idle.cpu", "perry.process-sampler.idle.v1", "percent", value, scenario) for value in cpu_samples]
    diagnostics = {
        "pid": options.pid,
        "process": command,
        "mode": options.mode,
        "duration_seconds": options.duration_seconds,
        "warmup_seconds": options.warmup_seconds,
        "interval_seconds": options.interval_seconds,
        "post_warmup_samples": len(rss_samples),
        "ambient_wake_enabled": options.mode != "idle" and ambient_wake_enabled(),
        "rss_kib_start": rss_samples[0],
        "rss_kib_end": rss_samples[-1],
    }
    if options.mode == "voice-endurance":
        diagnostics["swift_tasks"] = validate_task_snapshots(
            read_task_snapshots(options.task_log),
            run_started_at,
            options.warmup_seconds,
            run_ended_at,
        )
    return events, diagnostics


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Sample Perry process resources for a release performance run")
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--mode", choices=("voice-endurance", "idle"), required=True)
    parser.add_argument("--duration-seconds", type=float, required=True)
    parser.add_argument("--warmup-seconds", type=float, default=60)
    parser.add_argument("--interval-seconds", type=float, default=5)
    parser.add_argument("--event-log", type=Path, required=True)
    parser.add_argument("--diagnostics", type=Path, required=True)
    parser.add_argument("--task-log", type=Path)
    return parser


def main(arguments: list[str] | None = None) -> int:
    options = build_parser().parse_args(arguments)
    try:
        if options.pid <= 0:
            fail("pid must be positive")
        require_paths(options.event_log, options.diagnostics, options.task_log, options.mode)
        events, diagnostics = sample(options)
        append_events(options.event_log, events)
        options.diagnostics.write_text(json.dumps(diagnostics, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    except (OSError, SamplingFailure) as error:
        print(f"process sampling failed: {error}", file=sys.stderr)
        return 1
    print(f"process samples recorded: {len(events)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
