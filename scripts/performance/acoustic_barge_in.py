#!/usr/bin/env python3

from __future__ import annotations

import argparse
import array
import json
import math
import os
import sys
import wave
from datetime import datetime, timezone
from pathlib import Path


COLLECTOR = "perry.acoustic-barge-in.v1"
MARKER_NAME = "voice.barge_in_requested"


class AnalysisFailure(Exception):
    pass


def fail(message: str) -> None:
    raise AnalysisFailure(message)


def parse_timestamp(value: str, label: str) -> datetime:
    try:
        timestamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError):
        fail(f"{label} must be an ISO-8601 timestamp")
    if timestamp.tzinfo is None:
        fail(f"{label} must include a timezone")
    return timestamp.astimezone(timezone.utc)


def read_markers(path: Path) -> list[datetime]:
    markers: list[datetime] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        fail(f"could not read marker log {path}: {error}")
    for line_number, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        label = f"{path}:{line_number}"
        try:
            entry = json.loads(line)
        except json.JSONDecodeError as error:
            fail(f"{label} contains invalid JSON at column {error.colno}")
        if not isinstance(entry, dict) or set(entry) != {"name", "captured_at"}:
            fail(f"{label} must contain exactly captured_at and name")
        if entry["name"] == MARKER_NAME:
            markers.append(parse_timestamp(entry["captured_at"], f"{label}.captured_at"))
    if not markers:
        fail(f"marker log contains no {MARKER_NAME} markers")
    return markers


def read_pcm(path: Path) -> tuple[int, list[int]]:
    try:
        with wave.open(str(path), "rb") as recording:
            if recording.getcomptype() != "NONE" or recording.getsampwidth() != 2:
                fail("recording must be uncompressed 16-bit PCM WAV")
            sample_rate = recording.getframerate()
            channels = recording.getnchannels()
            if sample_rate <= 0 or channels <= 0:
                fail("recording has invalid audio metadata")
            samples = array.array("h", recording.readframes(recording.getnframes()))
    except (OSError, EOFError, wave.Error) as error:
        fail(f"could not read recording {path}: {error}")
    if sys.byteorder == "big":
        samples.byteswap()
    if len(samples) % channels:
        fail("recording contains a partial audio frame")
    mono = [max(abs(samples[index + channel]) for channel in range(channels))
            for index in range(0, len(samples), channels)]
    return sample_rate, mono


def window_rms(samples: list[int], start: int, length: int) -> float:
    window = samples[start:start + length]
    if not window:
        return 0
    return math.sqrt(sum(sample * sample for sample in window) / len(window))


def analyze(
    samples: list[int],
    sample_rate: int,
    recording_started_at: datetime,
    markers: list[datetime],
    threshold: float,
    pretrigger_ms: float,
    quiet_ms: float,
) -> list[float]:
    pretrigger_frames = max(1, round(sample_rate * pretrigger_ms / 1000))
    quiet_frames = max(1, round(sample_rate * quiet_ms / 1000))
    durations: list[float] = []
    for marker in markers:
        marker_frame = round((marker - recording_started_at).total_seconds() * sample_rate)
        if marker_frame < pretrigger_frames or marker_frame >= len(samples):
            fail(f"marker {marker.isoformat()} falls outside the analyzable recording interval")
        if window_rms(samples, marker_frame - pretrigger_frames, pretrigger_frames) < threshold:
            fail(f"marker {marker.isoformat()} has no audible pre-trigger output")
        silence_frame = None
        last_start = len(samples) - quiet_frames
        for frame in range(marker_frame, last_start + 1):
            if window_rms(samples, frame, quiet_frames) < threshold:
                silence_frame = frame
                break
        if silence_frame is None:
            fail(f"output never became quiet after marker {marker.isoformat()}")
        durations.append((silence_frame - marker_frame) * 1000 / sample_rate)
    return durations


def append_events(path: Path, durations: list[float], scenario: str, captured_at: datetime) -> None:
    if not path.is_absolute():
        fail("event log path must be absolute")
    timestamp = captured_at.isoformat().replace("+00:00", "Z")
    try:
        with path.open("a", encoding="utf-8") as output:
            for duration in durations:
                output.write(json.dumps({
                    "metric_id": "voice.barge_in_cancel",
                    "collector": COLLECTOR,
                    "unit": "ms",
                    "value": duration,
                    "scenario": scenario,
                    "captured_at": timestamp,
                }, sort_keys=True) + "\n")
            output.flush()
            os.fsync(output.fileno())
    except OSError as error:
        fail(f"could not append event log {path}: {error}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Measure Perry barge-in latency from an acoustic loopback WAV")
    parser.add_argument("--recording", type=Path, required=True)
    parser.add_argument("--recording-started-at", required=True)
    parser.add_argument("--marker-log", type=Path, required=True)
    parser.add_argument("--event-log", type=Path, required=True)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--silence-threshold", type=float, default=500)
    parser.add_argument("--pretrigger-ms", type=float, default=50)
    parser.add_argument("--quiet-ms", type=float, default=30)
    return parser


def main(arguments: list[str] | None = None) -> int:
    options = build_parser().parse_args(arguments)
    try:
        if options.silence_threshold <= 0 or options.pretrigger_ms <= 0 or options.quiet_ms <= 0:
            fail("threshold and window durations must be positive")
        recording_started_at = parse_timestamp(options.recording_started_at, "recording-started-at")
        sample_rate, samples = read_pcm(options.recording)
        markers = read_markers(options.marker_log)
        durations = analyze(
            samples,
            sample_rate,
            recording_started_at,
            markers,
            options.silence_threshold,
            options.pretrigger_ms,
            options.quiet_ms,
        )
        append_events(options.event_log, durations, options.scenario, datetime.now(timezone.utc))
    except AnalysisFailure as error:
        print(f"acoustic barge-in analysis failed: {error}", file=sys.stderr)
        return 1
    print(f"acoustic barge-in samples recorded: {len(durations)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
