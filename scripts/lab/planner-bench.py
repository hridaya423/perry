#!/usr/bin/env python3
"""Run Perry's real agent loop on scored desktop tasks with a chosen brain.

Usage: planner-bench.py --brain {claudeCode,local} --label <name> [--tasks T1,T2] [--reps 1]
                        [--timeout 420] [--out docs/evidence/lab/planner-<label>.jsonl]

Each task relaunches the DEBUG Perry.app with --perry-task-drill, resets its
fixture under ~/PerryBench/run, posts the goal through scripts/lab/guide-drill
task, waits for the agent trace to finish, then checks the result.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FIXTURES = REPO / "scripts/fixtures/dependable"
RUN = Path.home() / "PerryBench/run"
DATA = Path.home() / "PerryBench/data"
HELPER = REPO / "build/lab/guide-drill"
DRIVE = REPO / "scripts/lab/perry-drive.sh"
DOMAIN = "dev.perry.Perry"


def sh(command, check=False):
    return subprocess.run(command, shell=True, capture_output=True, text=True, check=check).stdout.strip()


def osa(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True).stdout.strip()


def quit_apps(*names):
    for name in names:
        osa(f'if application "{name}" is running then tell application "{name}" to quit saving no')
    time.sleep(1.5)


def fresh_inbox():
    shutil.copytree(FIXTURES / "finder/inbox", RUN / "inbox")
    quit_apps("Finder")
    sh("open -R " + str(RUN / "inbox/draft-c.txt"))
    time.sleep(2)


def cedar_page():
    page = (FIXTURES / "web/cedar.html").read_text().replace(
        ".textContent='Draft saved for '+document.querySelector('#name').value+': '+document.querySelector('#session').value;",
        ".textContent='Draft saved for '+document.querySelector('#name').value+': '+document.querySelector('#session').value;document.title=document.querySelector('#result').textContent;",
    )
    target = RUN / "cedar.html"
    target.write_text(page)
    quit_apps("Safari")
    sh(f"open -a Safari {target}")
    time.sleep(3)


def preview_brief():
    shutil.copy(FIXTURES / "documents/cedar-brief.pdf", RUN / "cedar-brief.pdf")
    quit_apps("Preview")
    sh(f"open -a Preview {RUN / 'cedar-brief.pdf'}")
    time.sleep(3)


def textedit_meeting():
    shutil.copy(FIXTURES / "notes/meeting.txt", RUN / "meeting.txt")
    quit_apps("TextEdit")
    sh(f"open -a TextEdit {RUN / 'meeting.txt'}")
    time.sleep(2)


def light_mode():
    osa('tell application "System Events" to tell appearance preferences to set dark mode to false')
    quit_apps("System Settings")


def calculator():
    quit_apps("Calculator")
    for key in ("RestoreInputValue", "RestoreResultValue", "LastResultValue"):
        sh(f"defaults delete com.apple.calculator {key}")
    sh("open -a Calculator")
    time.sleep(2)


def files():
    return {p.relative_to(RUN / "inbox").as_posix() for p in (RUN / "inbox").rglob("*") if p.is_file() and p.name != ".DS_Store"}


TASKS = {
    "rename": dict(
        goal="In the Finder window, rename draft-a.txt to cedar-a.txt.",
        setup=fresh_inbox,
        check=lambda answer, tools: files() == {"cedar-a.txt", "draft-b.txt", "draft-c.txt"},
    ),
    "folder": dict(
        goal="In the Finder window, create a folder called Review and move draft-b.txt and draft-c.txt into it.",
        setup=fresh_inbox,
        check=lambda answer, tools: files() == {"draft-a.txt", "Review/draft-b.txt", "Review/draft-c.txt"},
    ),
    "pdf": dict(
        goal="In the open Cedar brief, what is the archive code and who owns the next review?",
        setup=preview_brief,
        check=lambda answer, tools: "LANTERN-27" in answer.upper() and "ada" in answer.lower(),
    ),
    "table": dict(
        goal="On this web page, which session has the most open places, and how many more than Music?",
        setup=cedar_page,
        check=lambda answer, tools: "drawing" in answer.lower() and bool(re.search(r"\b7\b|seven", answer.lower())),
    ),
    "form": dict(
        goal="On this web page, fill in the form for Noor Patel in the Writing session and save the local draft.",
        setup=cedar_page,
        check=lambda answer, tools: "Noor Patel: Writing" in osa('tell application "Safari" to get name of front document'),
    ),
    "textedit": dict(
        goal="In the open TextEdit document, add a last line that says Reviewed by Perry, then save the document.",
        setup=textedit_meeting,
        check=lambda answer, tools: (RUN / "meeting.txt").read_text().rstrip().endswith("Reviewed by Perry")
        and "Noor owns the venue checklist" in (RUN / "meeting.txt").read_text(),
    ),
    "darkmode": dict(
        goal="Turn on Dark Mode for the whole Mac.",
        setup=light_mode,
        check=lambda answer, tools: osa('tell application "System Events" to tell appearance preferences to get dark mode') == "true",
        teardown=light_mode,
    ),
    "calculator": dict(
        goal="Use Calculator to work out 127 times 49 and tell me the result.",
        setup=calculator,
        check=lambda answer, tools: "6223" in answer.replace(",", "") and any(row["tool"].startswith("ui.") for row in tools),
    ),
}


def run_task(name, task, args, out):
    sh(f"{DRIVE} quit")
    shutil.rmtree(RUN, ignore_errors=True)
    RUN.mkdir(parents=True)
    task["setup"]()
    trace = RUN / "trace.jsonl"
    env = dict(os.environ, PERRY_DATA_DIRECTORY=str(DATA), PERRY_AGENT_TRACE=str(trace), PERRY_CLAUDE_CODE_MODEL=args.claude_model, PERRY_LAB_AUTO_APPROVE="1")
    subprocess.run([str(DRIVE), "launch", "--perry-task-drill"], env=env, capture_output=True, text=True)
    time.sleep(args.settle)
    started = time.time()
    command = task["goal"] if name in ("pdf", "table") else "Do this for me: " + task["goal"]
    subprocess.run([str(HELPER), "task", command])
    finished = None
    rows = []
    while time.time() - started < args.timeout:
        time.sleep(2)
        if trace.exists():
            rows = [json.loads(line) for line in trace.read_text().splitlines() if line.strip()]
            finished = next((row["finished"] for row in rows if "finished" in row), None)
            if finished:
                break
    seconds = round(time.time() - started, 1)
    answer = "".join(row.get("text", "") for row in rows)
    tools = [row for row in rows if "tool" in row]
    try:
        passed = bool(task["check"](answer, tools))
    except Exception as error:
        passed = False
        answer += f" [check error: {error}]"
    record = {
        "label": args.label, "brain": args.brain, "task": name, "passed": passed, "finished": finished or "timeout",
        "seconds": seconds, "tool_calls": len(tools), "tool_errors": sum(1 for row in rows if row.get("error")),
        "describe_calls": sum(1 for row in tools if isinstance(row.get("arguments"), dict) and "describe" in row["arguments"]),
        "approvals": sum(1 for row in rows if row.get("note", "").startswith("approval asked")),
        "tools": [row["tool"] for row in tools], "answer": answer[-400:],
    }
    if trace.exists():
        stem = f"{out.stem}-{name}-{int(started)}"
        shutil.copy(trace, out.with_name(f"{stem}.trace.jsonl"))
        for image in RUN.glob("trace.jsonl.*"):
            shutil.copy(image, out.with_name(f"{stem}.{image.name}"))
    with out.open("a") as handle:
        handle.write(json.dumps(record) + "\n")
    print(json.dumps({k: record[k] for k in ("task", "passed", "finished", "seconds", "tool_calls", "describe_calls")}), flush=True)
    task.get("teardown", lambda: None)()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--brain", choices=["claudeCode", "local"], required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--tasks", default=",".join(TASKS))
    parser.add_argument("--reps", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=420)
    parser.add_argument("--settle", type=float, default=8)
    parser.add_argument("--claude-model", default="claude-haiku-5-5")
    parser.add_argument("--out")
    args = parser.parse_args()
    out = Path(args.out or REPO / f"docs/evidence/lab/planner-{args.label}.jsonl")
    out.parent.mkdir(parents=True, exist_ok=True)
    HELPER.parent.mkdir(parents=True, exist_ok=True)
    source = REPO / "scripts/lab/guide-drill.swift"
    if not HELPER.exists() or source.stat().st_mtime > HELPER.stat().st_mtime:
        subprocess.run(["swiftc", "-O", "-o", str(HELPER), str(source)], check=True)
    sh(f"defaults write {DOMAIN} perry.brain.modelChoice {args.brain}")
    sh(f"defaults write {DOMAIN} perry.onboarding.completed -bool true")
    for _ in range(args.reps):
        for name in args.tasks.split(","):
            run_task(name, TASKS[name], args, out)
    sh(f"{DRIVE} quit")


if __name__ == "__main__":
    main()
