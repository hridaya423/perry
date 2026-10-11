#!/bin/bash
# talk-drill.sh — exercise the real ⌃⌥ talk loop end to end and report the
# hero latencies plus deixis outcomes.
#
# Per run: open a Calculator window, resolve a real AX button's centre via
# cua-driver, post a synthetic ⌃⌥ hold with the pointer resting on it, and
# wait for the turn to reach answer.first_text (or a failure marker). Speech
# comes from the app-side lab input: --perry-talk-script <text> (default —
# deterministic, no Speech permission needed) or --perry-talk-audio <file>
# when TALK_WAV=<path> is set (real SFSpeechURLRecognitionTask).
#
#   RUNS=10 HOLD=1.6 scripts/lab/talk-drill.sh
#
# Requires: Debug build at build/debug-p1, Screen Recording + Accessibility
# for the app, and a working brain.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DRIVE="$REPO_ROOT/scripts/lab/perry-drive.sh"
REPORT="$REPO_ROOT/scripts/lab/latency-report.py"
HOLD_BIN="${TALK_HOLD_BIN:-/tmp/perry-talk-hold}"
RUNS=${RUNS:-10}
HOLD=${HOLD:-1.6}
TIMEOUT=${TALK_TIMEOUT:-45}
BARGE=${BARGE:-1}
CUA="${CUA_DRIVER:-cua-driver}"

swiftc -O -o "$HOLD_BIN" "$REPO_ROOT/scripts/lab/talk-hold.swift"

LAB_ARGS=(--perry-talk-drill --perry-talk-script "${TALK_SCRIPT:-what does this do}")
if [ -n "${TALK_WAV:-}" ]; then
    if [ ! -f "$TALK_WAV" ]; then
        say -o /tmp/_perry_talk.aiff "${TALK_SCRIPT:-what does this do}"
        afconvert -f WAVE -d LEI16 /tmp/_perry_talk.aiff "$TALK_WAV"
    fi
    LAB_ARGS=(--perry-talk-drill --perry-talk-audio "$TALK_WAV")
fi

# Launch the binary directly: `open` spawns under launchd, where the embedded
# cua-driver attributes TCC to an ungranted Perry and every capture is refused.
# A shell-launched Perry inherits this terminal's trusted context, which is
# what the latency measurement is about. TCC-grant UX is a separate audit.
for stale in $(pgrep -x Perry); do kill "$stale" 2>/dev/null || true; done
sleep 0.5
EVIDENCE_DIR="$REPO_ROOT/docs/evidence/lab"
mkdir -p "$EVIDENCE_DIR"
LOG="$EVIDENCE_DIR/perf-$(date -u +%Y%m%dT%H%M%SZ).jsonl"
PERRY_PERFORMANCE_EVENT_LOG="$LOG" \
    "$REPO_ROOT/build/debug-p1/Build/Products/Debug/Perry.app/Contents/MacOS/Perry" \
    "${LAB_ARGS[@]}" >/tmp/perry-drill-out.log 2>/tmp/perry-drill-err.log &
for _ in $(seq 1 20); do pgrep -x Perry >/dev/null && break; sleep 0.5; done
pgrep -x Perry >/dev/null || { echo "talk-drill: Perry did not launch" >&2; exit 1; }
MARKERS="$LOG.markers.jsonl"
echo "markers=$MARKERS"

# Bring a target window forward *after* Perry launches so it is the frontmost
# app the Talk capture observes. This must repeat per run — Perry captures
# the frontmost app at hold time, and anything that activates another app
# between runs silently retargets the observation.
open -a Calculator
sleep 1.2
CALC_PID="$(pgrep -x Calculator | head -1)"

pick_target() {
    local win state
    win="$("$CUA" call list_windows "{\"pid\":$CALC_PID}" \
        | python3 -c 'import json,sys
ws=[w for w in json.load(sys.stdin)["windows"] if w.get("is_on_screen")]
w=max(ws,key=lambda w:w["bounds"]["width"]*w["bounds"]["height"]) if ws else None
print(w["window_id"] if w else "")')"
    [ -n "$win" ] || return 1
    state="$("$CUA" call get_window_state "{\"pid\":$CALC_PID,\"window_id\":$win,\"include_screenshot\":false}")"
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
    echo "talk-drill: could not resolve a Calculator button — aiming at window centre" >&2
    CX=860; CY=550
else
    read -r CX CY <<<"$TARGET"
    echo "target=($CX, $CY)"
fi

wait_for() {
    # wait_for <from-line> <regex> <timeout-s> → 0 when a new row matches
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
    open -a Calculator
    sleep 0.7
    "$HOLD_BIN" "$CX" "$CY" "$HOLD" 2>/dev/null
    if wait_for "$from" 'answer\.first_text|talk\.input_failed|talk\.turn_failed|talk\.capture_failed' "$TIMEOUT"; then
        if tail -n "+$from" "$MARKERS" | grep -q 'answer.first_text'; then
            echo "run $run: answered"
            # Let the turn finish before the next hold, or the next hold
            # becomes a barge-in and cancels it.
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
    # One barge-in: start a hold, wait for spoken output, press again.
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
    n=$(grep -c "\"$name\"" "$MARKERS" 2>/dev/null || true)
    echo "  $name: $n"
done
