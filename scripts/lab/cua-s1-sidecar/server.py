#!/usr/bin/env python3
"""cua-s1 sidecar — Phase 9 experiment (scripts/lab/cua-s1-sidecar/).

Serves POST /choose on loopback. This scaffold
defines the wire contract and the benchmark harness hook; the scoring
backend is pluggable:

- today: `heuristic_score` (role/label token overlap) — a stand-in so the
  client, wiring, and case recorder can be built and exercised end to end.
- target: cua-s1-4b via MLX/Transformers — drop `model_score` in below and
  set CUAS1_BACKEND=model once the checkpoint exists.

NOT the System-1 model. Enable it as a grounding chooser only if the
benchmark (200 recorded cases from Phases 2/6/7) shows accuracy >= frontier
- 3pts with lower latency. See megaplan §9.

Contract:
  POST /choose {"intent": str, "candidates": [{id, role, label, window, frame}]}
  -> 200 {"ranking": [candidate ids, best first]}

Run:  python3 server.py [--port 8424]
"""
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

BACKEND = os.environ.get("CUAS1_BACKEND", "heuristic")


def heuristic_score(intent: str, candidate: dict) -> float:
    """Token-overlap stand-in. Deliberately simple — it exists to exercise
    the wire, not to win the benchmark."""
    tokens = set(re.findall(r"[a-z0-9]+", intent.lower()))
    hay = f"{candidate.get('role', '')} {candidate.get('label', '')}".lower()
    return sum(1 for t in tokens if t in hay)


def model_score(intent: str, candidate: dict) -> float:
    raise RuntimeError(
        "cua-s1 model backend not installed; drop in MLX loading + LoRA here"
    )


SCORERS = {"heuristic": heuristic_score, "model": model_score}


def choose(payload: dict) -> list:
    score = SCORERS[BACKEND]
    intent = payload.get("intent", "")
    ranked = sorted(
        payload.get("candidates", []),
        key=lambda c: score(intent, c),
        reverse=True,
    )
    return [c["id"] for c in ranked if "id" in c]


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/choose":
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
            body = json.dumps({"ranking": choose(payload)}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception as exc:  # keep the wire honest: errors are JSON too
            body = json.dumps({"error": str(exc)}).encode()
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[sys.argv.index("--port") + 1]) if "--port" in sys.argv else 8424
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
