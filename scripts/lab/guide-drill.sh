#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PERRY_DATA_DIRECTORY="${PERRY_DATA_DIRECTORY:-$REPO_ROOT/build/lab/data}"
RUNS=20
GOAL="export as pdf"
while [ $# -gt 0 ]; do
    case "$1" in
        --runs) RUNS="$2"; shift 2 ;;
        --goal) GOAL="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

BUILD_DIR="$REPO_ROOT/build/lab"
HELPER="$BUILD_DIR/guide-drill"
STATE="${TMPDIR}perry-guide-drill-state.json"
mkdir -p "$BUILD_DIR"
if [ ! -x "$HELPER" ] || [ "$REPO_ROOT/scripts/lab/guide-drill.swift" -nt "$HELPER" ]; then
    swiftc -O -o "$HELPER" "$REPO_ROOT/scripts/lab/guide-drill.swift"
fi

FIXTURE="$BUILD_DIR/guide-drill-fixture.png"
if [ ! -f "$FIXTURE" ]; then
    src="$(find "$REPO_ROOT/docs/evidence" -name '*.png' -print -quit)"
    [ -n "$src" ] || { echo "guide-drill: no PNG under docs/evidence for the fixture" >&2; exit 1; }
    cp "$src" "$FIXTURE"
fi
rm -f "$BUILD_DIR/guide-drill-fixture-r"*.png

rm -f "$STATE" "$STATE.log"
APP="$REPO_ROOT/build/debug-p1/Build/Products/Debug/Perry.app"
LOG_DIR="$REPO_ROOT/docs/evidence/lab"
mkdir -p "$LOG_DIR"
PERF_LOG="$LOG_DIR/perf-$(date -u +%Y%m%dT%H%M%SZ).jsonl"
MARKERS="$PERF_LOG.markers.jsonl"
pgrep -x Perry >/dev/null && "$REPO_ROOT/scripts/lab/perry-drive.sh" quit
PERRY_PERFORMANCE_EVENT_LOG="$PERF_LOG" PERRY_ALLOW_SCREEN_CAPTURE=1 \
    PERRY_GUIDE_DRILL_STATE="$STATE" \
    "$APP/Contents/MacOS/Perry" --perry-guide-drill \
    >"$BUILD_DIR/perry-stderr.log" 2>&1 &
PERRY_PID=$!
trap 'kill "$PERRY_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do kill -0 "$PERRY_PID" 2>/dev/null && break; sleep 0.5; done
kill -0 "$PERRY_PID" || { echo "guide-drill: Perry did not launch" >&2; exit 1; }
echo "pid=$PERRY_PID"
echo "perf_log=$PERF_LOG"
sleep 3

REPO_ROOT="$REPO_ROOT" PERRY_APP="$APP" python3 - "$HELPER" "$STATE" "$GOAL" "$RUNS" "$MARKERS" "$APP" "$FIXTURE" <<'PY'
import json, os, re, subprocess, sys, time

helper, state_path, goal, runs, markers, app, fixture = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5], sys.argv[6], sys.argv[7]
log_path = state_path + ".log"
FIRST_TIMEOUT = 30.0
STEP_TIMEOUT = 25.0
MAX_STEPS = 8
MAX_CLICKS_PER_STEP = 3

def post(*argv):
    subprocess.run([helper, *argv], check=True)

sys.path.insert(0, os.path.join(os.environ["REPO_ROOT"], "scripts/lab"))
import agent_desktop as ad

def osa(script):
    subprocess.run(["osascript", "-e", script], capture_output=True, text=True, check=False)

FIXTURE_PREFIX = "guide-drill-fixture"

def fixture_windows():
    return [w for w in ad.windows(app_name="Preview") if w.get("title", "").startswith(FIXTURE_PREFIX)]

def close_fixture_windows():
    osa(f'tell application "Preview" to close (every window whose name starts with "{FIXTURE_PREFIX}")')

def activate_preview(fixture, run):
    close_fixture_windows()
    copy = os.path.join(os.path.dirname(fixture), f"{FIXTURE_PREFIX}-r{run}.png")
    subprocess.run(["cp", fixture, copy], check=True)
    subprocess.run(["open", "-a", "Preview", copy], check=False)
    deadline = time.monotonic() + 10.0
    windows = []
    while time.monotonic() < deadline and not windows:
        time.sleep(0.3)
        windows = [w for w in fixture_windows()
                   if w.get("title", "").startswith(f"{FIXTURE_PREFIX}-r{run}")]
    if windows:
        title = windows[0]["title"]
        osa(f'tell application "System Events" to tell process "Preview" to click menu item "Zoom to Fit" of menu "View" of menu bar 1')
        osa(f'tell application "Preview" to set bounds of (first window whose name is "{title}") to {{150, 60, 1150, 780}}')
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        front = subprocess.run([helper, "frontmost"], capture_output=True, text=True).stdout.strip()
        if front == "com.apple.Preview":
            return True
        time.sleep(0.2)
    return False

def read_state(min_seq, timeout, early_status=None):
    """Returns (record_or_None, last_status). Status-only records are
    consumed but keep the poll waiting for a presentation/done record —
    unless `early_status` matches (a string or tuple of needles), which
    returns immediately."""
    needles = (early_status,) if isinstance(early_status, str) else early_status
    deadline = time.monotonic() + timeout
    last_status = None
    while time.monotonic() < deadline:
        try:
            with open(state_path) as f:
                d = json.load(f)
            if d.get("seq", 0) > min_seq:
                min_seq = d["seq"]
                if "status" in d:
                    last_status = d["status"]
                    if needles and any(n in last_status for n in needles):
                        return None, last_status
                    continue
                return d, last_status
        except (OSError, ValueError):
            pass
        time.sleep(0.025)
    return None, last_status

def last_log_seq():
    seq = 0
    try:
        with open(log_path) as f:
            for line in f:
                try:
                    seq = max(seq, json.loads(line).get("seq", 0))
                except ValueError:
                    pass
    except OSError:
        pass
    return seq

runs_summary = []
for run in range(1, runs + 1):
    front_ok = activate_preview(fixture, run)
    time.sleep(0.4)
    seq = last_log_seq()
    post("start", goal)
    steps = misses = no_target = 0
    done = False
    status = None
    rec = None
    while steps < MAX_STEPS:
        if rec is None:
            rec, st = read_state(seq, FIRST_TIMEOUT if steps == 0 else STEP_TIMEOUT)
            if st:
                status = st
            if rec is None:
                break
            seq = rec["seq"]
        if rec.get("done"):
            done = True
            break
        if not rec.get("hasTarget"):
            no_target += 1
            break
        cx = rec["x"] + rec["w"] / 2.0
        cy = rec["y"] + rec["h"] / 2.0
        nxt = None
        for _ in range(MAX_CLICKS_PER_STEP):
            post("click", f"{cx:.1f}", f"{cy:.1f}")
            nxt, st = read_state(seq, STEP_TIMEOUT, early_status=("highlighted", "Not verified"))
            if st:
                status = st
            if nxt is None and status and "highlighted" in status:
                misses += 1
                continue
            if nxt is None and status and "Not verified" in status:
                post("done")
                nxt, st = read_state(seq, STEP_TIMEOUT)
                if st:
                    status = st
            if nxt is None:
                break
            seq = nxt["seq"]
            if nxt.get("instruction") == rec.get("instruction") and not nxt.get("done"):
                cx = nxt["x"] + nxt["w"] / 2.0
                cy = nxt["y"] + nxt["h"] / 2.0
                continue
            break
        steps += 1
        rec = nxt
    if not done:
        post("stop")
    s = status or ""
    if "cancelled" in s or "could not" in s or "stopped before" in s:
        outcome = "failed"
    elif steps == 0:
        outcome = "empty-plan"
    else:
        outcome = "clean-end"
    runs_summary.append({"run": run, "steps": steps, "misses": misses,
                         "no_target": no_target, "done": done, "status": status,
                         "outcome": outcome})
    print(f"run {run:2d}: steps={steps} misses={misses} {outcome}"
          + (f" status=\"{status}\"" if status else "")
          + (" (no-target presentation)" if no_target else "")
          + ("" if front_ok else " WARN: Preview not frontmost"), flush=True)
    time.sleep(6.0)

pairings = []
miss_markers = 0
try:
    rows = [json.loads(l) for l in open(markers)]
except OSError:
    rows = []
fmt = "%Y-%m-%dT%H:%M:%S.%fZ"
import datetime as _dt
def ts(row):
    return _dt.datetime.strptime(row["captured_at"], fmt).timestamp()
i = 0
while i < len(rows):
    if rows[i]["name"] == "guide.click":
        j = i + 1
        while j < len(rows) and rows[j]["name"] not in ("guide.step.shown", "guide.click.ignored", "guide.click", "guide.start"):
            j += 1
        if j < len(rows) and rows[j]["name"] == "guide.step.shown":
            pairings.append((ts(rows[j]) - ts(rows[i])) * 1000.0)
        elif j < len(rows) and rows[j]["name"] == "guide.click.ignored":
            miss_markers += 1
        i = j
    i += 1

pairings.sort()
def pct(p):
    return pairings[min(len(pairings) - 1, int(round((p / 100) * (len(pairings) - 1))))] if pairings else 0.0

completed = sum(1 for r in runs_summary if r["outcome"] == "clean-end")
failed = sum(1 for r in runs_summary if r["outcome"] == "failed")
empty = sum(1 for r in runs_summary if r["outcome"] == "empty-plan")
click_markers = sum(1 for r in rows if r["name"] == "guide.click")
total_misses = miss_markers
print("\n=== guide-drill results ===")
print(f"runs: {runs}  clean-end: {completed}  failed: {failed}  empty-plan: {empty}")
print(f"click→next-mark ms: n={len(pairings)} p50={pct(50):.0f} p95={pct(95):.0f} max={max(pairings) if pairings else 0:.0f}")
print(f"clicks: {click_markers}  misses: {total_misses}  hit rate: {100.0 * (click_markers - total_misses) / max(click_markers, 1):.1f}%")
print(f"markers: {markers}")
PY
