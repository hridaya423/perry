#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
LOCK_FILE="${PERRY_XCODEGEN_LOCK:-${SCRIPT_DIR}/xcodegen.lock}"
INSTALL_ROOT="${PERRY_XCODEGEN_ROOT:-${REPO_ROOT}/build/tools/xcodegen}"
BINARY="${INSTALL_ROOT}/bin/xcodegen"

die() {
  echo "xcodegen runtime: $*" >&2
  exit 1
}

[ -f "${LOCK_FILE}" ] || die "lock file does not exist: ${LOCK_FILE}"
. "${LOCK_FILE}"

case "${XCODEGEN_VERSION:-}" in
  *[!0-9.]*|'') die "XCODEGEN_VERSION must be numeric dotted version text" ;;
esac
case "${XCODEGEN_ARCHIVE_URL:-}" in
  "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip") ;;
  *) die "XCODEGEN_ARCHIVE_URL is not the pinned upstream release" ;;
esac
for digest in "${XCODEGEN_ARCHIVE_SHA256:-}" "${XCODEGEN_BINARY_SHA256:-}"; do
  case "${digest}" in
    *[!0-9a-f]*|'') die "lock contains an invalid SHA-256 digest" ;;
  esac
  [ "${#digest}" -eq 64 ] || die "lock contains an invalid SHA-256 digest"
done

case "${1:---check}" in
  --check-lock)
    echo "xcodegen ${XCODEGEN_VERSION} lock verified"
    ;;
  --check)
    [ -x "${BINARY}" ] || die "xcodegen is not installed at ${BINARY}"
    [ "$(shasum -a 256 "${BINARY}" | awk '{print $1}')" = "${XCODEGEN_BINARY_SHA256}" ] \
      || die "installed xcodegen checksum mismatch"
    [ "$(${BINARY} --version)" = "Version: ${XCODEGEN_VERSION}" ] \
      || die "installed xcodegen version mismatch"
    echo "xcodegen ${XCODEGEN_VERSION} verified"
    ;;
  --fetch)
    command -v curl >/dev/null 2>&1 || die "curl is required"
    command -v unzip >/dev/null 2>&1 || die "unzip is required"
    temporary="$(mktemp -d "${TMPDIR:-/tmp}/perry-xcodegen.XXXXXX")"
    trap 'find "${temporary}" -depth -delete' EXIT
    curl -fsSL "${XCODEGEN_ARCHIVE_URL}" -o "${temporary}/xcodegen.zip"
    [ "$(shasum -a 256 "${temporary}/xcodegen.zip" | awk '{print $1}')" = "${XCODEGEN_ARCHIVE_SHA256}" ] \
      || die "downloaded xcodegen archive checksum mismatch"
    unzip -q "${temporary}/xcodegen.zip" -d "${temporary}/expanded"
    staged="${temporary}/expanded/xcodegen"
    [ -x "${staged}/bin/xcodegen" ] || die "archive does not contain xcodegen"
    [ "$(shasum -a 256 "${staged}/bin/xcodegen" | awk '{print $1}')" = "${XCODEGEN_BINARY_SHA256}" ] \
      || die "downloaded xcodegen binary checksum mismatch"
    mkdir -p "$(dirname "${INSTALL_ROOT}")"
    if [ -e "${INSTALL_ROOT}" ]; then
      find "${INSTALL_ROOT}" -depth -delete
    fi
    mv "${staged}" "${INSTALL_ROOT}"
    "${0}" --check
    ;;
  *)
    die "usage: $0 [--check-lock|--check|--fetch]"
    ;;
esac
