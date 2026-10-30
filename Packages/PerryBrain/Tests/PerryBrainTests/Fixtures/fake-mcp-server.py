#!/usr/bin/env python3
import json
import sys

TOOLS_PAGE_1 = [
    {
        "name": "search",
        "description": "Search things",
        "inputSchema": {
            "type": "object",
            "properties": {"q": {"type": "string"}},
            "required": ["q"],
        },
        "annotations": {"readOnlyHint": True},
    }
]
TOOLS_PAGE_2 = [
    {
        "name": "mutate",
        "description": "Change things",
        "inputSchema": {"type": "object"},
    }
]


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
    except ValueError:
        continue
    method = req.get("method", "")
    rid = req.get("id")
    if rid is None:
        continue
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "Fake Tools", "version": "1.0"},
        }})
    elif method == "tools/list":
        params = req.get("params") or {}
        if params.get("cursor") == "page2":
            send({"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS_PAGE_2}})
        else:
            send({"jsonrpc": "2.0", "id": rid,
                  "result": {"tools": TOOLS_PAGE_1, "nextCursor": "page2"}})
    elif method == "tools/call":
        params = req.get("params") or {}
        name = params.get("name", "")
        if name == "fail_tool":
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "content": [{"type": "text", "text": "boom"}],
                "isError": True,
            }})
        else:
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "content": [{"type": "text", "text": json.dumps({
                    "name": name,
                    "arguments": params.get("arguments", {}),
                })}],
            }})
    elif method == "ping":
        send({"jsonrpc": "2.0", "id": rid, "result": {}})
    else:
        send({"jsonrpc": "2.0", "id": rid,
              "error": {"code": -32601, "message": "unknown method"}})
