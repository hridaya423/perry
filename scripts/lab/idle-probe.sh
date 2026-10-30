#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PID=""
SECONDS_TO_SAMPLE=60
CPU_BUDGET=0.5
RSS_BUDGET_MB=180

while [ $# -gt 0 ]; do
    case "$1" in
        --pid) PID="$2"; shift 2 ;;
        --seconds) SECONDS_TO_SAMPLE="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$PID" ]; then
    PID="$(pgrep -x Perry | head -1 || true)"
fi
if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
    echo "idle-probe: Perry is not running" >&2
    exit 2
fi

OUT_DIR="$REPO_ROOT/docs/evidence/perf"
mkdir -p "$OUT_DIR"
CSV="$OUT_DIR/idle-$(date -u +%Y%m%dT%H%M%SZ).csv"
echo "sample,cpu_percent,rss_kib" > "$CSV"

i=0
while [ "$i" -lt "$SECONDS_TO_SAMPLE" ]; do
    fields="$(ps -o %cpu=,rss= -p "$PID" 2>/dev/null | awk '{print $1","$2}')"
    if [ -z "$fields" ]; then
        echo "idle-probe: Perry (pid $PID) exited mid-probe" >&2
        exit 2
    fi
    echo "$i,$fields" >> "$CSV"
    i=$((i + 1))
    sleep 1
done

echo "csv: $CSV"
awk -F, 'NR>1 { cpu += $2; if ($2 > maxcpu) maxcpu = $2; if ($3 > maxrss) maxrss = $3; n++ }
END {
    if (n == 0) { print "idle-probe: no samples"; exit 2 }
    avg = cpu / n
    printf "pid_samples=%d avg_cpu=%.3f%% max_cpu=%.3f%% max_rss=%.1fMB\n", n, avg, maxcpu, maxrss / 1024
    ok = (avg <= '"$CPU_BUDGET"') && (maxrss / 1024 <= '"$RSS_BUDGET_MB"')
    printf "%s (budgets: avg_cpu <= %.1f%%, max_rss <= %dMB)\n", ok ? "PASS" : "FAIL", '"$CPU_BUDGET"', '"$RSS_BUDGET_MB"'
    exit ok ? 0 : 1
}' "$CSV"
