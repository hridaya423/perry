#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
APP="${PERRY_APP:-$ROOT/build/debug-p1/Build/Products/Debug/Perry.app}"
DRILL_DIR="$(mktemp -d /tmp/perry-routine-drill.XXXXXX)"
STORAGE="$DRILL_DIR/storage"
mkdir -p "$STORAGE/Routines"
PROBE="PERRY-REPLAY-PROBE-$(date +%H%M%S)"
TARGET_DOC="$DRILL_DIR/replay-target.txt"
LOG="$DRILL_DIR/journey.jsonl"
touch "$LOG"

log() { echo "{\"t\":$(python3 -c 'import time;print(time.time())'),\"event\":\"$1\"}" >> "$LOG"; echo "  · $1"; }

MODS=Packages/PerryGuide/.build/out/Products/Debug
[ -d "$MODS" ] || { echo "PerryGuide modules missing — run: swift test --package-path Packages/PerryGuide" >&2; exit 1; }
if [ ! -x "$DRILL_DIR/seed-routine" ]; then
    swiftc -I "$MODS" -L "$MODS" -lPerryGuide scripts/lab/seed-routine.swift -o "$DRILL_DIR/seed-routine"
fi
"$DRILL_DIR/seed-routine" "$STORAGE" com.apple.TextEdit "$PROBE" > "$DRILL_DIR/routine-id"
log "routine.seeded"

printf '' > "$TARGET_DOC"
open -a TextEdit "$TARGET_DOC"
sleep 2
log "target.opened"

scripts/lab/perry-drive.sh launch --perry-debug-storage-directory "$STORAGE" > "$DRILL_DIR/launch.txt"
PERRY_PID="$(sed -n 's/^pid=//p' "$DRILL_DIR/launch.txt")"
PERF_LOG="$(sed -n 's/^perf_log=//p' "$DRILL_DIR/launch.txt")"
sleep 3
log "perry.launched"

PERRY_APP="$APP" python3 - "$PERRY_PID" "$PROBE" "$DRILL_DIR" "$LOG" <<'PYEOF'
import json, os, subprocess, sys, time
sys.path.insert(0, os.path.join(os.getcwd(), "scripts/lab"))
import agent_desktop as ad

perry_pid, probe, drill_dir, log_path = sys.argv[1:5]
perry_pid = int(perry_pid)

def log(event, **extra):
    row = {"t": time.time(), "event": event, **extra}
    with open(log_path, "a") as f:
        f.write(json.dumps(row) + "\n")
    print("  ·", event)

def wait_for(pred, timeout, poll=0.5, desc=""):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        got = pred()
        if got:
            return got
        time.sleep(poll)
    raise SystemExit(f"timeout waiting for {desc or 'condition'}")

ad.press("ctrl+cmd+space")
log("home.hotkey.sent")

def home_window():
    for w in ad.windows(pid=perry_pid):
        if w.get("bounds", {}).get("width", 0) > 300:
            return w
    return None
home = wait_for(home_window, 15, desc="Perry Home window")
log("home.window", window_id=home["id"], title=home.get("title"))

def click_named(win, needle, role_hint=None):
    node = ad.find(win, needle, role_hint)
    if not node:
        labels = [ad.text(n) for n in ad.nodes(win) if n.get("ref_id")]
        raise SystemExit(f"no element matching {needle!r} in window {win}; labels: {labels[:40]}")
    ad.click(node["ref_id"])
    return node

time.sleep(1.0)
click_named(home["id"], "Routines")
log("routines.clicked")
time.sleep(1.0)
click_named(home["id"], "Run", "button")
log("routine.run.clicked")

def card_window():
    for w in ad.windows(pid=perry_pid):
        if any("About to" in ad.text(n) for n in ad.nodes(w["id"], interactive=False)):
            return w
    return None
deadline = time.monotonic() + 45
card = None
while time.monotonic() < deadline and not card:
    time.sleep(1.0)
    card = card_window()
if not card:
    raise SystemExit("plan card never appeared")
log("plan.card.shown", window_id=card["id"])

subprocess.run(["screencapture", "-x", os.path.join(drill_dir, "rehearsal.png")], check=False, timeout=60)
log("rehearsal.screenshot")

click_named(card["id"], "Run", "button")
log("plan.run.clicked")

def textedit_window():
    editors = ad.windows(app_name="TextEdit")
    return next((w for w in editors if "replay-target" in w.get("title", "")), None)

tw = wait_for(textedit_window, 10, desc="TextEdit window")
def probe_landed():
    return next((n for n in ad.nodes(tw["id"], interactive=False) if probe in str(n.get("value") or "")), None)
landed = wait_for(probe_landed, 30, desc="probe text in TextEdit")
log("probe.landed", ref=landed.get("ref_id"), role=landed.get("role"))

time.sleep(3)
receipts = []
for base, _dirs, files in os.walk(os.path.join(drill_dir, "storage")):
    for name in files:
        if name.endswith((".json", ".jsonl", ".md")) and "Routine" not in name:
            receipts.append(os.path.join(base, name))
with open(os.path.join(drill_dir, "receipts.txt"), "w") as f:
    f.write("\n".join(receipts))
log("receipts.collected", count=len(receipts))

print(f"JOURNEY PASSED — probe text observed in TextEdit; {len(receipts)} storage artifacts")
PYEOF

echo ""
echo "drill dir: $DRILL_DIR"
echo "perf log:  ${PERF_LOG:-n/a}"
scripts/lab/perry-drive.sh quit || true
