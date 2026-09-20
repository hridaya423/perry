#!/bin/sh
set -eu

if [ -n "${SRCROOT:-}" ]; then
  REPO_ROOT="$(CDPATH= cd -- "${SRCROOT}" && pwd)"
  SCRIPT_DIR="${REPO_ROOT}/scripts"
else
  SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
  REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
fi
LOCK_FILE="${PERRY_CODEX_RUNTIME_LOCK:-${SCRIPT_DIR}/codex-runtime.lock}"
DEST="${PERRY_RUNTIME_DEST:-${REPO_ROOT}/App/Resources/CodexRuntime}"

die() {
  echo "codex runtime: $*" >&2
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

if [ "$#" -gt 1 ]; then
  usage
  die "expected at most one option"
fi

[ -f "${LOCK_FILE}" ] || die "missing lock file: ${LOCK_FILE}"

if ! awk -F= '
  BEGIN {
    allowed["CODEX_RUNTIME_VERSION"] = 1
    allowed["CODEX_RUNTIME_TARGET"] = 1
    allowed["CODEX_RUNTIME_ARCHIVE_SHA256"] = 1
    allowed["CODEX_RUNTIME_BINARY_SHA256"] = 1
    allowed["CODEX_RUNTIME_LICENSE"] = 1
    allowed["CODEX_RUNTIME_SOURCE"] = 1
    allowed["CODEX_RUNTIME_LICENSE_URL"] = 1
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
  die "lock file must contain one value for each pinned runtime field: ${LOCK_FILE}"
fi

read_lock_value() {
  KEY="$1"
  VALUE="$(awk -F= -v key="${KEY}" '
    $1 == key { value = substr($0, index($0, "=") + 1); count += 1 }
    END {
      if (count != 1) exit 1
      print value
    }
  ' "${LOCK_FILE}" 2>/dev/null || true)"
  [ -n "${VALUE}" ] || die "lock file must define exactly one ${KEY}: ${LOCK_FILE}"
  printf '%s\n' "${VALUE}"
}

VERSION="$(read_lock_value CODEX_RUNTIME_VERSION)"
TARGET="$(read_lock_value CODEX_RUNTIME_TARGET)"
ARCHIVE_SHA256="$(read_lock_value CODEX_RUNTIME_ARCHIVE_SHA256)"
BINARY_SHA256="$(read_lock_value CODEX_RUNTIME_BINARY_SHA256)"
LICENSE="$(read_lock_value CODEX_RUNTIME_LICENSE)"
SOURCE="$(read_lock_value CODEX_RUNTIME_SOURCE)"
LICENSE_URL="$(read_lock_value CODEX_RUNTIME_LICENSE_URL)"

if ! printf '%s\n' "${VERSION}" | awk '/^[0-9]+\.[0-9]+\.[0-9]+$/ { valid = 1 } END { exit !valid }'; then
  die "runtime version must be a pinned semver: ${VERSION}"
fi

[ "${TARGET}" = "aarch64-apple-darwin" ] || die "runtime lock must target aarch64-apple-darwin"
case "${LICENSE}" in
  ''|*[!A-Za-z0-9.+-]*) die "invalid runtime license in ${LOCK_FILE}: ${LICENSE}" ;;
esac
[ "${LICENSE}" != "NOASSERTION" ] || die "runtime license must be identified in ${LOCK_FILE}"
[ "${SOURCE}" = "https://github.com/openai/codex" ] || die "runtime source must be the pinned Codex repository"
case "${LICENSE_URL}" in
  "https://github.com/openai/codex/blob/rust-v${VERSION}/"*) ;;
  *) die "runtime license URL must name the pinned runtime tag" ;;
esac

is_sha256() {
  printf '%s\n' "$1" | awk 'length($0) == 64 && $0 !~ /[^0-9a-f]/ { valid = 1 } END { exit !valid }'
}

is_sha256 "${ARCHIVE_SHA256}" || die "invalid archive checksum in ${LOCK_FILE}"
is_sha256 "${BINARY_SHA256}" || die "invalid binary checksum in ${LOCK_FILE}"

if [ "${MODE}" = "lock" ]; then
  echo "codex ${VERSION} runtime lock verified"
  exit 0
fi

[ "$(uname -m)" = "arm64" ] || die "Apple Silicon is required; found $(uname -m)"

URL="https://github.com/openai/codex/releases/download/rust-v${VERSION}/codex-${TARGET}.tar.gz"
BINARY="${DEST}/bin/codex"
VERSION_FILE="${DEST}/.version"

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

runtime_is_valid() {
  [ -x "${BINARY}" ] || return 1
  [ -f "${VERSION_FILE}" ] || return 1
  [ "$(cat "${VERSION_FILE}")" = "${VERSION}" ] || return 1
  [ "$(sha256_file "${BINARY}")" = "${BINARY_SHA256}" ] || return 1
  return 0
}

if runtime_is_valid; then
  echo "codex ${VERSION} arm64 runtime verified"
  exit 0
fi

if [ "${MODE}" = "check" ]; then
  die "bundled runtime is missing or failed version/checksum verification; run ${SCRIPT_DIR}/fetch-codex-runtime.sh"
fi

echo "downloading pinned codex ${VERSION} arm64 runtime"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/perry-codex-runtime.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 --max-time 180 \
  "${URL}" -o "${TMP}/codex.tar.gz"

ACTUAL_ARCHIVE_SHA256="$(sha256_file "${TMP}/codex.tar.gz")"
[ "${ACTUAL_ARCHIVE_SHA256}" = "${ARCHIVE_SHA256}" ] || die "archive checksum mismatch: expected ${ARCHIVE_SHA256}, got ${ACTUAL_ARCHIVE_SHA256}"

mkdir -p "${TMP}/extracted"
tar -xzf "${TMP}/codex.tar.gz" -C "${TMP}/extracted"

ARCHIVE_BINARY="${TMP}/extracted/${TARGET}"
if [ ! -f "${ARCHIVE_BINARY}" ]; then
  ARCHIVE_BINARY="${TMP}/extracted/codex-${TARGET}"
fi
if [ ! -f "${ARCHIVE_BINARY}" ]; then
  ARCHIVE_BINARY="$(find "${TMP}/extracted" -type f -name codex | head -n 1)"
fi
[ -f "${ARCHIVE_BINARY}" ] || die "archive does not contain a codex binary for ${TARGET}"

ACTUAL_BINARY_SHA256="$(sha256_file "${ARCHIVE_BINARY}")"
[ "${ACTUAL_BINARY_SHA256}" = "${BINARY_SHA256}" ] || die "binary checksum mismatch: expected ${BINARY_SHA256}, got ${ACTUAL_BINARY_SHA256}"

mkdir -p "${DEST}/bin"
cp "${ARCHIVE_BINARY}" "${BINARY}"
chmod 755 "${BINARY}"
printf '%s\n' "${VERSION}" > "${VERSION_FILE}"
echo "vendored codex ${VERSION} arm64 runtime -> ${BINARY}"
