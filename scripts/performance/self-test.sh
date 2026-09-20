#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PYTHON_BIN="$(command -v python3 || true)"

[ -n "${PYTHON_BIN}" ] || {
  echo "performance evaluator self-test: python3 is required" >&2
  exit 1
}

"${PYTHON_BIN}" "${SCRIPT_DIR}/test_evaluator.py"
"${PYTHON_BIN}" "${SCRIPT_DIR}/test_assemble.py"
"${PYTHON_BIN}" "${SCRIPT_DIR}/test_sample_process.py"
"${PYTHON_BIN}" "${SCRIPT_DIR}/test_acoustic_barge_in.py"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/perry-performance-self-test.XXXXXX")"
trap 'rmdir "${TEMP_DIR}"' EXIT

if "${SCRIPT_DIR}/evaluate.py" \
  --baseline "${TEMP_DIR}/missing-baseline.json" \
  --candidate "${TEMP_DIR}/missing-candidate.json" >/dev/null 2>&1; then
  echo "performance evaluator self-test: missing real measurements unexpectedly passed" >&2
  exit 1
fi

echo "performance evidence self-tests passed"
