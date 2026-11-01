#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${REPO_ROOT}/Perry.xcodeproj"
DERIVED_DATA="${PERRY_DERIVED_DATA_PATH:-${REPO_ROOT}/build/release}"
LOCK_FILE="${PERRY_CODEX_RUNTIME_LOCK:-${SCRIPT_DIR}/codex-runtime.lock}"
CUA_LOCK_FILE="${PERRY_CUA_DRIVER_LOCK:-${SCRIPT_DIR}/cua-driver.lock}"
AGENT_DESKTOP_LOCK_FILE="${PERRY_AGENT_DESKTOP_LOCK:-${SCRIPT_DIR}/agent-desktop.lock}"
XCODEGEN="${PERRY_XCODEGEN_BINARY:-${REPO_ROOT}/build/tools/xcodegen/bin/xcodegen}"

die() {
  echo "release verification: $*" >&2
  exit 1
}

"${SCRIPT_DIR}/validate-release-evidence.sh"
[ "$(uname -s)" = "Darwin" ] || die "macOS is required"
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon is required; found $(uname -m)"
[ -x "${XCODEGEN}" ] || die "pinned xcodegen is required at ${XCODEGEN}"
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild is required"
command -v lipo >/dev/null 2>&1 || die "lipo is required"

"${SCRIPT_DIR}/fetch-codex-runtime.sh" --check-lock
"${SCRIPT_DIR}/fetch-codex-runtime.sh" --check
"${SCRIPT_DIR}/fetch-agent-desktop.sh" --check-lock
"${SCRIPT_DIR}/fetch-agent-desktop.sh" --check
"${SCRIPT_DIR}/fetch-cua-driver.sh" --check-lock
"${SCRIPT_DIR}/fetch-cua-driver.sh" --check
"${SCRIPT_DIR}/fetch-xcodegen.sh" --check-lock
"${SCRIPT_DIR}/fetch-xcodegen.sh" --check
"${SCRIPT_DIR}/generate-release-metadata.sh" --check
"${SCRIPT_DIR}/verify-artifact-manifest.sh" --check
"${SCRIPT_DIR}/verify-sparkle-lock.sh"
"${XCODEGEN}" generate --spec "${REPO_ROOT}/project.yml" --project "${REPO_ROOT}"

BUILD_SETTINGS="$(xcodebuild \
  -project "${PROJECT}" \
  -scheme Perry \
  -configuration Release \
  -arch arm64 \
  -showBuildSettings \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  DEPLOYMENT_POSTPROCESSING=YES \
  STRIP_INSTALLED_PRODUCT=YES 2>&1)"

printf '%s\n' "${BUILD_SETTINGS}" | grep -Eq '^[[:space:]]+CONFIGURATION = Release$' || die "Release configuration was not selected"
printf '%s\n' "${BUILD_SETTINGS}" | grep -Eq '^[[:space:]]+ARCHS = arm64$' || die "Release build is not arm64-only"
printf '%s\n' "${BUILD_SETTINGS}" | grep -Eq '^[[:space:]]+ONLY_ACTIVE_ARCH = NO$' || die "Release build must compile its configured architecture"
printf '%s\n' "${BUILD_SETTINGS}" | grep -Eq '^[[:space:]]+CODE_SIGNING_ALLOWED = NO$' || die "Release verification must not require signing"
printf '%s\n' "${BUILD_SETTINGS}" | grep -Eq '^[[:space:]]+DEPLOYMENT_POSTPROCESSING = YES$' || die "Release verification must post-process the distributable"
printf '%s\n' "${BUILD_SETTINGS}" | grep -Eq '^[[:space:]]+STRIP_INSTALLED_PRODUCT = YES$' || die "Release verification must measure a stripped distributable"

xcodebuild \
  -project "${PROJECT}" \
  -scheme Perry \
  -configuration Release \
  -arch arm64 \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  DEPLOYMENT_POSTPROCESSING=YES \
  STRIP_INSTALLED_PRODUCT=YES \
  build

APP="${DERIVED_DATA}/Build/Products/Release/Perry.app"
EXECUTABLE="${APP}/Contents/MacOS/Perry"
RUNTIME="${APP}/Contents/Resources/CodexRuntime/bin/codex"
RUNTIME_VERSION_FILE="${APP}/Contents/Resources/CodexRuntime/.version"
CUA_DRIVER="${APP}/Contents/Resources/CuaDriver/bin/cua-driver"
CUA_VERSION_FILE="${APP}/Contents/Resources/CuaDriver/.version"
AGENT_DESKTOP="${APP}/Contents/Resources/AgentDesktop/bin/agent-desktop"
AGENT_DESKTOP_HELPER="${APP}/Contents/Resources/AgentDesktop/bin/agent-desktop-macos-helper"
AGENT_DESKTOP_VERSION_FILE="${APP}/Contents/Resources/AgentDesktop/.version"
SPARKLE_FRAMEWORK="${APP}/Contents/Frameworks/Sparkle.framework"
PRIVACY_MANIFEST="${APP}/Contents/Resources/PrivacyInfo.xcprivacy"

[ -x "${EXECUTABLE}" ] || die "missing Release app executable: ${EXECUTABLE}"
[ "$(lipo -archs "${EXECUTABLE}")" = "arm64" ] || die "Release app executable is not arm64-only"
[ -x "${RUNTIME}" ] || die "missing bundled Codex runtime: ${RUNTIME}"
[ -f "${RUNTIME_VERSION_FILE}" ] || die "missing bundled Codex runtime version: ${RUNTIME_VERSION_FILE}"

EXPECTED_VERSION="$(awk -F= '$1 == "CODEX_RUNTIME_VERSION" { print substr($0, index($0, "=") + 1); exit }' "${LOCK_FILE}")"
EXPECTED_BINARY_SHA256="$(awk -F= '$1 == "CODEX_RUNTIME_BINARY_SHA256" { print substr($0, index($0, "=") + 1); exit }' "${LOCK_FILE}")"
[ "$(cat "${RUNTIME_VERSION_FILE}")" = "${EXPECTED_VERSION}" ] || die "bundled Codex runtime version mismatch"
ACTUAL_BINARY_SHA256="$(shasum -a 256 "${RUNTIME}" | awk '{print $1}')"
[ "${ACTUAL_BINARY_SHA256}" = "${EXPECTED_BINARY_SHA256}" ] || die "bundled Codex runtime checksum mismatch"

EXPECTED_CUA_VERSION="$(awk -F= '$1 == "CUA_DRIVER_VERSION" { print substr($0, index($0, "=") + 1); exit }' "${CUA_LOCK_FILE}")"
EXPECTED_CUA_SHA256="$(awk -F= '$1 == "CUA_DRIVER_DISTRIBUTION_BINARY_SHA256" { print substr($0, index($0, "=") + 1); exit }' "${CUA_LOCK_FILE}")"
[ -x "${CUA_DRIVER}" ] || die "missing bundled Cua driver: ${CUA_DRIVER}"
[ -f "${CUA_VERSION_FILE}" ] || die "missing bundled Cua driver version: ${CUA_VERSION_FILE}"
[ "$(cat "${CUA_VERSION_FILE}")" = "${EXPECTED_CUA_VERSION}" ] || die "bundled Cua driver version mismatch"
[ "$(shasum -a 256 "${CUA_DRIVER}" | awk '{print $1}')" = "${EXPECTED_CUA_SHA256}" ] || die "bundled Cua driver checksum mismatch"
codesign --verify --strict --verbose=2 "${CUA_DRIVER}" >/dev/null 2>&1 || die "bundled Cua driver signature is invalid"
EXPECTED_AGENT_DESKTOP_VERSION="$(awk -F= '$1 == "AGENT_DESKTOP_VERSION" { print substr($0, index($0, "=") + 1); exit }' "${AGENT_DESKTOP_LOCK_FILE}")"
EXPECTED_AGENT_DESKTOP_SHA256="$(awk -F= '$1 == "AGENT_DESKTOP_BINARY_SHA256" { print substr($0, index($0, "=") + 1); exit }' "${AGENT_DESKTOP_LOCK_FILE}")"
EXPECTED_AGENT_DESKTOP_HELPER_SHA256="$(awk -F= '$1 == "AGENT_DESKTOP_HELPER_SHA256" { print substr($0, index($0, "=") + 1); exit }' "${AGENT_DESKTOP_LOCK_FILE}")"
[ -x "${AGENT_DESKTOP}" ] || die "missing bundled agent-desktop: ${AGENT_DESKTOP}"
[ -x "${AGENT_DESKTOP_HELPER}" ] || die "missing bundled agent-desktop helper: ${AGENT_DESKTOP_HELPER}"
[ -f "${AGENT_DESKTOP_VERSION_FILE}" ] || die "missing bundled agent-desktop version: ${AGENT_DESKTOP_VERSION_FILE}"
[ "$(cat "${AGENT_DESKTOP_VERSION_FILE}")" = "${EXPECTED_AGENT_DESKTOP_VERSION}" ] || die "bundled agent-desktop version mismatch"
[ "$(shasum -a 256 "${AGENT_DESKTOP}" | awk '{print $1}')" = "${EXPECTED_AGENT_DESKTOP_SHA256}" ] || die "bundled agent-desktop checksum mismatch"
[ "$(shasum -a 256 "${AGENT_DESKTOP_HELPER}" | awk '{print $1}')" = "${EXPECTED_AGENT_DESKTOP_HELPER_SHA256}" ] || die "bundled agent-desktop helper checksum mismatch"
codesign --verify --strict --verbose=2 "${AGENT_DESKTOP}" >/dev/null 2>&1 || die "bundled agent-desktop signature is invalid"
codesign --verify --strict --verbose=2 "${AGENT_DESKTOP_HELPER}" >/dev/null 2>&1 || die "bundled agent-desktop helper signature is invalid"
[ -d "${SPARKLE_FRAMEWORK}" ] || die "missing embedded Sparkle framework"
[ -f "${PRIVACY_MANIFEST}" ] || die "missing privacy manifest"
plutil -lint "${PRIVACY_MANIFEST}" >/dev/null || die "privacy manifest is invalid"
collected_count="$(plutil -extract NSPrivacyCollectedDataTypes raw "${PRIVACY_MANIFEST}" 2>/dev/null || echo -1)"
[ "${collected_count}" = "0" ] || die "privacy manifest must declare zero collected data types"
[ "$(plutil -extract NSPrivacyTracking raw "${PRIVACY_MANIFEST}")" = "false" ] \
  || die "privacy manifest must declare tracking disabled"
"${SCRIPT_DIR}/verify-sparkle-lock.sh" --package-manifest "${DERIVED_DATA}/SourcePackages/checkouts/Sparkle/Package.swift"
"${SCRIPT_DIR}/verify-bundle-contents.sh" "${APP}"

echo "verified unsigned arm64 Perry Release at ${APP}"
