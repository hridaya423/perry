#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
APP="${PERRY_APP:-$ROOT/build/debug-p1/Build/Products/Debug/Perry.app}"
DRIVER="$APP/Contents/Resources/CuaDriver/bin/cua-driver"
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

python3 - "$DRIVER" "$PERRY_PID" "$PROBE" "$DRILL_DIR" "$LOG" <<'PYEOF'
import json, os, subprocess, sys, time

driver, perry_pid, probe, drill_dir, log_path = sys.argv[1:6]
perry_pid = int(perry_pid)

def log(event, **extra):
    row = {"t": time.time(), "event": event, **extra}
    with open(log_path, "a") as f:
        f.write(json.dumps(row) + "\n")
    print("  ·", event)

def cua(name, arguments, timeout=30):
    reqs = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                    "clientInfo": {"name": "routine-drill", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
         "params": {"name": name, "arguments": arguments}},
    ]
    env = dict(os.environ, CUA_DRIVER_RS_UPDATE_CHECK="0")
    proc = subprocess.run([driver, "mcp", "--direct", "--embedded",
                           "--host-bundle-id", "dev.perry.Perry"],
                          input="\n".join(json.dumps(r) for r in reqs),
                          capture_output=True, text=True, env=env, timeout=timeout)
    for line in proc.stdout.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("id") == 2:
            return row.get("result", {})
    return {}

def windows(pid):
    res = cua("list_windows", {"pid": pid})
    return res.get("structuredContent", {}).get("windows", res.get("windows", []))

def find_element(elements, label_substr=None, role=None):
    for el in elements:
        lab = el.get("label") or el.get("title") or el.get("value") or ""
        if label_substr and label_substr not in str(lab):
            continue
        if role and el.get("role") != role:
            continue
        return el
    return None

def window_elements(pid, window_id):
    res = cua("get_window_state", {"pid": pid, "window_id": window_id})
    sc = res.get("structuredContent", {})
    return sc.get("elements", []), sc.get("snapshot_id")

def click_element(pid, window_id, snapshot_id, element_index):
    return cua("click", {"pid": pid, "window_id": window_id,
                         "snapshot_id": snapshot_id,
                         "element_index": element_index})

def wait_for(pred, timeout, poll=0.5, desc=""):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        got = pred()
        if got:
            return got
        time.sleep(poll)
    raise SystemExit(f"timeout waiting for {desc or 'condition'}")

cua("hotkey", {"keys": ["ctrl", "cmd", "space"], "scope": "desktop"})
log("home.hotkey.sent")

def home_window():
    for w in windows(perry_pid):
        if w.get("width", 0) > 300:
            return w
    return None
home = wait_for(home_window, 15, desc="Perry Home window")
log("home.window", window_id=home["window_id"], title=home.get("title"))

def click_named(pid, win, needle, role_hint=None, desc=""):
    els, snap = window_elements(pid, win)
    el = find_element(els, needle, role_hint)
    if not el:
        raise SystemExit(f"no element matching {needle!r} in window {win}; "
                         f"labels: {[e.get('label') or e.get('title') for e in els][:40]}")
    click_element(pid, win, snap, el["index"])
    return el

time.sleep(1.0)
click_named(perry_pid, home["window_id"], "Routines")
log("routines.clicked")
time.sleep(1.0)
run_el = click_named(perry_pid, home["window_id"], "Run", "AXButton", "routine Run button")
log("routine.run.clicked")

def card_window():
    for w in windows(perry_pid):
        els, snap = window_elements(perry_pid, w["window_id"])
        if any("About to" in str(e.get("label") or e.get("title") or "") or
               "About to" in str(e.get("value") or "") for e in els):
            return w, els, snap
    return None
deadline = time.monotonic() + 45
card = None
while time.monotonic() < deadline and not card:
    time.sleep(1.0)
    card = card_window()
if not card:
    raise SystemExit("plan card never appeared")
cw, els, snap = card
log("plan.card.shown", window_id=cw["window_id"])

cua("get_desktop_state", {"out": os.path.join(drill_dir, "rehearsal.png")}, timeout=60)
log("rehearsal.screenshot")

run_btn = find_element(els, "Run", "AXButton")
if not run_btn:
    raise SystemExit(f"no Run button on card; labels: {[e.get('label') for e in els][:40]}")
click_element(perry_pid, cw["window_id"], snap, run_btn["index"])
log("plan.run.clicked")

def textedit_window():
    for w in cua("list_windows", {"pid": 0}).get("structuredContent", {}).get("windows", []):
        if w.get("app_name") == "TextEdit" and "replay-target" in w.get("title", ""):
            return w
    for w in cua("list_windows", {}).get("structuredContent", {}).get("windows", []):
        if w.get("app_name") == "TextEdit":
            return w
    return None

tw = wait_for(textedit_window, 10, desc="TextEdit window")
def probe_landed():
    els, _ = window_elements(tw["pid"], tw["window_id"])
    for el in els:
        if el.get("role") == "AXTextArea" and probe in str(el.get("value", "")):
            return el
    return None
landed = wait_for(probe_landed, 30, desc="probe text in TextEdit")
log("probe.landed", stable_id=landed.get("stable_id"))

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
