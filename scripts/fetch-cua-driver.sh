#!/bin/sh
set -eu

if [ -n "${SRCROOT:-}" ]; then
  REPO_ROOT="$(CDPATH= cd -- "${SRCROOT}" && pwd)"
  SCRIPT_DIR="${REPO_ROOT}/scripts"
else
  SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
  REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
fi
LOCK_FILE="${PERRY_CUA_DRIVER_LOCK:-${SCRIPT_DIR}/cua-driver.lock}"
DEST="${PERRY_CUA_DRIVER_DEST:-${REPO_ROOT}/App/Resources/CuaDriver}"

die() {
  echo "cua driver: $*" >&2
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
    allowed["CUA_DRIVER_VERSION"] = 1
    allowed["CUA_DRIVER_TARGET"] = 1
    allowed["CUA_DRIVER_RELEASE_TAG"] = 1
    allowed["CUA_DRIVER_ASSET"] = 1
    allowed["CUA_DRIVER_ASSET_URL"] = 1
    allowed["CUA_DRIVER_ARCHIVE_SHA256"] = 1
    allowed["CUA_DRIVER_BINARY_SHA256"] = 1
    allowed["CUA_DRIVER_DISTRIBUTION_BINARY_SHA256"] = 1
    allowed["CUA_DRIVER_ARCHIVE_BINARY"] = 1
    allowed["CUA_DRIVER_SIGNING_IDENTIFIER"] = 1
    allowed["CUA_DRIVER_SIGNING_TEAM"] = 1
    allowed["CUA_DRIVER_SOURCE"] = 1
    allowed["CUA_DRIVER_SOURCE_REVISION"] = 1
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
  die "lock file must contain one value for each pinned driver field: ${LOCK_FILE}"
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

VERSION="$(read_lock_value CUA_DRIVER_VERSION)"
TARGET="$(read_lock_value CUA_DRIVER_TARGET)"
RELEASE_TAG="$(read_lock_value CUA_DRIVER_RELEASE_TAG)"
ASSET="$(read_lock_value CUA_DRIVER_ASSET)"
ASSET_URL="$(read_lock_value CUA_DRIVER_ASSET_URL)"
ARCHIVE_SHA256="$(read_lock_value CUA_DRIVER_ARCHIVE_SHA256)"
BINARY_SHA256="$(read_lock_value CUA_DRIVER_BINARY_SHA256)"
DISTRIBUTION_BINARY_SHA256="$(read_lock_value CUA_DRIVER_DISTRIBUTION_BINARY_SHA256)"
ARCHIVE_BINARY="$(read_lock_value CUA_DRIVER_ARCHIVE_BINARY)"
SIGNING_IDENTIFIER="$(read_lock_value CUA_DRIVER_SIGNING_IDENTIFIER)"
SIGNING_TEAM="$(read_lock_value CUA_DRIVER_SIGNING_TEAM)"
SOURCE="$(read_lock_value CUA_DRIVER_SOURCE)"
SOURCE_REVISION="$(read_lock_value CUA_DRIVER_SOURCE_REVISION)"

if ! printf '%s\n' "${VERSION}" | awk '/^[0-9]+\.[0-9]+\.[0-9]+$/ { valid = 1 } END { exit !valid }'; then
  die "driver version must be a pinned semver: ${VERSION}"
fi

[ "${TARGET}" = "aarch64-apple-darwin" ] || die "driver lock must target aarch64-apple-darwin"
[ "${RELEASE_TAG}" = "cua-driver-rs-v${VERSION}" ] || die "release tag must match version: ${RELEASE_TAG}"
[ "${ASSET}" = "cua-driver-rs-${VERSION}-darwin-arm64.tar.gz" ] || die "asset must be the Apple Silicon release archive: ${ASSET}"
[ "${ASSET_URL}" = "https://github.com/trycua/cua/releases/download/${RELEASE_TAG}/${ASSET}" ] || die "asset URL must be the exact pinned GitHub release asset"
case "${RELEASE_TAG}/${ASSET_URL}" in
  *latest*|*LATEST*) die "latest release resolution is not allowed" ;;
esac
[ "${ARCHIVE_BINARY}" = "cua-driver-rs-${VERSION}-darwin-arm64/cua-driver" ] || die "archive binary path must name the pinned cua-driver member"
[ "${SOURCE}" = "https://github.com/trycua/cua" ] || die "driver source must be the pinned Cua repository"

is_sha256() {
  printf '%s\n' "$1" | awk 'length($0) == 64 && $0 !~ /[^0-9a-f]/ { valid = 1 } END { exit !valid }'
}

is_revision() {
  printf '%s\n' "$1" | awk 'length($0) == 40 && $0 !~ /[^0-9a-f]/ { valid = 1 } END { exit !valid }'
}

is_sha256 "${ARCHIVE_SHA256}" || die "invalid archive SHA256 in ${LOCK_FILE}"
is_sha256 "${BINARY_SHA256}" || die "invalid binary SHA256 in ${LOCK_FILE}"
is_sha256 "${DISTRIBUTION_BINARY_SHA256}" || die "invalid distribution binary SHA256 in ${LOCK_FILE}"
is_revision "${SOURCE_REVISION}" || die "invalid source revision in ${LOCK_FILE}"
[ "${SIGNING_IDENTIFIER}" = "cua-driver" ] || die "driver signing identifier must be cua-driver"
printf '%s\n' "${SIGNING_TEAM}" | awk 'length($0) == 10 && $0 !~ /[^A-Z0-9]/ { valid = 1 } END { exit !valid }' \
  || die "driver signing team must be a ten-character Apple team identifier"

if [ "${MODE}" = "lock" ]; then
  echo "cua-driver ${VERSION} lock verified"
  exit 0
fi

[ "$(uname -s)" = "Darwin" ] || die "macOS is required; found $(uname -s)"
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon is required; found $(uname -m)"
command -v lipo >/dev/null 2>&1 || die "lipo is required"
command -v codesign >/dev/null 2>&1 || die "codesign is required"

sha256_file() {
  file_path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file_path}" | awk '{print $1}'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file_path}" | awk '{print $1}'
    return 0
  fi
  die "shasum or sha256sum is required"
}

driver_signature_is_valid() {
  driver_path="$1"
  codesign --verify --strict --verbose=2 "${driver_path}" >/dev/null 2>&1 || return 1
  signature="$(codesign -dv --verbose=4 "${driver_path}" 2>&1)" || return 1
  identifier="$(printf '%s\n' "${signature}" | awk -F= '$1 == "Identifier" { print $2; exit }')"
  team="$(printf '%s\n' "${signature}" | awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
  [ "${identifier}" = "${SIGNING_IDENTIFIER}" ] || return 1
  [ "${team}" = "${SIGNING_TEAM}" ] || return 1
}

verify_driver_signature() {
  driver_signature_is_valid "$1" || die "Cua driver signature identity is invalid: $1"
}

BINARY="${DEST}/bin/cua-driver"
VERSION_FILE="${DEST}/.version"

driver_is_valid() {
  [ -x "${BINARY}" ] || return 1
  [ -f "${VERSION_FILE}" ] || return 1
  [ "$(cat "${VERSION_FILE}")" = "${VERSION}" ] || return 1
  [ "$(sha256_file "${BINARY}")" = "${DISTRIBUTION_BINARY_SHA256}" ] || return 1
  [ "$(lipo -archs "${BINARY}")" = "arm64" ] || return 1
  driver_signature_is_valid "${BINARY}" || return 1
  return 0
}

if driver_is_valid; then
  echo "cua-driver ${VERSION} arm64 driver verified"
  exit 0
fi

if [ "${MODE}" = "check" ]; then
  die "bundled driver is missing or failed version/checksum verification; run ${SCRIPT_DIR}/fetch-cua-driver.sh"
fi

command -v curl >/dev/null 2>&1 || die "curl is required for --fetch"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/perry-cua-driver.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

echo "downloading pinned cua-driver ${VERSION} for Apple Silicon"
curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 --max-time 180 \
  "${ASSET_URL}" -o "${TMP}/${ASSET}"

ACTUAL_ARCHIVE_SHA256="$(sha256_file "${TMP}/${ASSET}")"
[ "${ACTUAL_ARCHIVE_SHA256}" = "${ARCHIVE_SHA256}" ] || die "archive SHA256 mismatch: expected ${ARCHIVE_SHA256}, got ${ACTUAL_ARCHIVE_SHA256}"

mkdir -p "${TMP}/extracted"
tar -xzf "${TMP}/${ASSET}" -C "${TMP}/extracted" "${ARCHIVE_BINARY}"

ARCHIVE_BINARY_PATH="${TMP}/extracted/${ARCHIVE_BINARY}"
[ -f "${ARCHIVE_BINARY_PATH}" ] || die "archive does not contain the pinned cua-driver member"
[ ! -L "${ARCHIVE_BINARY_PATH}" ] || die "archive Cua driver must be a regular file"

ACTUAL_BINARY_SHA256="$(sha256_file "${ARCHIVE_BINARY_PATH}")"
[ "${ACTUAL_BINARY_SHA256}" = "${BINARY_SHA256}" ] || die "binary SHA256 mismatch: expected ${BINARY_SHA256}, got ${ACTUAL_BINARY_SHA256}"
verify_driver_signature "${ARCHIVE_BINARY_PATH}"
printf '%s\n' "$(lipo -archs "${ARCHIVE_BINARY_PATH}")" | tr ' ' '\n' | grep -qx arm64 \
  || die "archive Cua driver does not contain arm64"

mkdir -p "${DEST}/bin"
lipo -thin arm64 "${ARCHIVE_BINARY_PATH}" -output "${BINARY}"
chmod 755 "${BINARY}"
[ "$(sha256_file "${BINARY}")" = "${DISTRIBUTION_BINARY_SHA256}" ] \
  || die "distribution binary SHA256 mismatch after arm64 thinning"
[ "$(lipo -archs "${BINARY}")" = "arm64" ] || die "distribution Cua driver is not arm64-only"
verify_driver_signature "${BINARY}"
printf '%s\n' "${VERSION}" > "${VERSION_FILE}"
echo "vendored cua-driver ${VERSION} arm64 driver -> ${BINARY}"
