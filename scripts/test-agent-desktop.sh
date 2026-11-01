#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
FETCH_SCRIPT="${SCRIPT_DIR}/fetch-agent-desktop.sh"
LOCK_FILE="${SCRIPT_DIR}/agent-desktop.lock"
ORIGINAL_PATH="${PATH}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/perry-agent-desktop-self-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

die() {
  echo "agent-desktop self-test: $*" >&2
  exit 1
}

[ -x "${FETCH_SCRIPT}" ] || die "fetch script is not executable"
PERRY_AGENT_DESKTOP_LOCK="${LOCK_FILE}" "${FETCH_SCRIPT}" --check-lock >/dev/null

FAKE_BIN="${TMP_DIR}/bin"
mkdir -p "${FAKE_BIN}"
CURL_MARKER="${TMP_DIR}/curl-marker"

printf '%s\n' \
  '#!/bin/sh' \
  'if [ "${1:-}" = "-s" ]; then printf "%s\n" Darwin; else printf "%s\n" arm64; fi' \
  > "${FAKE_BIN}/uname"
printf '%s\n' \
  '#!/bin/sh' \
  'output=""' \
  'url=""' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in' \
  '    -o) output="$2"; shift 2 ;;' \
  '    --retry|--connect-timeout|--max-time) shift 2 ;;' \
  '    --fail|--location|--silent|--show-error) shift ;;' \
  '    *) url="$1"; shift ;;' \
  '  esac' \
  'done' \
  'printf "%s\n" "${url}" > "${PERRY_AGENT_DESKTOP_TEST_CURL_MARKER}"' \
  'cp "${PERRY_AGENT_DESKTOP_TEST_ARCHIVE}" "${output}"' \
  > "${FAKE_BIN}/curl"
printf '%s\n' \
  '#!/bin/sh' \
  '[ "$1" = "-archs" ] || exit 1' \
  'if [ -f "${PERRY_AGENT_DESKTOP_TEST_UNIVERSAL:-/nonexistent}" ]; then printf "%s\n" "x86_64 arm64"; else printf "%s\n" arm64; fi' \
  > "${FAKE_BIN}/lipo"
chmod 755 "${FAKE_BIN}/uname" "${FAKE_BIN}/curl" "${FAKE_BIN}/lipo"

ARCHIVE_ROOT="${TMP_DIR}/archive-root"
mkdir -p "${ARCHIVE_ROOT}"
printf '%s\n' 'agent-desktop test binary' > "${ARCHIVE_ROOT}/agent-desktop"
printf '%s\n' 'agent-desktop test helper' > "${ARCHIVE_ROOT}/agent-desktop-macos-helper"
chmod 755 "${ARCHIVE_ROOT}/agent-desktop" "${ARCHIVE_ROOT}/agent-desktop-macos-helper"
ARCHIVE_FILE="${TMP_DIR}/agent-desktop-v1.0.2-aarch64-apple-darwin.tar.gz"
tar -czf "${ARCHIVE_FILE}" -C "${ARCHIVE_ROOT}" agent-desktop agent-desktop-macos-helper
ARCHIVE_SHA256="$(shasum -a 256 "${ARCHIVE_FILE}" | awk '{print $1}')"
BINARY_SHA256="$(shasum -a 256 "${ARCHIVE_ROOT}/agent-desktop" | awk '{print $1}')"
HELPER_SHA256="$(shasum -a 256 "${ARCHIVE_ROOT}/agent-desktop-macos-helper" | awk '{print $1}')"
TEST_LOCK="${TMP_DIR}/agent-desktop.lock"
awk -v archive="${ARCHIVE_SHA256}" -v binary="${BINARY_SHA256}" -v helper="${HELPER_SHA256}" '
  /^AGENT_DESKTOP_ARCHIVE_SHA256=/ { print "AGENT_DESKTOP_ARCHIVE_SHA256=" archive; next }
  /^AGENT_DESKTOP_BINARY_SHA256=/ { print "AGENT_DESKTOP_BINARY_SHA256=" binary; next }
  /^AGENT_DESKTOP_HELPER_SHA256=/ { print "AGENT_DESKTOP_HELPER_SHA256=" helper; next }
  { print }
' "${LOCK_FILE}" > "${TEST_LOCK}"

DEST="${TMP_DIR}/installed"
export PATH="${FAKE_BIN}:${ORIGINAL_PATH}"
export PERRY_AGENT_DESKTOP_TEST_ARCHIVE="${ARCHIVE_FILE}"
export PERRY_AGENT_DESKTOP_TEST_CURL_MARKER="${CURL_MARKER}"
PERRY_AGENT_DESKTOP_LOCK="${TEST_LOCK}" PERRY_AGENT_DESKTOP_DEST="${DEST}" "${FETCH_SCRIPT}" --fetch >/dev/null
[ -x "${DEST}/bin/agent-desktop" ] || die "fetch did not install the binary"
[ -x "${DEST}/bin/agent-desktop-macos-helper" ] || die "fetch did not install the helper"
[ "$(cat "${DEST}/.version")" = "1.0.2" ] || die "fetch wrote the wrong version marker"
[ "$(shasum -a 256 "${DEST}/bin/agent-desktop" | awk '{print $1}')" = "${BINARY_SHA256}" ] || die "fetch installed the wrong binary"
[ "$(cat "${CURL_MARKER}")" = "https://github.com/vercel-labs/agent-desktop/releases/download/v1.0.2/agent-desktop-v1.0.2-aarch64-apple-darwin.tar.gz" ] || die "fetch used the wrong release URL"

printf '%s\n' offline > "${CURL_MARKER}"
PERRY_AGENT_DESKTOP_LOCK="${TEST_LOCK}" PERRY_AGENT_DESKTOP_DEST="${DEST}" "${FETCH_SCRIPT}" --check >/dev/null
[ "$(cat "${CURL_MARKER}")" = offline ] || die "--check attempted a network download"

printf '%s\n' changed > "${DEST}/bin/agent-desktop-macos-helper"
if PERRY_AGENT_DESKTOP_LOCK="${TEST_LOCK}" PERRY_AGENT_DESKTOP_DEST="${DEST}" "${FETCH_SCRIPT}" --check >/dev/null 2>&1; then
  die "--check accepted a helper with the wrong checksum"
fi
[ "$(cat "${CURL_MARKER}")" = offline ] || die "failed --check attempted a network download"

rm -rf "${DEST}"
touch "${TMP_DIR}/universal"
if PERRY_AGENT_DESKTOP_TEST_UNIVERSAL="${TMP_DIR}/universal" PERRY_AGENT_DESKTOP_LOCK="${TEST_LOCK}" \
  PERRY_AGENT_DESKTOP_DEST="${DEST}" "${FETCH_SCRIPT}" --fetch >/dev/null 2>&1; then
  die "--fetch accepted a binary that is not arm64-only"
fi

LATEST_LOCK="${TMP_DIR}/latest.lock"
awk '
  /^AGENT_DESKTOP_ASSET_URL=/ {
    print "AGENT_DESKTOP_ASSET_URL=https://github.com/vercel-labs/agent-desktop/releases/latest/agent-desktop-v1.0.2-aarch64-apple-darwin.tar.gz"
    next
  }
  { print }
' "${LOCK_FILE}" > "${LATEST_LOCK}"
if PERRY_AGENT_DESKTOP_LOCK="${LATEST_LOCK}" "${FETCH_SCRIPT}" --check-lock >/dev/null 2>&1; then
  die "--check-lock accepted a latest release URL"
fi

echo "agent-desktop self-tests passed"
