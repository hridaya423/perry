#!/bin/sh
RUN="$HOME/Honey/perry-cua-scratch/run"; S="$HOME/Honey/perry-cua-scratch"
BENCH="$HOME/Honey/perry-cua/scripts/lab/cua-bench.py"
OLD="$S/v0.22.1/x/cua-driver-rs-0.22.1-darwin-arm64/CuaDriver.app/Contents/MacOS/cua-driver"
NEW="$S/v0.38.0/x/cua-driver-rs-0.38.0-darwin-arm64/CuaDriver.app/Contents/MacOS/cua-driver"
mkdir -p "$RUN/out"
N="${REPEATS:-30}"
variant() {
  round="$1"; label="$2"; shift 2
  /usr/bin/python3 -I "$BENCH" --label "$label" --repeats "$N" --out "$RUN/out/r$round-$label.json" "$@" 2>&1
}
round() {
  r="$1"; order="$2"
  for v in $order; do
    case "$v" in
      old-full) variant $r old-0.22.1-full-manifest --driver "$OLD" --manifest "$RUN/capabilities-full.yaml" ;;
      new-full) variant $r new-0.38.0-full-manifest --driver "$NEW" --tree-format both --manifest "$RUN/capabilities-full.yaml" ;;
      new-wait0) variant $r new-0.38.0-full-manifest-wait0 --driver "$NEW" --tree-format both --manifest "$RUN/capabilities-full.yaml" --env CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS=0 ;;
      new-std) variant $r new-0.38.0-standard-no-manifest --driver "$NEW" --tree-format both --permission-mode standard ;;
      old-small) variant $r old-0.22.1-small-manifest --driver "$OLD" --manifest "$RUN/capabilities-small.yaml" ;;
      new-small) variant $r new-0.38.0-small-manifest --driver "$NEW" --tree-format both --manifest "$RUN/capabilities-small.yaml" ;;
    esac
  done
}
round 1 "old-full new-full new-wait0 new-std old-small new-small"
round 2 "new-small old-small new-std new-wait0 new-full old-full"
