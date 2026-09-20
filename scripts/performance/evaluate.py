#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 2
RAW_MEASUREMENTS_KIND = "perry.performance.raw_measurements"
BUDGETS_KIND = "perry.performance.budgets"
RELEASE_REGRESSION_FACTOR = Decimal("1.1")
REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_BUDGETS_PATH = REPO_ROOT / "docs/release-readiness/performance/budgets.json"
DEFAULT_BASELINE_PATH = REPO_ROOT / "docs/release-readiness/performance/measurements/baseline.json"
DEFAULT_CANDIDATE_PATH = REPO_ROOT / "docs/release-readiness/performance/measurements/candidate.json"


class EvaluationFailure(Exception):
    pass


def fail(message: str) -> None:
    raise EvaluationFailure(message)


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    return value


def require_fields(
    value: dict[str, Any],
    required: tuple[str, ...],
    label: str,
    optional: tuple[str, ...] = (),
) -> None:
    missing = [field for field in required if field not in value]
    if missing:
        fail(f"{label} is missing {', '.join(missing)}")
    allowed = set(required) | set(optional)
    unknown = sorted(set(value) - allowed)
    if unknown:
        fail(f"{label} has unsupported field(s): {', '.join(unknown)}")


def require_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"{label} must be a non-empty string")
    return value


def require_boolean(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        fail(f"{label} must be a boolean")
    return value


def require_decimal(value: Any, label: str) -> Decimal:
    if isinstance(value, bool) or not isinstance(value, (int, float, Decimal)):
        fail(f"{label} must be a number")
    try:
        parsed = Decimal(str(value))
    except (InvalidOperation, ValueError):
        fail(f"{label} must be a number")
    if not parsed.is_finite():
        fail(f"{label} must be finite")
    return parsed


def require_nonnegative_decimal(value: Any, label: str) -> Decimal:
    parsed = require_decimal(value, label)
    if parsed < 0:
        fail(f"{label} must be non-negative")
    return parsed


def require_timestamp(value: Any, label: str) -> str:
    text = require_string(value, label)
    normalized = f"{text[:-1]}+00:00" if text.endswith("Z") else text
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        fail(f"{label} must be an ISO 8601 timestamp")
    if parsed.tzinfo is None:
        fail(f"{label} must include a timezone")
    return text


def load_json_object(path: Path, description: str) -> dict[str, Any]:
    try:
        parsed = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        if description == "measurement file":
            fail(f"missing real measurement file: {path}")
        fail(f"{description} not found: {path}")
    except OSError as error:
        fail(f"could not read {description} {path}: {error}")
    except json.JSONDecodeError as error:
        fail(f"invalid JSON in {description} {path} at line {error.lineno}, column {error.colno}")
    return require_object(parsed, f"{description} {path}")


def load_metrics(path: Path) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    registry = load_json_object(path, "budget registry")
    require_fields(
        registry,
        ("schema_version", "kind", "source", "percentile_method", "regression_factor", "metrics"),
        "budget registry",
    )
    if registry["schema_version"] != SCHEMA_VERSION:
        fail(f"budget registry schema_version must be {SCHEMA_VERSION}")
    if registry["kind"] != BUDGETS_KIND:
        fail(f"budget registry kind must be {BUDGETS_KIND}")
    require_string(registry["source"], "budget registry.source")
    if registry["percentile_method"] != "linear":
        fail("budget registry.percentile_method must be linear")
    regression_factor = require_decimal(registry["regression_factor"], "budget registry.regression_factor")
    if regression_factor != RELEASE_REGRESSION_FACTOR:
        fail("budget registry.regression_factor must be 1.1")

    entries = registry["metrics"]
    if not isinstance(entries, list) or not entries:
        fail("budget registry.metrics must be a non-empty array")

    metrics: list[dict[str, Any]] = []
    by_id: dict[str, dict[str, Any]] = {}
    for index, entry_value in enumerate(entries):
        label = f"budget registry.metrics[{index}]"
        entry = require_object(entry_value, label)
        require_fields(
            entry,
            ("id", "name", "description", "unit", "constraints", "source"),
            label,
        )
        metric_id = require_string(entry["id"], f"{label}.id")
        if metric_id in by_id:
            fail(f"duplicate metric id: {metric_id}")
        name = require_string(entry["name"], f"{label}.name")
        description = require_string(entry["description"], f"{label}.description")
        unit = require_string(entry["unit"], f"{label}.unit")
        constraints_value = entry["constraints"]
        if not isinstance(constraints_value, list) or not constraints_value:
            fail(f"{label}.constraints must be a non-empty array")
        constraints = []
        seen_percentiles = set()
        for constraint_index, constraint_value in enumerate(constraints_value):
            constraint_label = f"{label}.constraints[{constraint_index}]"
            constraint = require_object(constraint_value, constraint_label)
            require_fields(constraint, ("percentile", "operator", "limit"), constraint_label)
            percentile = require_decimal(constraint["percentile"], f"{constraint_label}.percentile")
            if percentile != percentile.to_integral_value() or not Decimal("0") < percentile <= Decimal("100"):
                fail(f"{constraint_label}.percentile must be an integer from 1 to 100")
            if percentile in seen_percentiles:
                fail(f"{label} contains duplicate p{decimal_number(percentile)} constraints")
            seen_percentiles.add(percentile)
            operator = constraint["operator"]
            if operator not in {"<", "<="}:
                fail(f"{constraint_label}.operator must be < or <=")
            constraints.append({
                "percentile": int(percentile),
                "operator": operator,
                "limit": require_nonnegative_decimal(constraint["limit"], f"{constraint_label}.limit"),
            })
        source = entry["source"]
        if not isinstance(source, list) or not source or any(
            not isinstance(item, str) or not item.strip() for item in source
        ):
            fail(f"{label}.source must be a non-empty array of strings")
        metric = {
            "id": metric_id,
            "name": name,
            "description": description,
            "unit": unit,
            "constraints": constraints,
            "source": source,
        }
        metrics.append(metric)
        by_id[metric_id] = metric
    return metrics, by_id


def load_run(path: Path, allow_fixtures: bool) -> dict[str, Any]:
    raw = load_json_object(path, "measurement file")
    require_fields(raw, ("schema_version", "kind", "run", "measurements"), "measurement file")
    if raw["schema_version"] != SCHEMA_VERSION:
        fail(f"measurement file {path} schema_version must be {SCHEMA_VERSION}")
    if raw["kind"] != RAW_MEASUREMENTS_KIND:
        fail(f"measurement file {path} kind must be {RAW_MEASUREMENTS_KIND}")

    run = require_object(raw["run"], f"measurement file {path}.run")
    require_fields(
        run,
        ("id", "captured_at", "provenance", "machine", "build", "network"),
        f"measurement file {path}.run",
    )
    run_id = require_string(run["id"], f"measurement file {path}.run.id")
    captured_at = require_timestamp(run["captured_at"], f"measurement file {path}.run.captured_at")

    provenance = require_object(run["provenance"], f"measurement file {path}.run.provenance")
    require_fields(
        provenance,
        ("kind", "collector", "command", "synthetic"),
        f"measurement file {path}.run.provenance",
    )
    provenance_kind = provenance["kind"]
    if provenance_kind not in {"live", "fixture"}:
        fail(f"measurement file {path}.run.provenance.kind must be live or fixture")
    collector = require_string(provenance["collector"], f"measurement file {path}.run.provenance.collector")
    command = require_string(provenance["command"], f"measurement file {path}.run.provenance.command")
    synthetic = require_boolean(provenance["synthetic"], f"measurement file {path}.run.provenance.synthetic")
    if provenance_kind == "live" and synthetic:
        fail(f"measurement file {path} marks a live run as synthetic")
    if provenance_kind == "fixture" and not synthetic:
        fail(f"measurement file {path} marks a fixture as real")
    if provenance_kind != "live" and not allow_fixtures:
        fail(f"measurement file {path} is not a real measurement; fixture data requires --allow-fixtures")

    machine = require_object(run["machine"], f"measurement file {path}.run.machine")
    require_fields(
        machine,
        ("model", "architecture", "os", "os_version", "memory_gb"),
        f"measurement file {path}.run.machine",
    )
    machine_model = require_string(machine["model"], f"measurement file {path}.run.machine.model")
    machine_architecture = require_string(machine["architecture"], f"measurement file {path}.run.machine.architecture")
    machine_os = require_string(machine["os"], f"measurement file {path}.run.machine.os")
    machine_os_version = require_string(machine["os_version"], f"measurement file {path}.run.machine.os_version")
    machine_memory = require_decimal(machine["memory_gb"], f"measurement file {path}.run.machine.memory_gb")
    if machine_memory <= 0:
        fail(f"measurement file {path}.run.machine.memory_gb must be greater than zero")

    build = require_object(run["build"], f"measurement file {path}.run.build")
    require_fields(
        build,
        ("version", "commit", "configuration", "toolchain"),
        f"measurement file {path}.run.build",
    )
    build_version = require_string(build["version"], f"measurement file {path}.run.build.version")
    build_commit = require_string(build["commit"], f"measurement file {path}.run.build.commit")
    build_configuration = require_string(build["configuration"], f"measurement file {path}.run.build.configuration")
    build_toolchain = require_string(build["toolchain"], f"measurement file {path}.run.build.toolchain")

    network = require_object(run["network"], f"measurement file {path}.run.network")
    require_fields(
        network,
        ("mode", "internet_reachable"),
        f"measurement file {path}.run.network",
        optional=("rtt_ms",),
    )
    network_mode = network["mode"]
    if network_mode not in {"offline", "ethernet", "wifi", "cellular", "unknown"}:
        fail(f"measurement file {path}.run.network.mode is invalid")
    internet_reachable = require_boolean(
        network["internet_reachable"],
        f"measurement file {path}.run.network.internet_reachable",
    )
    network_rtt = None
    if "rtt_ms" in network:
        network_rtt = require_nonnegative_decimal(network["rtt_ms"], f"measurement file {path}.run.network.rtt_ms")

    measurements_value = raw["measurements"]
    if not isinstance(measurements_value, list) or not measurements_value:
        fail(f"measurement file {path}.measurements must be a non-empty array")
    measurements: list[dict[str, Any]] = []
    for index, entry_value in enumerate(measurements_value):
        label = f"measurement file {path}.measurements[{index}]"
        entry = require_object(entry_value, label)
        require_fields(entry, ("metric_id", "collector", "unit", "samples"), label, optional=("scenario",))
        metric_id = require_string(entry["metric_id"], f"{label}.metric_id")
        collector = require_string(entry["collector"], f"{label}.collector")
        unit = require_string(entry["unit"], f"{label}.unit")
        samples_value = entry["samples"]
        if not isinstance(samples_value, list) or not samples_value:
            fail(f"{label}.samples must be a non-empty array")
        samples = [
            require_nonnegative_decimal(sample, f"{label}.samples[{sample_index}]")
            for sample_index, sample in enumerate(samples_value)
        ]
        scenario = None
        if "scenario" in entry:
            scenario = require_string(entry["scenario"], f"{label}.scenario")
        measurements.append({
            "metric_id": metric_id,
            "collector": collector,
            "unit": unit,
            "samples": samples,
            "scenario": scenario,
        })

    return {
        "run": {
            "id": run_id,
            "captured_at": captured_at,
            "provenance": {
                "kind": provenance_kind,
                "collector": collector,
                "command": command,
                "synthetic": synthetic,
            },
            "machine": {
                "model": machine_model,
                "architecture": machine_architecture,
                "os": machine_os,
                "os_version": machine_os_version,
                "memory_gb": machine_memory,
            },
            "build": {
                "version": build_version,
                "commit": build_commit,
                "configuration": build_configuration,
                "toolchain": build_toolchain,
            },
            "network": {
                "mode": network_mode,
                "internet_reachable": internet_reachable,
                "rtt_ms": network_rtt,
            },
        },
        "measurements": measurements,
    }


def index_measurements(
    run: dict[str, Any],
    metrics: dict[str, dict[str, Any]],
    label: str,
) -> dict[str, dict[str, Any]]:
    indexed: dict[str, dict[str, Any]] = {}
    for measurement in run["measurements"]:
        metric_id = measurement["metric_id"]
        if metric_id not in metrics:
            fail(f"{label} contains unpublished metric id: {metric_id}")
        if metric_id in indexed:
            fail(f"{label} contains duplicate measurement for {metric_id}")
        metric = metrics[metric_id]
        if measurement["unit"] != metric["unit"]:
            fail(
                f"{label} measurement {metric_id} uses {measurement['unit']} but the metric uses {metric['unit']}"
            )
        indexed[metric_id] = measurement
    missing = sorted(set(metrics) - set(indexed))
    if missing:
        fail(f"{label} is missing real measurements for: {', '.join(missing)}")
    return indexed


def environment_mismatches(baseline: dict[str, Any], candidate: dict[str, Any]) -> list[str]:
    mismatches: list[str] = []
    baseline_machine = baseline["run"]["machine"]
    candidate_machine = candidate["run"]["machine"]
    for field in ("model", "architecture", "os", "os_version", "memory_gb"):
        if baseline_machine[field] != candidate_machine[field]:
            mismatches.append(f"machine.{field}")
    baseline_network = baseline["run"]["network"]
    candidate_network = candidate["run"]["network"]
    for field in ("mode", "internet_reachable"):
        if baseline_network[field] != candidate_network[field]:
            mismatches.append(f"network.{field}")
    return mismatches


def percentile_value(samples: list[Decimal], percentile: Decimal) -> Decimal:
    if not samples:
        fail("cannot compute a percentile from an empty sample set")
    if not Decimal("0") <= percentile <= Decimal("100"):
        fail("percentile must be between 0 and 100")
    ordered = sorted(samples)
    position = percentile / Decimal("100") * Decimal(len(ordered) - 1)
    lower_index = int(position)
    upper_index = min(lower_index + 1, len(ordered) - 1)
    fraction = position - Decimal(lower_index)
    return ordered[lower_index] + (ordered[upper_index] - ordered[lower_index]) * fraction


def compute_percentile(samples: list[float], percentile: float) -> float:
    values = [require_nonnegative_decimal(sample, "sample") for sample in samples]
    return float(percentile_value(values, require_decimal(percentile, "percentile")))


def within_limit(value: Decimal, operator: str, limit: Decimal) -> bool:
    if operator == "<":
        return value < limit
    return value <= limit


def decimal_number(value: Decimal) -> int | float:
    if value == value.to_integral_value():
        return int(value)
    return float(value)


def json_value(value: Any) -> Any:
    if isinstance(value, Decimal):
        return decimal_number(value)
    if isinstance(value, dict):
        return {key: json_value(item) for key, item in value.items()}
    if isinstance(value, list):
        return [json_value(item) for item in value]
    return value


def percent_delta(candidate: Decimal, baseline: Decimal) -> Decimal | None:
    if baseline == 0:
        return None if candidate > 0 else Decimal("0")
    return (candidate - baseline) / baseline * Decimal("100")


def evaluate_paths(
    budgets_path: Path,
    baseline_path: Path,
    candidate_path: Path,
    allow_fixtures: bool = False,
) -> dict[str, Any]:
    metrics, metrics_by_id = load_metrics(budgets_path)
    baseline = load_run(baseline_path, allow_fixtures)
    candidate = load_run(candidate_path, allow_fixtures)
    mismatches = environment_mismatches(baseline, candidate)
    if mismatches:
        fail(f"baseline and candidate do not share a measurement environment: {', '.join(mismatches)}")

    baseline_measurements = index_measurements(baseline, metrics_by_id, "baseline")
    candidate_measurements = index_measurements(candidate, metrics_by_id, "candidate")
    collector_mismatches = sorted(
        metric_id
        for metric_id in metrics_by_id
        if baseline_measurements[metric_id]["collector"] != candidate_measurements[metric_id]["collector"]
    )
    if collector_mismatches:
        fail(f"baseline and candidate use different collectors for: {', '.join(collector_mismatches)}")
    evaluations: list[dict[str, Any]] = []
    failures: list[str] = []
    for metric in metrics:
        metric_id = metric["id"]
        for constraint in metric["constraints"]:
            percentile = Decimal(constraint["percentile"])
            baseline_value = percentile_value(baseline_measurements[metric_id]["samples"], percentile)
            candidate_value = percentile_value(candidate_measurements[metric_id]["samples"], percentile)
            constraint_passed = within_limit(candidate_value, constraint["operator"], constraint["limit"])
            regression_limit = baseline_value * RELEASE_REGRESSION_FACTOR
            regression_failed = candidate_value > regression_limit
            delta = percent_delta(candidate_value, baseline_value)
            evaluations.append({
                "id": metric_id,
                "name": metric["name"],
                "description": metric["description"],
                "source": metric["source"],
                "unit": metric["unit"],
                "collector": candidate_measurements[metric_id]["collector"],
                "percentile": constraint["percentile"],
                "baseline": decimal_number(baseline_value),
                "candidate": decimal_number(candidate_value),
                "constraint_operator": constraint["operator"],
                "constraint_limit": decimal_number(constraint["limit"]),
                "constraint_passed": constraint_passed,
                "regression_factor": decimal_number(RELEASE_REGRESSION_FACTOR),
                "regression_limit": decimal_number(regression_limit),
                "regression_failed": regression_failed,
                "delta_percent": None if delta is None else decimal_number(delta),
                "baseline_samples": len(baseline_measurements[metric_id]["samples"]),
                "candidate_samples": len(candidate_measurements[metric_id]["samples"]),
                "baseline_scenario": baseline_measurements[metric_id]["scenario"],
                "candidate_scenario": candidate_measurements[metric_id]["scenario"],
            })
            if not constraint_passed:
                failures.append(
                    f"{metric_id} p{constraint['percentile']} {decimal_number(candidate_value)} {metric['unit']} "
                    f"violates {constraint['operator']} {decimal_number(constraint['limit'])} {metric['unit']}"
                )
            if regression_failed:
                failures.append(
                    f"{metric_id} p{constraint['percentile']} regressed by more than 10% "
                    f"({decimal_number(baseline_value)} to {decimal_number(candidate_value)} {metric['unit']})"
                )

    if failures:
        fail("performance budget gate failed: " + "; ".join(failures))

    return {
        "schema_version": SCHEMA_VERSION,
        "percentile_method": "linear",
        "regression_factor": decimal_number(RELEASE_REGRESSION_FACTOR),
        "passed": True,
        "baseline": baseline["run"],
        "candidate": candidate["run"],
        "constraints": evaluations,
    }


def human_number(value: int | float | None) -> str:
    if value is None:
        return "infinite"
    if isinstance(value, int):
        return str(value)
    text = f"{value:.12f}".rstrip("0").rstrip(".")
    return text or "0"


def print_text(summary: dict[str, Any]) -> None:
    candidate = summary["candidate"]
    machine = candidate["machine"]
    network = candidate["network"]
    build = candidate["build"]
    network_rtt = network["rtt_ms"]
    network_rtt_text = "none" if network_rtt is None else human_number(decimal_number(network_rtt))
    print(f"performance constraints passed: {len(summary['constraints'])}")
    print(
        f"candidate run={candidate['id']} build={build['version']} commit={build['commit']} "
        f"configuration={build['configuration']} toolchain={build['toolchain']}"
    )
    print(
        f"machine={machine['model']} architecture={machine['architecture']} os={machine['os']} "
        f"os_version={machine['os_version']} memory_gb={human_number(decimal_number(machine['memory_gb']))} "
        f"network={network['mode']} internet_reachable={str(network['internet_reachable']).lower()} "
        f"network_rtt_ms={network_rtt_text}"
    )
    for constraint in summary["constraints"]:
        delta = constraint["delta_percent"]
        delta_text = "infinite" if delta is None else f"{human_number(delta)}%"
        print(
            f"{constraint['id']}: p{constraint['percentile']} baseline={human_number(constraint['baseline'])} "
            f"candidate={human_number(constraint['candidate'])} {constraint['unit']} delta={delta_text} "
            f"constraint={constraint['constraint_operator']}{human_number(constraint['constraint_limit'])} "
            f"regression<={human_number(constraint['regression_limit'])}"
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Evaluate Perry performance release evidence")
    parser.add_argument("--budgets", type=Path, default=DEFAULT_BUDGETS_PATH)
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE_PATH)
    parser.add_argument("--candidate", "--current", dest="candidate", type=Path, default=DEFAULT_CANDIDATE_PATH)
    parser.add_argument("--allow-fixtures", action="store_true", help="allow fixture provenance for self-tests")
    parser.add_argument("--format", choices=("text", "json"), default="text")
    return parser


def main(arguments: list[str] | None = None) -> int:
    options = build_parser().parse_args(arguments)
    try:
        summary = evaluate_paths(
            options.budgets,
            options.baseline,
            options.candidate,
            allow_fixtures=options.allow_fixtures,
        )
    except EvaluationFailure as error:
        print(f"performance release readiness: {error}", file=sys.stderr)
        return 1
    if options.format == "json":
        print(json.dumps(json_value(summary), indent=2, sort_keys=True))
    else:
        print_text(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
