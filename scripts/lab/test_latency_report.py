#!/usr/bin/env python3
"""Stdlib unittest for latency-report.py pairing and percentile math."""

import importlib.util
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


def _load_module():
    spec = importlib.util.spec_from_file_location(
        "latency_report",
        Path(__file__).with_name("latency-report.py"),
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


REPORT = _load_module()


def ts(offset_ms: int) -> str:
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)
    return (base + timedelta(milliseconds=offset_ms)).isoformat()


def markers(*entries):
    return [(REPORT.parse_timestamp(ts(t)), name) for name, t in entries]


class PairingTests(unittest.TestCase):
    def test_end_pairs_with_most_recent_start(self):
        marks = markers(
            ("invoke.keydown", 0),
            ("invoke.keydown", 100),
            ("panel.visible", 150),
        )
        self.assertEqual(
            REPORT.durations_ms(marks, "invoke.keydown", "panel.visible"), [50.0]
        )

    def test_start_is_consumed_by_first_end(self):
        marks = markers(
            ("invoke.keydown", 0),
            ("panel.visible", 50),
            ("panel.visible", 90),
        )
        self.assertEqual(
            REPORT.durations_ms(marks, "invoke.keydown", "panel.visible"), [50.0]
        )

    def test_end_without_start_is_ignored(self):
        marks = markers(("panel.visible", 10), ("invoke.keydown", 20))
        self.assertEqual(
            REPORT.durations_ms(marks, "invoke.keydown", "panel.visible"), []
        )

    def test_multiple_pairs(self):
        marks = markers(
            ("a", 0), ("b", 40), ("a", 100), ("b", 300),
        )
        self.assertEqual(REPORT.durations_ms(marks, "a", "b"), [40.0, 200.0])


class PercentileTests(unittest.TestCase):
    def test_empty(self):
        self.assertIsNone(REPORT.percentile([], 50))

    def test_single(self):
        self.assertEqual(REPORT.percentile([7.0], 95), 7.0)

    def test_interpolated(self):
        values = [float(v) for v in range(10, 110, 10)]  # 10..100, n=10
        self.assertAlmostEqual(REPORT.percentile(values, 50), 55.0)
        self.assertAlmostEqual(REPORT.percentile(values, 95), 95.5)
        self.assertAlmostEqual(REPORT.percentile(values, 0), 10.0)
        self.assertAlmostEqual(REPORT.percentile(values, 100), 100.0)


class SummarizeTests(unittest.TestCase):
    def test_fields(self):
        stats = REPORT.summarize([10.0, 20.0, 30.0])
        self.assertEqual(stats["n"], 3)
        self.assertAlmostEqual(stats["p50_ms"], 20.0)
        self.assertAlmostEqual(stats["p95_ms"], 29.0)
        self.assertEqual(stats["max_ms"], 30.0)


if __name__ == "__main__":
    unittest.main()
