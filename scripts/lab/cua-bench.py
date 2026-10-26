#!/usr/bin/env python3
"""Time cua-driver MCP operations the way Perry spawns the driver.

Usage: cua-bench.py --driver <bin> --label <name> --out <json>
                    [--manifest <capabilities.yaml> | --permission-mode standard]
                    [--env KEY=VALUE ...] [--repeats 20]
                    [--ops cold,warm,click,type]
                    [--text-app com.apple.TextEdit] [--click-app com.apple.calculator]

Each operation reports n/p50/p95/max/mean/min in milliseconds plus the raw
samples. Failed calls are counted and excluded from the timings.
"""

import argparse
import json
import os
import platform
import statistics
import subprocess
import sys
import threading
import time

TEXT_APP = "com.apple.TextEdit"
CLICK_APP = "com.apple.calculator"


class Driver:
    def __init__(self, binary, env_extra, manifest, permission_mode, timeout, embedded):
        self.timeout = timeout
        env = {
            "CUA_DRIVER_PERMISSION_MODE": permission_mode,
            "CUA_DRIVER_RS_UPDATE_CHECK": "0",
            "CUA_DRIVER_RS_TELEMETRY_ENABLED": "0",
            "HOME": os.environ.get("HOME", ""),
            "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        }
        if manifest:
            env["CUA_DRIVER_CAPABILITY_MANIFEST_FILE"] = os.path.abspath(manifest)
            env["CUA_DRIVER_CAPABILITY_MANIFEST_APPROVED"] = "1"
        if embedded:
            env["CUA_DRIVER_EMBEDDED"] = "1"
            env["CUA_DRIVER_HOST_BUNDLE_ID"] = "dev.perry.Perry"
        env.update(env_extra)
        command = [binary, "mcp", "--direct"]
        if embedded:
            command += ["--embedded", "--host-bundle-id", "dev.perry.Perry"]
        self.arrivals = {}
        self.cond = threading.Condition()
        self.next_id = 1
        self.started = time.perf_counter()
        self.proc = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for raw in self.proc.stdout:
            now = time.perf_counter()
            try:
                msg = json.loads(raw)
            except ValueError:
                continue
            if "id" in msg:
                with self.cond:
                    self.arrivals[msg["id"]] = (msg, now)
                    self.cond.notify_all()

    def request(self, method, params=None):
        request_id = self.next_id
        self.next_id += 1
        body = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            body["params"] = params
        sent = time.perf_counter()
        self.proc.stdin.write(json.dumps(body).encode() + b"\n")
        self.proc.stdin.flush()
        deadline = sent + self.timeout
        with self.cond:
            while request_id not in self.arrivals:
                remaining = deadline - time.perf_counter()
                if remaining <= 0:
                    raise TimeoutError(method)
                self.cond.wait(remaining)
            msg, arrived = self.arrivals.pop(request_id)
        return msg, (arrived - sent) * 1000.0

    def initialize(self):
        msg, ms = self.request("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "perry-bench", "version": "0.1"},
        })
        if "error" in msg:
            raise RuntimeError(f"initialize refused: {msg['error']}")
        self.proc.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.proc.stdin.flush()
        return ms

    def call(self, name, arguments):
        msg, ms = self.request("tools/call", {"name": name, "arguments": arguments})
        if "error" in msg:
            return None, ms, json.dumps(msg["error"])[:300]
        result = msg.get("result", {})
        if result.get("isError"):
            text = " ".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
            return result, ms, text[:300]
        return result, ms, None

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def stats(samples):
    if not samples:
        return {"n": 0}
    ordered = sorted(samples)

    def pct(p):
        index = max(0, min(len(ordered) - 1, round(p / 100.0 * (len(ordered) - 1))))
        return ordered[index]

    return {
        "n": len(ordered),
        "p50": round(pct(50), 1),
        "p95": round(pct(95), 1),
        "max": round(ordered[-1], 1),
        "mean": round(statistics.fmean(ordered), 1),
        "min": round(ordered[0], 1),
    }


def find_window(driver, bundle_id):
    result, _, error = driver.call("list_apps", {})
    if error:
        raise RuntimeError(f"list_apps: {error}")
    apps = result["structuredContent"].get("apps", [])
    app = next((a for a in apps if a.get("bundle_id") == bundle_id and a.get("running")), None)
    if app is None:
        raise RuntimeError(f"{bundle_id} is not running")
    pid = app["pid"]
    result, _, error = driver.call("list_windows", {"pid": pid, "on_screen_only": False})
    if error:
        raise RuntimeError(f"list_windows: {error}")
    windows = [w for w in result["structuredContent"].get("windows", []) if w.get("pid") == pid]
    windows.sort(key=lambda w: (
        not w.get("is_on_screen", False),
        -(w.get("bounds", {}).get("width", 0) * w.get("bounds", {}).get("height", 0)),
    ))
    if not windows:
        raise RuntimeError(f"{bundle_id} has no window")
    return pid, windows[0]["window_id"]


TREE_FORMAT = None


def state_args(pid, window_id):
    arguments = {
        "pid": pid,
        "window_id": window_id,
        "include_screenshot": True,
        "max_elements": 300,
        "max_depth": 12,
    }
    if TREE_FORMAT:
        arguments["tree_format"] = TREE_FORMAT
    return arguments


def elements_of(result):
    return result["structuredContent"].get("elements", [])


def pick_button(elements, wanted):
    for element in elements:
        label = str(element.get("label") or element.get("title") or "")
        role = str(element.get("role") or "")
        if label == wanted and "Button" in role and element.get("element_token"):
            return element["element_token"]
    for element in elements:
        if str(element.get("label") or "") == wanted and element.get("element_token"):
            return element["element_token"]
    return None


def run(args):
    global TREE_FORMAT
    TREE_FORMAT = args.tree_format
    env_extra = dict(item.split("=", 1) for item in args.env)
    manifest = args.manifest
    mode = "standard" if args.permission_mode == "standard" else "bounded"
    ops = args.ops.split(",")
    report = {
        "label": args.label,
        "driver": args.driver,
        "driver_version": subprocess.run([args.driver, "--version"], capture_output=True, text=True).stdout.strip(),
        "permission_mode": mode,
        "embedded": not args.standalone,
        "tree_format": args.tree_format,
        "manifest": manifest,
        "env": env_extra,
        "repeats": args.repeats,
        "host": platform.node(),
        "macos": platform.mac_ver()[0],
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "results": {},
        "errors": {},
        "preflight": {},
    }

    def make():
        return Driver(args.driver, env_extra, manifest, mode, args.timeout, not args.standalone)

    setup = make()
    try:
        setup.initialize()
        permissions, _, error = setup.call("check_permissions", {})
        report["preflight"]["check_permissions"] = error or permissions.get("structuredContent")
        text_pid, text_window = find_window(setup, args.text_app)
        click_pid, click_window = find_window(setup, args.click_app)
        report["preflight"]["text_target"] = {"pid": text_pid, "window_id": text_window}
        report["preflight"]["click_target"] = {"pid": click_pid, "window_id": click_window}
        probe, ms, error = setup.call("get_window_state", state_args(text_pid, text_window))
        report["preflight"]["get_window_state"] = error or {"ms": round(ms, 1), "elements": len(elements_of(probe))}
        if error:
            raise RuntimeError(f"get_window_state refused: {error}")
    finally:
        setup.close()

    def record_error(op, error):
        report["errors"].setdefault(op, []).append(error)

    if "cold" in ops:
        total, spawn_init, first_state = [], [], []
        for _ in range(args.repeats):
            t0 = time.perf_counter()
            driver = make()
            try:
                init_ms = driver.initialize()
                _, state_ms, error = driver.call("get_window_state", state_args(text_pid, text_window))
                end = time.perf_counter()
                if error:
                    record_error("cold", error)
                else:
                    total.append((end - t0) * 1000.0)
                    spawn_init.append((end - t0) * 1000.0 - state_ms)
                    first_state.append(state_ms)
            except Exception as exc:
                record_error("cold", repr(exc))
            finally:
                driver.close()
        report["results"]["cold_spawn_plus_first_get_window_state"] = {
            **stats(total), "samples_ms": [round(v, 1) for v in total],
        }
        report["results"]["cold_spawn_and_initialize"] = {
            **stats(spawn_init), "samples_ms": [round(v, 1) for v in spawn_init],
        }
        report["results"]["cold_first_get_window_state"] = {
            **stats(first_state), "samples_ms": [round(v, 1) for v in first_state],
        }

    needs_warm = [op for op in ("warm", "click", "type") if op in ops]
    if needs_warm:
        driver = make()
        try:
            driver.initialize()
            driver.call("get_window_state", state_args(text_pid, text_window))
            if "warm" in ops:
                samples = []
                for _ in range(args.repeats):
                    _, ms, error = driver.call("get_window_state", state_args(text_pid, text_window))
                    if error:
                        record_error("warm", error)
                    else:
                        samples.append(ms)
                report["results"]["warm_get_window_state"] = {
                    **stats(samples), "samples_ms": [round(v, 1) for v in samples],
                }
            if "click" in ops:
                samples, landed = [], []
                for index in range(args.repeats):
                    state, _, error = driver.call("get_window_state", state_args(click_pid, click_window))
                    if error:
                        record_error("click", error)
                        continue
                    token = pick_button(elements_of(state), "AC") or pick_button(elements_of(state), "All Clear") \
                        or pick_button(elements_of(state), str(index % 9 + 1))
                    if token is None:
                        record_error("click", "no button token found")
                        continue
                    result, ms, error = driver.call("click", {
                        "element_token": token, "pid": click_pid, "window_id": click_window,
                        "delivery_mode": "background",
                    })
                    if error:
                        record_error("click", error)
                    else:
                        samples.append(ms)
                        landed.append(result.get("structuredContent", {}).get("effect"))
                report["results"]["click_calculator_button"] = {
                    **stats(samples), "samples_ms": [round(v, 1) for v in samples],
                    "effects": sorted({str(v) for v in landed}),
                }
            if "type" in ops:
                samples, verified = [], []
                for _ in range(args.repeats):
                    result, ms, error = driver.call("type_text", {
                        "text": "perry ", "pid": text_pid, "window_id": text_window,
                        "delivery_mode": "background",
                    })
                    if error:
                        record_error("type", error)
                    else:
                        samples.append(ms)
                        verified.append(json.dumps(result.get("structuredContent", {}), sort_keys=True)[:200])
                report["results"]["type_text_textedit"] = {
                    **stats(samples), "samples_ms": [round(v, 1) for v in samples],
                    "result_samples": sorted(set(verified))[:3],
                }
        except Exception as exc:
            record_error("session", repr(exc))
        finally:
            driver.close()

    with open(args.out, "w") as handle:
        json.dump(report, handle, indent=1)
    for name, row in report["results"].items():
        if row.get("n"):
            print(f"{args.label:28s} {name:42s} n={row['n']:3d} p50={row['p50']:8.1f} p95={row['p95']:8.1f} max={row['max']:8.1f}")
        else:
            print(f"{args.label:28s} {name:42s} n=0")
    for op, errors in report["errors"].items():
        print(f"{args.label}: {len(errors)} {op} errors, first: {errors[0]}", file=sys.stderr)
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--driver", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--manifest")
    parser.add_argument("--permission-mode", default="bounded")
    parser.add_argument("--standalone", action="store_true",
                        help="spawn without --embedded, so the driver's own bundle identity owns TCC")
    parser.add_argument("--tree-format", help="get_window_state tree_format (0.38.0 defaults to markdown; Perry needs elements)")
    parser.add_argument("--env", action="append", default=[])
    parser.add_argument("--repeats", type=int, default=20)
    parser.add_argument("--ops", default="cold,warm,click,type")
    parser.add_argument("--text-app", default=TEXT_APP)
    parser.add_argument("--click-app", default=CLICK_APP)
    parser.add_argument("--timeout", type=float, default=30.0)
    return run(parser.parse_args())


if __name__ == "__main__":
    sys.exit(main())
