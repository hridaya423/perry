#!/usr/bin/env python3

from __future__ import annotations

import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

import sample_process


class ProcessSamplerTests(unittest.TestCase):
    def task_snapshots(self, *, cycles: int = 10, final_active: int = 2) -> tuple[list[dict], datetime, datetime]:
        started_at = datetime(2026, 8, 29, 10, 0, tzinfo=timezone.utc)
        snapshots = []
        sequence = 1
        started = 2
        finished = 0
        for cycle in range(cycles + 1):
            captured_at = started_at + timedelta(seconds=61 + cycle * 2)
            snapshots.append({
                "sequence": sequence,
                "session_generation": 1,
                "utterance_generation": cycle,
                "active": 3,
                "started": started + 1,
                "finished": finished,
                "active_by_role": {"receiver": 1, "audio_ingress": 1, "commit": 1},
                "started_by_role": {"receiver": 1, "audio_ingress": 1, "commit": cycle + 1},
                "finished_by_role": {"commit": cycle},
                "captured_at": captured_at.isoformat().replace("+00:00", "Z"),
            })
            sequence += 1
            started += 1
            captured_at += timedelta(seconds=1)
            snapshots.append({
                "sequence": sequence,
                "session_generation": 1,
                "utterance_generation": cycle,
                "active": 2,
                "started": started,
                "finished": finished + 1,
                "active_by_role": {"receiver": 1, "audio_ingress": 1},
                "started_by_role": {"receiver": 1, "audio_ingress": 1, "commit": cycle + 1},
                "finished_by_role": {"commit": cycle + 1},
                "captured_at": captured_at.isoformat().replace("+00:00", "Z"),
            })
            sequence += 1
            finished += 1
        if final_active > 2:
            snapshots[-1]["active"] = final_active
            snapshots[-1]["started"] += final_active - 2
            snapshots[-1]["active_by_role"]["pipeline"] = final_active - 2
            snapshots[-1]["started_by_role"]["pipeline"] = final_active - 2
        ended_at = started_at + timedelta(minutes=30)
        return snapshots, started_at, ended_at

    def test_memory_growth_uses_the_first_post_warm_up_sample(self) -> None:
        self.assertEqual(sample_process.memory_growth_percentages([100, 104, 103, 95]), [0, 4, 3, 0])

    def test_invalid_memory_baseline_fails(self) -> None:
        for samples in ([], [0, 1]):
            with self.subTest(samples=samples):
                with self.assertRaises(sample_process.SamplingFailure):
                    sample_process.memory_growth_percentages(samples)

    def test_release_durations_cannot_be_shortened(self) -> None:
        for mode, duration, expected in [
            ("voice-endurance", 1_799, "1800"),
            ("idle", 299, "300"),
        ]:
            with self.subTest(mode=mode):
                with self.assertRaises(sample_process.SamplingFailure) as context:
                    sample_process.require_duration(mode, duration, 60, 5)
                self.assertIn(expected, str(context.exception))

    def test_non_finite_timing_fails(self) -> None:
        with self.assertRaises(sample_process.SamplingFailure):
            sample_process.require_duration("voice-endurance", float("nan"), 60, 5)

    def test_ambient_wake_setting_is_parsed_strictly(self) -> None:
        self.assertTrue(sample_process.parse_boolean_setting("1\n"))
        self.assertFalse(sample_process.parse_boolean_setting("false\n"))
        with self.assertRaises(sample_process.SamplingFailure):
            sample_process.parse_boolean_setting("maybe")

    def test_event_log_is_append_only_jsonl(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.jsonl"
            first = sample_process.event("idle.cpu", "perry.process-sampler.idle.v1", "percent", 0.4, "idle")
            second = sample_process.event("idle.cpu", "perry.process-sampler.idle.v1", "percent", 0.5, "idle")

            sample_process.append_events(path, [first])
            sample_process.append_events(path, [second])

            lines = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
            self.assertEqual([line["value"] for line in lines], [0.4, 0.5])
            self.assertEqual({line["metric_id"] for line in lines}, {"idle.cpu"})

    def test_task_snapshots_prove_bounded_commit_cycles(self) -> None:
        snapshots, started_at, ended_at = self.task_snapshots()

        result = sample_process.validate_task_snapshots(snapshots, started_at, 60, ended_at)

        self.assertEqual(result["baseline_active"], 3)
        self.assertEqual(result["final_active"], 2)
        self.assertEqual(result["maximum_active"], 3)
        self.assertEqual(result["commit_starts"], 10)
        self.assertEqual(result["commit_finishes"], 11)

    def test_task_snapshot_growth_fails(self) -> None:
        snapshots, started_at, ended_at = self.task_snapshots(final_active=4)

        with self.assertRaisesRegex(sample_process.SamplingFailure, "grew"):
            sample_process.validate_task_snapshots(snapshots, started_at, 60, ended_at)

    def test_unbalanced_task_snapshot_fails(self) -> None:
        snapshots, started_at, ended_at = self.task_snapshots()
        snapshots[3]["finished"] = 0

        with self.assertRaisesRegex(sample_process.SamplingFailure, "unbalanced"):
            sample_process.validate_task_snapshots(snapshots, started_at, 60, ended_at)

    def test_task_snapshot_requires_exercised_commits(self) -> None:
        snapshots, started_at, ended_at = self.task_snapshots(cycles=3)

        with self.assertRaisesRegex(sample_process.SamplingFailure, "at least 10"):
            sample_process.validate_task_snapshots(snapshots, started_at, 60, ended_at)


if __name__ == "__main__":
    unittest.main()
