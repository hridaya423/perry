#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${REPO_ROOT}/Perry.xcodeproj"
OUTPUT_DIR="${PERRY_RELEASE_OUTPUT_DIR:-${REPO_ROOT}/build/distribution}"
ARCHIVE_PATH="${OUTPUT_DIR}/Perry.xcarchive"
DERIVED_DATA="${OUTPUT_DIR}/DerivedData"
DMG_PATH="${OUTPUT_DIR}/Perry-${PERRY_RELEASE_VERSION:-1.0}.dmg"
APP_NOTARY_ZIP="${OUTPUT_DIR}/Perry-${PERRY_RELEASE_VERSION:-1.0}-notary.zip"
APPCAST_DIR="${PERRY_APPCAST_OUTPUT_DIR:-${OUTPUT_DIR}/appcast}"
ROLLOUT_STATE="${PERRY_ROLLOUT_STATE:-${OUTPUT_DIR}/rollout/rollout.json}"
XCODEGEN="${PERRY_XCODEGEN_BINARY:-${REPO_ROOT}/build/tools/xcodegen/bin/xcodegen}"

die() {
  echo "release packaging: $*" >&2
  exit 1
}

require_value() {
  eval "value=\${$1:-}"
  [ -n "${value}" ] || die "$1 is required"
}

[ "$(uname -s)" = "Darwin" ] || die "macOS is required"
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon is required"
[ -x "${XCODEGEN}" ] || die "pinned xcodegen is required at ${XCODEGEN}"
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild is required"
command -v codesign >/dev/null 2>&1 || die "codesign is required"
command -v xcrun >/dev/null 2>&1 || die "xcrun is required"
command -v hdiutil >/dev/null 2>&1 || die "hdiutil is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
require_value PERRY_DEVELOPER_ID_APPLICATION
require_value PERRY_DEVELOPMENT_TEAM
require_value PERRY_UPDATE_FEED_URL
require_value PERRY_SPARKLE_PUBLIC_KEY
require_value PERRY_NOTARY_KEYCHAIN_PROFILE
require_value PERRY_RELEASE_VERSION
require_value PERRY_RELEASE_BUILD
require_value PERRY_SPARKLE_PRIVATE_KEY_FILE
require_value PERRY_UPDATE_DOWNLOAD_PREFIX
require_value PERRY_PREVIOUS_RELEASE_VERSION
require_value PERRY_PREVIOUS_RELEASE_BUILD
require_value PERRY_PREVIOUS_RELEASE_DMG
require_value PERRY_PREVIOUS_RELEASE_APPCAST

"${SCRIPT_DIR}/verify-release-source.sh"

case "${PERRY_DEVELOPER_ID_APPLICATION}" in
  "Developer ID Application:"*) ;;
  *) die "PERRY_DEVELOPER_ID_APPLICATION must name a Developer ID Application identity" ;;
esac
security find-identity -v -p codesigning | grep -Fq "\"${PERRY_DEVELOPER_ID_APPLICATION}\"" \
  || die "PERRY_DEVELOPER_ID_APPLICATION is not installed in the signing Keychain"
case "${PERRY_UPDATE_FEED_URL}" in
  https://*) ;;
  *) die "PERRY_UPDATE_FEED_URL must use HTTPS" ;;
esac
case "${PERRY_RELEASE_VERSION}" in
  *[!0-9.]*|'') die "PERRY_RELEASE_VERSION must be numeric dotted version text" ;;
esac
case "${PERRY_RELEASE_BUILD}" in
  *[!0-9]*|'') die "PERRY_RELEASE_BUILD must be a positive integer" ;;
esac
[ "${PERRY_RELEASE_BUILD}" -gt 0 ] || die "PERRY_RELEASE_BUILD must be a positive integer"

printf '%s' "${PERRY_SPARKLE_PUBLIC_KEY}" | python3 -B "${SCRIPT_DIR}/validate_sparkle_public_key.py" \
  || die "PERRY_SPARKLE_PUBLIC_KEY must be a base64-encoded 32-byte EdDSA public key"
[ -f "${PERRY_SPARKLE_PRIVATE_KEY_FILE}" ] || die "PERRY_SPARKLE_PRIVATE_KEY_FILE does not exist"
[ -f "${PERRY_PREVIOUS_RELEASE_DMG}" ] || die "PERRY_PREVIOUS_RELEASE_DMG does not exist"
[ -f "${PERRY_PREVIOUS_RELEASE_APPCAST}" ] || die "PERRY_PREVIOUS_RELEASE_APPCAST does not exist"
case "${PERRY_PREVIOUS_RELEASE_VERSION}" in
  *[!0-9.]*|'') die "PERRY_PREVIOUS_RELEASE_VERSION must be numeric dotted version text" ;;
esac
case "${PERRY_PREVIOUS_RELEASE_BUILD}" in
  *[!0-9]*|'') die "PERRY_PREVIOUS_RELEASE_BUILD must be a positive integer" ;;
esac
[ "${PERRY_PREVIOUS_RELEASE_BUILD}" -gt 0 ] || die "PERRY_PREVIOUS_RELEASE_BUILD must be a positive integer"
[ "${PERRY_RELEASE_BUILD}" -gt "${PERRY_PREVIOUS_RELEASE_BUILD}" ] \
  || die "PERRY_RELEASE_BUILD must be newer than PERRY_PREVIOUS_RELEASE_BUILD"
case "${PERRY_UPDATE_DOWNLOAD_PREFIX}" in
  https://*) ;;
  *) die "PERRY_UPDATE_DOWNLOAD_PREFIX must use HTTPS" ;;
esac

"${SCRIPT_DIR}/fetch-codex-runtime.sh" --check-lock
"${SCRIPT_DIR}/fetch-codex-runtime.sh" --check
"${SCRIPT_DIR}/fetch-cua-driver.sh" --check-lock
"${SCRIPT_DIR}/fetch-cua-driver.sh" --check
"${SCRIPT_DIR}/fetch-xcodegen.sh" --check-lock
"${SCRIPT_DIR}/fetch-xcodegen.sh" --check
"${SCRIPT_DIR}/generate-release-metadata.sh" --check
"${SCRIPT_DIR}/verify-artifact-manifest.sh" --check
"${SCRIPT_DIR}/verify-sparkle-lock.sh"
"${XCODEGEN}" generate --spec "${REPO_ROOT}/project.yml" --project "${REPO_ROOT}"

sh "${SCRIPT_DIR}/prepare-release-output.sh" "${OUTPUT_DIR}"

xcodebuild archive \
  -project "${PROJECT}" \
  -scheme Perry \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "${ARCHIVE_PATH}" \
  -derivedDataPath "${DERIVED_DATA}" \
  DEVELOPMENT_TEAM="${PERRY_DEVELOPMENT_TEAM}" \
  CODE_SIGN_IDENTITY="${PERRY_DEVELOPER_ID_APPLICATION}" \
  CODE_SIGN_STYLE=Manual \
  PERRY_UPDATE_FEED_URL="${PERRY_UPDATE_FEED_URL}" \
  PERRY_SPARKLE_PUBLIC_KEY="${PERRY_SPARKLE_PUBLIC_KEY}" \
  MARKETING_VERSION="${PERRY_RELEASE_VERSION}" \
  CURRENT_PROJECT_VERSION="${PERRY_RELEASE_BUILD}"

APP="${ARCHIVE_PATH}/Products/Applications/Perry.app"
[ -d "${APP}" ] || die "archive did not contain Perry.app"
"${SCRIPT_DIR}/verify-bundle-contents.sh" "${APP}"

"${SCRIPT_DIR}/sign-distribution.sh" \
  "${APP}" \
  "${PERRY_DEVELOPER_ID_APPLICATION}" \
  "${REPO_ROOT}/App/Perry.entitlements"
"${SCRIPT_DIR}/verify-distribution-signatures.sh" "${APP}" "${PERRY_DEVELOPMENT_TEAM}"
ditto -c -k --keepParent "${APP}" "${APP_NOTARY_ZIP}"
xcrun notarytool submit "${APP_NOTARY_ZIP}" --keychain-profile "${PERRY_NOTARY_KEYCHAIN_PROFILE}" --wait
xcrun stapler staple "${APP}"
xcrun stapler validate "${APP}"
rm -f "${APP_NOTARY_ZIP}"

"${SCRIPT_DIR}/make-dmg.sh" "${APP}" "${DMG_PATH}"
codesign --force --timestamp --sign "${PERRY_DEVELOPER_ID_APPLICATION}" "${DMG_PATH}"
xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${PERRY_NOTARY_KEYCHAIN_PROFILE}" --wait
xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG_PATH}"
"${SCRIPT_DIR}/verify-gatekeeper-dmg.sh" "${DMG_PATH}"
"${SCRIPT_DIR}/verify-gatekeeper-dmg.sh" "${PERRY_PREVIOUS_RELEASE_DMG}"

GENERATE_APPCAST="${DERIVED_DATA}/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
[ -x "${GENERATE_APPCAST}" ] || die "Sparkle generate_appcast tool is missing"
SIGN_UPDATE="${DERIVED_DATA}/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "${SIGN_UPDATE}" ] || die "Sparkle sign_update tool is missing"
mkdir -p "${APPCAST_DIR}"
ditto "${DMG_PATH}" "${APPCAST_DIR}/$(basename "${DMG_PATH}")"
ditto "${REPO_ROOT}/App/Resources/CHANGELOG.md" "${APPCAST_DIR}/Perry-${PERRY_RELEASE_VERSION}.md"
set -- \
  --ed-key-file "${PERRY_SPARKLE_PRIVATE_KEY_FILE}" \
  --download-url-prefix "${PERRY_UPDATE_DOWNLOAD_PREFIX}" \
  --maximum-versions 3 \
  --maximum-deltas 5
if [ -n "${PERRY_SPARKLE_CHANNEL:-}" ]; then
  set -- "$@" --channel "${PERRY_SPARKLE_CHANNEL}"
fi
if [ -n "${PERRY_PHASED_ROLLOUT_INTERVAL:-}" ]; then
  set -- "$@" --phased-rollout-interval "${PERRY_PHASED_ROLLOUT_INTERVAL}"
fi
"${GENERATE_APPCAST}" "$@" "${APPCAST_DIR}"
[ -f "${APPCAST_DIR}/appcast.xml" ] || die "Sparkle did not generate appcast.xml"
python3 -B "${SCRIPT_DIR}/verify_sparkle_release.py" \
  --appcast "${APPCAST_DIR}/appcast.xml" \
  --dmg "${DMG_PATH}" \
  --version "${PERRY_RELEASE_VERSION}" \
  --build "${PERRY_RELEASE_BUILD}" \
  --sign-update "${SIGN_UPDATE}" \
  --key-file "${PERRY_SPARKLE_PRIVATE_KEY_FILE}"
python3 -B "${SCRIPT_DIR}/verify_sparkle_release.py" \
  --appcast "${PERRY_PREVIOUS_RELEASE_APPCAST}" \
  --dmg "${PERRY_PREVIOUS_RELEASE_DMG}" \
  --version "${PERRY_PREVIOUS_RELEASE_VERSION}" \
  --build "${PERRY_PREVIOUS_RELEASE_BUILD}" \
  --sign-update "${SIGN_UPDATE}" \
  --key-file "${PERRY_SPARKLE_PRIVATE_KEY_FILE}"
"${SCRIPT_DIR}/manage-update-rollout.py" initialize \
  --state "${ROLLOUT_STATE}" \
  --version "${PERRY_RELEASE_VERSION}" \
  --build "${PERRY_RELEASE_BUILD}" \
  --dmg "${DMG_PATH}" \
  --appcast "${APPCAST_DIR}/appcast.xml" \
  --previous-version "${PERRY_PREVIOUS_RELEASE_VERSION}" \
  --previous-build "${PERRY_PREVIOUS_RELEASE_BUILD}" \
  --previous-dmg "${PERRY_PREVIOUS_RELEASE_DMG}" \
  --previous-appcast "${PERRY_PREVIOUS_RELEASE_APPCAST}"
"${SCRIPT_DIR}/manage-update-rollout.py" verify --state "${ROLLOUT_STATE}"

echo "packaged signed and notarized Perry DMG at ${DMG_PATH} with rollout state ${ROLLOUT_STATE}"
