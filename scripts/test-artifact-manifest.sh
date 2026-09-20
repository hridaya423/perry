#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/perry-artifact-manifest-test.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

ARTIFACT_ROOT="${TMP}/root"
POLICY_PATH="${ARTIFACT_ROOT}/App/Resources/CuaDriver/capabilities.yaml"
MANIFEST_PATH="${TMP}/artifact-manifest.sha256"
mkdir -p "$(dirname -- "${POLICY_PATH}")"
cp "${REPO_ROOT}/App/Resources/CuaDriver/capabilities.yaml" "${POLICY_PATH}"

CLEAN_SOURCE="${TMP}/clean-source"
mkdir -p "${CLEAN_SOURCE}/App/Resources/CuaDriver"
cp "${REPO_ROOT}/.gitignore" "${CLEAN_SOURCE}/.gitignore"
cp "${REPO_ROOT}/App/Resources/CuaDriver/capabilities.yaml" \
  "${CLEAN_SOURCE}/App/Resources/CuaDriver/capabilities.yaml"
git -C "${CLEAN_SOURCE}" init -q
git -C "${CLEAN_SOURCE}" config user.name "Perry Artifact Manifest Test"
git -C "${CLEAN_SOURCE}" config user.email "artifact-manifest-test@perry.invalid"
git -C "${CLEAN_SOURCE}" add .gitignore App/Resources/CuaDriver/capabilities.yaml
git -C "${CLEAN_SOURCE}" commit -qm initial
git -C "${CLEAN_SOURCE}" ls-files --error-unmatch App/Resources/CuaDriver/capabilities.yaml >/dev/null
PERRY_RELEASE_SOURCE_ROOT="${CLEAN_SOURCE}" \
  "${SCRIPT_DIR}/verify-release-source.sh" >/dev/null

PERRY_ARTIFACT_ROOT="${ARTIFACT_ROOT}" \
PERRY_ARTIFACT_MANIFEST="${MANIFEST_PATH}" \
PERRY_RELEASE_ARTIFACTS="App/Resources/CuaDriver/capabilities.yaml" \
  "${SCRIPT_DIR}/verify-artifact-manifest.sh" --write >/dev/null
grep -Fq '  App/Resources/CuaDriver/capabilities.yaml' "${MANIFEST_PATH}"
PERRY_ARTIFACT_ROOT="${ARTIFACT_ROOT}" \
PERRY_ARTIFACT_MANIFEST="${MANIFEST_PATH}" \
PERRY_RELEASE_ARTIFACTS="App/Resources/CuaDriver/capabilities.yaml" \
  "${SCRIPT_DIR}/verify-artifact-manifest.sh" --check >/dev/null

printf '%s\n' mutation >> "${POLICY_PATH}"
if output="$(PERRY_ARTIFACT_ROOT="${ARTIFACT_ROOT}" \
  PERRY_ARTIFACT_MANIFEST="${MANIFEST_PATH}" \
  PERRY_RELEASE_ARTIFACTS="App/Resources/CuaDriver/capabilities.yaml" \
  "${SCRIPT_DIR}/verify-artifact-manifest.sh" --check 2>&1)"; then
  echo "artifact manifest test: mutated capabilities.yaml verified" >&2
  exit 1
fi
printf '%s\n' "${output}" | grep -Fq "hash mismatch for App/Resources/CuaDriver/capabilities.yaml"

echo "artifact manifest mutation regression passed"
