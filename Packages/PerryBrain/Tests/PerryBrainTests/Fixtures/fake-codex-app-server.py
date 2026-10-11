#!/usr/bin/env python3
# Scripted `codex app-server` stand-in for PerryBrain tests. Speaks
# newline-delimited JSON-RPC on stdio, driven by SCENARIO:
#   a = signed out; account/login/start -> authUrl + login completed notify
#   b = turn streams 3 deltas + token usage + turn/completed
#   c = server issues item/tool/call, asserts client response, completes turn
#   d = exits mid-turn after one delta
#   e = waits for turn/interrupt after turn/start, then turn/completed interrupted
#   stale-turn = a thread's second turn/start errors "unknown thread",
#                simulating a thread the server has forgotten
# Every received message is logged as JSONL to FAKE_LOG (if set).
import json
import os
import signal
import sys
import threading
import time

SCENARIO = os.environ.get("SCENARIO", "b")
STATE_FILE = os.environ.get("FAKE_STATE", "")


def effective_scenario():
    if SCENARIO == "d" and STATE_FILE:
        if os.path.exists(STATE_FILE):
            return "b"
        open(STATE_FILE, "w").write("once")
        return "d"
    return SCENARIO
LOG_PATH = os.environ.get("FAKE_LOG", "")
LOG_LOCK = threading.Lock()


def log(message):
    if not LOG_PATH:
        return
    with LOG_LOCK:
        parent = os.path.dirname(LOG_PATH)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(LOG_PATH, "a") as fh:
            fh.write(json.dumps(message) + "\n")


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def read_line():
    line = sys.stdin.readline()
    if not line:
        return None
    return json.loads(line)


def respond(request_id, result):
    send({"id": request_id, "result": result})


def respond_error(request_id, message):
    send({"id": request_id, "error": {"code": -32000, "message": message}})


def notify(method, params):
    send({"method": method, "params": params})


def handle_request(message):
    method = message.get("method")
    request_id = message.get("id")
    params = message.get("params") or {}
    log(message)

    if method == "initialize":
        if SCENARIO == "delayed-initialize":
            time.sleep(0.3)
        if SCENARIO == "blocked-initialize":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            log({"blocked_pid": os.getpid()})
            time.sleep(60)
        respond(request_id, {"userAgent": "fake-codex/0.0.0"})
        return

    if method == "account/read":
        if SCENARIO == "a":
            respond(request_id, {"requiresOpenaiAuth": True, "account": None})
        else:
            respond(request_id, {
                "requiresOpenaiAuth": True,
                "account": {"type": "chatgpt", "email": "tester@example.com", "planType": "pro"},
            })
        return

    if method == "account/login/start":
        respond(request_id, {
            "type": "chatgpt",
            "authUrl": "https://example.invalid/auth?loginId=login-1",
            "loginId": "login-1",
        })
        if SCENARIO == "a":
            def complete():
                time.sleep(0.2)
                notify("account/login/completed", {"success": True, "loginId": "login-1"})
            threading.Thread(target=complete, daemon=True).start()
        return

    if method == "account/login/cancel":
        respond(request_id, {"status": "canceled"})
        return

    if method == "account/logout":
        respond(request_id, {})
        return

    if method == "account/rateLimits/read":
        respond(request_id, {
            "rateLimits": {
                "planType": "pro",
                "primary": {"usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1893456000},
                "secondary": {"usedPercent": 10, "windowDurationMins": 10080, "resetsAt": 1894060800},
            },
            "rateLimitsByLimitId": None,
        })
        return

    if method == "model/list":
        respond(request_id, {
            "data": [{
                "id": "gpt-5.5",
                "model": "gpt-5.5",
                "displayName": "GPT-5.5",
                "description": "fake",
                "hidden": False,
                "isDefault": True,
                "defaultReasoningEffort": "medium",
                "supportedReasoningEfforts": [{"reasoningEffort": "low"}, {"reasoningEffort": "medium"}],
                "inputModalities": ["text", "image"],
            }],
            "nextCursor": None,
        })
        return

    if method == "thread/start":
        state["seq"] = state.get("seq", 0) + 1
        tid = "thr_%d" % state["seq"]
        state["dynamicTools"] = params.get("dynamicTools")
        state["threadId"] = tid
        respond(request_id, {
            "approvalPolicy": "never",
            "approvalsReviewer": "user",
            "cwd": params.get("cwd") or "/tmp",
            "model": params.get("model") or "gpt-5.5",
            "modelProvider": "openai",
            "sandbox": {"type": "readOnly"},
            "thread": {"id": tid},
        })
        return

    if method == "turn/start":
        tid = params.get("threadId", "thr_1")
        state["turnId"] = "turn_1"
        state["turnThread"] = tid
        state["threadTurns"][tid] = state["threadTurns"].get(tid, 0) + 1
        if SCENARIO == "stale-turn" and tid == "thr_1" and state["threadTurns"][tid] > 1:
            respond_error(request_id, "unknown thread %s" % tid)
            return
        respond(request_id, {"turn": {"id": "turn_1", "status": "inProgress", "items": []}})
        scenario = effective_scenario()
        if scenario in ("missing-status", "unknown-status"):
            turn = {"id": "turn_1", "items": []}
            if scenario == "unknown-status":
                turn["status"] = "unexpected"
            notify("turn/completed", {"threadId": tid, "turn": turn})
        elif scenario in ("b", "stale-turn"):
            for delta in ["Hello", " from", " fake-codex"]:
                notify("item/agentMessage/delta", {
                    "threadId": tid, "turnId": "turn_1", "itemId": "it_1", "delta": delta,
                })
            notify("thread/tokenUsage/updated", {
                "threadId": tid, "turnId": "turn_1",
                "tokenUsage": {
                    "total": {"cachedInputTokens": 0, "inputTokens": 30, "outputTokens": 9,
                              "reasoningOutputTokens": 0, "totalTokens": 39},
                    "last": {"cachedInputTokens": 0, "inputTokens": 30, "outputTokens": 9,
                             "reasoningOutputTokens": 0, "totalTokens": 39},
                },
            })
            notify("turn/completed", {
                "threadId": tid,
                "turn": {"id": "turn_1", "status": "completed", "items": []},
            })
        elif scenario == "c":
            send({
                "id": 9001, "method": "item/tool/call",
                "params": {
                    "threadId": tid, "turnId": "turn_1", "callId": "call_1",
                    "tool": state["dynamicTools"][0]["name"], "arguments": {"city": "Paris"},
                },
            })
        elif scenario == "d":
            notify("item/agentMessage/delta", {
                "threadId": tid, "turnId": "turn_1", "itemId": "it_1", "delta": "partial",
            })
            sys.stdout.flush()
            os._exit(0)
        elif scenario == "e":
            pass
        return

    if method == "turn/interrupt":
        respond(request_id, {})
        notify("turn/completed", {
            "threadId": params.get("threadId", "thr_1"),
            "turn": {"id": params.get("turnId", "turn_1"), "status": "interrupted", "items": []},
        })
        return

    respond(request_id, {})


state = {"dynamicTools": None, "threadId": None, "turnId": None, "turnThread": None,
        "seq": 0, "threadTurns": {}}


def main():
    log({"fake": "started", "scenario": SCENARIO})
    while True:
        message = read_line()
        if message is None:
            return
        if "id" in message and "result" in message or "id" in message and "error" in message:
            # response to a server request (e.g. item/tool/call in scenario c)
            log(message)
            if message.get("id") == 9001 and SCENARIO == "c":
                result = message.get("result", {})
                items = result.get("contentItems", [])
                ok = bool(result.get("success")) and items and items[0].get("text") == "sunny"
                if not ok:
                    sys.stderr.write("tool call response assertion failed: %s\n" % message)
                    os._exit(3)
                notify("item/agentMessage/delta", {
                    "threadId": state["turnThread"] or "thr_1", "turnId": "turn_1",
                    "itemId": "it_2", "delta": "It is sunny.",
                })
                notify("turn/completed", {
                    "threadId": state["turnThread"] or "thr_1",
                    "turn": {"id": "turn_1", "status": "completed", "items": []},
                })
            continue
        if "method" in message and "id" not in message:
            log(message)
            continue
        if "method" in message and "id" in message:
            handle_request(message)


if __name__ == "__main__":
    main()
