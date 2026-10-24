#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
APP_PATH="${1:-}"
SIGNING_IDENTITY="${2:-}"
APP_ENTITLEMENTS="${3:-${REPO_ROOT}/App/Perry.entitlements}"

die() {
  echo "distribution signing: $*" >&2
  exit 1
}

resolve_existing_path() {
  path="$1"
  symlink_count=0
  while [ -L "${path}" ]; do
    [ "${symlink_count}" -lt 40 ] || return 1
    link_target="$(readlink "${path}")" || return 1
    case "${link_target}" in
      /*) path="${link_target}" ;;
      *) path="$(dirname -- "${path}")/${link_target}" ;;
    esac
    symlink_count=$((symlink_count + 1))
  done
  resolved_directory="$(CDPATH= cd -- "$(dirname -- "${path}")" && pwd -P)" || return 1
  printf '%s/%s\n' "${resolved_directory}" "$(basename -- "${path}")"
}

[ -d "${APP_PATH}" ] || die "Perry.app path is required"
[ -n "${SIGNING_IDENTITY}" ] || die "signing identity is required"
[ -f "${APP_ENTITLEMENTS}" ] || die "app entitlements are required"
command -v codesign >/dev/null 2>&1 || die "codesign is required"
APP_BUNDLE_PATH="$(CDPATH= cd -- "${APP_PATH}" && pwd -P)" || die "Perry.app path is required"

MAIN_EXECUTABLE="${APP_PATH}/Contents/MacOS/Perry"
CODEX_EXECUTABLE="${APP_PATH}/Contents/Resources/CodexRuntime/bin/codex"
CUA_EXECUTABLE="${APP_PATH}/Contents/Resources/CuaDriver/bin/cua-driver"
MCP_EXECUTABLE="${APP_PATH}/Contents/MacOS/perry-mcp"
CUA_CAPABILITIES="${APP_BUNDLE_PATH}/Contents/Resources/CuaDriver/capabilities.yaml"
SPARKLE_FRAMEWORK="${APP_PATH}/Contents/Frameworks/Sparkle.framework"
SPARKLE_EXECUTABLE="${SPARKLE_FRAMEWORK}/Versions/Current/Sparkle"
AUTOUPDATE="${SPARKLE_FRAMEWORK}/Versions/Current/Autoupdate"
UPDATER_APP="${SPARKLE_FRAMEWORK}/Versions/Current/Updater.app"
UPDATER_EXECUTABLE="${UPDATER_APP}/Contents/MacOS/Updater"
DOWNLOADER_XPC="${SPARKLE_FRAMEWORK}/Versions/Current/XPCServices/Downloader.xpc"
DOWNLOADER_EXECUTABLE="${DOWNLOADER_XPC}/Contents/MacOS/Downloader"
INSTALLER_XPC="${SPARKLE_FRAMEWORK}/Versions/Current/XPCServices/Installer.xpc"
INSTALLER_EXECUTABLE="${INSTALLER_XPC}/Contents/MacOS/Installer"

[ -e "${CUA_CAPABILITIES}" ] || die "missing Cua capabilities.yaml: ${CUA_CAPABILITIES}"
CUA_CAPABILITIES_RESOLVED="$(resolve_existing_path "${CUA_CAPABILITIES}")" \
  || die "could not resolve Cua capabilities.yaml: ${CUA_CAPABILITIES}"
[ -f "${CUA_CAPABILITIES_RESOLVED}" ] \
  || die "Cua capabilities.yaml is not a regular file: ${CUA_CAPABILITIES}"
case "${CUA_CAPABILITIES_RESOLVED}" in
  "${APP_BUNDLE_PATH}"/*) ;;
  *) die "Cua capabilities.yaml resolves outside the app bundle: ${CUA_CAPABILITIES_RESOLVED}" ;;
esac

for target in \
  "${APP_PATH}" \
  "${MAIN_EXECUTABLE}" \
  "${CODEX_EXECUTABLE}" \
  "${CUA_EXECUTABLE}" \
  "${MCP_EXECUTABLE}" \
  "${SPARKLE_FRAMEWORK}" \
  "${SPARKLE_EXECUTABLE}" \
  "${AUTOUPDATE}" \
  "${UPDATER_APP}" \
  "${UPDATER_EXECUTABLE}" \
  "${DOWNLOADER_XPC}" \
  "${DOWNLOADER_EXECUTABLE}" \
  "${INSTALLER_XPC}" \
  "${INSTALLER_EXECUTABLE}"
do
  [ -e "${target}" ] || die "missing nested code object: ${target}"
done

sign_code() {
  target="$1"
  shift
  codesign --force --timestamp --options runtime "$@" --sign "${SIGNING_IDENTITY}" "${target}"
}

sign_code "${CODEX_EXECUTABLE}"
sign_code "${CUA_EXECUTABLE}"
sign_code "${MCP_EXECUTABLE}"
sign_code "${INSTALLER_XPC}"
sign_code "${DOWNLOADER_XPC}" --preserve-metadata=entitlements
sign_code "${AUTOUPDATE}"
sign_code "${UPDATER_APP}"
sign_code "${SPARKLE_FRAMEWORK}"
sign_code "${APP_PATH}" --entitlements "${APP_ENTITLEMENTS}"
