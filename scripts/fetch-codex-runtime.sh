#!/bin/sh
set -eu

VERSION="0.132.0"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
DEST="${SCRIPT_DIR}/../App/Resources/CodexRuntime"

case "$(uname -m)" in
  arm64) TRIPLE="aarch64-apple-darwin" ;;
  x86_64) TRIPLE="x86_64-apple-darwin" ;;
  *) echo "unsupported macOS architecture: $(uname -m)" >&2; exit 1 ;;
esac

if [ -x "${DEST}/bin/codex" ] && [ "$(cat "${DEST}/.version" 2>/dev/null || true)" = "${VERSION}" ]; then
  echo "codex ${VERSION} already vendored"
  exit 0
fi

URL="https://github.com/openai/codex/releases/download/rust-v${VERSION}/codex-${TRIPLE}.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

curl -fsSL "${URL}" -o "${TMP}/codex.tar.gz"
mkdir -p "${TMP}/extracted"
tar -xzf "${TMP}/codex.tar.gz" -C "${TMP}/extracted"

BIN="${TMP}/extracted/codex-${TRIPLE}"
if [ ! -f "${BIN}" ]; then
  BIN="$(find "${TMP}/extracted" -type f -name codex | head -n 1)"
fi
if [ -z "${BIN}" ] || [ ! -f "${BIN}" ]; then
  echo "could not locate codex binary inside release archive" >&2
  exit 1
fi

mkdir -p "${DEST}/bin"
cp "${BIN}" "${DEST}/bin/codex"
chmod +x "${DEST}/bin/codex"
printf '%s\n' "${VERSION}" > "${DEST}/.version"
echo "vendored codex ${VERSION} (${TRIPLE}) -> ${DEST}/bin/codex"
