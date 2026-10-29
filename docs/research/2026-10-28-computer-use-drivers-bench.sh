#!/bin/sh
set -eu

: "${CUA_038:?CuaDriver.app/Contents/MacOS/cua-driver from the 0.38.0 tarball}"
: "${CUA_NIGHTLY:?CuaDriver.app/Contents/MacOS/cua-driver from the 20261028 nightly tarball}"
: "${FIXTURE_DIR:?folder Finder shows in one list-view window with 800+ visible-or-scrolled nodes}"
: "${FIXTURE_FILE:?name of one file in FIXTURE_DIR the rename ops may rename and restore}"

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BENCH="$HERE/2026-10-28-computer-use-drivers-bench.py"
OUT="${OUT:-$PWD/bench-out}"
REPEATS="${REPEATS:-10}"
PEEKABOO="${PEEKABOO:-}"
mkdir -p "$OUT"

cua() {
  label="$1"
  driver="$2"
  shift 2
  python3 -I "$BENCH" cua --driver "$driver" --label "$label" --fixture-dir "$FIXTURE_DIR" \
    --file "$FIXTURE_FILE" --out "$OUT/$label.json" --repeats "$REPEATS" "$@"
}

arms_forward() {
  cua "r$1-A-038-asis" "$CUA_038"
  cua "r$1-B-038-wait0-gap2" "$CUA_038" --env CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS=0 --env CUA_DRIVER_KEY_GAP_MS=2
  cua "r$1-C-nightly-pawnone" "$CUA_NIGHTLY" --post-action-wait none
  cua "r$1-D-nightly-pawnone-bg" "$CUA_NIGHTLY" --post-action-wait none --delivery background
}

arms_reverse() {
  cua "r$1-D-nightly-pawnone-bg" "$CUA_NIGHTLY" --post-action-wait none --delivery background
  cua "r$1-C-nightly-pawnone" "$CUA_NIGHTLY" --post-action-wait none
  cua "r$1-B-038-wait0-gap2" "$CUA_038" --env CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS=0 --env CUA_DRIVER_KEY_GAP_MS=2
  cua "r$1-A-038-asis" "$CUA_038"
}

peekaboo_arm() {
  [ -n "$PEEKABOO" ] || return 0
  python3 -I "$BENCH" peekaboo --peekaboo "$PEEKABOO" --label "r$1-F-peekaboo" --fixture-dir "$FIXTURE_DIR" \
    --file "$FIXTURE_FILE" --out "$OUT/r$1-F-peekaboo.json" --repeats "$REPEATS"
}

arms_forward 1
peekaboo_arm 1
peekaboo_arm 2
arms_reverse 2

if [ -n "${DEVELOPER_DIR:-}" ] || command -v swiftc >/dev/null 2>&1; then
  swiftc -O "$HERE/2026-10-28-ax-walk-micro.swift" -o "$OUT/ax-walk-micro"
  finder_pid="$(pgrep -x Finder | head -1)"
  if [ -n "${FINDER_WINDOW_ID:-}" ]; then
    "$OUT/ax-walk-micro" "$finder_pid" "$FINDER_WINDOW_ID" 10 12 | tee "$OUT/G-ax-walk-micro.tsv"
  else
    "$OUT/ax-walk-micro" "$finder_pid" "" 10 12 | tee "$OUT/G-ax-walk-micro.tsv"
  fi
fi
