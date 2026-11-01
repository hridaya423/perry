#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/perry-release-automation.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    echo "release automation test: expected failure: $*" >&2
    exit 1
  fi
}

expect_validation_failure() {
  expected="$1"
  shift
  if output="$("$@" 2>&1)"; then
    echo "release automation test: expected validation failure: $*" >&2
    exit 1
  fi
  printf '%s\n' "${output}" | grep -Fq "${expected}" || {
    echo "release automation test: validation failure did not contain ${expected}" >&2
    exit 1
  }
}

"${SCRIPT_DIR}/validate-release-evidence.sh" >/dev/null
sh "${SCRIPT_DIR}/test-bundle-contents.sh"
python3 -B "${SCRIPT_DIR}/test_distribution_signatures.py"
python3 -B "${SCRIPT_DIR}/test_sign_distribution.py"
python3 -B "${SCRIPT_DIR}/test_sparkle_public_key.py"
python3 -B "${SCRIPT_DIR}/test_verify_sparkle_release.py"

RELEASE_OUTPUT="${TMP}/artifacts/release"
sh "${SCRIPT_DIR}/prepare-release-output.sh" "${RELEASE_OUTPUT}"
[ -d "${RELEASE_OUTPUT}" ]
printf '%s\n' preserved > "${RELEASE_OUTPUT}/Perry.xcarchive"
expect_failure sh "${SCRIPT_DIR}/prepare-release-output.sh" "${RELEASE_OUTPUT}"
[ "$(cat "${RELEASE_OUTPUT}/Perry.xcarchive")" = preserved ]
mkdir "${TMP}/empty-output"
expect_failure sh "${SCRIPT_DIR}/prepare-release-output.sh" "${TMP}/empty-output"
ln -s "${RELEASE_OUTPUT}" "${TMP}/linked-output"
expect_failure sh "${SCRIPT_DIR}/prepare-release-output.sh" "${TMP}/linked-output"
[ "$(cat "${RELEASE_OUTPUT}/Perry.xcarchive")" = preserved ]
expect_failure sh "${SCRIPT_DIR}/prepare-release-output.sh" relative-output
expect_failure sh "${SCRIPT_DIR}/prepare-release-output.sh"
expect_failure sh "${SCRIPT_DIR}/prepare-release-output.sh" "${TMP}/extra-argument" unexpected
[ ! -e "${TMP}/extra-argument" ]

if grep -ERq 'uses:[[:space:]]+[^[:space:]]+@v[0-9]+([[:space:]]|$)' "${REPO_ROOT}/.github/workflows"; then
  echo "release automation test: workflow action references must use immutable revisions" >&2
  exit 1
fi
grep -Fq 'runs-on: macos-26' "${REPO_ROOT}/.github/workflows/ci.yml"
grep -Fq 'environment: release' "${REPO_ROOT}/.github/workflows/release.yml"
grep -Fq 'run: ./scripts/package-release.sh' "${REPO_ROOT}/.github/workflows/release.yml"
grep -Fq 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' \
  "${REPO_ROOT}/.github/workflows/release.yml"
grep -Fq 'DEPLOYMENT_POSTPROCESSING=YES' "${SCRIPT_DIR}/verify-release.sh"
grep -Fq 'STRIP_INSTALLED_PRODUCT=YES' "${SCRIPT_DIR}/verify-release.sh"

CLEAN_SOURCE="${TMP}/clean-source"
mkdir -p "${CLEAN_SOURCE}"
git -C "${CLEAN_SOURCE}" init -q
git -C "${CLEAN_SOURCE}" config user.name "Perry Release Test"
git -C "${CLEAN_SOURCE}" config user.email "release-test@perry.invalid"
printf '%s\n' Perry > "${CLEAN_SOURCE}/README.md"
printf '%s\n' generated/ > "${CLEAN_SOURCE}/.gitignore"
git -C "${CLEAN_SOURCE}" add README.md
git -C "${CLEAN_SOURCE}" add .gitignore
git -C "${CLEAN_SOURCE}" commit -qm initial
mkdir -p "${CLEAN_SOURCE}/generated"
printf '%s\n' fetched > "${CLEAN_SOURCE}/generated/runtime"
PERRY_RELEASE_SOURCE_ROOT="${CLEAN_SOURCE}" "${SCRIPT_DIR}/verify-release-source.sh" >/dev/null
printf '%s\n' changed >> "${CLEAN_SOURCE}/README.md"
expect_failure env PERRY_RELEASE_SOURCE_ROOT="${CLEAN_SOURCE}" \
  "${SCRIPT_DIR}/verify-release-source.sh"
git -C "${CLEAN_SOURCE}" restore README.md
printf '%s\n' untracked > "${CLEAN_SOURCE}/untracked.txt"
expect_failure env PERRY_RELEASE_SOURCE_ROOT="${CLEAN_SOURCE}" \
  "${SCRIPT_DIR}/verify-release-source.sh"

BAD_EVIDENCE="${TMP}/release-proven-without-release-evidence.json"
python3 - "${BAD_EVIDENCE}" "${REPO_ROOT}/docs/release-readiness/features.json" <<'PY'
import json
import sys


with open(sys.argv[2], encoding="utf-8") as stream:
    registry = json.load(stream)
feature = next(item for item in registry["features"] if item["id"] == "platform.updates")
feature["status"] = "release-proven"
feature["evidence"] = [item for item in feature["evidence"] if item["kind"] != "release"]
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(registry, stream)
PY
expect_failure "${SCRIPT_DIR}/validate-release-evidence.sh" "${BAD_EVIDENCE}"
if output="$(RELEASE_EVIDENCE_FILE="${BAD_EVIDENCE}" "${SCRIPT_DIR}/verify-release.sh" 2>&1)"; then
  echo "release automation test: release verification accepted invalid evidence" >&2
  exit 1
fi
printf '%s\n' "${output}" | grep -Fq "requires release evidence"

UNIT_TEST_WITHOUT_UNIT_EVIDENCE="${TMP}/unit-tested-without-unit-evidence.json"
python3 - "${UNIT_TEST_WITHOUT_UNIT_EVIDENCE}" "${REPO_ROOT}/docs/release-readiness/features.json" <<'PY'
import json
import sys


with open(sys.argv[2], encoding="utf-8") as stream:
    registry = json.load(stream)
feature = next(item for item in registry["features"] if item["status"] == "unit-tested")
feature["evidence"] = [item for item in feature["evidence"] if item["kind"] != "unit-test"]
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(registry, stream)
PY
expect_failure "${SCRIPT_DIR}/validate-release-evidence.sh" "${UNIT_TEST_WITHOUT_UNIT_EVIDENCE}"

MISSING_LIVE_EVIDENCE="${TMP}/missing-live-evidence.json"
python3 - "${MISSING_LIVE_EVIDENCE}" "${REPO_ROOT}/docs/release-readiness/features.json" <<'PY'
import json
import sys


with open(sys.argv[2], encoding="utf-8") as stream:
    registry = json.load(stream)
feature = next(item for item in registry["features"] if item["id"] == "appearance.panel-style")
feature["status"] = "live-tested"
live_test = next(item for item in feature["evidence"] if item["kind"] == "live-test")
live_test["reference"] = "docs/release-readiness/missing-live-evidence.md"
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(registry, stream)
PY
expect_failure "${SCRIPT_DIR}/validate-release-evidence.sh" "${MISSING_LIVE_EVIDENCE}"

FAILED_PRIVACY_CAPTURE="${TMP}/failed-privacy-capture.json"
PRIVACY_ROOT="${TMP}/privacy-root"
mkdir -p "${PRIVACY_ROOT}/docs"
cp -R "${REPO_ROOT}/docs/release-readiness" "${PRIVACY_ROOT}/docs/release-readiness"
python3 - "${FAILED_PRIVACY_CAPTURE}" "${REPO_ROOT}/docs/release-readiness/features.json" <<'PY'
import json
import sys


with open(sys.argv[2], encoding="utf-8") as stream:
    registry = json.load(stream)
feature = next(item for item in registry["features"] if item["id"] == "appearance.panel-style")
capture = next(item for item in feature["evidence"] if item["kind"] == "live-test")
capture["reference"] = "docs/release-readiness/privacy/invalid-capture.json"
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(registry, stream)
PY
INVALID_CAPTURE="${PRIVACY_ROOT}/docs/release-readiness/privacy/invalid-capture.json"
printf '%s\n' '{"schema_version":1,"passed":false}' > "${INVALID_CAPTURE}"
expect_failure env RELEASE_EVIDENCE_ROOT="${PRIVACY_ROOT}" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${FAILED_PRIVACY_CAPTURE}"

TAMPERED_NETWORK_EVIDENCE="${TMP}/tampered-network-evidence.json"
python3 - "${TAMPERED_NETWORK_EVIDENCE}" "${REPO_ROOT}/docs/release-readiness/features.json" <<'PY'
import json
import sys

with open(sys.argv[2], encoding="utf-8") as stream:
    registry = json.load(stream)
feature = next(item for item in registry["features"] if item["id"] == "platform.updates")
feature["evidence"].append(
    {
        "kind": "live-test",
        "reference": "docs/release-readiness/privacy/telemetry-opt-out-1800/metadata.json",
    }
)
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(registry, stream)
PY
printf '%s\n' tampered >> "${PRIVACY_ROOT}/docs/release-readiness/privacy/telemetry-opt-out-1800/nettop.csv"
expect_failure env RELEASE_EVIDENCE_ROOT="${PRIVACY_ROOT}" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${TAMPERED_NETWORK_EVIDENCE}"

TAMPERED_UI_EVIDENCE="${TMP}/tampered-ui-evidence.json"
cp "${REPO_ROOT}/docs/release-readiness/features.json" "${TAMPERED_UI_EVIDENCE}"
printf '%s\n' tampered >> "${PRIVACY_ROOT}/docs/release-readiness/ui/onboarding-welcome-2026-08-30.jpeg"
expect_failure env RELEASE_EVIDENCE_ROOT="${PRIVACY_ROOT}" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${TAMPERED_UI_EVIDENCE}"

DIRTY_UI_PROMOTION="${TMP}/dirty-ui-promotion.json"
python3 - "${DIRTY_UI_PROMOTION}" "${REPO_ROOT}/docs/release-readiness/features.json" <<'PY'
import json
import sys


with open(sys.argv[2], encoding="utf-8") as stream:
    registry = json.load(stream)
feature = next(item for item in registry["features"] if item["id"] == "onboarding.guided-tutorial")
feature["status"] = "live-tested"
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(registry, stream)
PY
expect_failure "${SCRIPT_DIR}/validate-release-evidence.sh" "${DIRTY_UI_PROMOTION}"

STRUCTURED_ROOT="${TMP}/structured-evidence"
STRUCTURED_REGISTRY_BASE="${STRUCTURED_ROOT}/base.json"
mkdir -p "${STRUCTURED_ROOT}"
python3 - "${STRUCTURED_REGISTRY_BASE}" <<'PY'
import json
import sys
from pathlib import Path


root = Path(sys.argv[1]).parent
(root / "audit.md").write_text("Fixture audit\n", encoding="utf-8")
(root / "source.txt").write_text("Fixture source\n", encoding="utf-8")
(root / "tests.txt").write_text("testFixture\n", encoding="utf-8")
registry = {
    "schema_version": 3,
    "milestone": "M0",
    "source": "docs/heyclicky-feature-audit.md",
    "statuses": ["absent", "wired", "unit-tested", "live-tested", "release-proven"],
    "features": [{
        "id": "fixture.feature",
        "name": "Fixture",
        "status": "unit-tested",
        "owner": "Tests",
        "support": "macOS",
        "limitations": ["fixture limitation"],
        "verification": {
            "supported_environments": {"status": "not-recorded"},
            "last_successful_run": {"status": "not-recorded"},
            "benchmark": {"status": "not-recorded"}
        },
        "evidence": [
            {"kind": "audit", "reference": "audit.md"},
            {"kind": "source", "reference": "source.txt::Fixture"},
            {"kind": "unit-test", "reference": "tests.txt::testFixture"}
        ]
    }]
}
with (root / "base.json").open("w", encoding="utf-8") as stream:
    json.dump(registry, stream)
PY

FAILED_REPORT_PASSED_WRAPPER="${TMP}/failed-report-passed-wrapper.json"
python3 - "${FAILED_REPORT_PASSED_WRAPPER}" "${STRUCTURED_REGISTRY_BASE}" "${STRUCTURED_ROOT}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path


registry_path = Path(sys.argv[1])
base_path = Path(sys.argv[2])
report_path = Path(sys.argv[3]) / "failed-report.md"
report_path.write_text("Result: failed\n", encoding="utf-8")
with base_path.open(encoding="utf-8") as stream:
    registry = json.load(stream)
feature = registry["features"][0]
feature["status"] = "release-proven"
reference = report_path.name
feature["verification"]["last_successful_run"] = {
    "status": "recorded",
    "reference": reference
}
run_digest = hashlib.sha256(report_path.read_bytes()).hexdigest()
actual_run = {
    "reference": reference,
    "sha256": run_digest,
    "feature_id": "fixture.feature",
    "captured_at": "2026-08-27T12:00:00Z",
    "build": {"configuration": "Release", "architecture": "arm64", "revision": "fixture-revision"},
    "environment": {"platform": "macOS", "version": "26.5.1"},
    "result": "passed",
    "artifact": {"reference": reference, "sha256": run_digest}
}
for kind in ("live-test", "release"):
    feature["evidence"].append({"kind": kind, "reference": reference, "actual_run": actual_run})
with registry_path.open("w", encoding="utf-8") as stream:
    json.dump(registry, stream)
PY
expect_validation_failure "must reference a structured JSON artifact" \
  env RELEASE_EVIDENCE_ROOT="${STRUCTURED_ROOT}" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${FAILED_REPORT_PASSED_WRAPPER}"

MALFORMED_ACTUAL_RUN="${TMP}/malformed-actual-run.json"
python3 - "${MALFORMED_ACTUAL_RUN}" "${STRUCTURED_REGISTRY_BASE}" "${STRUCTURED_ROOT}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path


registry_path = Path(sys.argv[1])
base_path = Path(sys.argv[2])
run_path = Path(sys.argv[3]) / "malformed-run.json"
run = {
    "schema_version": 1,
    "feature_id": "fixture.feature",
    "captured_at": "2026-08-27T12:00:00Z",
    "environment": {"platform": "macOS", "version": "26.5.1"},
    "result": "passed"
}
run_path.write_text(json.dumps(run), encoding="utf-8")
with base_path.open(encoding="utf-8") as stream:
    registry = json.load(stream)
feature = registry["features"][0]
feature["status"] = "live-tested"
reference = run_path.name
feature["verification"]["last_successful_run"] = {
    "status": "recorded",
    "reference": reference
}
feature["evidence"].append(
    {
        "kind": "live-test",
        "reference": reference,
        "actual_run": {
            "reference": reference,
            "sha256": hashlib.sha256(run_path.read_bytes()).hexdigest()
        }
    }
)
with registry_path.open("w", encoding="utf-8") as stream:
    json.dump(registry, stream)
PY
expect_validation_failure "actual_run artifact.build must be an object" \
  env RELEASE_EVIDENCE_ROOT="${STRUCTURED_ROOT}" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${MALFORMED_ACTUAL_RUN}"

WRONG_FEATURE_ACTUAL_RUN="${TMP}/wrong-feature-actual-run.json"
python3 - "${WRONG_FEATURE_ACTUAL_RUN}" "${STRUCTURED_REGISTRY_BASE}" "${STRUCTURED_ROOT}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path


registry_path = Path(sys.argv[1])
base_path = Path(sys.argv[2])
run_path = Path(sys.argv[3]) / "wrong-feature-run.json"
run = {
    "schema_version": 1,
    "feature_id": "wrong.feature",
    "captured_at": "2026-08-27T12:00:00Z",
    "build": {
        "configuration": "Debug",
        "architecture": "arm64",
        "revision": "fixture-revision"
    },
    "environment": {"platform": "macOS", "version": "26.5.1"},
    "result": "passed"
}
run_path.write_text(json.dumps(run), encoding="utf-8")
with base_path.open(encoding="utf-8") as stream:
    registry = json.load(stream)
feature = registry["features"][0]
feature["status"] = "live-tested"
reference = run_path.name
feature["verification"]["last_successful_run"] = {
    "status": "recorded",
    "reference": reference
}
feature["evidence"].append(
    {
        "kind": "live-test",
        "reference": reference,
        "actual_run": {
            "reference": reference,
            "sha256": hashlib.sha256(run_path.read_bytes()).hexdigest()
        }
    }
)
with registry_path.open("w", encoding="utf-8") as stream:
    json.dump(registry, stream)
PY
expect_validation_failure "actual_run artifact feature_id does not match" \
  env RELEASE_EVIDENCE_ROOT="${STRUCTURED_ROOT}" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${WRONG_FEATURE_ACTUAL_RUN}"

SCRIPT_AS_RELEASE="${TMP}/script-as-release.json"
python3 - "${SCRIPT_AS_RELEASE}" "${REPO_ROOT}/docs/release-readiness/features.json" <<'PY'
import json
import sys


with open(sys.argv[2], encoding="utf-8") as stream:
    registry = json.load(stream)
feature = next(item for item in registry["features"] if item["id"] == "operations.update-notice")
evidence = next(item for item in feature["evidence"] if item["reference"] == "scripts/verify-release.sh")
evidence["kind"] = "release"
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(registry, stream)
PY
expect_validation_failure "release evidence must reference a structured actual run" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${SCRIPT_AS_RELEASE}"

ARBITRARY_MARKDOWN_RELEASE="${TMP}/arbitrary-markdown-release.json"
printf '%s\n' 'Result: passed' > "${STRUCTURED_ROOT}/arbitrary-release.md"
python3 - "${ARBITRARY_MARKDOWN_RELEASE}" "${STRUCTURED_REGISTRY_BASE}" "${STRUCTURED_ROOT}" <<'PY'
import hashlib
import json
import sys
from pathlib import Path


registry_path = Path(sys.argv[1])
base_path = Path(sys.argv[2])
markdown_path = Path(sys.argv[3]) / "arbitrary-release.md"
with base_path.open(encoding="utf-8") as stream:
    registry = json.load(stream)
feature = registry["features"][0]
feature["status"] = "release-proven"
reference = markdown_path.name
feature["evidence"].append(
    {
        "kind": "release",
        "reference": reference,
        "actual_run": {
            "reference": reference,
            "sha256": hashlib.sha256(markdown_path.read_bytes()).hexdigest()
        }
    }
)
with registry_path.open("w", encoding="utf-8") as stream:
    json.dump(registry, stream)
PY
expect_validation_failure "must reference a structured JSON artifact" \
  env RELEASE_EVIDENCE_ROOT="${STRUCTURED_ROOT}" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${ARBITRARY_MARKDOWN_RELEASE}"

RELEASE_REVISION="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
PLAIN_BINARY_RELEASE="${STRUCTURED_ROOT}/plain-binary.json"
BINARY_DIGEST_MISMATCH="${STRUCTURED_ROOT}/binary-digest-mismatch.json"
ARBITRARY_IDENTITY_RELEASE="${STRUCTURED_ROOT}/arbitrary-identity.json"
WRONG_ARCHITECTURE_RELEASE="${STRUCTURED_ROOT}/wrong-architecture.json"
INVALID_REVISION_RELEASE="${STRUCTURED_ROOT}/invalid-revision.json"
WRONG_PLATFORM_RELEASE="${STRUCTURED_ROOT}/wrong-platform.json"
ABSOLUTE_RELEASE_REFERENCE="${STRUCTURED_ROOT}/absolute-release-reference.json"
ESCAPING_RELEASE_REFERENCE="${STRUCTURED_ROOT}/escaping-release-reference.json"
COUNTERFEIT_31_BYTE_RELEASE="${STRUCTURED_ROOT}/counterfeit-31-byte.json"
python3 - "${STRUCTURED_ROOT}" "${STRUCTURED_REGISTRY_BASE}" "${RELEASE_REVISION}" <<'PY'
import copy
import hashlib
import json
import plistlib
import sys
from pathlib import Path


root = Path(sys.argv[1])
base_path = Path(sys.argv[2])
revision = sys.argv[3]


def make_bundle(directory, executable_bytes):
    bundle = root / directory / "Perry.app"
    executable = bundle / "Contents" / "MacOS" / "Perry"
    executable.parent.mkdir(parents=True, exist_ok=True)
    executable.write_bytes(executable_bytes)
    executable.chmod(0o755)
    info = {
        "CFBundleIdentifier": "dev.perry.Perry",
        "CFBundleExecutable": "Perry",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1"
    }
    (bundle / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
    return executable


arm64_macho = bytes.fromhex("cffaedfe0c000001") + b"p" * 23
if len(arm64_macho) != 31:
    raise AssertionError("counterfeit executable fixture must be 31 bytes")
valid_executable = make_bundle("valid", arm64_macho)
plain_executable = make_bundle("plain", b"plain text release binary")
valid_reference = valid_executable.relative_to(root).as_posix()
plain_reference = plain_executable.relative_to(root).as_posix()
valid_digest = hashlib.sha256(valid_executable.read_bytes()).hexdigest()


def write_case(name, artifact_reference=valid_reference, artifact_digest=valid_digest, identity=None, architecture="arm64", case_revision=revision, platform="macOS"):
    run_reference = f"{name}-run.json"
    run = {
        "schema_version": 1,
        "feature_id": "fixture.feature",
        "captured_at": "2026-08-31T12:00:00Z",
        "build": {"configuration": "Release", "architecture": architecture, "revision": case_revision},
        "environment": {"platform": platform, "version": "26.5.1"},
        "result": "passed",
        "release_artifact": {
            "kind": "binary",
            "reference": artifact_reference,
            "sha256": artifact_digest,
            "identity": identity or {"bundle_id": "dev.perry.Perry", "version": "1.0", "build": "1"}
        }
    }
    run_path = root / run_reference
    run_path.write_text(json.dumps(run), encoding="utf-8")
    with base_path.open(encoding="utf-8") as stream:
        registry = json.load(stream)
    feature = copy.deepcopy(registry["features"][0])
    feature["status"] = "release-proven"
    feature["verification"]["last_successful_run"] = {"status": "recorded", "reference": run_reference}
    wrapper = {"reference": run_reference, "sha256": hashlib.sha256(run_path.read_bytes()).hexdigest()}
    feature["evidence"].extend(
        {"kind": kind, "reference": run_reference, "actual_run": wrapper}
        for kind in ("live-test", "release")
    )
    registry["features"][0] = feature
    (root / f"{name}.json").write_text(json.dumps(registry), encoding="utf-8")


write_case("plain-binary", artifact_reference=plain_reference)
write_case("binary-digest-mismatch", artifact_digest="0" * 64)
write_case("arbitrary-identity", identity={"bundle_id": "com.example.Other", "version": "1.0", "build": "1"})
write_case("wrong-architecture", architecture="x86_64")
write_case("invalid-revision", case_revision="not-a-commit")
write_case("wrong-platform", platform="Linux")
write_case("absolute-release-reference", artifact_reference=str(valid_executable))
write_case("escaping-release-reference", artifact_reference="../outside-release")
write_case("counterfeit-31-byte")
PY
expect_validation_failure "not a Mach-O executable" \
  env RELEASE_EVIDENCE_ROOT="${STRUCTURED_ROOT}" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${PLAIN_BINARY_RELEASE}"
expect_validation_failure "release artifact hash does not match" \
  env RELEASE_EVIDENCE_ROOT="${STRUCTURED_ROOT}" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${BINARY_DIGEST_MISMATCH}"
expect_validation_failure "release artifact identity is not Perry" \
  env RELEASE_EVIDENCE_ROOT="${STRUCTURED_ROOT}" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${ARBITRARY_IDENTITY_RELEASE}"
expect_validation_failure "release proof must use arm64" \
  env RELEASE_EVIDENCE_ROOT="${STRUCTURED_ROOT}" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${WRONG_ARCHITECTURE_RELEASE}"
expect_validation_failure "release proof revision must be a commit" \
  env RELEASE_EVIDENCE_ROOT="${STRUCTURED_ROOT}" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${INVALID_REVISION_RELEASE}"
expect_validation_failure "release proof platform must be macOS" \
  env RELEASE_EVIDENCE_ROOT="${STRUCTURED_ROOT}" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${WRONG_PLATFORM_RELEASE}"
expect_validation_failure "reference must stay within evidence root" \
  env RELEASE_EVIDENCE_ROOT="${STRUCTURED_ROOT}" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${ABSOLUTE_RELEASE_REFERENCE}"
expect_validation_failure "reference must stay within evidence root" \
  env RELEASE_EVIDENCE_ROOT="${STRUCTURED_ROOT}" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${ESCAPING_RELEASE_REFERENCE}"
expect_validation_failure "release-proven promotion is disabled" \
  env RELEASE_EVIDENCE_ROOT="${STRUCTURED_ROOT}" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${COUNTERFEIT_31_BYTE_RELEASE}"

ABSOLUTE_EVIDENCE_REFERENCE="${TMP}/absolute-evidence-reference.json"
python3 - "${ABSOLUTE_EVIDENCE_REFERENCE}" "${REPO_ROOT}/docs/release-readiness/features.json" <<'PY'
import json
import sys


with open(sys.argv[2], encoding="utf-8") as stream:
    registry = json.load(stream)
registry["features"][0]["evidence"][0]["reference"] = "/etc/hosts"
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(registry, stream)
PY
expect_validation_failure "reference must stay within evidence root" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${ABSOLUTE_EVIDENCE_REFERENCE}"

ESCAPING_EVIDENCE_REFERENCE="${TMP}/escaping-evidence-reference.json"
python3 - "${ESCAPING_EVIDENCE_REFERENCE}" "${REPO_ROOT}/docs/release-readiness/features.json" <<'PY'
import json
import sys


with open(sys.argv[2], encoding="utf-8") as stream:
    registry = json.load(stream)
registry["features"][0]["evidence"][0]["reference"] = "../outside-evidence.md"
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(registry, stream)
PY
expect_validation_failure "reference must stay within evidence root" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${ESCAPING_EVIDENCE_REFERENCE}"

SYMLINK_ROOT="${TMP}/symlink-root"
SYMLINK_REGISTRY="${TMP}/symlink-evidence-reference.json"
mkdir -p "${SYMLINK_ROOT}"
python3 - "${SYMLINK_ROOT}" "${SYMLINK_REGISTRY}" <<'PY'
import json
import sys
from pathlib import Path


root = Path(sys.argv[1])
outside = root.parent / "outside-evidence.md"
outside.write_text("outside\n", encoding="utf-8")
(root / "evidence.md").symlink_to(outside)
registry = {
    "schema_version": 3,
    "milestone": "M0",
    "source": "docs/heyclicky-feature-audit.md",
    "statuses": ["absent", "wired", "unit-tested", "live-tested", "release-proven"],
    "features": [{
        "id": "fixture.symlink",
        "name": "Symlink fixture",
        "status": "absent",
        "owner": "Tests",
        "support": "macOS",
        "limitations": ["fixture limitation"],
        "verification": {
            "supported_environments": {"status": "not-recorded"},
            "last_successful_run": {"status": "not-recorded"},
            "benchmark": {"status": "not-recorded"}
        },
        "evidence": [{"kind": "audit", "reference": "evidence.md"}]
    }]
}
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(registry, stream)
PY
expect_validation_failure "reference must stay within evidence root" \
  env RELEASE_EVIDENCE_ROOT="${SYMLINK_ROOT}" \
  "${SCRIPT_DIR}/validate-release-evidence.sh" "${SYMLINK_REGISTRY}"

for evidence_kind in source source-member audit release
do
  INVALID_REFERENCE="${TMP}/invalid-${evidence_kind}.json"
  python3 - "${INVALID_REFERENCE}" "${REPO_ROOT}/docs/release-readiness/features.json" "${evidence_kind}" <<'PY'
import json
import sys


with open(sys.argv[2], encoding="utf-8") as stream:
    registry = json.load(stream)
kind = sys.argv[3]
if kind == "source":
    evidence = next(
        item
        for feature in registry["features"]
        for item in feature["evidence"]
        if item["kind"] == "source"
    )
    evidence["reference"] = "App/MissingSource.swift"
elif kind == "source-member":
    evidence = next(
        item
        for feature in registry["features"]
        for item in feature["evidence"]
        if item["kind"] == "source" and "::" in item["reference"]
    )
    evidence["reference"] = evidence["reference"].split("::", 1)[0] + "::missingSourceMember"
elif kind == "audit":
    evidence = next(
        item
        for feature in registry["features"]
        for item in feature["evidence"]
        if item["kind"] == "audit"
    )
    evidence["reference"] = "docs/heyclicky-feature-audit.md:999999"
else:
    evidence = next(
        item
        for feature in registry["features"]
        for item in feature["evidence"]
        if item["kind"] == "live-test"
    )
    evidence["kind"] = "release"
    evidence["reference"] = "scripts/missing-release-verifier.sh"
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(registry, stream)
PY
  expect_failure "${SCRIPT_DIR}/validate-release-evidence.sh" "${INVALID_REFERENCE}"
done

"${SCRIPT_DIR}/fetch-codex-runtime.sh" --check-lock >/dev/null
"${SCRIPT_DIR}/fetch-cua-driver.sh" --check-lock >/dev/null
"${SCRIPT_DIR}/fetch-agent-desktop.sh" --check-lock >/dev/null
"${SCRIPT_DIR}/fetch-xcodegen.sh" --check-lock >/dev/null

METADATA_DIR="${TMP}/metadata"
PERRY_RELEASE_METADATA_DIR="${METADATA_DIR}" "${SCRIPT_DIR}/generate-release-metadata.sh" --write >/dev/null
PERRY_RELEASE_METADATA_DIR="${METADATA_DIR}" "${SCRIPT_DIR}/generate-release-metadata.sh" --check >/dev/null
python3 - "${METADATA_DIR}/sbom.cdx.json" "${METADATA_DIR}/third-party-licenses.json" <<'PY'
import json
import sys


with open(sys.argv[1], encoding="utf-8") as stream:
    sbom = json.load(stream)
with open(sys.argv[2], encoding="utf-8") as stream:
    licenses = json.load(stream)

components = {component["bom-ref"]: component for component in sbom["components"]}
cua_driver = components["runtime:cua-driver"]
agent_desktop = components["runtime:agent-desktop"]
sparkle = components["framework:sparkle"]
if cua_driver["licenses"] != [{"license": {"id": "MIT"}}]:
    raise AssertionError("Cua Driver license is not MIT")
cua_properties = {item["name"]: item["value"] for item in cua_driver["properties"]}
cua_expected_properties = {
    "perry:runtime-target": "aarch64-apple-darwin",
    "perry:source-revision": "85e2b1318bd77ccf3cfa88ccdf875a4bb7eaed19",
    "perry:archive-sha256": "5f71191c082ca07c9dfc13b7c9a6eec60a82818c245a93534cc0eb7911471d72",
    "perry:archive-binary-sha256": "92067848d0eeb9de76929fbd06a137af801b0ff6caedbb3109bd7a6cc84a1f9f",
    "perry:binary-sha256": "6320105f0df8174175f75b68e59523fece754b83e62936ee9fbdead98fe15d9c",
    "perry:signing-identifier": "cua-driver",
    "perry:signing-team": "YCK386LBJ7",
}
if cua_properties != cua_expected_properties:
    raise AssertionError("Cua Driver SBOM properties do not match the lock")
if agent_desktop["licenses"] != [{"license": {"id": "Apache-2.0"}}]:
    raise AssertionError("agent-desktop license is not Apache-2.0")
properties = {item["name"]: item["value"] for item in agent_desktop["properties"]}
expected_properties = {
    "perry:runtime-target": "aarch64-apple-darwin",
    "perry:release-tag": "v1.0.2",
    "perry:source-revision": "a47ed664e0db00d1d4df364eb3fe8a5599882f3c",
    "perry:archive-sha256": "7bee385196d7b478de80cf05ca4304aaa38f0eba593b3406ad3c247c1773be19",
    "perry:binary-sha256": "bf0a3c9256512f2f57288d37ccd17d7f03665fccc53c2f74011a49b98e61ba59",
    "perry:helper-sha256": "522829116cb006b5770c6a82b361f466a4775f794d6af4083e75231a2d6bb551",
}
if properties != expected_properties:
    raise AssertionError("agent-desktop SBOM properties do not match the lock")
application = next(item for item in sbom["dependencies"] if item["ref"] == "application:perry")
if "runtime:cua-driver" not in application["dependsOn"]:
    raise AssertionError("Perry does not depend on Cua Driver")
if "runtime:agent-desktop" not in application["dependsOn"]:
    raise AssertionError("Perry does not depend on agent-desktop")
if "framework:sparkle" not in application["dependsOn"]:
    raise AssertionError("Perry does not depend on Sparkle")
if "framework:sentry" in application["dependsOn"] or "framework:posthog" in application["dependsOn"]:
    raise AssertionError("Telemetry frameworks must not appear in the SBOM")
sparkle_properties = {item["name"]: item["value"] for item in sparkle["properties"]}
if sparkle_properties != {
    "perry:source-revision": "b6496a74a087257ef5e6da1c5b29a447a60f5bd7",
    "perry:artifact-sha256": "cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0",
}:
    raise AssertionError("Sparkle SBOM properties do not match the lock")
if "framework:sentry" in components or "framework:posthog" in components:
    raise AssertionError("Telemetry SDKs must not appear as SBOM components")
license_components = {component["id"]: component for component in licenses["components"]}
cua_license = license_components["runtime.cua-driver"]
if cua_license["license"] != "MIT" or cua_license["source"] != "https://github.com/trycua/cua":
    raise AssertionError("Cua Driver license inventory is missing its MIT source")
if licenses["source"]["cua_driver_lock"] != "scripts/cua-driver.lock":
    raise AssertionError("Cua Driver lock is missing from license metadata")
agent_desktop_license = license_components["runtime.agent-desktop"]
if agent_desktop_license["license"] != "Apache-2.0" or agent_desktop_license["source"] != "https://github.com/vercel-labs/agent-desktop":
    raise AssertionError("agent-desktop license inventory is missing its Apache-2.0 source")
if licenses["source"]["agent_desktop_lock"] != "scripts/agent-desktop.lock":
    raise AssertionError("agent-desktop lock is missing from license metadata")
if licenses["source"]["sparkle_lock"] != "scripts/sparkle.lock":
    raise AssertionError("Sparkle lock is missing from license metadata")
if "telemetry_sdk_lock" in licenses["source"]:
    raise AssertionError("Telemetry SDK lock must not appear in license metadata")
if licenses["source"]["xcodegen_lock"] != "scripts/xcodegen.lock":
    raise AssertionError("XcodeGen lock is missing from license metadata")
if "framework.sentry" in license_components or "framework.posthog" in license_components:
    raise AssertionError("Telemetry SDKs must not appear in license inventory")
PY
cp "${METADATA_DIR}/sbom.cdx.json" "${TMP}/sbom.first.json"
cp "${METADATA_DIR}/third-party-licenses.json" "${TMP}/licenses.first.json"
PERRY_RELEASE_METADATA_DIR="${METADATA_DIR}" "${SCRIPT_DIR}/generate-release-metadata.sh" --write >/dev/null
cmp -s "${TMP}/sbom.first.json" "${METADATA_DIR}/sbom.cdx.json"
cmp -s "${TMP}/licenses.first.json" "${METADATA_DIR}/third-party-licenses.json"

BAD_LOCK="${TMP}/bad-runtime.lock"
sed 's/^CODEX_RUNTIME_VERSION=.*/CODEX_RUNTIME_VERSION=latest/' \
  "${SCRIPT_DIR}/codex-runtime.lock" > "${BAD_LOCK}"
expect_failure env PERRY_CODEX_RUNTIME_LOCK="${BAD_LOCK}" \
  "${SCRIPT_DIR}/fetch-codex-runtime.sh" --check-lock

BAD_CUA_LOCK="${TMP}/bad-cua-driver.lock"
sed 's/^CUA_DRIVER_SOURCE_REVISION=.*/CUA_DRIVER_SOURCE_REVISION=not-a-revision/' \
  "${SCRIPT_DIR}/cua-driver.lock" > "${BAD_CUA_LOCK}"
expect_failure env PERRY_CUA_DRIVER_LOCK="${BAD_CUA_LOCK}" \
  PERRY_RELEASE_METADATA_DIR="${METADATA_DIR}" \
  "${SCRIPT_DIR}/generate-release-metadata.sh" --check

BAD_AGENT_DESKTOP_LOCK="${TMP}/bad-agent-desktop.lock"
sed 's/^AGENT_DESKTOP_SOURCE_REVISION=.*/AGENT_DESKTOP_SOURCE_REVISION=not-a-revision/' \
  "${SCRIPT_DIR}/agent-desktop.lock" > "${BAD_AGENT_DESKTOP_LOCK}"
expect_failure env PERRY_AGENT_DESKTOP_LOCK="${BAD_AGENT_DESKTOP_LOCK}" \
  PERRY_RELEASE_METADATA_DIR="${METADATA_DIR}" \
  "${SCRIPT_DIR}/generate-release-metadata.sh" --check

BAD_XCODEGEN_LOCK="${TMP}/bad-xcodegen.lock"
sed 's/^XCODEGEN_ARCHIVE_SHA256=.*/XCODEGEN_ARCHIVE_SHA256=latest/' \
  "${SCRIPT_DIR}/xcodegen.lock" > "${BAD_XCODEGEN_LOCK}"
expect_failure env PERRY_XCODEGEN_LOCK="${BAD_XCODEGEN_LOCK}" \
  "${SCRIPT_DIR}/fetch-xcodegen.sh" --check-lock

ARTIFACT_ROOT="${TMP}/artifacts"
mkdir -p "${ARTIFACT_ROOT}"
printf '%s\n' alpha > "${ARTIFACT_ROOT}/one.txt"
printf '%s\n' beta > "${ARTIFACT_ROOT}/two.txt"
PERRY_ARTIFACT_ROOT="${ARTIFACT_ROOT}" \
PERRY_ARTIFACT_MANIFEST="${TMP}/artifacts.sha256" \
PERRY_RELEASE_ARTIFACTS="one.txt:two.txt" \
  "${SCRIPT_DIR}/verify-artifact-manifest.sh" --write >/dev/null
PERRY_ARTIFACT_ROOT="${ARTIFACT_ROOT}" \
PERRY_ARTIFACT_MANIFEST="${TMP}/artifacts.sha256" \
PERRY_RELEASE_ARTIFACTS="one.txt:two.txt" \
  "${SCRIPT_DIR}/verify-artifact-manifest.sh" --check >/dev/null
printf '%s\n' changed > "${ARTIFACT_ROOT}/one.txt"
expect_failure env PERRY_ARTIFACT_ROOT="${ARTIFACT_ROOT}" \
  PERRY_ARTIFACT_MANIFEST="${TMP}/artifacts.sha256" \
  PERRY_RELEASE_ARTIFACTS="one.txt:two.txt" \
  "${SCRIPT_DIR}/verify-artifact-manifest.sh" --check

UNSIGNED_APP="${TMP}/Unsigned.app"
mkdir -p "${UNSIGNED_APP}/Contents/MacOS"
printf '%s\n' '#!/bin/sh' 'exit 0' > "${UNSIGNED_APP}/Contents/MacOS/Unsigned"
chmod +x "${UNSIGNED_APP}/Contents/MacOS/Unsigned"
codesign --force --sign - "${UNSIGNED_APP}" >/dev/null 2>&1
expect_failure "${SCRIPT_DIR}/verify-distribution-signatures.sh" "${UNSIGNED_APP}" "TESTTEAM"
expect_failure "${SCRIPT_DIR}/verify-gatekeeper-dmg.sh" "${TMP}/missing.dmg"

ROLLOUT_ROOT="${TMP}/rollout"
mkdir -p "${ROLLOUT_ROOT}/artifacts"
printf '%s\n' current-dmg > "${ROLLOUT_ROOT}/artifacts/Perry-1.0.dmg"
printf '%s\n' previous-dmg > "${ROLLOUT_ROOT}/artifacts/Perry-0.9.dmg"
CURRENT_DMG_SIZE="$(stat -f '%z' "${ROLLOUT_ROOT}/artifacts/Perry-1.0.dmg")"
PREVIOUS_DMG_SIZE="$(stat -f '%z' "${ROLLOUT_ROOT}/artifacts/Perry-0.9.dmg")"
sed -e "s/@VERSION@/1.0/g" -e "s/@BUILD@/2/g" -e "s/@DMG@/Perry-1.0.dmg/g" -e "s/@LENGTH@/${CURRENT_DMG_SIZE}/g" \
  "${SCRIPT_DIR}/fixtures/appcast.xml" > "${ROLLOUT_ROOT}/artifacts/appcast-1.0.xml"
sed -e "s/@VERSION@/0.9/g" -e "s/@BUILD@/1/g" -e "s/@DMG@/Perry-0.9.dmg/g" -e "s/@LENGTH@/${PREVIOUS_DMG_SIZE}/g" \
  "${SCRIPT_DIR}/fixtures/appcast.xml" > "${ROLLOUT_ROOT}/artifacts/appcast-0.9.xml"
ROLLOUT_STATE="${ROLLOUT_ROOT}/rollout.json"
"${SCRIPT_DIR}/manage-update-rollout.py" initialize \
  --state "${ROLLOUT_STATE}" \
  --version 1.0 \
  --build 2 \
  --dmg "${ROLLOUT_ROOT}/artifacts/Perry-1.0.dmg" \
  --appcast "${ROLLOUT_ROOT}/artifacts/appcast-1.0.xml" \
  --previous-version 0.9 \
  --previous-build 1 \
  --previous-dmg "${ROLLOUT_ROOT}/artifacts/Perry-0.9.dmg" \
  --previous-appcast "${ROLLOUT_ROOT}/artifacts/appcast-0.9.xml" >/dev/null
"${SCRIPT_DIR}/manage-update-rollout.py" verify --state "${ROLLOUT_STATE}" >/dev/null
expect_failure "${SCRIPT_DIR}/manage-update-rollout.py" promote \
  --state "${ROLLOUT_STATE}" --stage 10
for stage in beta 10 25; do
  "${SCRIPT_DIR}/manage-update-rollout.py" promote \
    --state "${ROLLOUT_STATE}" --stage "${stage}" >/dev/null
done
"${SCRIPT_DIR}/manage-update-rollout.py" verify --state "${ROLLOUT_STATE}" >/dev/null
printf '%s\n' tampered >> "${ROLLOUT_ROOT}/feeds/10/appcast.xml"
expect_failure "${SCRIPT_DIR}/manage-update-rollout.py" verify --state "${ROLLOUT_STATE}"
cp "${ROLLOUT_ROOT}/artifacts/current/appcast.xml" "${ROLLOUT_ROOT}/feeds/10/appcast.xml"
"${SCRIPT_DIR}/manage-update-rollout.py" rollback --state "${ROLLOUT_STATE}" >/dev/null
"${SCRIPT_DIR}/manage-update-rollout.py" verify --state "${ROLLOUT_STATE}" >/dev/null
cmp -s "${ROLLOUT_ROOT}/artifacts/previous/appcast.xml" "${ROLLOUT_ROOT}/feeds/internal/appcast.xml"
cmp -s "${ROLLOUT_ROOT}/artifacts/previous/appcast.xml" "${ROLLOUT_ROOT}/feeds/25/appcast.xml"
expect_failure "${SCRIPT_DIR}/manage-update-rollout.py" promote \
  --state "${ROLLOUT_STATE}" --stage 50

BUNDLE_FIXTURE="${TMP}/Perry.app"
mkdir -p \
  "${BUNDLE_FIXTURE}/Contents/MacOS" \
  "${BUNDLE_FIXTURE}/Contents/Resources/Sounds" \
  "${BUNDLE_FIXTURE}/Contents/Resources/CodexRuntime/bin" \
  "${BUNDLE_FIXTURE}/Contents/Resources/CuaDriver/bin" \
  "${BUNDLE_FIXTURE}/Contents/Resources/AgentDesktop/bin" \
  "${BUNDLE_FIXTURE}/Contents/Resources/LocalEngine"
for cue in wake send receive done fail; do
  printf '%s\n' "${cue}" > "${BUNDLE_FIXTURE}/Contents/Resources/Sounds/${cue}.caf"
done
printf '%s\n' 'int main(void) { return 0; }' > "${TMP}/bundle-fixture.c"
xcrun --sdk macosx clang -arch arm64 "${TMP}/bundle-fixture.c" -o "${BUNDLE_FIXTURE}/Contents/MacOS/Perry"
cp "${BUNDLE_FIXTURE}/Contents/MacOS/Perry" "${BUNDLE_FIXTURE}/Contents/Resources/CodexRuntime/bin/codex"
cp "${BUNDLE_FIXTURE}/Contents/MacOS/Perry" "${BUNDLE_FIXTURE}/Contents/Resources/CuaDriver/bin/cua-driver"
cp "${BUNDLE_FIXTURE}/Contents/MacOS/Perry" "${BUNDLE_FIXTURE}/Contents/Resources/AgentDesktop/bin/agent-desktop"
cp "${BUNDLE_FIXTURE}/Contents/MacOS/Perry" "${BUNDLE_FIXTURE}/Contents/Resources/AgentDesktop/bin/agent-desktop-macos-helper"
cp "${BUNDLE_FIXTURE}/Contents/MacOS/Perry" "${BUNDLE_FIXTURE}/Contents/MacOS/perry-mcp"
cp "${BUNDLE_FIXTURE}/Contents/MacOS/Perry" "${BUNDLE_FIXTURE}/Contents/Resources/LocalEngine/llama-server"
"${SCRIPT_DIR}/verify-bundle-contents.sh" "${BUNDLE_FIXTURE}" >/dev/null
printf '%s\n' duplicate > "${BUNDLE_FIXTURE}/Contents/Resources/wake.caf"
expect_failure "${SCRIPT_DIR}/verify-bundle-contents.sh" "${BUNDLE_FIXTURE}"

echo "release automation self-tests passed"
