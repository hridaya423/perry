import json
import os
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = os.environ.get("PERRY_APP", os.path.join(ROOT, "build/debug-p1/Build/Products/Debug/Perry.app"))
DRIVER = os.environ.get("AGENT_DESKTOP", os.path.join(APP, "Contents/Resources/AgentDesktop/bin/agent-desktop"))
SESSION = os.environ.get("AGENT_DESKTOP_SESSION_NAME", "perry-lab")


class DriverError(RuntimeError):
    def __init__(self, command, code, message):
        super().__init__(f"agent-desktop {command}: {code} {message}")
        self.code = code


def call(*arguments, timeout=30):
    proc = subprocess.run([DRIVER, *map(str, arguments), "--session", SESSION],
                          capture_output=True, text=True, timeout=timeout)
    try:
        envelope = json.loads(proc.stdout)
    except ValueError:
        raise DriverError(arguments[0], "NO_ENVELOPE", proc.stderr.strip() or proc.stdout.strip())
    if not envelope.get("ok"):
        error = envelope.get("error") or {}
        raise DriverError(arguments[0], error.get("code", "UNKNOWN"), error.get("message", ""))
    return envelope.get("data")


def windows(pid=None, app_name=None):
    rows = call("list-windows")
    rows = rows if isinstance(rows, list) else rows.get("windows", [])
    return [w for w in rows
            if (pid is None or w.get("pid") == pid) and (app_name is None or w.get("app_name") == app_name)]


def nodes(window_id, interactive=True):
    arguments = ["snapshot", "--window-id", window_id, "--include-bounds", "--max-depth", "12"]
    if interactive:
        arguments.append("-i")
    data = call(*arguments)
    flat = []

    def walk(node, depth):
        flat.append({**node, "depth": depth})
        for child in node.get("children", []):
            walk(child, depth + 1)

    walk(data["tree"], 0)
    return flat


def text(node):
    return " ".join(str(node.get(key) or "") for key in ("name", "description", "value")).strip()


def find(window_id, needle=None, role=None):
    for node in nodes(window_id):
        if not node.get("ref_id"):
            continue
        if needle and needle not in text(node):
            continue
        if role and node.get("role") != role:
            continue
        return node
    return None


def click(ref):
    return call("click", ref)


def press(combo, window_id=None):
    arguments = ["press", combo]
    arguments += ["--window-id", window_id] if window_id else ["--headed"]
    return call(*arguments)
