#!/usr/bin/env python3
"""A/B bench for Perry's Finder task: read, click, rename by type_text and by set_value.

cua arm:
  2026-10-28-computer-use-drivers-bench.py cua --driver <cua-driver> --label cua-0.38.0 \
      --fixture-dir <dir Finder shows> --file <name of a file in it> --out out/cua-0.38.0.json \
      [--env CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS=0] [--env CUA_DRIVER_KEY_GAP_MS=2] \
      [--post-action-wait none] [--delivery foreground|background] [--repeats 10] \
      [--ops read,click,rename-type,rename-setvalue,batch]

Peekaboo arm (commands copied from docs/commands/*.md, not run when this was written):
  2026-10-28-computer-use-drivers-bench.py peekaboo --peekaboo <peekaboo> --label peekaboo-4.9.7 \
      --fixture-dir <dir> --file <name> --out out/peekaboo.json [--repeats 10]

Finder must already show a window for the fixture dir. The rename ops rename <file> to
<stem>-bench<ext> and back; the filesystem is checked after every rename, outside the timings.
Spawns the driver the way scripts/lab/cua-bench.py does (same Driver class).
"""

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("cua_bench", os.path.join(HERE, "..", "..", "scripts", "lab", "cua-bench.py"))
cua_bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cua_bench)

FINDER = "com.apple.finder"
PERRY_READ = {"include_screenshot": True, "max_elements": 1000, "timeout_ms": 3000, "tree_format": "elements"}


def now_ms(start):
    return (time.perf_counter() - start) * 1000.0


class Samples:
    def __init__(self):
        self.data = {}
        self.errors = {}
        self.notes = {}

    def add(self, op, ms):
        self.data.setdefault(op, []).append(ms)

    def error(self, op, text):
        self.errors.setdefault(op, []).append(text[:200])

    def report(self):
        out = {}
        for op, values in self.data.items():
            out[op] = dict(cua_bench.stats(values), samples=[round(v, 1) for v in values])
        return {"results": out, "errors": self.errors, "notes": self.notes}


def element_for(elements, label):
    for element in elements:
        if str(element.get("label") or "") == label and element.get("element_token"):
            return element
    for element in elements:
        if label in str(element.get("label") or "") and element.get("element_token"):
            return element
    return None


def rename_field(elements, stem):
    for element in elements:
        if "TextField" in str(element.get("role") or "") and stem in str(element.get("value") or "") and element.get("element_token"):
            return element
    for element in elements:
        if "TextField" in str(element.get("role") or "") and element.get("element_token"):
            return element
    return None


class CuaArm:
    def __init__(self, args):
        self.args = args
        env = dict(item.split("=", 1) for item in args.env)
        self.driver = cua_bench.Driver(args.driver, env, args.manifest, args.permission_mode, args.timeout, True)
        self.samples = Samples()
        self.extra = {"post_action_wait": args.post_action_wait} if args.post_action_wait else {}
        self.delivery = {"delivery_mode": args.delivery}
        self.samples.add("spawn_initialize", self.driver.initialize())
        self.pid, self.window_id = cua_bench.find_window(self.driver, FINDER)
        self.target = {"pid": self.pid, "window_id": self.window_id}
        self.stem, self.ext = os.path.splitext(args.file)

    def call(self, op, name, arguments, record=True):
        result, ms, error = self.driver.call(name, arguments)
        if record:
            self.samples.add(op, ms)
        if error:
            self.samples.error(op, error)
        return result

    def read(self, op, **overrides):
        arguments = dict(PERRY_READ, **self.target)
        arguments.update(overrides)
        arguments = {key: value for key, value in arguments.items() if value is not None}
        result = self.call(op, "get_window_state", arguments)
        if result is None:
            return []
        structured = result.get("structuredContent", {})
        self.samples.notes[op] = {"elements": len(structured.get("elements", [])), "truncated": structured.get("truncated")}
        return structured.get("elements", [])

    def act(self, op, name, arguments, timed=True):
        merged = dict(arguments, **self.target, **self.extra)
        if name in ("click", "type_text", "press_key"):
            merged.update(self.delivery)
        return self.call(op, name, merged, record=timed)

    def read_ops(self):
        repeats = self.args.repeats
        self.read("read_warmup")
        self.samples.data.pop("read_warmup", None)
        variants = [
            ("read_perry", {}),
            ("read_no_screenshot", {"include_screenshot": False}),
            ("read_screenshot_only", {"include_accessibility_tree": False, "tree_format": None, "max_elements": None}),
            ("read_depth6", {"max_depth": 6}),
            ("read_query", {"query": self.args.file}),
        ]
        for op, overrides in variants:
            for _ in range(repeats):
                self.read(op, **overrides)
        self.read("read_since_seed", include_screenshot=False)
        self.samples.data.pop("read_since_seed", None)
        for _ in range(repeats):
            self.read("read_since_latest", include_screenshot=False, since="latest")

    def click_op(self):
        elements = self.read("click_setup_read")
        self.samples.data.pop("click_setup_read", None)
        row = element_for(elements, self.args.file)
        if row is None:
            self.samples.error("click", f"no element labelled {self.args.file}")
            return
        for _ in range(self.args.repeats):
            self.act("click", "click", {"element_token": row["element_token"]})

    def wait_for_name(self, expected):
        deadline = time.perf_counter() + 5
        while time.perf_counter() < deadline:
            if os.path.exists(os.path.join(self.args.fixture_dir, expected)):
                return True
            time.sleep(0.02)
        return False

    def rename_once(self, op, old, new, use_set_value):
        old_stem = os.path.splitext(old)[0]
        started = time.perf_counter()
        elements = self.read(f"{op}_read_before")
        row = element_for(elements, old)
        if row is None:
            self.samples.error(op, f"no row {old}")
            return False
        self.act(f"{op}_click", "click", {"element_token": row["element_token"]})
        self.act(f"{op}_begin", "press_key", {"key": "return"})
        elements = self.read(f"{op}_read_field")
        field = rename_field(elements, old_stem)
        if field is None:
            self.samples.error(op, "no rename field")
            return False
        new_stem = os.path.splitext(new)[0]
        if use_set_value:
            self.call(f"{op}_edit", "set_value", {"element_token": field["element_token"], "value": new_stem, **self.target, **self.extra})
        else:
            self.act(f"{op}_edit", "type_text", {"text": new_stem, "element_token": field["element_token"], "delay_ms": 10})
        self.act(f"{op}_commit", "press_key", {"key": "return"})
        landed = self.wait_for_name(new)
        self.samples.add(f"{op}_total", now_ms(started))
        if not landed:
            self.samples.error(op, f"{new} not on disk")
        return landed

    def rename_op(self, op, use_set_value):
        stem, ext = self.stem, self.ext
        original, renamed = f"{stem}{ext}", f"{stem}-bench{ext}"
        for _ in range(self.args.repeats):
            if not self.rename_once(op, original, renamed, use_set_value):
                break
            if not self.rename_once(op, renamed, original, use_set_value):
                break
        if not os.path.exists(os.path.join(self.args.fixture_dir, original)) and os.path.exists(os.path.join(self.args.fixture_dir, renamed)):
            os.rename(os.path.join(self.args.fixture_dir, renamed), os.path.join(self.args.fixture_dir, original))
            self.samples.error(op, "left renamed; restored on disk, Finder may need a refresh")

    def batch_op(self):
        stem, ext = self.stem, self.ext
        original, renamed = f"{stem}{ext}", f"{stem}-bench{ext}"
        for _ in range(self.args.repeats):
            for old, new in ((original, renamed), (renamed, original)):
                elements = self.read("batch_read_before")
                row = element_for(elements, old)
                if row is None:
                    self.samples.error("batch", f"no row {old}")
                    return
                steps = [
                    {"tool": "click", "args": dict({"element_token": row["element_token"]}, **self.target, **self.delivery)},
                    {"tool": "press_key", "args": dict({"key": "return"}, **self.target, **self.delivery)},
                    {"tool": "type_text", "args": dict({"text": os.path.splitext(new)[0], "delay_ms": 10}, **self.target, **self.delivery)},
                    {"tool": "press_key", "args": dict({"key": "return"}, **self.target, **self.delivery)},
                ]
                self.call("batch_run_steps", "run_steps", {"steps": steps})
                if not self.wait_for_name(new):
                    self.samples.error("batch", f"{new} not on disk")
                    return

    def run(self):
        ops = self.args.ops.split(",")
        try:
            if "read" in ops:
                self.read_ops()
            if "click" in ops:
                self.click_op()
            if "rename-type" in ops:
                self.rename_op("rename_type", False)
            if "rename-setvalue" in ops:
                self.rename_op("rename_setvalue", True)
            if "batch" in ops:
                self.batch_op()
        finally:
            self.driver.close()
        return self.samples.report()


def walk(node, found):
    if isinstance(node, dict):
        found.append(node)
        for value in node.values():
            walk(value, found)
    elif isinstance(node, list):
        for value in node:
            walk(value, found)


class PeekabooArm:
    def __init__(self, args):
        self.args = args
        self.samples = Samples()
        self.stem, self.ext = os.path.splitext(args.file)

    def run_cli(self, op, *cli, record=True):
        started = time.perf_counter()
        process = subprocess.run([self.args.peekaboo, *cli], capture_output=True, text=True, timeout=60)
        ms = now_ms(started)
        if record:
            self.samples.add(op, ms)
        if process.returncode != 0:
            self.samples.error(op, (process.stderr or process.stdout))
        return process.stdout

    def see(self, op, *extra):
        out = self.run_cli(op, "see", "--app", "Finder", "--json", "--max-elements", "1000", *extra)
        try:
            payload = json.loads(out)
        except ValueError:
            self.samples.error(op, "see did not print JSON")
            return None, []
        nodes = []
        walk(payload, nodes)
        elements = [n for n in nodes if n.get("id") or n.get("element_id")]
        self.samples.notes[op] = {"elements": len(elements)}
        return payload, elements

    def find(self, elements, label):
        for element in elements:
            text = " ".join(str(element.get(key) or "") for key in ("label", "title", "description", "value"))
            if label in text:
                return element.get("id") or element.get("element_id")
        return None

    def snapshot_of(self, payload):
        nodes = []
        walk(payload, nodes)
        for node in nodes:
            if node.get("snapshot_id"):
                return node["snapshot_id"]
        return None

    def run(self):
        repeats = self.args.repeats
        self.see("see_warmup", "--no-screenshot", "--tree", "--fresh")
        self.samples.data.pop("see_warmup", None)
        for _ in range(repeats):
            self.see("see_tree_fresh", "--no-screenshot", "--tree", "--fresh")
        for _ in range(repeats):
            self.see("see_tree_cached", "--no-screenshot", "--tree")
        for _ in range(repeats):
            self.see("see_with_screenshot", "--fresh", "--path", "/tmp/peekaboo-bench.png")
        original, renamed = f"{self.stem}{self.ext}", f"{self.stem}-bench{self.ext}"
        for use_set_value in (False, True):
            op = "rename_setvalue" if use_set_value else "rename_type"
            for _ in range(repeats):
                for old, new in ((original, renamed), (renamed, original)):
                    started = time.perf_counter()
                    payload, elements = self.see(f"{op}_see", "--fresh")
                    snapshot = self.snapshot_of(payload) if payload else None
                    row = self.find(elements, old)
                    if row is None or snapshot is None:
                        self.samples.error(op, f"no row or snapshot for {old}")
                        return self.samples.report()
                    self.run_cli(f"{op}_click", "click", "--on", row, "--snapshot", snapshot, "--app", "Finder")
                    self.run_cli(f"{op}_begin", "press", "return", "--app", "Finder")
                    new_stem = os.path.splitext(new)[0]
                    if use_set_value:
                        payload, elements = self.see(f"{op}_see_field", "--fresh")
                        field = next((e for e in elements if "TextField" in str(e.get("role") or e.get("type") or "")), None)
                        if field is None:
                            self.samples.error(op, "no rename field")
                            return self.samples.report()
                        self.run_cli(f"{op}_edit", "set-value", new_stem, "--on", field.get("id") or field.get("element_id"), "--snapshot", self.snapshot_of(payload) or "latest", "--app", "Finder")
                    else:
                        self.run_cli(f"{op}_edit", "type", new_stem, "--app", "Finder")
                    self.run_cli(f"{op}_commit", "press", "return", "--app", "Finder")
                    deadline = time.perf_counter() + 5
                    while time.perf_counter() < deadline and not os.path.exists(os.path.join(self.args.fixture_dir, new)):
                        time.sleep(0.02)
                    self.samples.add(f"{op}_total", now_ms(started))
                    if not os.path.exists(os.path.join(self.args.fixture_dir, new)):
                        self.samples.error(op, f"{new} not on disk")
                        return self.samples.report()
        return self.samples.report()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("arm", choices=["cua", "peekaboo"])
    parser.add_argument("--driver")
    parser.add_argument("--peekaboo")
    parser.add_argument("--label", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--fixture-dir", required=True)
    parser.add_argument("--file", required=True)
    parser.add_argument("--manifest")
    parser.add_argument("--permission-mode", default="standard")
    parser.add_argument("--env", action="append", default=[])
    parser.add_argument("--post-action-wait", choices=["none", "default"])
    parser.add_argument("--delivery", choices=["foreground", "background"], default="foreground")
    parser.add_argument("--repeats", type=int, default=10)
    parser.add_argument("--ops", default="read,click,rename-type,rename-setvalue,batch")
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()
    if not os.path.exists(os.path.join(args.fixture_dir, args.file)):
        sys.exit(f"{args.file} is not in {args.fixture_dir}")
    arm = CuaArm(args) if args.arm == "cua" else PeekabooArm(args)
    report = arm.run()
    report.update(label=args.label, arm=args.arm, env=args.env, post_action_wait=args.post_action_wait, delivery=args.delivery, repeats=args.repeats)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as handle:
        json.dump(report, handle, indent=2)
    for op, stat in report["results"].items():
        print(f"{op:28s} n={stat['n']:<3} p50={stat.get('p50', '-'):<8} p95={stat.get('p95', '-'):<8} max={stat.get('max', '-')}")
    for op, errors in report["errors"].items():
        print(f"ERRORS {op}: {len(errors)} first: {errors[0]}")


if __name__ == "__main__":
    main()
