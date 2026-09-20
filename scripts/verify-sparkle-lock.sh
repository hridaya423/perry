#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
LOCK_FILE="${PERRY_SPARKLE_LOCK:-${SCRIPT_DIR}/sparkle.lock}"

die() {
  echo "Sparkle lock verification: $*" >&2
  exit 1
}

[ -f "${LOCK_FILE}" ] || die "missing lock file"
REVISION="$(awk -F= '$1 == "SPARKLE_REVISION" { print $2; exit }' "${LOCK_FILE}")"
CHECKSUM="$(awk -F= '$1 == "SPARKLE_ARTIFACT_SHA256" { print $2; exit }' "${LOCK_FILE}")"
[ "${#REVISION}" = 40 ] || die "invalid source revision"
[ "${#CHECKSUM}" = 64 ] || die "invalid artifact checksum"
grep -Fq "revision: ${REVISION}" "${REPO_ROOT}/project.yml" || die "project.yml does not pin the locked revision"

if [ "$#" -eq 2 ] && [ "$1" = "--package-manifest" ]; then
  MANIFEST="$2"
  [ -f "${MANIFEST}" ] || die "missing resolved Package.swift"
  grep -Fq "let checksum = \"${CHECKSUM}\"" "${MANIFEST}" || die "Sparkle artifact checksum does not match the locked revision"
fi

echo "verified Sparkle source and artifact lock"
