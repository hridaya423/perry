#!/usr/bin/env python3
"""Raw driver latency: process spawn, cold and warm calls, and per-op cost.

Usage: driver-cli-bench.py --fixture <PerryTortureFixture.app> --ad <label=path> [--ad ...]
       --cua <cua-driver> --manifest <capabilities.yaml> --out <json> [--repeats 30]

Run it from a process that holds Accessibility and Screen Recording (Perry), or every
call reports denied. It launches its own torture fixture and quits it at the end.
"""

import argparse
import json
import os
import platform
import select
import statistics
import subprocess
import tempfile
import time
import uuid


def stats(samples):
    ordered = sorted(samples)
    if not ordered:
        return {"n": 0}

    def pct(p):
        return ordered[min(len(ordered) - 1, round(p * (len(ordered) - 1)))]

    return {"n": len(ordered), "p50": round(pct(0.5), 1), "p95": round(pct(0.95), 1),
            "min": round(ordered[0], 1), "max": round(ordered[-1], 1), "mean": round(statistics.fmean(ordered), 1)}


def timed(argv, env=None):
    started = time.perf_counter()
    proc = subprocess.run(argv, capture_output=True, text=True, env=env)
    elapsed = (time.perf_counter() - started) * 1000
    return elapsed, proc


def envelope(proc):
    try:
        return json.loads(proc.stdout)
    except ValueError:
        return {"ok": False, "error": {"code": "NO_ENVELOPE", "message": proc.stderr[-200:]}}


def launch_fixture(app):
    log = os.path.join(tempfile.gettempdir(), f"perry-bench-{uuid.uuid4().hex[:8]}.log")
    subprocess.run(["open", "-n", "-g", app, "--args", log, "Perry Bench Fixture"], check=True)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if os.path.exists(log):
            for line in open(log):
                if line.startswith("ready "):
                    _, pid, window = line.split()
                    time.sleep(0.8)
                    return int(pid), int(window), log
        time.sleep(0.1)
    raise SystemExit("fixture never became ready")


def count(log, prefix):
    return sum(1 for line in open(log) if line.startswith(prefix))


def bench_agent_desktop(binary, window, log, repeats):
    home = tempfile.mkdtemp(prefix="perry-bench-ad-")
    env = {"AGENT_DESKTOP_HOME": home, "HOME": os.environ["HOME"], "TMPDIR": tempfile.gettempdir()}
    result = {}
    result["exec_version"] = stats([timed([binary, "version"], env)[0] for _ in range(repeats)])
    result["sh_exec_version"] = stats([timed(["/bin/sh", "-c", f"exec '{binary}' version"], env)[0] for _ in range(repeats)])
    result["cold_list_windows"] = stats([timed([binary, "list-windows", "--session", f"cold-{uuid.uuid4().hex[:6]}"], env)[0] for _ in range(repeats)])
    session = f"warm-{uuid.uuid4().hex[:6]}"
    timed([binary, "list-windows", "--session", session], env)
    result["warm_list_windows"] = stats([timed([binary, "list-windows", "--session", session], env)[0] for _ in range(repeats)])
    wid = f"w-{window}"
    snap_samples, snap = [], None
    for _ in range(repeats):
        ms, proc = timed([binary, "snapshot", "--window-id", wid, "--include-bounds", "--max-depth", "12", "-i", "--session", session], env)
        snap_samples.append(ms)
        snap = envelope(proc)
    result["snapshot_i"] = stats(snap_samples)
    result["screenshot"] = stats([timed([binary, "screenshot", "--window-id", wid, "--session", session], env)[0] for _ in range(max(5, repeats // 3))])
    nodes = []

    def walk(node):
        nodes.append(node)
        for child in node.get("children", []):
            walk(child)

    if snap and snap.get("ok"):
        walk(snap["data"]["tree"])
    works = next((n.get("ref_id") for n in nodes if n.get("role") == "button" and n.get("name") == "Works"), None)
    name = next((n.get("ref_id") for n in nodes if n.get("role") == "textfield" and n.get("name") == "Name"), None)
    dispositions = {}
    if works:
        before = count(log, "works")
        samples = []
        for _ in range(repeats):
            ms, proc = timed([binary, "click", works, "--session", session], env)
            samples.append(ms)
            data = envelope(proc)
            delivery = ((data.get("data") or data.get("error") or {}).get("disposition") or {}).get("delivery", "none")
            dispositions[delivery] = dispositions.get(delivery, 0) + 1
        time.sleep(0.5)
        result["click_ref"] = stats(samples)
        result["click_landed"] = f"{count(log, 'works') - before}/{repeats}"
        result["click_dispositions"] = dispositions
    if name:
        result["type_ref"] = stats([timed([binary, "type", name, "--session", session, "--", "perry "], env)[0] for _ in range(repeats)])
    hosts = subprocess.run(["pgrep", "-f", binary], capture_output=True, text=True).stdout.split()
    result["lingering_processes"] = len(hosts)
    rss = 0
    for pid in hosts:
        out = subprocess.run(["ps", "-o", "rss=", "-p", pid], capture_output=True, text=True).stdout.strip()
        rss += int(out or 0)
    result["lingering_rss_mb"] = round(rss / 1024, 1)
    for pid in hosts:
        subprocess.run(["kill", pid], check=False)
    return result


class Mcp:
    def __init__(self, binary, manifest):
        env = {
            "CUA_DRIVER_EMBEDDED": "1", "CUA_DRIVER_HOST_BUNDLE_ID": "dev.perry.Perry",
            "CUA_DRIVER_PERMISSION_MODE": "bounded", "CUA_DRIVER_CAPABILITY_MANIFEST_FILE": manifest,
            "CUA_DRIVER_CAPABILITY_MANIFEST_APPROVED": "1", "CUA_DRIVER_RS_UPDATE_CHECK": "0",
            "CUA_DRIVER_RS_TELEMETRY_ENABLED": "0", "CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS": "200",
            "HOME": os.environ["HOME"], "TMPDIR": tempfile.gettempdir(),
        }
        started = time.perf_counter()
        self.proc = subprocess.Popen([binary, "mcp", "--direct", "--embedded", "--host-bundle-id", "dev.perry.Perry"],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, text=True)
        self.next_id = 0
        self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "bench", "version": "1"}})
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        self.proc.stdin.flush()
        self.startup_ms = (time.perf_counter() - started) * 1000

    def request(self, method, params):
        self.next_id += 1
        wanted = self.next_id
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": wanted, "method": method, "params": params}) + "\n")
        self.proc.stdin.flush()
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.proc.stdout], [], [], 1)
            if not ready:
                continue
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("cua-driver exited")
            message = json.loads(line)
            if message.get("id") == wanted:
                return message
        raise RuntimeError(f"{method} timed out")

    def tool(self, name, arguments):
        started = time.perf_counter()
        message = self.request("tools/call", {"name": name, "arguments": arguments})
        return (time.perf_counter() - started) * 1000, message.get("result") or {}

    def close(self):
        self.proc.terminate()


def bench_cua(binary, manifest, pid, window, log, repeats):
    result = {}
    starts = []
    for _ in range(5):
        client = Mcp(binary, manifest)
        starts.append(client.startup_ms)
        client.close()
    result["mcp_startup"] = stats(starts)
    client = Mcp(binary, manifest)
    session = f"bench-{uuid.uuid4().hex[:6]}"
    client.tool("start_session", {"session": session})
    result["list_windows"] = stats([client.tool("list_windows", {"on_screen_only": False})[0] for _ in range(repeats)])
    base = {"pid": pid, "window_id": window, "session": session}
    state_samples, state = [], {}
    for _ in range(repeats):
        ms, state = client.tool("get_window_state", {**base, "include_screenshot": False, "max_elements": 1000, "timeout_ms": 3000, "tree_format": "elements"})
        state_samples.append(ms)
    result["get_window_state"] = stats(state_samples)
    result["get_window_state_screenshot"] = stats([client.tool("get_window_state", {**base, "include_screenshot": True, "max_elements": 1000, "timeout_ms": 3000, "tree_format": "elements"})[0] for _ in range(max(5, repeats // 3))])
    structured = state.get("structuredContent") or {}
    elements = structured.get("elements") or []
    works = next((e.get("element_token") for e in elements if e.get("label") == "Works" or e.get("title") == "Works"), None)
    if not works:
        result["note"] = f"no Works token; keys={list(structured.keys())[:8]} error={json.dumps(state)[:300]}"
        client.close()
        return result
    before = count(log, "works")
    samples = []
    for _ in range(repeats):
        _, fresh = client.tool("get_window_state", {**base, "include_screenshot": False, "max_elements": 1000, "timeout_ms": 3000, "tree_format": "elements"})
        token = next((e.get("element_token") for e in (fresh.get("structuredContent") or {}).get("elements", []) if e.get("label") == "Works" or e.get("title") == "Works"), works)
        ms, _ = client.tool("click", {**base, "element_token": token, "delivery_mode": "background"})
        samples.append(ms)
    time.sleep(0.5)
    result["click_token"] = stats(samples)
    result["click_landed"] = f"{count(log, 'works') - before}/{repeats}"
    name = next((e.get("element_token") for e in elements if e.get("label") == "Name"), None)
    if name:
        type_samples = []
        for _ in range(repeats):
            _, fresh = client.tool("get_window_state", {**base, "include_screenshot": False, "max_elements": 1000, "timeout_ms": 3000, "tree_format": "elements"})
            token = next((e.get("element_token") for e in (fresh.get("structuredContent") or {}).get("elements", []) if e.get("label") == "Name"), name)
            ms, _ = client.tool("type_text", {**base, "element_token": token, "text": "perry ", "delay_ms": 10, "delivery_mode": "background"})
            type_samples.append(ms)
        result["type_text"] = stats(type_samples)
    rss = subprocess.run(["ps", "-o", "rss=", "-p", str(client.proc.pid)], capture_output=True, text=True).stdout.strip()
    result["resident_rss_mb"] = round(int(rss or 0) / 1024, 1)
    client.close()
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--ad", action="append", default=[])
    parser.add_argument("--cua")
    parser.add_argument("--manifest")
    parser.add_argument("--out", required=True)
    parser.add_argument("--repeats", type=int, default=30)
    args = parser.parse_args()
    pid, window, log = launch_fixture(args.fixture)
    report = {"machine": platform.node(), "repeats": args.repeats, "drivers": {}}
    try:
        for entry in args.ad:
            label, binary = entry.split("=", 1)
            report["drivers"][label] = bench_agent_desktop(binary, window, log, args.repeats)
        if args.cua:
            report["drivers"]["cua"] = bench_cua(args.cua, args.manifest, pid, window, log, args.repeats)
    finally:
        subprocess.run(["kill", str(pid)], check=False)
    with open(args.out, "w") as handle:
        json.dump(report, handle, indent=2)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
