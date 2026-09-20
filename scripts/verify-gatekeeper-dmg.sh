#!/bin/sh
set -eu

DMG_PATH="${1:-}"

die() {
  echo "Gatekeeper DMG verification: $*" >&2
  exit 1
}

[ "$(uname -s)" = "Darwin" ] || die "macOS is required"
[ -f "${DMG_PATH}" ] || die "DMG path is required"
command -v hdiutil >/dev/null 2>&1 || die "hdiutil is required"
command -v codesign >/dev/null 2>&1 || die "codesign is required"
command -v spctl >/dev/null 2>&1 || die "spctl is required"
command -v xattr >/dev/null 2>&1 || die "xattr is required"

MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/perry-dmg-mount.XXXXXX")"
INSTALL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/perry-gatekeeper-install.XXXXXX")"
mounted=false

cleanup() {
  if [ "${mounted}" = true ]; then
    hdiutil detach "${MOUNT_POINT}" -quiet 2>/dev/null || true
  fi
  rm -rf "${MOUNT_POINT}" "${INSTALL_ROOT}"
}
trap cleanup EXIT INT TERM

hdiutil attach "${DMG_PATH}" -nobrowse -readonly -mountpoint "${MOUNT_POINT}" -quiet
mounted=true
[ -d "${MOUNT_POINT}/Perry.app" ] || die "mounted DMG does not contain Perry.app"
ditto "${MOUNT_POINT}/Perry.app" "${INSTALL_ROOT}/Perry.app"
QUARANTINE_TIMESTAMP="$(printf '%x' "$(date +%s)")"
xattr -w com.apple.quarantine "0081;${QUARANTINE_TIMESTAMP};Perry;$(uuidgen)" "${INSTALL_ROOT}/Perry.app"
codesign --verify --deep --strict --verbose=2 "${INSTALL_ROOT}/Perry.app"
spctl --assess --type execute --verbose=4 "${INSTALL_ROOT}/Perry.app"

echo "verified quarantined Perry.app from ${DMG_PATH} with Gatekeeper"
