#!/bin/bash
# perry-drive.sh, thin lab driver for the debug Perry.app.
#   launch            open Perry with PERRY_PERFORMANCE_EVENT_LOG set; echoes the log path
#   hotkey <combo>    send a chord like cmd+option+p (via cua-driver hotkey, desktop-scoped)
#   windows           list Perry's windows (cua-driver list_windows)
#   quit              cooperative quit, then cua-driver kill_app fallback
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${PERRY_APP:-$REPO_ROOT/build/debug-p1/Build/Products/Debug/Perry.app}"
EVIDENCE_DIR="$REPO_ROOT/docs/evidence/lab"
CUA="${CUA_DRIVER:-cua-driver}"

perry_pid() { pgrep -x Perry | head -1 || true; }

cmd="${1:-}"
case "$cmd" in
    launch)
        shift
        mkdir -p "$EVIDENCE_DIR"
        if pid="$(perry_pid)"; [ -n "$pid" ]; then
            "$0" quit
        fi
        LOG="$EVIDENCE_DIR/perf-$(date -u +%Y%m%dT%H%M%SZ).jsonl"
        # Adhoc+runtime Release builds cannot load adhoc frameworks (each "-"
        # signature is its own team); strip the runtime flag for lab launches.
        if codesign -dv "$APP" 2>&1 | grep -q "adhoc,runtime"; then
            codesign --force --sign - "$APP/Contents/MacOS/Perry" >/dev/null 2>&1
            echo "perry-drive: re-signed adhoc without hardened runtime for lab launch" >&2
        fi
        # Lab runs opt into screen capture — Perry chrome is share-hidden
        # by default (PerryWindowChrome.applyChrome) and evidence tooling
        # must be able to record it.
        if [ "$#" -gt 0 ]; then
            open -n "$APP" --env "PERRY_PERFORMANCE_EVENT_LOG=$LOG" --env "PERRY_ALLOW_SCREEN_CAPTURE=1" --args "$@"
        else
            open -n "$APP" --env "PERRY_PERFORMANCE_EVENT_LOG=$LOG" --env "PERRY_ALLOW_SCREEN_CAPTURE=1"
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
