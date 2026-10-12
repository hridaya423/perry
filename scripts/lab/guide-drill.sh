#!/bin/bash
# guide-drill.sh — Phase-3 gate drill: N guide runs on a real Preview
# document. For every presented mark the drill injects a click at the
# mark's AX target center through the production
# handleSessionClick→acceptClick path, then reports click→next-mark
# latency (guide.click→guide.step.shown markers) and hit accuracy.
#
# Usage: scripts/lab/guide-drill.sh [--runs 20] [--goal "export as pdf"]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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

# Fixture document: any PNG Preview opens; its File menu carries
# "Export as PDF…" for the goal to match.
FIXTURE="$BUILD_DIR/guide-drill-fixture.png"
if [ ! -f "$FIXTURE" ]; then
    src="$(find "$REPO_ROOT/docs/evidence" -name '*.png' -print -quit)"
    [ -n "$src" ] || { echo "guide-drill: no PNG under docs/evidence for the fixture" >&2; exit 1; }
    cp "$src" "$FIXTURE"
fi
# Preview remembers per-doc window state; the drill reopens a fresh copy
# per run. Close only prior drill windows — never the user's docs.
osascript -e 'tell application "Preview" to close (every window whose name starts with "guide-drill-fixture")' >/dev/null 2>&1 || true
rm -f "$BUILD_DIR/guide-drill-fixture-r"*.png
sleep 1

rm -f "$STATE" "$STATE.log"
APP="$REPO_ROOT/build/debug-p1/Build/Products/Debug/Perry.app"
# Direct exec, not `open`: an `open`-launched Perry runs under its own
# (ungranted) TCC bundle identity, and the embedded cua-driver's AX reads
# fail there. Exec'ing inherits this terminal's grants so the real worker
# path — bundled driver, live AX observation — stays intact.
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

python3 - "$HELPER" "$STATE" "$GOAL" "$RUNS" "$MARKERS" "$APP" "$FIXTURE" <<'PY'
import json, os, re, subprocess, sys, time

helper, state_path, goal, runs, markers, app, fixture = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5], sys.argv[6], sys.argv[7]
log_path = state_path + ".log"
FIRST_TIMEOUT = 30.0
STEP_TIMEOUT = 15.0
MAX_STEPS = 8
MAX_CLICKS_PER_STEP = 3

def post(*argv):
    subprocess.run([helper, *argv], check=True)

DRIVER = os.path.join(app, "Contents/Resources/CuaDriver/bin/cua-driver")

def cua_call(name, arguments):
    """One-shot MCP-stdio call against Perry's bundled cua-driver."""
    reqs = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                    "clientInfo": {"name": "guide-drill", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": name, "arguments": arguments}},
    ]
    env = dict(os.environ, CUA_DRIVER_RS_UPDATE_CHECK="0")
    proc = subprocess.run([DRIVER, "mcp", "--direct", "--embedded",
                           "--host-bundle-id", "dev.perry.Perry"],
                          input="\n".join(json.dumps(r) for r in reqs),
                          capture_output=True, text=True, env=env, timeout=30)
    for line in proc.stdout.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("id") == 2:
            return row.get("result", {})
    return {}

FIXTURE_PREFIX = "guide-drill-fixture"

def fixture_windows():
    res = cua_call("list_windows", {"on_screen_only": True})
    return [w for w in res.get("structuredContent", {}).get("windows", [])
            if w.get("app_name") == "Preview" and w.get("title", "").startswith(FIXTURE_PREFIX)]

def activate_preview(fixture, run):
    # Each run opens a fresh copy of the doc: a new file URL means Preview
    # applies no persisted zoom/frame state from prior runs' clicks.
    copy = os.path.join(os.path.dirname(fixture), f"{FIXTURE_PREFIX}-r{run}.png")
    subprocess.run(["cp", fixture, copy], check=True)
    subprocess.run(["open", "-a", "Preview", copy], check=False)
    deadline = time.monotonic() + 10.0
    windows = []
    while time.monotonic() < deadline and not windows:
        time.sleep(0.3)
        windows = fixture_windows()
    # Normalize the window: Zoom to Fit un-poisons any persisted tiny-zoom
    # state, then the frame gets pinned to a known-good size.
    if windows:
        w = windows[0]
        cua_call("invoke_menu", {"pid": w["pid"], "window_id": w["window_id"],
                                 "path": ["View", "Zoom to Fit"]})
        cua_call("set_window_frame", {"pid": w["pid"], "window_id": w["window_id"],
                                    "x": 150, "y": 60, "width": 1000, "height": 720})
    subprocess.run(["osascript", "-e", 'tell application "Preview" to activate'],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # Wait until Preview is actually frontmost — a `start` posted early
    # resolves the target hint to the wrong app and the worker fails to
    # identify the window.
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        front = subprocess.run([helper, "frontmost"], capture_output=True, text=True).stdout.strip()
        if front == "com.apple.Preview":
            return True
        time.sleep(0.2)
    return False

def read_state(min_seq, timeout):
    """Returns (record_or_None, last_status). Status-only records are
    consumed but keep the poll waiting for a presentation/done record."""
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
    while steps < MAX_STEPS:
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
        for _ in range(MAX_CLICKS_PER_STEP):
            post("click", f"{cx:.1f}", f"{cy:.1f}")
            nxt, st = read_state(seq, STEP_TIMEOUT)
            if st:
                status = st
            if nxt is None:
                break
            seq = nxt["seq"]
            if nxt.get("done"):
                done = True
                break
            # A new presentation for the *same* instruction means the click
            # missed (ignored → represent) — count it and retry the mark.
            if nxt.get("instruction") == rec.get("instruction"):
                misses += 1
                continue
            break
        steps += 1
        if done:
            break
    post("stop")
    runs_summary.append({"run": run, "steps": steps, "misses": misses,
                         "no_target": no_target, "done": done, "status": status})
    print(f"run {run:2d}: steps={steps} misses={misses} done={done}"
          + (f" status=\"{status}\"" if status else "")
          + (" (no-target presentation)" if no_target else "")
          + ("" if front_ok else " WARN: Preview not frontmost"), flush=True)
    # The previous guide's embedded driver is still terminating (the
    # worker-service stop deadline is 500ms); start the next run too soon
    # and its worker admission collides with the tail of this teardown.
    time.sleep(3.0)

# Pair each guide.click with the guide.step.shown that follows it (or an
# ignored marker = miss) to compute click→next-mark latency.
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
        while j < len(rows) and rows[j]["name"] not in ("guide.step.shown", "guide.click.ignored", "guide.click"):
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

completed = sum(1 for r in runs_summary if r["done"])
total_misses = sum(r["misses"] for r in runs_summary) + miss_markers
total_clicks = len(pairings) + miss_markers + total_misses
print("\n=== guide-drill results ===")
print(f"runs: {runs}  completed-guides: {completed}")
print(f"click→next-mark ms: n={len(pairings)} p50={pct(50):.0f} p95={pct(95):.0f} max={max(pairings) if pairings else 0:.0f}")
print(f"clicks: {total_clicks}  misses: {total_misses}  hit rate: {100.0 * (total_clicks - total_misses) / max(total_clicks, 1):.1f}%")
print(f"markers: {markers}")
PY
