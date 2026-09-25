#!/usr/bin/env python3
"""Drive a cua-driver MCP stdio process once, like Perry does.

Usage: cua-mcp.py --driver <bin> --manifest <capabilities.yaml>
                  <tool> <json-args> [--timeout SEC]

Prints the tool result JSON (or the refusal/error) to stdout.
"""

import argparse
import json
import os
import subprocess
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--driver", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("tool")
    parser.add_argument("args", help="JSON arguments for the tool")
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--repeat", type=int, default=1,
                        help="call the tool N times; prints per-call ms to stderr")
    options = parser.parse_args()

    env = {
        "CUA_DRIVER_EMBEDDED": "1",
        "CUA_DRIVER_HOST_BUNDLE_ID": "dev.perry.Perry",
        "CUA_DRIVER_PERMISSION_MODE": "bounded",
        "CUA_DRIVER_CAPABILITY_MANIFEST_FILE": os.path.abspath(options.manifest),
        "CUA_DRIVER_CAPABILITY_MANIFEST_APPROVED": "1",
        "CUA_DRIVER_RS_UPDATE_CHECK": "0",
        "CUA_DRIVER_RS_TELEMETRY_ENABLED": "0",
        "HOME": os.environ.get("HOME", ""),
        "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    }
    proc = subprocess.Popen(
        [options.driver, "mcp", "--direct", "--embedded",
         "--host-bundle-id", "dev.perry.Perry"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=env,
    )

    lines: list[dict] = []
    lines_lock = threading.Lock()

    def reader() -> None:
        assert proc.stdout is not None
        for raw in proc.stdout:
            line = raw.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            with lines_lock:
                lines.append(msg)

    threading.Thread(target=reader, daemon=True).start()

    def send(msg: dict) -> None:
        assert proc.stdin is not None
        proc.stdin.write(json.dumps(msg).encode() + b"\n")
        proc.stdin.flush()

    def wait_for(msg_id: int) -> dict | None:
        import time
        deadline = time.monotonic() + options.timeout
        while time.monotonic() < deadline:
            with lines_lock:
                for i, m in enumerate(lines):
                    if m.get("id") == msg_id:
                        lines.pop(i)
                        return m
            time.sleep(0.01)
        return None

    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "perry-lab", "version": "0.1"},
        }})
        init = wait_for(1)
        if init is None:
            print(json.dumps({"error": "initialize timeout / driver refused manifest"}))
            return 1
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        import time
        last = None
        for i in range(options.repeat):
            req_id = 2 + i
            t0 = time.monotonic()
            send({"jsonrpc": "2.0", "id": req_id, "method": "tools/call", "params": {
                "name": options.tool,
                "arguments": json.loads(options.args),
            }})
            resp = wait_for(req_id)
            elapsed = (time.monotonic() - t0) * 1000
            if resp is None:
                print(json.dumps({"error": "tools/call timeout"}))
                return 1
            print(f"call {i}: {elapsed:.0f} ms", file=sys.stderr)
            last = resp
        print(json.dumps(last.get("result", last.get("error", last)), indent=1)[:200000])
        return 0
    finally:
        proc.terminate()


if __name__ == "__main__":
    sys.exit(main())
