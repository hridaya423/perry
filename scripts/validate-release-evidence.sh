#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
REGISTRY_PATH="${1:-${RELEASE_EVIDENCE_FILE:-${REPO_ROOT}/docs/release-readiness/features.json}}"
PYTHON_BIN="$(command -v python3 || true)"

if [ -z "${PYTHON_BIN}" ]; then
  echo "release evidence validation: python3 is required" >&2
  exit 1
fi

exec "${PYTHON_BIN}" - "${REGISTRY_PATH}" "${REPO_ROOT}" <<'PY'
import csv
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

registry_path = Path(sys.argv[1])
source_repo_root = Path(sys.argv[2]).resolve()
repo_root = Path(os.environ.get("RELEASE_EVIDENCE_ROOT", sys.argv[2])).resolve()
allowed_statuses = {
    "absent",
    "wired",
    "unit-tested",
    "live-tested",
    "release-proven",
}
allowed_evidence_kinds = {
    "audit",
    "source",
    "unit-test",
    "live-test",
    "release",
}
recorded_statuses = {"recorded", "not-recorded"}
perry_bundle_id = "dev.perry.Perry"
perry_executable = "Perry"
supported_release_architecture = "arm64"
supported_release_platform = "macOS"


def fail(message):
    print(f"release evidence validation: {message}", file=sys.stderr)
    raise SystemExit(1)


def resolve_within_root(evidence_label, candidate, reference):
    try:
        resolved = candidate.resolve(strict=False)
        resolved.relative_to(repo_root)
    except (OSError, RuntimeError, ValueError):
        fail(f"{evidence_label} reference must stay within evidence root: {reference}")
    return resolved


def referenced_file(evidence_label, reference):
    path_reference = reference.split("::", 1)[0]
    if Path(path_reference).is_absolute():
        fail(f"{evidence_label} reference must stay within evidence root: {reference}")
    line_match = re.fullmatch(r"(.+):([1-9][0-9]*)", path_reference)
    if line_match:
        path_reference = line_match.group(1)
        line = int(line_match.group(2))
    else:
        line = None
    resolved = resolve_within_root(evidence_label, repo_root / path_reference, reference)
    return resolved, line


def require_file(evidence_label, reference):
    path, line = referenced_file(evidence_label, reference)
    if not path.is_file():
        fail(f"{evidence_label} names a missing file: {reference}")
    return path, line


def require_path(evidence_label, reference):
    path, _ = referenced_file(evidence_label, reference)
    if not path.is_file() and not path.is_dir():
        fail(f"{evidence_label} names a missing path: {reference}")
    return path


def require_string(value, label):
    if not isinstance(value, str) or not value.strip():
        fail(f"{label} must be a non-empty string")


def digest_path(path):
    if path.is_file():
        return hashlib.sha256(path.read_bytes()).hexdigest()
    if not path.is_dir():
        fail(f"cannot hash release artifact path: {path}")
    digest = hashlib.sha256()
    entries = sorted(path.rglob("*"), key=lambda entry: entry.relative_to(path).as_posix())
    for entry in entries:
        relative = entry.relative_to(path).as_posix().encode("utf-8")
        if entry.is_symlink():
            digest.update(b"L\0" + relative + b"\0" + os.readlink(entry).encode("utf-8") + b"\0")
        elif entry.is_dir():
            digest.update(b"D\0" + relative + b"\0")
        elif entry.is_file():
            digest.update(b"F\0" + relative + b"\0")
            digest.update(hashlib.sha256(entry.read_bytes()).digest())
    return digest.hexdigest()


def require_arm64_macho(evidence_label, executable):
    try:
        header = executable.read_bytes()[:8]
    except OSError as error:
        fail(f"{evidence_label}.actual_run release executable cannot be read: {error}")
    if len(header) < 8:
        fail(f"{evidence_label}.actual_run release artifact is not an arm64 Mach-O executable")
    if header[:4] == b"\xcf\xfa\xed\xfe":
        byteorder = "little"
    elif header[:4] == b"\xfe\xed\xfa\xcf":
        byteorder = "big"
    else:
        fail(f"{evidence_label}.actual_run release artifact is not a Mach-O executable")
    if int.from_bytes(header[4:8], byteorder) != 0x0100000C:
        fail(f"{evidence_label}.actual_run release artifact executable must be arm64")


def release_bundle_paths(evidence_label, release_kind, release_path):
    if release_kind == "bundle":
        if release_path.name != "Perry.app":
            fail(f"{evidence_label}.actual_run release bundle must be Perry.app")
        app_path = release_path
    else:
        if release_path.name != perry_executable:
            fail(f"{evidence_label}.actual_run release binary must be Perry.app/Contents/MacOS/Perry")
        app_path = next((parent for parent in release_path.parents if parent.name == "Perry.app"), None)
        if app_path is None or release_path != app_path / "Contents" / "MacOS" / perry_executable:
            fail(f"{evidence_label}.actual_run release binary must be Perry.app/Contents/MacOS/Perry")
    info_path = resolve_within_root(
        evidence_label,
        app_path / "Contents" / "Info.plist",
        f"{release_path}/Contents/Info.plist",
    )
    executable = resolve_within_root(
        evidence_label,
        app_path / "Contents" / "MacOS" / perry_executable,
        f"{release_path}/Contents/MacOS/{perry_executable}",
    )
    if not info_path.is_file():
        fail(f"{evidence_label}.actual_run release bundle is missing Contents/Info.plist")
    if not executable.is_file() or not os.access(executable, os.X_OK):
        fail(f"{evidence_label}.actual_run release bundle is missing an executable Perry")
    try:
        bundle_info = plistlib.loads(info_path.read_bytes())
    except (OSError, TypeError, ValueError, plistlib.InvalidFileException) as error:
        fail(f"{evidence_label}.actual_run release bundle identity is invalid: {error}")
    if not isinstance(bundle_info, dict):
        fail(f"{evidence_label}.actual_run release bundle identity is invalid")
    if bundle_info.get("CFBundleIdentifier") != perry_bundle_id:
        fail(f"{evidence_label}.actual_run release bundle is not Perry")
    if bundle_info.get("CFBundleExecutable") != perry_executable:
        fail(f"{evidence_label}.actual_run release bundle executable identity is invalid")
    if bundle_info.get("CFBundlePackageType") != "APPL":
        fail(f"{evidence_label}.actual_run release bundle package identity is invalid")
    return executable, bundle_info


def validate_actual_run(evidence_label, feature_id, evidence_reference, actual_run, release):
    if not isinstance(actual_run, dict):
        fail(f"{evidence_label}.actual_run must be an object")
    run_reference = actual_run.get("reference")
    require_string(run_reference, f"{evidence_label}.actual_run.reference")
    if run_reference != evidence_reference:
        fail(f"{evidence_label}.actual_run reference does not match the evidence reference")
    run_digest = actual_run.get("sha256")
    if not isinstance(run_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", run_digest):
        fail(f"{evidence_label}.actual_run SHA-256 is invalid")
    run_path, _ = require_file(evidence_label, run_reference)
    if hashlib.sha256(run_path.read_bytes()).hexdigest() != run_digest:
        fail(f"{evidence_label}.actual_run hash does not match the structured run artifact")
    try:
        run = json.loads(run_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"{evidence_label}.actual_run must reference a structured JSON artifact: {error}")
    if not isinstance(run, dict):
        fail(f"{evidence_label}.actual_run artifact must be an object")
    if run.get("schema_version") != 1:
        fail(f"{evidence_label}.actual_run artifact schema_version must be 1")
    if run.get("feature_id") != feature_id:
        fail(f"{evidence_label}.actual_run artifact feature_id does not match {feature_id}")
    require_string(run.get("captured_at"), f"{evidence_label}.actual_run artifact.captured_at")
    if run.get("result") != "passed":
        fail(f"{evidence_label}.actual_run artifact result must be passed")

    build = run.get("build")
    if not isinstance(build, dict):
        fail(f"{evidence_label}.actual_run artifact.build must be an object")
    for field in ("configuration", "architecture", "revision"):
        require_string(build.get(field), f"{evidence_label}.actual_run artifact.build.{field}")
    if release:
        if build["configuration"] != "Release":
            fail(f"{evidence_label}.actual_run artifact release proof must use a Release build")
        if build["architecture"] != supported_release_architecture:
            fail(f"{evidence_label}.actual_run artifact release proof must use arm64")
        if not re.fullmatch(r"[0-9a-f]{40}", build["revision"]):
            fail(f"{evidence_label}.actual_run artifact release proof revision must be a commit")
        try:
            subprocess.run(
                ["git", "-C", str(source_repo_root), "cat-file", "-e", f"{build['revision']}^{{commit}}"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=True,
            )
        except (OSError, subprocess.CalledProcessError):
            fail(f"{evidence_label}.actual_run artifact release proof revision is not a commit")

    environment = run.get("environment")
    if not isinstance(environment, dict):
        fail(f"{evidence_label}.actual_run artifact.environment must be an object")
    for field in ("platform", "version"):
        require_string(environment.get(field), f"{evidence_label}.actual_run artifact.environment.{field}")
    if release and environment["platform"] != supported_release_platform:
        fail(f"{evidence_label}.actual_run artifact release proof platform must be macOS")

    if release:
        release_artifact = run.get("release_artifact")
        if not isinstance(release_artifact, dict):
            fail(f"{evidence_label}.actual_run artifact.release_artifact must be an object")
        for field in ("kind", "reference", "sha256", "identity"):
            if field not in release_artifact:
                fail(f"{evidence_label}.actual_run artifact.release_artifact is missing {field}")
        release_kind = release_artifact["kind"]
        if release_kind not in {"binary", "bundle"}:
            fail(f"{evidence_label}.actual_run artifact.release_artifact.kind is invalid")
        release_reference = release_artifact["reference"]
        require_string(release_reference, f"{evidence_label}.actual_run artifact.release_artifact.reference")
        if release_reference == run_reference:
            fail(f"{evidence_label}.actual_run release artifact must be distinct from its run artifact")
        release_path = require_path(evidence_label, release_reference)
        if release_kind == "binary" and not release_path.is_file():
            fail(f"{evidence_label}.actual_run release artifact binary must be a file")
        if release_kind == "bundle" and not release_path.is_dir():
            fail(f"{evidence_label}.actual_run release artifact bundle must be a directory")
        executable, bundle_info = release_bundle_paths(evidence_label, release_kind, release_path)
        require_arm64_macho(evidence_label, executable)
        release_digest = release_artifact["sha256"]
        if not isinstance(release_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", release_digest):
            fail(f"{evidence_label}.actual_run release artifact SHA-256 is invalid")
        if digest_path(release_path) != release_digest:
            fail(f"{evidence_label}.actual_run release artifact hash does not match the release artifact")
        identity = release_artifact["identity"]
        if not isinstance(identity, dict):
            fail(f"{evidence_label}.actual_run release artifact identity must be an object")
        for field in ("bundle_id", "version", "build"):
            require_string(identity.get(field), f"{evidence_label}.actual_run release artifact identity.{field}")
        expected_identity = {
            "bundle_id": bundle_info.get("CFBundleIdentifier"),
            "version": bundle_info.get("CFBundleShortVersionString"),
            "build": bundle_info.get("CFBundleVersion"),
        }
        if identity["bundle_id"] != perry_bundle_id:
            fail(f"{evidence_label}.actual_run release artifact identity is not Perry")
        if any(
            not isinstance(value, str) or identity[field] != value
            for field, value in expected_identity.items()
        ):
            fail(f"{evidence_label}.actual_run release bundle identity does not match Contents/Info.plist")

    if set(actual_run) != {"reference", "sha256"}:
        fail(f"{evidence_label}.actual_run wrapper must contain only reference and sha256")


try:
    registry = json.loads(registry_path.read_text(encoding="utf-8"))
except FileNotFoundError:
    fail(f"registry not found: {registry_path}")
except OSError as error:
    fail(f"could not read {registry_path}: {error}")
except json.JSONDecodeError as error:
    fail(f"invalid JSON at line {error.lineno}, column {error.colno}")

if not isinstance(registry, dict):
    fail("registry root must be an object")
if registry.get("schema_version") != 3:
    fail("schema_version must be 3")
if registry.get("milestone") != "M0":
    fail("milestone must be M0")
if registry.get("source") != "docs/heyclicky-feature-audit.md":
    fail("source must be docs/heyclicky-feature-audit.md")
if registry.get("statuses") != [
    "absent",
    "wired",
    "unit-tested",
    "live-tested",
    "release-proven",
]:
    fail("statuses must list the five supported evidence statuses in order")

features = registry.get("features")
if not isinstance(features, list) or not features:
    fail("features must be a non-empty array")

seen_ids = set()
status_counts = {status: 0 for status in allowed_statuses}

for index, feature in enumerate(features):
    label = f"features[{index}]"
    if not isinstance(feature, dict):
        fail(f"{label} must be an object")

    for field in ("id", "name", "status", "owner", "support", "limitations", "verification", "evidence"):
        if field not in feature:
            fail(f"{label} is missing {field}")

    feature_id = feature["id"]
    if not isinstance(feature_id, str) or not feature_id.strip():
        fail(f"{label}.id must be a non-empty string")
    if feature_id in seen_ids:
        fail(f"duplicate feature id: {feature_id}")
    seen_ids.add(feature_id)

    for field in ("name", "owner", "support"):
        value = feature[field]
        if not isinstance(value, str) or not value.strip():
            fail(f"{label}.{field} must be a non-empty string")

    limitations = feature["limitations"]
    if not isinstance(limitations, list) or not limitations or any(
        not isinstance(item, str) or not item.strip() for item in limitations
    ):
        fail(f"{label}.limitations must be a non-empty array of strings")

    status = feature["status"]
    if status not in allowed_statuses:
        fail(f"{label}.status is invalid: {status!r}")
    status_counts[status] += 1

    verification = feature["verification"]
    if not isinstance(verification, dict):
        fail(f"{label}.verification must be an object")
    supported_environments = verification.get("supported_environments")
    if not isinstance(supported_environments, dict):
        fail(f"{label}.verification.supported_environments must be an object")
    environment_status = supported_environments.get("status")
    if environment_status not in recorded_statuses:
        fail(f"{label}.verification.supported_environments.status is invalid")
    if environment_status == "not-recorded":
        if set(supported_environments) != {"status"}:
            fail(f"{label}.verification.supported_environments not-recorded state must not contain values")
    else:
        values = supported_environments.get("values")
        if not isinstance(values, list) or not values or any(
            not isinstance(value, str) or not value.strip() for value in values
        ):
            fail(f"{label}.verification.supported_environments.recorded state must contain values")

    last_successful_run = verification.get("last_successful_run")
    if not isinstance(last_successful_run, dict):
        fail(f"{label}.verification.last_successful_run must be an object")
    last_run_status = last_successful_run.get("status")
    if last_run_status not in recorded_statuses:
        fail(f"{label}.verification.last_successful_run.status is invalid")
    if last_run_status == "not-recorded" and set(last_successful_run) != {"status"}:
        fail(f"{label}.verification.last_successful_run not-recorded state must not contain a reference")
    if last_run_status == "recorded":
        require_string(last_successful_run.get("reference"), f"{label}.verification.last_successful_run.reference")

    benchmark = verification.get("benchmark")
    if not isinstance(benchmark, dict):
        fail(f"{label}.verification.benchmark must be an object")
    benchmark_status = benchmark.get("status")
    if benchmark_status not in recorded_statuses:
        fail(f"{label}.verification.benchmark.status is invalid")
    if benchmark_status == "not-recorded" and set(benchmark) != {"status"}:
        fail(f"{label}.verification.benchmark not-recorded state must not contain a reference")
    if benchmark_status == "recorded":
        require_string(benchmark.get("reference"), f"{label}.verification.benchmark.reference")
        require_file(f"{label}.verification.benchmark", benchmark["reference"])

    evidence = feature["evidence"]
    if not isinstance(evidence, list) or not evidence:
        fail(f"{label}.evidence must be a non-empty array")

    live_evidence = False
    release_evidence = False
    source_evidence = False
    unit_evidence = False
    actual_live_runs = set()
    actual_release_runs = set()
    actual_run_references = set()
    for evidence_index, item in enumerate(evidence):
        evidence_label = f"{label}.evidence[{evidence_index}]"
        if not isinstance(item, dict):
            fail(f"{evidence_label} must be an object")
        kind = item.get("kind")
        reference = item.get("reference")
        if kind not in allowed_evidence_kinds:
            fail(f"{evidence_label}.kind is invalid: {kind!r}")
        if not isinstance(reference, str) or not reference.strip():
            fail(f"{evidence_label}.reference must be a non-empty string")
        actual_run = item.get("actual_run")
        if actual_run is not None:
            if kind not in {"live-test", "release"}:
                fail(f"{evidence_label}.actual_run is only valid for live-test or release evidence")
            validate_actual_run(
                evidence_label, feature_id, reference, actual_run, release=kind == "release"
            )
            actual_run_references.add(actual_run["reference"])
            if kind == "live-test":
                actual_live_runs.add(reference)
            if kind == "release":
                actual_release_runs.add(reference)
        if kind in {"audit", "source", "release"}:
            evidence_path, evidence_line = require_file(evidence_label, reference)
            try:
                evidence_source = evidence_path.read_text(encoding="utf-8")
            except OSError as error:
                fail(f"could not read evidence {reference}: {error}")
            if evidence_line is not None and evidence_line > len(evidence_source.splitlines()):
                fail(f"{evidence_label} names a line outside its file: {reference}")
            if kind == "source" and "::" in reference:
                source_member = reference.split("::", 1)[1]
                if not source_member or source_member not in evidence_source:
                    fail(f"{evidence_label} names a missing source member: {reference}")
        if kind == "source":
            source_evidence = True
        if kind == "live-test":
            live_evidence = True
            live_path, _ = require_file(evidence_label, reference)
            privacy_root = repo_root / "docs/release-readiness/privacy"
            ui_root = repo_root / "docs/release-readiness/ui"
            if privacy_root in live_path.parents and live_path.suffix == ".json":
                try:
                    capture = json.loads(live_path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError) as error:
                    fail(f"{evidence_label} contains invalid privacy capture metadata: {error}")
                if capture.get("schema_version") != 1:
                    fail(f"{evidence_label} privacy capture schema_version must be 1")
                if capture.get("passed") is not True:
                    fail(f"{evidence_label} privacy capture must have passed")
                digest = capture.get("executable_sha256")
                if not isinstance(digest, str) or len(digest) != 64 or any(
                    character not in "0123456789abcdef" for character in digest
                ):
                    fail(f"{evidence_label} privacy capture executable_sha256 is invalid")
                if capture.get("capture_type") == "telemetry-opt-out-network":
                    if capture.get("external_network_rows") != 0:
                        fail(f"{evidence_label} privacy capture contains external network rows")
                    if capture.get("network_protocols") != ["tcp", "udp"]:
                        fail(f"{evidence_label} privacy capture must cover TCP and UDP")
                    if not isinstance(capture.get("samples"), int) or capture["samples"] < 1800:
                        fail(f"{evidence_label} network capture must contain at least 1800 samples")
                    raw_artifacts = capture.get("raw_artifacts")
                    expected_names = {"nettop.csv", "nettop.err", "lsof.txt", "perry.log"}
                    if not isinstance(raw_artifacts, dict) or set(raw_artifacts) != expected_names:
                        fail(f"{evidence_label} network capture must hash every raw artifact")
                    raw_paths = {}
                    for name, expected_digest in raw_artifacts.items():
                        raw_path = resolve_within_root(
                            evidence_label,
                            live_path.parent / name,
                            f"{live_path.parent / name}",
                        )
                        if not raw_path.is_file():
                            fail(f"{evidence_label} is missing raw artifact {name}")
                        raw_paths[name] = raw_path
                        actual_digest = hashlib.sha256(raw_path.read_bytes()).hexdigest()
                        if actual_digest != expected_digest:
                            fail(f"{evidence_label} raw artifact hash mismatch for {name}")
                    header_count = 0
                    external_rows = 0
                    with raw_paths["nettop.csv"].open(newline="", encoding="utf-8") as stream:
                        for row in csv.reader(stream):
                            if row and row[0] == "time":
                                header_count += 1
                            elif row and any(value.strip() for value in row[1:]):
                                external_rows += 1
                    if header_count != capture["samples"] or external_rows != 0:
                        fail(f"{evidence_label} raw nettop capture disagrees with its metadata")
                else:
                    if capture.get("external_network_rows") != 0:
                        fail(f"{evidence_label} privacy capture contains external network rows")
                    if capture.get("network_protocols") != ["tcp", "udp"]:
                        fail(f"{evidence_label} privacy capture must cover TCP and UDP")
                    if not isinstance(capture.get("samples"), int) or capture["samples"] < 1:
                        fail(f"{evidence_label} privacy capture must contain samples")
            elif ui_root in live_path.parents and live_path.suffix == ".json":
                try:
                    capture = json.loads(live_path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError) as error:
                    fail(f"{evidence_label} contains invalid UI capture metadata: {error}")
                if capture.get("schema_version") != 1:
                    fail(f"{evidence_label} UI capture schema_version must be 1")
                checks = capture.get("checks")
                if (
                    not isinstance(checks, list)
                    or not checks
                    or any(not isinstance(check, dict) or check.get("passed") is not True for check in checks)
                ):
                    fail(f"{evidence_label} UI capture must contain only passed checks")
                artifacts = capture.get("artifacts")
                if not isinstance(artifacts, list) or not artifacts:
                    fail(f"{evidence_label} UI capture must contain artifacts")
                for artifact in artifacts:
                    if not isinstance(artifact, dict):
                        fail(f"{evidence_label} UI capture artifact must be an object")
                    relative_path = artifact.get("path")
                    expected_digest = artifact.get("sha256")
                    if not isinstance(relative_path, str) or not relative_path.startswith("docs/release-readiness/ui/"):
                        fail(f"{evidence_label} UI capture artifact path is invalid")
                    if not isinstance(expected_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_digest):
                        fail(f"{evidence_label} UI capture artifact SHA-256 is invalid")
                    artifact_path, _ = require_file(evidence_label, relative_path)
                    actual_digest = hashlib.sha256(artifact_path.read_bytes()).hexdigest()
                    if actual_digest != expected_digest:
                        fail(f"{evidence_label} UI artifact hash mismatch for {relative_path}")
                build = capture.get("build")
                if not isinstance(build, dict) or not isinstance(build.get("git_dirty"), bool):
                    fail(f"{evidence_label} UI capture must declare build.git_dirty")
                if status in {"live-tested", "release-proven"} and build["git_dirty"]:
                    fail(f"{evidence_label} dirty-build UI capture cannot prove status {status}")
                limitations = capture.get("limitations")
                if not isinstance(limitations, list) or not limitations:
                    fail(f"{evidence_label} UI capture must declare limitations")
        if kind == "release":
            release_evidence = True
            if reference.endswith(".sh"):
                fail(f"{evidence_label} release evidence must reference a structured actual run")
            if actual_run is None:
                fail(f"{evidence_label} release evidence requires actual_run")
        if kind == "unit-test":
            unit_evidence = True
            if "::" not in reference:
                fail(f"{evidence_label} must name a test with path::func ...")
            test_path, test_name = reference.split("::", 1)
            test_file, _ = require_file(evidence_label, test_path)
            try:
                test_source = test_file.read_text(encoding="utf-8")
            except OSError as error:
                fail(f"could not read test evidence {test_path}: {error}")
            if test_name not in test_source:
                fail(f"{evidence_label} names a missing test: {reference}")

    if status == "release-proven" and not release_evidence:
        fail(f"{label} with status release-proven requires release evidence")
    if status == "release-proven" and not actual_release_runs:
        fail(f"{label} with status release-proven requires a passing structured release actual run")
    if last_run_status == "recorded":
        if last_successful_run["reference"] not in actual_run_references:
            fail(f"{label}.verification.last_successful_run must reference an actual run")
    if status in {"live-tested", "release-proven"} and last_run_status != "recorded":
        fail(f"{label} with status {status} requires a recorded last successful run")
    if status in {"wired", "unit-tested", "live-tested", "release-proven"} and not source_evidence:
        fail(f"{label} with status {status} requires source evidence")
    if status in {"unit-tested", "live-tested", "release-proven"} and not unit_evidence:
        fail(f"{label} with status {status} requires unit-test evidence")
    if status in {"live-tested", "release-proven"} and not live_evidence:
        fail(f"{label} with status {status} requires live-test evidence")
    if status in {"live-tested", "release-proven"} and not actual_live_runs:
        fail(f"{label} with status {status} requires a passing structured live actual run")
    if release_evidence and status != "release-proven":
        fail(f"{label} has release evidence without release-proven status")

if status_counts["release-proven"]:
    fail(
        "release-proven promotion is disabled: no externally trusted distribution-signature "
        "or artifact-to-revision provenance verifier is configured; provide real "
        "/usr/bin/codesign and /usr/sbin/spctl results plus external build provenance before "
        "promotion; self-declared Release/revision JSON is not accepted"
    )

summary = ", ".join(
    f"{status}={status_counts[status]}"
    for status in ("absent", "wired", "unit-tested", "live-tested", "release-proven")
    if status_counts[status]
)
print(f"release evidence valid: {len(features)} features ({summary})")
PY
