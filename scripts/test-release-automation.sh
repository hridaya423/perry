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
