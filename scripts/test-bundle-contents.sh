#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VERIFIER="${SCRIPT_DIR}/verify-bundle-contents.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/perry-bundle-contents.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

command -v xcrun >/dev/null 2>&1
command -v lipo >/dev/null 2>&1

APP="${TMP}/Perry.app"
RESOURCES="${APP}/Contents/Resources"
mkdir -p "${APP}/Contents/MacOS" "${RESOURCES}/CodexRuntime/bin" "${RESOURCES}/CuaDriver/bin" "${RESOURCES}/AgentDesktop/bin" "${RESOURCES}/LocalEngine" "${RESOURCES}/Sounds"
printf '%s\n' 'int main(void) { return 0; }' > "${TMP}/main.c"
xcrun --sdk macosx clang -arch arm64 "${TMP}/main.c" -o "${TMP}/arm64"
xcrun --sdk macosx clang -arch x86_64 "${TMP}/main.c" -o "${TMP}/x86_64"
cp "${TMP}/arm64" "${APP}/Contents/MacOS/Perry"
cp "${TMP}/arm64" "${RESOURCES}/CodexRuntime/bin/codex"
cp "${TMP}/arm64" "${RESOURCES}/CuaDriver/bin/cua-driver"
cp "${TMP}/arm64" "${RESOURCES}/AgentDesktop/bin/agent-desktop"
cp "${TMP}/arm64" "${RESOURCES}/AgentDesktop/bin/agent-desktop-macos-helper"
cp "${TMP}/arm64" "${APP}/Contents/MacOS/perry-mcp"
cp "${TMP}/arm64" "${RESOURCES}/LocalEngine/llama-server"
for cue in wake send receive done fail
do
  : > "${RESOURCES}/Sounds/${cue}.caf"
done

"${VERIFIER}" "${APP}" >/dev/null

lipo -create "${TMP}/arm64" "${TMP}/x86_64" -output "${RESOURCES}/CuaDriver/bin/cua-driver"
if output="$("${VERIFIER}" "${APP}" 2>&1)"; then
  echo "bundle content self-test: accepted a universal Cua driver" >&2
  exit 1
fi
printf '%s\n' "${output}" | grep -Fq "executable is not arm64-only"
cp "${TMP}/arm64" "${RESOURCES}/CuaDriver/bin/cua-driver"

lipo -create "${TMP}/arm64" "${TMP}/x86_64" -output "${RESOURCES}/AgentDesktop/bin/agent-desktop-macos-helper"
if output="$("${VERIFIER}" "${APP}" 2>&1)"; then
  echo "bundle content self-test: accepted a universal agent-desktop helper" >&2
  exit 1
fi
printf '%s\n' "${output}" | grep -Fq "executable is not arm64-only"

echo "bundle content self-tests passed"
