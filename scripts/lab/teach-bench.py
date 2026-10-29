#!/usr/bin/env python3
"""Score Perry's teaching on real apps with the real model planner.
Usage: teach-bench.py --label <name> [--cases C1,C2] [--claude-model M] [--out path]
Guide cases relaunch the DEBUG Perry.app with --perry-guide-live, post the goal,
then act as the user: each step's mark is captured from the screen and a real
click lands on its centre. A case passes when the app ends in the goal state.
Draw cases ask the agent to mark things without acting and capture the marks.
"""
import argparse
import base64
import importlib.util
import json
import re
import os
import subprocess
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("bench", REPO / "scripts/lab/planner-bench.py")
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)

STATE = bench.RUN.parent / "guide-state.json"
OVERLAYS = bench.RUN.parent / "overlays.jsonl"
DRIVER = os.path.expanduser("~/.local/bin/cua-driver")
DRAW_TOOLS = ("point", "ring", "arrow", "underline", "caption", "path")


def driver(name, arguments):
    out = subprocess.run([DRIVER, "call", name], input=json.dumps(arguments), capture_output=True, text=True).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {}


def capture(path):
    shot = driver("get_desktop_state", {})
    if shot.get("screenshot_png_b64"):
        path.write_bytes(base64.b64decode(shot["screenshot_png_b64"]))
        return path.name
    return None


def calculator_result():
    window = next(w for w in driver("list_windows", {"on_screen_only": True}).get("windows", [])
                  if w.get("app_name") == "Calculator" and w["bounds"]["width"] > 200)
    tree = driver("get_window_state", {"pid": window["pid"], "window_id": window["window_id"]}).get("tree_markdown", "")
    match = re.search(r'AXStaticText = "([^"]*)" \(Edit field\)', tree)
    value = match.group(1).replace(",", "").replace("\u200e", "").strip() if match else ""
    print(json.dumps(dict(calculator_display=value)), flush=True)
    return value


def dark_mode():
    return bench.osa('tell application "System Events" to tell appearance preferences to get dark mode') == "true"


def settings_open():
    bench.light_mode()
    bench.sh("open -b com.apple.systempreferences")
    time.sleep(3)


def close_finder_windows():
    for _ in range(40):
        windows = [w for w in driver("list_windows", {"on_screen_only": True}).get("windows", [])
                   if w.get("app_name") == "Finder" and w["bounds"]["width"] > 200]
        if not windows:
            return
        driver("invoke_menu", {"pid": windows[0]["pid"], "window_id": windows[0]["window_id"], "path": ["File", "Close Window"]})
        time.sleep(0.3)


def hidden_path_bar():
    bench.sh("defaults write com.apple.finder ShowPathbar -bool false")
    close_finder_windows()
    bench.fresh_inbox()
    finder = [w for w in driver("list_windows", {"on_screen_only": False}).get("windows", [])
              if w.get("app_name") == "Finder" and w["bounds"]["width"] > 200]
    print(json.dumps(dict(finder_windows=len(finder))), flush=True)


GUIDE = {
    "darkmode": dict(
        goal="Show me how to turn on Dark Mode.",
        setup=settings_open,
        check=dark_mode,
        teardown=bench.light_mode,
    ),
    "calculator": dict(
        goal="Show me how to work out 12 times 7 in Calculator.",
        setup=bench.calculator,
        check=lambda: calculator_result() == "84",
    ),
    "pathbar": dict(
        goal="Show me how to show the path bar in this Finder window.",
        setup=hidden_path_bar,
        check=lambda: bench.sh("defaults read com.apple.finder ShowPathbar") == "1",
    ),
}

DRAW = {
    "circle": dict(
        goal="Without pressing anything, circle the 7 key in Calculator and put an arrow on the equals key.",
        setup=bench.calculator,
    ),
    "point": dict(
        goal="Without changing anything, point at the setting in System Settings that turns on Dark Mode.",
        setup=settings_open,
    ),
}


TALK = {
    "talk-calc": dict(
        app="Calculator", offset=(142, 157), setup=bench.calculator,
        say="What does this button do? Circle it for me.",
    ),
    "talk-settings": dict(
        app="System Settings", offset=(73, 448), setup=settings_open,
        say="Where do I turn on dark mode from here? Show me.",
    ),
}
HOLD = bench.REPO / "build/lab/talk-hold"


def overlay_rows():
    try:
        return [json.loads(line) for line in OVERLAYS.read_text().splitlines() if line.strip()]
    except OSError:
        return []


def window_point(app, offset):
    window = next(w for w in driver("list_windows", {"on_screen_only": True}).get("windows", [])
                  if w.get("app_name") == app and w["bounds"]["width"] > 200)
    return window["bounds"]["x"] + offset[0], window["bounds"]["y"] + offset[1]


def launch(args, *flags, extra_env=None):
    bench.sh(f"{bench.DRIVE} quit")
    OVERLAYS.unlink(missing_ok=True)
    env = dict(os.environ, PERRY_DATA_DIRECTORY=str(bench.DATA), PERRY_CLAUDE_CODE_MODEL=args.claude_model,
               PERRY_OVERLAY_DUMP=str(OVERLAYS), **(extra_env or {}))
    subprocess.run([str(bench.DRIVE), "launch", *flags], env=env, capture_output=True, text=True)
    time.sleep(args.settle)


def read_state(after, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            record = json.loads(STATE.read_text())
            if record.get("seq", 0) > after:
                return record
        except (OSError, ValueError):
            pass
        time.sleep(0.1)
    return None


def run_guide(name, case, args, out):
    bench.shutil.rmtree(bench.RUN, ignore_errors=True)
    bench.RUN.mkdir(parents=True)
    STATE.unlink(missing_ok=True)
    case["setup"]()
    trace = out.with_name(f"{out.stem}-{name}-{int(time.time())}-trace.jsonl")
    trace.unlink(missing_ok=True)
    launch(args, "--perry-guide-live", extra_env={"PERRY_GUIDE_DRILL_STATE": str(STATE), "PERRY_AGENT_TRACE": str(trace)})
    started = time.time()
    subprocess.run([str(bench.HELPER), "start", case["goal"]])
    steps, statuses, seq, dones, step_dones = [], [], 0, 0, 0
    stem = f"{out.stem}-{name}-{int(started)}"
    while len(steps) < args.max_steps and time.time() - started < args.timeout:
        record = read_state(seq, args.step_timeout)
        if record is None:
            break
        seq = record["seq"]
        if "status" in record:
            statuses.append(record["status"])
            if "choose Done" in record["status"]:
                if step_dones >= 2:
                    break
                step_dones += 1
                dones += 1
                subprocess.run([str(bench.HELPER), "done"])
            continue
        if record.get("done"):
            break
        time.sleep(args.click_delay)
        shot = capture(out.with_name(f"{stem}-step{len(steps) + 1}.png"))
        step = {k: record.get(k) for k in ("instruction", "targetLabel", "targetRole", "targetID", "postcondition", "x", "y", "w", "h")}
        step.update(seconds=round(time.time() - started, 1), shot=shot)
        steps.append(step)
        if not record.get("hasTarget"):
            break
        x, y = record["x"] + record["w"] / 2, record["y"] + record["h"] / 2
        subprocess.run([str(bench.HELPER), "tap", f"{x:.1f}", f"{y:.1f}"])
        step_dones = 0
        time.sleep(1.2)
        step["after"] = capture(out.with_name(f"{stem}-step{len(steps)}-after.png"))
    time.sleep(1.5)
    passed = bool(case["check"]())
    subprocess.run([str(bench.HELPER), "stop"])
    record = dict(label=args.label, mode="guide", case=name, passed=passed, seconds=round(time.time() - started, 1),
                  steps=steps, dones=dones, statuses=statuses[-5:])
    with out.open("a") as handle:
        handle.write(json.dumps(record) + "\n")
    print(json.dumps(dict(case=name, passed=passed, steps=len(steps), dones=dones, seconds=record["seconds"],
                          marks=[(s["instruction"] or "")[:60] + " -> " + (s["targetLabel"] or "?") for s in steps])), flush=True)
    case.get("teardown", lambda: None)()


def run_draw(name, case, args, out):
    bench.shutil.rmtree(bench.RUN, ignore_errors=True)
    bench.RUN.mkdir(parents=True)
    case["setup"]()
    trace = bench.RUN.parent / "trace.jsonl"
    for old in bench.RUN.parent.glob("trace.jsonl*"):
        old.unlink()
    launch(args, "--perry-task-drill", extra_env={"PERRY_AGENT_TRACE": str(trace), "PERRY_LAB_AUTO_APPROVE": "1"})
    started = time.time()
    subprocess.run([str(bench.HELPER), "task", case["goal"]])
    stem = f"{out.stem}-{name}-{int(started)}"
    rows, shots, finished_at = [], [], None
    while time.time() - started < args.timeout:
        if trace.exists():
            rows = [json.loads(line) for line in trace.read_text().splitlines() if line.strip()]
        if any(row.get("tool") in DRAW_TOOLS for row in rows) and len(shots) < 12:
            shots.append(capture(out.with_name(f"{stem}-t{time.time() - started:04.1f}.png")))
        else:
            time.sleep(0.3)
        if finished_at is None and any("finished" in row for row in rows):
            finished_at = time.time()
        if finished_at and time.time() - finished_at > 4:
            break
    calls = [dict(tool=row["tool"], arguments=row.get("arguments")) for row in rows if "tool" in row]
    errors = [row.get("result", "")[:200] for row in rows if row.get("error")]
    record = dict(label=args.label, mode="draw", case=name, seconds=round(time.time() - started, 1), calls=calls,
                  errors=errors, shots=shots, answer="".join(row.get("text", "") for row in rows)[-300:])
    with out.open("a") as handle:
        handle.write(json.dumps(record) + "\n")
    print(json.dumps(dict(case=name, seconds=record["seconds"], calls=calls, errors=errors, shots=shots)), flush=True)


def run_talk(name, case, args, out):
    case["setup"]()
    trace = bench.RUN.parent / "trace.jsonl"
    for old in bench.RUN.parent.glob("trace.jsonl*"):
        old.unlink()
    launch(args, "--perry-talk-drill", "--perry-talk-script", case["say"], extra_env={"PERRY_AGENT_TRACE": str(trace)})
    bench.sh(f"open -a '{case['app']}'")
    time.sleep(1.5)
    x, y = window_point(case["app"], case["offset"])
    started = time.time()
    stem = f"{out.stem}-{name}-{int(started)}"
    subprocess.run([str(HOLD), f"{x:.0f}", f"{y:.0f}", "1.6"], capture_output=True)
    shots = []
    while time.time() - started < args.talk_seconds:
        shots.append(capture(out.with_name(f"{stem}-t{time.time() - started:04.1f}.png")))
        time.sleep(0.8)
    rows = [json.loads(line) for line in trace.read_text().splitlines() if line.strip()] if trace.exists() else []
    calls = [dict(tool=row["tool"], arguments=row.get("arguments")) for row in rows if "tool" in row]
    errors = [row.get("result", "")[:200] for row in rows if row.get("error")]
    answer = "".join(row.get("text", "") for row in rows)[-300:]
    record = dict(label=args.label, mode="talk", case=name, target=[x, y], shots=shots, overlays=overlay_rows(),
                  calls=calls, errors=errors, answer=answer)
    with out.open("a") as handle:
        handle.write(json.dumps(record) + "\n")
    print(json.dumps(dict(case=name, target=[round(x), round(y)], shots=len(shots), calls=calls, errors=errors,
                          marked=any(row["overlays"] for row in record["overlays"]), answer=answer)), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    parser.add_argument("--cases", default=",".join(list(GUIDE) + list(DRAW) + list(TALK)))
    parser.add_argument("--talk-seconds", type=float, default=25)
    parser.add_argument("--click-delay", type=float, default=0.8, help="seconds a guide step waits before the capture and click")
    parser.add_argument("--claude-model", default="claude-sonnet-5-5")
    parser.add_argument("--settle", type=float, default=8)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--step-timeout", type=float, default=45)
    parser.add_argument("--max-steps", type=int, default=10)
    parser.add_argument("--out")
    args = parser.parse_args()
    out = Path(args.out or REPO / f"docs/evidence/lab/teach-{args.label}.jsonl")
    out.parent.mkdir(parents=True, exist_ok=True)
    if not HOLD.exists():
        subprocess.run(["swiftc", "-O", "-o", str(HOLD), str(REPO / "scripts/lab/talk-hold.swift")], check=True)
    source = REPO / "scripts/lab/guide-drill.swift"
    if not bench.HELPER.exists() or source.stat().st_mtime > bench.HELPER.stat().st_mtime:
        bench.HELPER.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", "-o", str(bench.HELPER), str(source)], check=True)
    bench.sh(f"defaults write {bench.DOMAIN} perry.brain.modelChoice claudeCode")
    bench.sh(f"defaults write {bench.DOMAIN} perry.onboarding.completed -bool true")
    for name in args.cases.split(","):
        if name in GUIDE:
            run_guide(name, GUIDE[name], args, out)
        elif name in TALK:
            run_talk(name, TALK[name], args, out)
        else:
            run_draw(name, DRAW[name], args, out)
    bench.sh(f"{bench.DRIVE} quit")


if __name__ == "__main__":
    main()
