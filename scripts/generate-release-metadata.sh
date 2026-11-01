#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${PERRY_RELEASE_METADATA_DIR:-${REPO_ROOT}/docs/release-readiness}"
SBOM_PATH="${PERRY_SBOM_PATH:-${OUTPUT_DIR}/sbom.cdx.json}"
LICENSES_PATH="${PERRY_THIRD_PARTY_LICENSES_PATH:-${OUTPUT_DIR}/third-party-licenses.json}"
LOCK_FILE="${PERRY_CODEX_RUNTIME_LOCK:-${SCRIPT_DIR}/codex-runtime.lock}"
CUA_LOCK_FILE="${PERRY_CUA_DRIVER_LOCK:-${SCRIPT_DIR}/cua-driver.lock}"
AGENT_DESKTOP_LOCK_FILE="${PERRY_AGENT_DESKTOP_LOCK:-${SCRIPT_DIR}/agent-desktop.lock}"
SPARKLE_LOCK_FILE="${PERRY_SPARKLE_LOCK:-${SCRIPT_DIR}/sparkle.lock}"
XCODEGEN_LOCK_FILE="${PERRY_XCODEGEN_LOCK:-${SCRIPT_DIR}/xcodegen.lock}"
PYTHON_BIN="$(command -v python3 || true)"

die() {
  echo "release metadata: $*" >&2
  exit 1
}

usage() {
  echo "usage: $0 [--check|--write]" >&2
}

MODE="check"
case "${1:-}" in
  "") ;;
  --check) MODE="check" ;;
  --write) MODE="write" ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    usage
    die "unknown option: $1"
    ;;
esac

[ "$#" -le 1 ] || die "expected at most one option"
[ -n "${PYTHON_BIN}" ] || die "python3 is required"
[ -f "${LOCK_FILE}" ] || die "runtime lock not found: ${LOCK_FILE}"
[ -f "${CUA_LOCK_FILE}" ] || die "Cua driver lock not found: ${CUA_LOCK_FILE}"
[ -f "${AGENT_DESKTOP_LOCK_FILE}" ] || die "agent-desktop lock not found: ${AGENT_DESKTOP_LOCK_FILE}"
[ -f "${SPARKLE_LOCK_FILE}" ] || die "Sparkle lock not found: ${SPARKLE_LOCK_FILE}"
[ -f "${XCODEGEN_LOCK_FILE}" ] || die "XcodeGen lock not found: ${XCODEGEN_LOCK_FILE}"

PERRY_CODEX_RUNTIME_LOCK="${LOCK_FILE}" "${SCRIPT_DIR}/fetch-codex-runtime.sh" --check-lock >/dev/null
PERRY_CUA_DRIVER_LOCK="${CUA_LOCK_FILE}" "${SCRIPT_DIR}/fetch-cua-driver.sh" --check-lock >/dev/null
PERRY_AGENT_DESKTOP_LOCK="${AGENT_DESKTOP_LOCK_FILE}" "${SCRIPT_DIR}/fetch-agent-desktop.sh" --check-lock >/dev/null
PERRY_XCODEGEN_LOCK="${XCODEGEN_LOCK_FILE}" "${SCRIPT_DIR}/fetch-xcodegen.sh" --check-lock >/dev/null

command -v swift >/dev/null 2>&1 || die "swift is required"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/perry-release-metadata.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

for package in PerryCore PerryRuntimes PerryOverlay PerryGuide; do
  GRAPH_PATH="${TMP}/${package}.json"
  swift package show-dependencies \
    --package-path "${REPO_ROOT}/Packages/${package}" \
    --format json > "${GRAPH_PATH}"
done

if [ "${MODE}" = "write" ]; then
  mkdir -p "${OUTPUT_DIR}"
  "${PYTHON_BIN}" "${SCRIPT_DIR}/release_metadata.py" \
    --repo-root "${REPO_ROOT}" \
    --lock-file "${LOCK_FILE}" \
    --cua-driver-lock "${CUA_LOCK_FILE}" \
    --agent-desktop-lock "${AGENT_DESKTOP_LOCK_FILE}" \
    --sparkle-lock "${SPARKLE_LOCK_FILE}" \
    --xcodegen-lock "${XCODEGEN_LOCK_FILE}" \
    --sbom-path "${SBOM_PATH}" \
    --licenses-path "${LICENSES_PATH}" \
    --graph "${TMP}/PerryCore.json" \
    --graph "${TMP}/PerryRuntimes.json" \
    --graph "${TMP}/PerryOverlay.json" \
    --graph "${TMP}/PerryGuide.json"
  exit 0
fi

GENERATED_DIR="${TMP}/generated"
mkdir -p "${GENERATED_DIR}"
"${PYTHON_BIN}" "${SCRIPT_DIR}/release_metadata.py" \
  --repo-root "${REPO_ROOT}" \
  --lock-file "${LOCK_FILE}" \
  --cua-driver-lock "${CUA_LOCK_FILE}" \
  --agent-desktop-lock "${AGENT_DESKTOP_LOCK_FILE}" \
  --sparkle-lock "${SPARKLE_LOCK_FILE}" \
  --xcodegen-lock "${XCODEGEN_LOCK_FILE}" \
  --sbom-path "${GENERATED_DIR}/sbom.cdx.json" \
  --licenses-path "${GENERATED_DIR}/third-party-licenses.json" \
  --graph "${TMP}/PerryCore.json" \
  --graph "${TMP}/PerryRuntimes.json" \
  --graph "${TMP}/PerryOverlay.json" \
  --graph "${TMP}/PerryGuide.json" >/dev/null

[ -f "${SBOM_PATH}" ] || die "missing generated SBOM: ${SBOM_PATH}"
[ -f "${LICENSES_PATH}" ] || die "missing license inventory: ${LICENSES_PATH}"
cmp -s "${GENERATED_DIR}/sbom.cdx.json" "${SBOM_PATH}" || die "SBOM is stale; run ${SCRIPT_DIR}/generate-release-metadata.sh --write"
cmp -s "${GENERATED_DIR}/third-party-licenses.json" "${LICENSES_PATH}" || die "license inventory is stale; run ${SCRIPT_DIR}/generate-release-metadata.sh --write"
echo "release metadata verified: ${SBOM_PATH}, ${LICENSES_PATH}"
