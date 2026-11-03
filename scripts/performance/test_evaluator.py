#!/usr/bin/env python3

from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

import evaluate


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[1]
BUDGETS_PATH = REPO_ROOT / "scripts/performance/budgets.json"
SCHEMA_PATH = REPO_ROOT / "scripts/performance/raw-measurements.schema.json"


class PerformanceEvaluatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary_directory.name)
        self.baseline = self.fixture_run("baseline", 0.45)
        self.candidate = self.fixture_run("candidate", 0.46)
        self.baseline_path = self.write("baseline.json", self.baseline)
        self.candidate_path = self.write("candidate.json", self.candidate)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_linear_percentile_interpolates_sorted_samples(self) -> None:
        self.assertEqual(evaluate.compute_percentile([4, 1, 3, 2], 50), 2.5)
        self.assertAlmostEqual(evaluate.compute_percentile([1, 2, 3, 4], 95), 3.85)

    def test_versioned_schema_covers_every_locked_release_metric(self) -> None:
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        registry = self.registry()
        self.assertEqual(schema["$id"], "perry-performance-raw-measurements-v2")
        self.assertEqual(schema["properties"]["schema_version"]["const"], 2)
        self.assertEqual(registry["schema_version"], 2)
        self.assertEqual(len(registry["metrics"]), 14)
        dictation = next(metric for metric in registry["metrics"] if metric["id"] == "dictation.speech_end_to_insert")
        self.assertEqual(dictation["constraints"], [
            {"percentile": 50, "operator": "<=", "limit": 450},
            {"percentile": 95, "operator": "<=", "limit": 900},
        ])

    def test_complete_fixture_passes_every_constraint(self) -> None:
        summary = self.evaluate(self.baseline_path, self.candidate_path)
        self.assertTrue(summary["passed"])
        self.assertEqual(len(summary["constraints"]), 15)
        self.assertEqual(
            [item["percentile"] for item in summary["constraints"] if item["id"] == "dictation.speech_end_to_insert"],
            [50, 95],
        )

    def test_exact_ten_percent_regression_is_allowed(self) -> None:
        self.set_samples(self.baseline, "overlay.first_frame", [100])
        self.set_samples(self.candidate, "overlay.first_frame", [110])
        summary = self.evaluate(
            self.write("exact-baseline.json", self.baseline),
            self.write("exact-candidate.json", self.candidate),
        )
        overlay = next(item for item in summary["constraints"] if item["id"] == "overlay.first_frame")
        self.assertFalse(overlay["regression_failed"])

    def test_more_than_ten_percent_regression_fails(self) -> None:
        self.set_samples(self.baseline, "overlay.first_frame", [100])
        self.set_samples(self.candidate, "overlay.first_frame", [111])
        with self.assertRaises(evaluate.EvaluationFailure) as context:
            self.evaluate(
                self.write("regression-baseline.json", self.baseline),
                self.write("regression-candidate.json", self.candidate),
            )
        self.assertIn("overlay.first_frame", str(context.exception))
        self.assertIn("more than 10%", str(context.exception))

    def test_absolute_budget_limit_fails(self) -> None:
        self.set_samples(self.baseline, "ui.input_feedback", [49])
        self.set_samples(self.candidate, "ui.input_feedback", [51])
        with self.assertRaises(evaluate.EvaluationFailure) as context:
            self.evaluate(
                self.write("limit-baseline.json", self.baseline),
                self.write("limit-candidate.json", self.candidate),
            )
        self.assertIn("violates <= 50 ms", str(context.exception))

    def test_missing_metric_fails_without_synthesis(self) -> None:
        self.candidate["measurements"].pop()
        with self.assertRaises(evaluate.EvaluationFailure) as context:
            self.evaluate(self.baseline_path, self.write("missing.json", self.candidate))
        self.assertIn("missing real measurements", str(context.exception))

    def test_fixture_provenance_is_not_release_evidence(self) -> None:
        with self.assertRaises(evaluate.EvaluationFailure) as context:
            evaluate.evaluate_paths(BUDGETS_PATH, self.baseline_path, self.candidate_path)
        self.assertIn("not a real measurement", str(context.exception))

    def test_live_provenance_passes_without_fixture_override(self) -> None:
        for run in (self.baseline, self.candidate):
            run["run"]["provenance"] = {
                "kind": "live",
                "collector": "instrumented-performance-run",
                "command": "perry performance capture",
                "synthetic": False,
            }
        summary = evaluate.evaluate_paths(
            BUDGETS_PATH,
            self.write("live-baseline.json", self.baseline),
            self.write("live-candidate.json", self.candidate),
        )
        self.assertTrue(summary["passed"])

    def test_missing_measurement_file_fails(self) -> None:
        with self.assertRaises(evaluate.EvaluationFailure) as context:
            self.evaluate(self.directory / "missing.json", self.candidate_path)
        self.assertIn("missing real measurement file", str(context.exception))

    def test_machine_context_must_match(self) -> None:
        self.candidate["run"]["machine"]["model"] = "different-machine"
        with self.assertRaises(evaluate.EvaluationFailure) as context:
            self.evaluate(self.baseline_path, self.write("different-machine.json", self.candidate))
        self.assertIn("machine.model", str(context.exception))

    def test_duplicate_metric_measurement_fails(self) -> None:
        self.candidate["measurements"].append(copy.deepcopy(self.candidate["measurements"][0]))
        with self.assertRaises(evaluate.EvaluationFailure) as context:
            self.evaluate(self.baseline_path, self.write("duplicate.json", self.candidate))
        self.assertIn("duplicate measurement", str(context.exception))

    def test_baseline_and_candidate_must_use_the_same_collector(self) -> None:
        self.candidate["measurements"][0]["collector"] = "different.collector"

        with self.assertRaises(evaluate.EvaluationFailure) as context:
            self.evaluate(self.baseline_path, self.write("different-collector.json", self.candidate))

        self.assertIn("different collectors", str(context.exception))

    def evaluate(self, baseline: Path, candidate: Path) -> dict:
        return evaluate.evaluate_paths(BUDGETS_PATH, baseline, candidate, allow_fixtures=True)

    def fixture_run(self, name: str, ratio: float) -> dict:
        measurements = []
        for metric in self.registry()["metrics"]:
            smallest_limit = min(constraint["limit"] for constraint in metric["constraints"])
            value = smallest_limit * ratio
            measurements.append({
                "metric_id": metric["id"],
                "collector": f"fixture.{metric['id']}",
                "unit": metric["unit"],
                "scenario": f"fixture {metric['id']}",
                "samples": [value] * 5,
            })
        return {
            "schema_version": 2,
            "kind": "perry.performance.raw_measurements",
            "run": {
                "id": f"fixture-{name}",
                "captured_at": "2026-08-29T14:00:00Z",
                "provenance": {
                    "kind": "fixture",
                    "collector": "performance-evaluator-self-test",
                    "command": f"fixture {name}",
                    "synthetic": True,
                },
                "machine": {
                    "model": "fixture-machine",
                    "architecture": "arm64",
                    "os": "macOS",
                    "os_version": "26.0",
                    "memory_gb": 16,
                },
                "build": {
                    "version": name,
                    "commit": f"{name}-fixture-commit",
                    "configuration": "Release",
                    "toolchain": "Xcode fixture",
                },
                "network": {"mode": "offline", "internet_reachable": False},
            },
            "measurements": measurements,
        }

    def registry(self) -> dict:
        return json.loads(BUDGETS_PATH.read_text(encoding="utf-8"))

    def set_samples(self, run: dict, metric_id: str, samples: list[float]) -> None:
        measurement = next(item for item in run["measurements"] if item["metric_id"] == metric_id)
        measurement["samples"] = samples

    def write(self, name: str, value: dict) -> Path:
        path = self.directory / name
        path.write_text(json.dumps(value), encoding="utf-8")
        return path


if __name__ == "__main__":
    unittest.main()
