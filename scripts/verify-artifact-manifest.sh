#!/bin/sh
set -eu
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
MANIFEST_PATH="${PERRY_ARTIFACT_MANIFEST:-${REPO_ROOT}/docs/release-readiness/artifact-manifest.sha256}"
ARTIFACT_ROOT="${PERRY_ARTIFACT_ROOT:-${REPO_ROOT}}"
ARTIFACTS="${PERRY_RELEASE_ARTIFACTS:-scripts/codex-runtime.lock:scripts/cua-driver.lock:scripts/agent-desktop.lock:scripts/sparkle.lock:scripts/xcodegen.lock:docs/release-readiness/sbom.cdx.json:docs/release-readiness/third-party-licenses.json:App/Resources/CodexRuntime/.version:App/Resources/CodexRuntime/bin/codex:App/Resources/CuaDriver/.version:App/Resources/CuaDriver/bin/cua-driver:App/Resources/CuaDriver/capabilities.yaml:App/Resources/AgentDesktop/.version:App/Resources/AgentDesktop/bin/agent-desktop:App/Resources/AgentDesktop/bin/agent-desktop-macos-helper}"

die() {
  echo "artifact manifest: $*" >&2
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
[ -d "${ARTIFACT_ROOT}" ] || die "artifact root not found: ${ARTIFACT_ROOT}"

is_sha256() {
  printf '%s\n' "$1" | awk 'length($0) == 64 && $0 !~ /[^0-9a-f]/ { valid = 1 } END { exit !valid }'
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
    return 0
  fi
  die "shasum or sha256sum is required"
}

validate_artifact_path() {
  case "$1" in
    ''|/*|.|./*|../*|*/../*|*[!A-Za-z0-9_./-]*) die "invalid artifact path: $1" ;;
  esac
}

if [ "${MODE}" = "write" ]; then
  mkdir -p "$(dirname -- "${MANIFEST_PATH}")"
  TEMP_MANIFEST="$(mktemp "${TMPDIR:-/tmp}/perry-artifact-manifest.XXXXXX")"
  trap 'rm -f "${TEMP_MANIFEST}"' EXIT
  set -f
  for artifact in $(printf '%s\n' "${ARTIFACTS}" | tr ':' '\n' | sed '/^$/d' | LC_ALL=C sort -u); do
    validate_artifact_path "${artifact}"
    FILE="${ARTIFACT_ROOT}/${artifact}"
    [ -f "${FILE}" ] || die "artifact not found: ${FILE}"
    HASH="$(sha256_file "${FILE}")"
    is_sha256 "${HASH}" || die "could not calculate SHA-256 for ${FILE}"
    printf '%s  %s\n' "${HASH}" "${artifact}" >> "${TEMP_MANIFEST}"
  done
  [ -s "${TEMP_MANIFEST}" ] || die "no artifacts configured"
  mv "${TEMP_MANIFEST}" "${MANIFEST_PATH}"
  trap - EXIT
  echo "artifact manifest written: ${MANIFEST_PATH}"
  exit 0
fi

[ -f "${MANIFEST_PATH}" ] || die "manifest not found: ${MANIFEST_PATH}"
set -f
PREVIOUS=""
COUNT=0
FOUND_ARTIFACTS=""
while IFS= read -r line || [ -n "${line}" ]; do
  [ -n "${line}" ] || die "manifest contains a blank line"
  set -- ${line}
  [ "$#" -eq 2 ] || die "manifest line must contain a SHA-256 and path: ${line}"
  EXPECTED="$1"
  ARTIFACT="$2"
  is_sha256 "${EXPECTED}" || die "manifest has an invalid SHA-256: ${EXPECTED}"
  validate_artifact_path "${ARTIFACT}"
  if [ -n "${PREVIOUS}" ] && [ "${ARTIFACT}" \< "${PREVIOUS}" ]; then
    die "manifest paths must be sorted: ${ARTIFACT}"
  fi
  [ "${ARTIFACT}" != "${PREVIOUS}" ] || die "manifest repeats artifact: ${ARTIFACT}"
  FILE="${ARTIFACT_ROOT}/${ARTIFACT}"
  [ -f "${FILE}" ] || die "artifact not found: ${FILE}"
  ACTUAL="$(sha256_file "${FILE}")"
  [ "${ACTUAL}" = "${EXPECTED}" ] || die "hash mismatch for ${ARTIFACT}: expected ${EXPECTED}, got ${ACTUAL}"
  PREVIOUS="${ARTIFACT}"
  FOUND_ARTIFACTS="${FOUND_ARTIFACTS}${ARTIFACT}:"
  COUNT=$((COUNT + 1))
done < "${MANIFEST_PATH}"

[ "${COUNT}" -gt 0 ] || die "manifest is empty"
EXPECTED_ARTIFACTS="$(printf '%s\n' "${ARTIFACTS}" | tr ':' '\n' | sed '/^$/d' | LC_ALL=C sort -u | tr '\n' ':')"
[ "${FOUND_ARTIFACTS}" = "${EXPECTED_ARTIFACTS}" ] || die "manifest artifact set does not match configured release artifacts"
echo "artifact manifest verified: ${COUNT} artifacts"
