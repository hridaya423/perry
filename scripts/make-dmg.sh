#!/bin/sh
set -eu

APP="${1:-}"
DMG_PATH="${2:-}"
VOLUME_NAME="Perry"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"

die() {
  echo "make-dmg: $*" >&2
  exit 1
}

[ -d "${APP}" ] || die "usage: make-dmg.sh <Perry.app> <output.dmg>"
[ -n "${DMG_PATH}" ] || die "usage: make-dmg.sh <Perry.app> <output.dmg>"
[ ! -e "/Volumes/${VOLUME_NAME}" ] || die "/Volumes/${VOLUME_NAME} is already mounted; eject it first"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/perry-dmg.XXXXXX")"
DEVICE=""
cleanup() {
  if [ -n "${DEVICE}" ]; then
    hdiutil detach "${DEVICE}" -quiet -force 2>/dev/null || true
  fi
  rm -rf "${WORK}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

swiftc -parse-as-library -O -o "${WORK}/render-background" \
  "${REPO_ROOT}"/Packages/PerryOverlay/Sources/PerryOverlay/*.swift \
  "${SCRIPT_DIR}/dmg/background.swift"
"${WORK}/render-background" "${WORK}/art"
tiffutil -cathidpicheck "${WORK}/art/background.png" "${WORK}/art/background@2x.png" -out "${WORK}/background.tiff" >/dev/null

STAGE="${WORK}/stage"
mkdir -p "${STAGE}/.background"
ditto "${APP}" "${STAGE}/Perry.app"
ln -s /Applications "${STAGE}/Applications"
cp "${WORK}/background.tiff" "${STAGE}/.background/background.tiff"

APP_KB="$(du -sk "${STAGE}" | cut -f1)"
hdiutil create -quiet -srcfolder "${STAGE}" -volname "${VOLUME_NAME}" -fs HFS+ -format UDRW -size "$((APP_KB / 1024 + 32))m" "${WORK}/rw.dmg"
DEVICE="$(hdiutil attach "${WORK}/rw.dmg" -readwrite -noverify -noautoopen | awk '/Apple_HFS/ { print $1 }')"
MOUNT="/Volumes/${VOLUME_NAME}"
[ -d "${MOUNT}" ] || die "volume did not mount at ${MOUNT}"

osascript <<OSA
tell application "Finder"
  tell disk "${VOLUME_NAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 548}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 12
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "Perry.app" of container window to {170, 190}
    set position of item "Applications" of container window to {470, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

if [ -f "${APP}/Contents/Resources/AppIcon.icns" ]; then
  cp "${APP}/Contents/Resources/AppIcon.icns" "${MOUNT}/.VolumeIcon.icns"
  xcrun SetFile -a C "${MOUNT}"
fi
chmod -Rf go-w "${MOUNT}" 2>/dev/null || true
sync
for _ in 1 2 3 4 5; do
  [ -f "${MOUNT}/.DS_Store" ] && break
  sleep 1
done
attempt=1
until hdiutil detach "${DEVICE}" -quiet 2>/dev/null; do
  [ "${attempt}" -lt 5 ] || { hdiutil detach "${DEVICE}" -quiet -force; break; }
  attempt=$((attempt + 1))
  sleep 1
done
DEVICE=""
rm -f "${DMG_PATH}"
hdiutil convert "${WORK}/rw.dmg" -quiet -format UDZO -imagekey zlib-level=9 -o "${DMG_PATH}"
echo "made ${DMG_PATH}"
