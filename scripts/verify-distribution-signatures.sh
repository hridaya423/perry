#!/bin/sh
set -eu

APP_PATH="${1:-}"
EXPECTED_TEAM="${2:-}"

die() {
  echo "distribution signature verification: $*" >&2
  exit 1
}

[ -d "${APP_PATH}" ] || die "Perry.app path is required"
[ -n "${EXPECTED_TEAM}" ] || die "expected signing team is required"
command -v codesign >/dev/null 2>&1 || die "codesign is required"

codesign --verify --deep --strict --verbose=2 "${APP_PATH}" >/dev/null 2>&1 \
  || die "Perry.app failed strict nested signature verification"

for code in \
  "${APP_PATH}" \
  "${APP_PATH}/Contents/MacOS/Perry" \
  "${APP_PATH}/Contents/Resources/CodexRuntime/bin/codex" \
  "${APP_PATH}/Contents/Resources/CuaDriver/bin/cua-driver" \
  "${APP_PATH}/Contents/Resources/AgentDesktop/bin/agent-desktop" \
  "${APP_PATH}/Contents/Resources/AgentDesktop/bin/agent-desktop-macos-helper" \
  "${APP_PATH}/Contents/Resources/LocalEngine/llama-server" \
  "${APP_PATH}/Contents/Frameworks/Sparkle.framework" \
  "${APP_PATH}/Contents/Frameworks/Sparkle.framework/Versions/Current/Sparkle" \
  "${APP_PATH}/Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate" \
  "${APP_PATH}/Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app" \
  "${APP_PATH}/Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app/Contents/MacOS/Updater" \
  "${APP_PATH}/Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Downloader.xpc" \
  "${APP_PATH}/Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
  "${APP_PATH}/Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Installer.xpc" \
  "${APP_PATH}/Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices/Installer.xpc/Contents/MacOS/Installer"
do
  [ -e "${code}" ] || die "missing signed code object: ${code}"
  details="$(codesign -dv --verbose=4 "${code}" 2>&1)" \
    || die "could not inspect signature: ${code}"
  team="$(printf '%s\n' "${details}" | awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
  [ "${team}" = "${EXPECTED_TEAM}" ] \
    || die "unexpected signing team for ${code}: ${team:-none}"
  printf '%s\n' "${details}" | grep -Eq '^CodeDirectory .* flags=0x[[:xdigit:]]+\(([^,()]+,)*runtime(,[^,()]+)*\)([[:space:]]|$)' \
    || die "hardened runtime is missing from ${code}"
done

echo "verified Perry distribution signatures for team ${EXPECTED_TEAM}"
