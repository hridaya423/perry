#!/usr/bin/env python3

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import assemble


class PerformanceAssemblerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary_directory.name)
        self.metrics = {
            "first": {"unit": "ms"},
            "second": {"unit": "percent"},
        }
        self.collectors = {
            "first": {"fixture.first"},
            "second": {"fixture.second"},
        }

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_events_group_into_one_sample_stream_per_metric(self) -> None:
        path = self.write_events([
            self.event("first", "fixture.first", "ms", 10, "one"),
            self.event("second", "fixture.second", "percent", 2, "two"),
            self.event("first", "fixture.first", "ms", 12, "one"),
        ])

        measurements = assemble.group_measurements(
            assemble.read_events([path], self.metrics, self.collectors),
            self.metrics,
        )

        self.assertEqual(measurements, [
            {"metric_id": "first", "collector": "fixture.first", "unit": "ms", "scenario": "one", "samples": [10, 12]},
            {"metric_id": "second", "collector": "fixture.second", "unit": "percent", "scenario": "two", "samples": [2]},
        ])

    def test_missing_metric_fails(self) -> None:
        path = self.write_events([self.event("first", "fixture.first", "ms", 10, "one")])

        with self.assertRaises(assemble.AssemblyFailure) as context:
            assemble.group_measurements(assemble.read_events([path], self.metrics, self.collectors), self.metrics)

        self.assertIn("missing metrics: second", str(context.exception))

    def test_unknown_metric_and_wrong_unit_fail_at_the_boundary(self) -> None:
        for event, expected in [
            (self.event("unknown", "fixture.unknown", "ms", 10, "one"), "unpublished metric"),
            (self.event("first", "fixture.first", "percent", 10, "one"), "requires ms"),
        ]:
            with self.subTest(expected=expected):
                path = self.write_events([event])
                with self.assertRaises(assemble.AssemblyFailure) as context:
                    assemble.read_events([path], self.metrics, self.collectors)
                self.assertIn(expected, str(context.exception))

    def test_unregistered_collector_fails_at_the_boundary(self) -> None:
        path = self.write_events([self.event("first", "unknown.collector", "ms", 10, "one")])

        with self.assertRaises(assemble.AssemblyFailure) as context:
            assemble.read_events([path], self.metrics, self.collectors)

        self.assertIn("unregistered collector", str(context.exception))

    def test_mixed_scenarios_fail_instead_of_merging_incomparable_samples(self) -> None:
        path = self.write_events([
            self.event("first", "fixture.first", "ms", 10, "speaker"),
            self.event("first", "fixture.first", "ms", 11, "headphones"),
            self.event("second", "fixture.second", "percent", 2, "two"),
        ])

        with self.assertRaises(assemble.AssemblyFailure) as context:
            assemble.group_measurements(assemble.read_events([path], self.metrics, self.collectors), self.metrics)

        self.assertIn("mixes scenarios", str(context.exception))

    def event(self, metric_id: str, collector: str, unit: str, value: float, scenario: str) -> dict:
        return {
            "metric_id": metric_id,
            "collector": collector,
            "unit": unit,
            "value": value,
            "scenario": scenario,
            "captured_at": "2026-08-29T13:00:00Z",
        }

    def write_events(self, events: list[dict]) -> Path:
        path = self.directory / "events.jsonl"
        path.write_text("\n".join(json.dumps(event) for event in events) + "\n", encoding="utf-8")
        return path


if __name__ == "__main__":
    unittest.main()
