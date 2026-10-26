#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
FETCH_SCRIPT="${SCRIPT_DIR}/fetch-cua-driver.sh"
LOCK_FILE="${SCRIPT_DIR}/cua-driver.lock"
ORIGINAL_PATH="${PATH}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/perry-cua-self-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

die() {
  echo "cua self-test: $*" >&2
  exit 1
}

[ -x "${FETCH_SCRIPT}" ] || die "fetch script is not executable"
PERRY_CUA_DRIVER_LOCK="${LOCK_FILE}" "${FETCH_SCRIPT}" --check-lock >/dev/null

FAKE_BIN="${TMP_DIR}/bin"
mkdir -p "${FAKE_BIN}"
UNAME_SCRIPT="${FAKE_BIN}/uname"
CURL_SCRIPT="${FAKE_BIN}/curl"
LIPO_SCRIPT="${FAKE_BIN}/lipo"
CODESIGN_SCRIPT="${FAKE_BIN}/codesign"
CURL_MARKER="${TMP_DIR}/curl-marker"

printf '%s\n' \
  '#!/bin/sh' \
  'if [ "${1:-}" = "-s" ]; then printf "%s\n" Darwin; else printf "%s\n" arm64; fi' \
  > "${UNAME_SCRIPT}"
chmod 755 "${UNAME_SCRIPT}"

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
  'printf "%s\n" "${url}" > "${PERRY_CUA_TEST_CURL_MARKER}"' \
  'cp "${PERRY_CUA_TEST_ARCHIVE}" "${output}"' \
  > "${CURL_SCRIPT}"
chmod 755 "${CURL_SCRIPT}"

printf '%s\n' \
  '#!/bin/sh' \
  'if [ "$1" = "-archs" ]; then' \
  '  case "$2" in' \
  '    "${PERRY_CUA_DRIVER_DEST}"/bin/cua-driver) printf "%s\n" arm64 ;;' \
  '    *) printf "%s\n" "x86_64 arm64" ;;' \
  '  esac' \
  '  exit 0' \
  'fi' \
  '[ "$1" = "-thin" ] && [ "$2" = "arm64" ] && [ "$4" = "-output" ]' \
  'cp "$3" "$5"' \
  > "${LIPO_SCRIPT}"
chmod 755 "${LIPO_SCRIPT}"

printf '%s\n' \
  '#!/bin/sh' \
  'if [ "$1" = "--verify" ]; then exit 0; fi' \
  'printf "%s\n" "Identifier=cua-driver" "TeamIdentifier=${PERRY_CUA_TEST_SIGNING_TEAM:-YCK386LBJ7}" >&2' \
  > "${CODESIGN_SCRIPT}"
chmod 755 "${CODESIGN_SCRIPT}"

ARCHIVE_ROOT="${TMP_DIR}/archive-root/cua-driver-rs-0.38.0-darwin-arm64"
mkdir -p "${ARCHIVE_ROOT}"
printf '%s\n' 'cua test driver' > "${ARCHIVE_ROOT}/cua-driver"
chmod 755 "${ARCHIVE_ROOT}/cua-driver"
ARCHIVE_FILE="${TMP_DIR}/cua-driver-rs-0.38.0-darwin-arm64.tar.gz"
tar -czf "${ARCHIVE_FILE}" -C "${TMP_DIR}/archive-root" cua-driver-rs-0.38.0-darwin-arm64/cua-driver
ARCHIVE_SHA256="$(shasum -a 256 "${ARCHIVE_FILE}" | awk '{print $1}')"
BINARY_SHA256="$(shasum -a 256 "${ARCHIVE_ROOT}/cua-driver" | awk '{print $1}')"
TEST_LOCK="${TMP_DIR}/cua-driver.lock"
awk -v archive_sha256="${ARCHIVE_SHA256}" -v binary_sha256="${BINARY_SHA256}" '
  /^CUA_DRIVER_ARCHIVE_SHA256=/ {
    print "CUA_DRIVER_ARCHIVE_SHA256=" archive_sha256
    next
  }
  /^CUA_DRIVER_BINARY_SHA256=/ {
    print "CUA_DRIVER_BINARY_SHA256=" binary_sha256
    next
  }
  /^CUA_DRIVER_DISTRIBUTION_BINARY_SHA256=/ {
    print "CUA_DRIVER_DISTRIBUTION_BINARY_SHA256=" binary_sha256
    next
  }
  { print }
' "${LOCK_FILE}" > "${TEST_LOCK}"

DEST="${TMP_DIR}/installed"
export PATH="${FAKE_BIN}:${ORIGINAL_PATH}"
export PERRY_CUA_TEST_ARCHIVE="${ARCHIVE_FILE}"
export PERRY_CUA_TEST_CURL_MARKER="${CURL_MARKER}"
PERRY_CUA_DRIVER_LOCK="${TEST_LOCK}" PERRY_CUA_DRIVER_DEST="${DEST}" "${FETCH_SCRIPT}" --fetch >/dev/null
[ -x "${DEST}/bin/cua-driver" ] || die "fetch did not install an executable"
[ "$(cat "${DEST}/.version")" = "0.38.0" ] || die "fetch wrote the wrong version marker"
[ "$(shasum -a 256 "${DEST}/bin/cua-driver" | awk '{print $1}')" = "${BINARY_SHA256}" ] || die "fetch installed the wrong binary"
[ "$(PERRY_CUA_DRIVER_DEST="${DEST}" lipo -archs "${DEST}/bin/cua-driver")" = arm64 ] || die "fetch did not install an arm64-only binary"
[ "$(cat "${CURL_MARKER}")" = "https://github.com/trycua/cua/releases/download/cua-driver-rs-v0.38.0/cua-driver-rs-0.38.0-darwin-arm64.tar.gz" ] || die "fetch used the wrong release URL"

printf '%s\n' offline > "${CURL_MARKER}"
PERRY_CUA_DRIVER_LOCK="${TEST_LOCK}" PERRY_CUA_DRIVER_DEST="${DEST}" "${FETCH_SCRIPT}" --check >/dev/null
[ "$(cat "${CURL_MARKER}")" = offline ] || die "--check attempted a network download"

if PERRY_CUA_TEST_SIGNING_TEAM=WRONGTEAM1 PERRY_CUA_DRIVER_LOCK="${TEST_LOCK}" \
  PERRY_CUA_DRIVER_DEST="${DEST}" "${FETCH_SCRIPT}" --check >/dev/null 2>&1; then
  die "--check accepted a binary signed by the wrong team"
fi

printf '%s\n' changed > "${DEST}/bin/cua-driver"
if PERRY_CUA_DRIVER_LOCK="${TEST_LOCK}" PERRY_CUA_DRIVER_DEST="${DEST}" "${FETCH_SCRIPT}" --check >/dev/null 2>&1; then
  die "--check accepted a binary with the wrong checksum"
fi
[ "$(cat "${CURL_MARKER}")" = offline ] || die "failed --check attempted a network download"

LATEST_LOCK="${TMP_DIR}/latest.lock"
awk -v asset="cua-driver-rs-0.38.0-darwin-arm64.tar.gz" '
  /^CUA_DRIVER_ASSET_URL=/ {
    print "CUA_DRIVER_ASSET_URL=https://github.com/trycua/cua/releases/latest/" asset
    next
  }
  { print }
' "${LOCK_FILE}" > "${LATEST_LOCK}"
if PERRY_CUA_DRIVER_LOCK="${LATEST_LOCK}" "${FETCH_SCRIPT}" --check-lock >/dev/null 2>&1; then
  die "--check-lock accepted a latest release URL"
fi

echo "cua driver self-tests passed"
