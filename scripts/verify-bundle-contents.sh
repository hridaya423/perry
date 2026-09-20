#!/bin/sh
set -eu

APP_PATH="${1:-}"

die() {
  echo "bundle content verification: $*" >&2
  exit 1
}

require_size_at_most() {
  limit="$1"
  path="$2"
  [ -f "${path}" ] || die "missing executable: ${path}"
  size="$(stat -f '%z' "${path}")"
  [ "${size}" -le "${limit}" ] || die "executable exceeds size budget: ${path} (${size} bytes)"
}

require_arm64_only() {
  path="$1"
  [ -f "${path}" ] || die "missing executable: ${path}"
  [ "$(lipo -archs "${path}")" = "arm64" ] || die "executable is not arm64-only: ${path}"
}

[ "$(uname -s)" = "Darwin" ] || die "macOS is required"
[ -d "${APP_PATH}" ] || die "Perry.app path is required"
command -v lipo >/dev/null 2>&1 || die "lipo is required"

RESOURCES="${APP_PATH}/Contents/Resources"
MAIN_EXECUTABLE="${APP_PATH}/Contents/MacOS/Perry"
CODEX_EXECUTABLE="${RESOURCES}/CodexRuntime/bin/codex"
CUA_EXECUTABLE="${RESOURCES}/CuaDriver/bin/cua-driver"

for cue in wake send receive done fail
do
  [ -f "${RESOURCES}/Sounds/${cue}.caf" ] || die "missing sound cue: ${cue}.caf"
  [ ! -e "${RESOURCES}/${cue}.caf" ] || die "duplicate root sound cue: ${cue}.caf"
done

sound_count="$(find "${RESOURCES}" -type f -name '*.caf' | wc -l | tr -d ' ')"
[ "${sound_count}" = "5" ] || die "expected 5 sound files, found ${sound_count}"

app_kib="$(du -sk "${APP_PATH}" | awk '{print $1}')"
[ "${app_kib}" -le 307200 ] || die "app bundle exceeds 300 MiB: ${app_kib} KiB"

require_size_at_most 16777216 "${MAIN_EXECUTABLE}"
require_size_at_most 230686720 "${CODEX_EXECUTABLE}"
require_size_at_most 83886080 "${CUA_EXECUTABLE}"
require_arm64_only "${MAIN_EXECUTABLE}"
require_arm64_only "${CODEX_EXECUTABLE}"
require_arm64_only "${CUA_EXECUTABLE}"

echo "verified Perry bundle contents and size budgets"
