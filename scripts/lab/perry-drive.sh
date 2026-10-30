#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${PERRY_APP:-$REPO_ROOT/build/debug-p1/Build/Products/Debug/Perry.app}"
EVIDENCE_DIR="$REPO_ROOT/docs/evidence/lab"
CUA="${CUA_DRIVER:-cua-driver}"

perry_pid() { pgrep -x Perry | head -1 || true; }

cmd="${1:-}"
case "$cmd" in
    seed-lab-data)
        REAL_AUTH="$HOME/Library/Application Support/Perry/CodexRuntime/auth.json"
        if [ -n "${PERRY_DATA_DIRECTORY:-}" ] && [ ! -f "$PERRY_DATA_DIRECTORY/CodexRuntime/auth.json" ] && [ -f "$REAL_AUTH" ]; then
            mkdir -p "$PERRY_DATA_DIRECTORY/CodexRuntime"
            cp "$REAL_AUTH" "$PERRY_DATA_DIRECTORY/CodexRuntime/auth.json"
        fi
        ;;
    launch)
        shift
        mkdir -p "$EVIDENCE_DIR"
        if pid="$(perry_pid)"; [ -n "$pid" ]; then
            "$0" quit
        fi
        LOG="$EVIDENCE_DIR/perf-$(date -u +%Y%m%dT%H%M%SZ).jsonl"
        "$0" seed-lab-data
        if codesign -dv "$APP" 2>&1 | grep -q "adhoc,runtime"; then
            codesign --force --sign - "$APP/Contents/MacOS/Perry" >/dev/null 2>&1
            echo "perry-drive: re-signed adhoc without hardened runtime for lab launch" >&2
        fi
        ENVS=(--env "PERRY_PERFORMANCE_EVENT_LOG=$LOG" --env "PERRY_ALLOW_SCREEN_CAPTURE=1" --env "PERRY_DATA_DIRECTORY=${PERRY_DATA_DIRECTORY:-}")
        for name in PERRY_AGENT_TRACE PERRY_CLAUDE_CODE_MODEL PERRY_LAB_AUTO_APPROVE PERRY_GUIDE_DRILL_STATE PERRY_OVERLAY_DUMP; do
            [ -n "${!name:-}" ] && ENVS+=(--env "$name=${!name}")
        done
        if [ "$#" -gt 0 ]; then
            open -n "$APP" "${ENVS[@]}" --args "$@"
        else
            open -n "$APP" "${ENVS[@]}"
        fi
        for _ in $(seq 1 30); do
            pid="$(perry_pid)"
            [ -n "$pid" ] && break
            sleep 1
        done
        [ -n "${pid:-}" ] || { echo "perry-drive: Perry did not launch" >&2; exit 1; }
        echo "pid=$pid"
        echo "perf_log=$LOG"
        ;;
    hotkey)
        combo="${2:?usage: perry-drive.sh hotkey <combo e.g. cmd+option+p>}"
        keys="$(printf '%s' "$combo" | tr '+' '\n' | sed 's/^/"/; s/$/"/' | paste -sd, -)"
        "$CUA" call hotkey "{\"keys\":[$keys],\"scope\":\"desktop\"}"
        ;;
    windows)
        pid="$(perry_pid)"
        [ -n "$pid" ] || { echo "perry-drive: Perry is not running" >&2; exit 1; }
        "$CUA" call list_windows "{\"pid\":$pid}"
        ;;
    quit)
        pid="$(perry_pid)"
        [ -n "$pid" ] || exit 0
        osascript -e 'tell application "Perry" to quit' >/dev/null 2>&1 || true
        for _ in $(seq 1 10); do
            kill -0 "$pid" 2>/dev/null || exit 0
            sleep 0.5
        done
        "$CUA" call kill_app "{\"pid\":$pid}" >/dev/null
        ;;
    *)
        echo "usage: perry-drive.sh {launch|hotkey <combo>|windows|quit}" >&2
        exit 2
        ;;
esac
