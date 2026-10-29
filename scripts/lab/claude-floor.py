#!/usr/bin/env python3
"""Time Claude Code turns started cold and started from a process that had time to boot.

usage: claude-floor.py [--runs 5] [--model claude-haiku-5-5] [--effort low] [--warm-wait 8]
"""
import argparse
import json
import os
import shutil
import statistics
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("--runs", type=int, default=5)
parser.add_argument("--model", default="claude-haiku-5-5")
parser.add_argument("--effort", default="low")
parser.add_argument("--warm-wait", type=float, default=8.0)
parser.add_argument("--mcp", action="store_true", help="attach a stub stdio MCP server with 30 tools")
parser.add_argument("--prompt-kb", type=int, default=0, help="pad the system prompt to this many KB")
parser.add_argument("--claude", default=shutil.which("claude") or os.path.expanduser("~/.local/bin/claude"))
args = parser.parse_args()

STUB = r"""
import json, sys
tools = [{"name": f"tool_{i}", "description": "A Perry tool. " * 20, "inputSchema": {"type": "object", "properties": {"x": {"type": "string"}}}} for i in range(30)]
for raw in sys.stdin:
    msg = json.loads(raw)
    if "id" not in msg:
        continue
    method = msg.get("method")
    if method == "initialize":
        result = {"protocolVersion": msg["params"]["protocolVersion"], "capabilities": {"tools": {}}, "serverInfo": {"name": "perry", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": tools}
    else:
        result = {}
    print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}), flush=True)
"""
SYSTEM = "You are Perry." + (" Perry helps on the Mac." * (args.prompt_kb * 1024 // 24))

LINE = json.dumps({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "Say hi in two words."}]}}) + "\n"


def turn(wait):
    workspace = tempfile.mkdtemp(prefix="perry-floor-")
    command = [args.claude, "-p", "--output-format", "stream-json", "--input-format", "stream-json", "--verbose",
               "--system-prompt", SYSTEM, "--model", args.model, "--effort", args.effort,
               "--tools", "", "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence"]
    if args.mcp:
        stub = os.path.join(workspace, "stub.py")
        with open(stub, "w") as handle:
            handle.write(STUB)
        config = {"mcpServers": {"perry": {"command": "python3", "args": [stub]}}}
        command += ["--mcp-config", json.dumps(config), "--allowedTools", ",".join(f"mcp__perry__tool_{i}" for i in range(30))]
    process = subprocess.Popen(command, cwd=workspace, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    time.sleep(wait)
    sent = time.monotonic()
    process.stdin.write(LINE)
    process.stdin.close()
    first = done = None
    for raw in process.stdout:
        event = json.loads(raw)
        if event.get("type") == "assistant" and first is None:
            first = time.monotonic() - sent
        if event.get("type") == "result":
            done = time.monotonic() - sent
    process.wait()
    shutil.rmtree(workspace, ignore_errors=True)
    return first, done


def report(name, rows):
    firsts = [r[0] for r in rows if r[0] is not None]
    dones = [r[1] for r in rows if r[1] is not None]
    print(f"{name}: n={len(rows)} first p50={statistics.median(firsts):.2f}s max={max(firsts):.2f}s "
          f"done p50={statistics.median(dones):.2f}s")


cold = [turn(0) for _ in range(args.runs)]
warm = [turn(args.warm_wait) for _ in range(args.runs)]
print(f"model={args.model} effort={args.effort} mcp={args.mcp} prompt_kb={args.prompt_kb}")
report("cold", cold)
report(f"booted {args.warm_wait:.0f}s before input", warm)
