#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PERRY_DATA_DIRECTORY="${PERRY_DATA_DIRECTORY:-$REPO_ROOT/build/lab/data}"
DRIVE="$REPO_ROOT/scripts/lab/perry-drive.sh"
REPORT="$REPO_ROOT/scripts/lab/latency-report.py"
HOLD_BIN="${TALK_HOLD_BIN:-/tmp/perry-talk-hold}"
RUNS=${RUNS:-10}
HOLD=${HOLD:-1.6}
TIMEOUT=${TALK_TIMEOUT:-45}
BARGE=${BARGE:-1}
CUA="${CUA_DRIVER:-cua-driver}"
ASSERT=0
[ "${1:-}" = "--assert" ] && ASSERT=1

swiftc -O -o "$HOLD_BIN" "$REPO_ROOT/scripts/lab/talk-hold.swift"

TARGET_APP="${TALK_TARGET_APP:-DrillTarget}"
TARGET_PID=""
if [ "$TARGET_APP" = "DrillTarget" ]; then
    TARGET_BIN="$REPO_ROOT/build/lab/DrillTarget"
    mkdir -p "$(dirname "$TARGET_BIN")"
    [ "$TARGET_BIN" -nt "$REPO_ROOT/scripts/lab/drill-target.swift" ] || \
        swiftc -O -o "$TARGET_BIN" "$REPO_ROOT/scripts/lab/drill-target.swift"
    for stale in $(pgrep -x DrillTarget); do kill "$stale" 2>/dev/null || true; done
    "$TARGET_BIN" &
    sleep 1
    TARGET_PID="$(pgrep -x DrillTarget | head -1)"
    activate_target() {
        osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $TARGET_PID) to true" >/dev/null 2>&1
    }
else
    activate_target() { open -a "$TARGET_APP"; }
fi

front_target() {
    activate_target
    sleep 1
    TARGET_PID="${TARGET_PID:-$(pgrep -x "$TARGET_APP" | head -1)}"
    [ -n "$TARGET_PID" ] || { echo "talk-drill: no $TARGET_APP process" >&2; exit 1; }
}

LAB_ARGS=(--perry-talk-drill --perry-talk-script "${TALK_SCRIPT:-what does this do}")
if [ -n "${TALK_WAV:-}" ]; then
    if [ ! -f "$TALK_WAV" ]; then
        say -o /tmp/_perry_talk.aiff "${TALK_SCRIPT:-what does this do}"
        afconvert -f WAVE -d LEI16 /tmp/_perry_talk.aiff "$TALK_WAV"
    fi
    LAB_ARGS=(--perry-talk-drill --perry-talk-audio "$TALK_WAV")
fi

for stale in $(pgrep -x Perry); do kill "$stale" 2>/dev/null || true; done
sleep 0.5
"$DRIVE" seed-lab-data
EVIDENCE_DIR="$REPO_ROOT/docs/evidence/lab"
mkdir -p "$EVIDENCE_DIR"
LOG="$EVIDENCE_DIR/perf-$(date -u +%Y%m%dT%H%M%SZ).jsonl"
APP_BUNDLE="$REPO_ROOT/build/debug-p1/Build/Products/Debug/Perry.app"
if [ -n "${TALK_WAV:-}" ]; then
    open -n "$APP_BUNDLE" --env "PERRY_PERFORMANCE_EVENT_LOG=$LOG" --env "PERRY_ALLOW_SCREEN_CAPTURE=1" --args "${LAB_ARGS[@]}"
else
    PERRY_PERFORMANCE_EVENT_LOG="$LOG" "$APP_BUNDLE/Contents/MacOS/Perry" \
        "${LAB_ARGS[@]}" >/tmp/perry-drill-out.log 2>/tmp/perry-drill-err.log &
fi
for _ in $(seq 1 20); do pgrep -x Perry >/dev/null && break; sleep 0.5; done
pgrep -x Perry >/dev/null || { echo "talk-drill: Perry did not launch" >&2; exit 1; }
MARKERS="$LOG.markers.jsonl"
echo "markers=$MARKERS"

front_target

pick_target() {
    local win state
    win="$("$CUA" call list_windows "{\"pid\":$TARGET_PID}" \
        | python3 -c 'import json,sys
ws=[w for w in json.load(sys.stdin)["windows"] if w.get("is_on_screen")]
w=max(ws,key=lambda w:w["bounds"]["width"]*w["bounds"]["height"]) if ws else None
print(w["window_id"] if w else "")')"
    [ -n "$win" ] || return 1
    state="$("$CUA" call get_window_state "{\"pid\":$TARGET_PID,\"window_id\":$win,\"include_screenshot\":false,\"tree_format\":\"elements\"}")"
    printf '%s' "$state" | python3 -c 'import json,sys
els=json.load(sys.stdin).get("elements",[])
buttons=[e for e in els if e.get("role")=="AXButton" and e.get("enabled",True)]
preferred=("5","Five","9","Nine","All Clear","Percent")
for want in preferred:
    for e in buttons:
        if e.get("label")==want:
            f=e["frame"]; print(f["x"]+f["w"]/2, f["y"]+f["h"]/2); sys.exit(0)
if buttons:
    e=max(buttons,key=lambda e:e["frame"]["w"]*e["frame"]["h"])
    f=e["frame"]; print(f["x"]+f["w"]/2, f["y"]+f["h"]/2); sys.exit(0)
sys.exit(1)'
}

TARGET="$(pick_target || true)"
if [ -z "$TARGET" ]; then
    echo "talk-drill: could not resolve a target button — aiming at window centre" >&2
    CX=860; CY=550
else
    read -r CX CY <<<"$TARGET"
    echo "target=($CX, $CY)"
fi

wait_for() {
    local from=$1 re=$2 seconds=$3
    local limit=$((seconds * 4)) i=0
    while [ "$i" -lt "$limit" ]; do
        if [ -f "$MARKERS" ] && tail -n "+$from" "$MARKERS" | grep -qE "$re"; then
            return 0
        fi
        sleep 0.25
        i=$((i + 1))
    done
    return 1
}

marker_count() { [ -f "$MARKERS" ] && wc -l < "$MARKERS" | tr -d ' ' || echo 0; }

for run in $(seq 1 "$RUNS"); do
    from=$(( $(marker_count) + 1 ))
    front_target
    sleep 0.2
    "$HOLD_BIN" "$CX" "$CY" "$HOLD" 2>/dev/null
    if wait_for "$from" 'answer\.first_text|talk\.input_failed|talk\.turn_failed|talk\.capture_failed' "$TIMEOUT"; then
        if tail -n "+$from" "$MARKERS" | grep -q 'answer.first_text'; then
            echo "run $run: answered"
            wait_for "$from" 'talk\.first_audio|talk\.turn_failed' "$TIMEOUT" || true
            sleep 3
        else
            echo "run $run: $(tail -n "+$from" "$MARKERS" | grep -oE 'talk\.input_failed|talk\.turn_failed\.[A-Za-z]+|talk\.capture_failed' | head -1)"
            sleep 2
        fi
    else
        echo "run $run: TIMEOUT waiting for answer.first_text"
    fi
done

if [ "$BARGE" != "0" ]; then
    from=$(( $(marker_count) + 1 ))
    "$HOLD_BIN" "$CX" "$CY" "$HOLD" 2>/dev/null
    if wait_for "$from" 'talk\.first_audio' "$TIMEOUT"; then
        "$HOLD_BIN" "$CX" "$CY" 0.4 2>/dev/null
        echo "barge-in: second hold posted during speech"
        sleep 2
    else
        echo "barge-in: skipped (no first_audio observed)"
    fi
fi

echo
[ "$TARGET_APP" = "DrillTarget" ] && kill "$TARGET_PID" 2>/dev/null || true

echo "== talk drill latencies =="
python3 "$REPORT" "$MARKERS" \
    --pair talk.keydown:talk.listening \
    --pair talk.keydown:talk.hold_commit \
    --pair talk.keydown:capture.done \
    --pair talk.keyup:answer.first_text \
    --pair talk.keyup:talk.first_audio \
    --pair talk.keyup:ink.first_draw \
    --pair talk.bargein:bargein.silence

echo
echo "== deixis outcomes =="
for name in deixis.element deixis.point deixis.window deixis.none talk.input_failed talk.cancel; do
    n=$(grep -c "\"$name" "$MARKERS" 2>/dev/null || true)
    echo "  $name: $n"
done

if [ "$ASSERT" = "1" ]; then
    echo
    echo "== assert =="
    if python3 "$REPO_ROOT/scripts/lab/drill-assert.py" "$MARKERS" "$RUNS"; then
        echo "assert: all gates green"
    else
        echo "assert: gates failed" >&2
        exit 1
    fi
fi
