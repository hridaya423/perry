#!/bin/sh
set -eu

if [ -n "${SRCROOT:-}" ]; then
  REPO_ROOT="$(CDPATH= cd -- "${SRCROOT}" && pwd)"
  SCRIPT_DIR="${REPO_ROOT}/scripts"
else
  SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
  REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
fi
LOCK_FILE="${PERRY_AGENT_DESKTOP_LOCK:-${SCRIPT_DIR}/agent-desktop.lock}"
DEST="${PERRY_AGENT_DESKTOP_DEST:-${REPO_ROOT}/App/Resources/AgentDesktop}"

die() {
  echo "agent-desktop: $*" >&2
  exit 1
}

usage() {
  echo "usage: $0 [--check|--check-lock|--fetch]" >&2
}

MODE="fetch"
case "${1:-}" in
  "") ;;
  --check) MODE="check" ;;
  --check-lock) MODE="lock" ;;
  --fetch) MODE="fetch" ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    usage
    die "unknown option: $1"
    ;;
esac

[ "$#" -le 1 ] || {
  usage
  die "expected at most one option"
}

[ -f "${LOCK_FILE}" ] || die "missing lock file: ${LOCK_FILE}"

if ! awk -F= '
  BEGIN {
    allowed["AGENT_DESKTOP_VERSION"] = 1
    allowed["AGENT_DESKTOP_TARGET"] = 1
    allowed["AGENT_DESKTOP_RELEASE_TAG"] = 1
    allowed["AGENT_DESKTOP_ASSET"] = 1
    allowed["AGENT_DESKTOP_ASSET_URL"] = 1
    allowed["AGENT_DESKTOP_ARCHIVE_SHA256"] = 1
    allowed["AGENT_DESKTOP_BINARY_SHA256"] = 1
    allowed["AGENT_DESKTOP_HELPER_SHA256"] = 1
    allowed["AGENT_DESKTOP_SOURCE"] = 1
    allowed["AGENT_DESKTOP_SOURCE_REVISION"] = 1
  }
  /^[[:space:]]*$/ { next }
  {
    if (NF != 2 || !($1 in allowed) || $2 == "") invalid = 1
    seen[$1] += 1
  }
  END {
    for (key in allowed) {
      if (seen[key] != 1) invalid = 1
    }
    exit invalid
  }
' "${LOCK_FILE}"; then
  die "lock file must contain one value for each pinned field: ${LOCK_FILE}"
fi

read_lock_value() {
  lock_key="$1"
  lock_value="$(awk -F= -v key="${lock_key}" '
    $1 == key {
      value = substr($0, index($0, "=") + 1)
      count += 1
    }
    END {
      if (count != 1) exit 1
      print value
    }
  ' "${LOCK_FILE}" 2>/dev/null || true)"
  [ -n "${lock_value}" ] || die "lock file must define exactly one ${lock_key}: ${LOCK_FILE}"
  printf '%s\n' "${lock_value}"
}

VERSION="$(read_lock_value AGENT_DESKTOP_VERSION)"
TARGET="$(read_lock_value AGENT_DESKTOP_TARGET)"
RELEASE_TAG="$(read_lock_value AGENT_DESKTOP_RELEASE_TAG)"
ASSET="$(read_lock_value AGENT_DESKTOP_ASSET)"
ASSET_URL="$(read_lock_value AGENT_DESKTOP_ASSET_URL)"
ARCHIVE_SHA256="$(read_lock_value AGENT_DESKTOP_ARCHIVE_SHA256)"
BINARY_SHA256="$(read_lock_value AGENT_DESKTOP_BINARY_SHA256)"
HELPER_SHA256="$(read_lock_value AGENT_DESKTOP_HELPER_SHA256)"
SOURCE="$(read_lock_value AGENT_DESKTOP_SOURCE)"
SOURCE_REVISION="$(read_lock_value AGENT_DESKTOP_SOURCE_REVISION)"

if ! printf '%s\n' "${VERSION}" | awk '/^[0-9]+\.[0-9]+\.[0-9]+$/ { valid = 1 } END { exit !valid }'; then
  die "version must be a pinned semver: ${VERSION}"
fi

[ "${TARGET}" = "aarch64-apple-darwin" ] || die "lock must target aarch64-apple-darwin"
[ "${RELEASE_TAG}" = "v${VERSION}" ] || die "release tag must match version: ${RELEASE_TAG}"
[ "${ASSET}" = "agent-desktop-v${VERSION}-aarch64-apple-darwin.tar.gz" ] || die "asset must be the Apple Silicon release archive: ${ASSET}"
[ "${ASSET_URL}" = "https://github.com/vercel-labs/agent-desktop/releases/download/${RELEASE_TAG}/${ASSET}" ] || die "asset URL must be the exact pinned GitHub release asset"
case "${RELEASE_TAG}/${ASSET_URL}" in
  *latest*|*LATEST*) die "latest release resolution is not allowed" ;;
esac
[ "${SOURCE}" = "https://github.com/vercel-labs/agent-desktop" ] || die "source must be the pinned agent-desktop repository"

is_sha256() {
  printf '%s\n' "$1" | awk 'length($0) == 64 && $0 !~ /[^0-9a-f]/ { valid = 1 } END { exit !valid }'
}

is_revision() {
  printf '%s\n' "$1" | awk 'length($0) == 40 && $0 !~ /[^0-9a-f]/ { valid = 1 } END { exit !valid }'
}

is_sha256 "${ARCHIVE_SHA256}" || die "invalid archive SHA256 in ${LOCK_FILE}"
is_sha256 "${BINARY_SHA256}" || die "invalid binary SHA256 in ${LOCK_FILE}"
is_sha256 "${HELPER_SHA256}" || die "invalid helper SHA256 in ${LOCK_FILE}"
is_revision "${SOURCE_REVISION}" || die "invalid source revision in ${LOCK_FILE}"

if [ "${MODE}" = "lock" ]; then
  echo "agent-desktop ${VERSION} lock verified"
  exit 0
fi

[ "$(uname -s)" = "Darwin" ] || die "macOS is required; found $(uname -s)"
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon is required; found $(uname -m)"
command -v lipo >/dev/null 2>&1 || die "lipo is required"

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

BINARY="${DEST}/bin/agent-desktop"
HELPER="${DEST}/bin/agent-desktop-macos-helper"
VERSION_FILE="${DEST}/.version"

installed_is_valid() {
  [ -x "${BINARY}" ] || return 1
  [ -x "${HELPER}" ] || return 1
  [ -f "${VERSION_FILE}" ] || return 1
  [ "$(cat "${VERSION_FILE}")" = "${VERSION}" ] || return 1
  [ "$(sha256_file "${BINARY}")" = "${BINARY_SHA256}" ] || return 1
  [ "$(sha256_file "${HELPER}")" = "${HELPER_SHA256}" ] || return 1
  [ "$(lipo -archs "${BINARY}")" = "arm64" ] || return 1
  [ "$(lipo -archs "${HELPER}")" = "arm64" ] || return 1
  return 0
}

if installed_is_valid; then
  echo "agent-desktop ${VERSION} arm64 verified"
  exit 0
fi

if [ "${MODE}" = "check" ]; then
  die "bundled agent-desktop is missing or failed version/checksum verification; run ${SCRIPT_DIR}/fetch-agent-desktop.sh"
fi

command -v curl >/dev/null 2>&1 || die "curl is required for --fetch"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/perry-agent-desktop.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

echo "downloading pinned agent-desktop ${VERSION} for Apple Silicon"
curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 --max-time 180 \
  "${ASSET_URL}" -o "${TMP}/${ASSET}"

ACTUAL_ARCHIVE_SHA256="$(sha256_file "${TMP}/${ASSET}")"
[ "${ACTUAL_ARCHIVE_SHA256}" = "${ARCHIVE_SHA256}" ] || die "archive SHA256 mismatch: expected ${ARCHIVE_SHA256}, got ${ACTUAL_ARCHIVE_SHA256}"

mkdir -p "${TMP}/extracted"
tar -xzf "${TMP}/${ASSET}" -C "${TMP}/extracted" agent-desktop agent-desktop-macos-helper

for member in agent-desktop agent-desktop-macos-helper; do
  [ -f "${TMP}/extracted/${member}" ] || die "archive does not contain ${member}"
  [ ! -L "${TMP}/extracted/${member}" ] || die "archive ${member} must be a regular file"
  [ "$(lipo -archs "${TMP}/extracted/${member}")" = "arm64" ] || die "archive ${member} is not arm64-only"
done
[ "$(sha256_file "${TMP}/extracted/agent-desktop")" = "${BINARY_SHA256}" ] || die "binary SHA256 mismatch"
[ "$(sha256_file "${TMP}/extracted/agent-desktop-macos-helper")" = "${HELPER_SHA256}" ] || die "helper SHA256 mismatch"

mkdir -p "${DEST}/bin"
cp "${TMP}/extracted/agent-desktop" "${BINARY}"
cp "${TMP}/extracted/agent-desktop-macos-helper" "${HELPER}"
chmod 755 "${BINARY}" "${HELPER}"
printf '%s\n' "${VERSION}" > "${VERSION_FILE}"
echo "vendored agent-desktop ${VERSION} arm64 -> ${DEST}/bin"
