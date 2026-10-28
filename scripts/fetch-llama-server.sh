#!/bin/sh
set -eu

if [ -n "${SRCROOT:-}" ]; then
  REPO_ROOT="$(CDPATH= cd -- "${SRCROOT}" && pwd)"
else
  REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fi
LOCK_FILE="${REPO_ROOT}/scripts/llama-server.lock"
DEST="${PERRY_LLAMA_DEST:-${REPO_ROOT}/App/Resources/LocalEngine}"
FILES="llama-server libllama-server-impl.dylib libllama-common.0.dylib libmtmd.0.dylib libllama.0.dylib libggml.0.dylib libggml-base.0.dylib libggml-cpu.0.dylib libggml-blas.0.dylib libggml-metal.0.dylib libggml-rpc.0.dylib LICENSE"

die() {
  echo "llama-server: $*" >&2
  exit 1
}

[ -f "${LOCK_FILE}" ] || die "missing lock file: ${LOCK_FILE}"
. "${LOCK_FILE}"
case "${LLAMA_VERSION:-}" in
  b[0-9]*) ;;
  *) die "LLAMA_VERSION must be a pinned build tag" ;;
esac
[ "${LLAMA_ASSET_URL:-}" = "https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_VERSION}/llama-${LLAMA_VERSION}-bin-macos-arm64.tar.gz" ] \
  || die "LLAMA_ASSET_URL is not the pinned upstream release"
printf '%s\n' "${LLAMA_ARCHIVE_SHA256:-}" | awk 'length($0) == 64 && $0 !~ /[^0-9a-f]/ { ok = 1 } END { exit !ok }' \
  || die "invalid archive SHA-256 in ${LOCK_FILE}"

installed() {
  [ "$(cat "${DEST}/.version" 2>/dev/null)" = "${LLAMA_VERSION}" ] || return 1
  for file in ${FILES}; do [ -f "${DEST}/${file}" ] || return 1; done
}

if installed; then
  echo "llama-server ${LLAMA_VERSION} present"
  exit 0
fi
[ "${1:-}" = "--check" ] && die "missing or stale; run scripts/fetch-llama-server.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/perry-llama.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 --max-time 300 \
  "${LLAMA_ASSET_URL}" -o "${TMP}/llama.tar.gz"
[ "$(shasum -a 256 "${TMP}/llama.tar.gz" | awk '{print $1}')" = "${LLAMA_ARCHIVE_SHA256}" ] || die "archive SHA-256 mismatch"
tar -xzf "${TMP}/llama.tar.gz" -C "${TMP}"
rm -rf "${DEST}"
mkdir -p "${DEST}"
for file in ${FILES}; do
  cp -L "${TMP}/llama-${LLAMA_VERSION}/${file}" "${DEST}/${file}"
done
chmod 755 "${DEST}/llama-server"
printf '%s\n' "${LLAMA_VERSION}" > "${DEST}/.version"
echo "vendored llama-server ${LLAMA_VERSION} -> ${DEST}"
