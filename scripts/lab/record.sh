#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAME="${1:?usage: record.sh <name> [seconds]}"
SECONDS_TO_RECORD="${2:-30}"
OUT_DIR="$REPO_ROOT/docs/evidence/recordings"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$NAME.mov"

screencapture -v -V "$SECONDS_TO_RECORD" "$OUT"
echo "$OUT"
