#!/usr/bin/env python3
"""Webhook relay for proving Hindsight <-> Hermes reachability on hermes-net.

Stdlib only -- no pip install, so the image is python:3-slim plus this file.

  POST /hook   log the delivery, then probe BOTH services and report each leg
  GET  /log    last N deliveries, newest first
  GET  /health liveness (compose healthcheck)

Hindsight has no native webhook/subscription endpoint, so this service plays the
receiver: whatever POSTs /hook (curl, `make webhook-test`, either container) is
relayed to Hindsight (read-only recall) and to Hermes (chat completion).
The two legs run independently, so a failure is attributable to one side.
"""
import json
import os
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib import request, error

PORT = int(os.environ.get("WEBHOOK_TEST_PORT", "8777"))
HINDSIGHT_URL = os.environ.get("HINDSIGHT_API_URL", "http://hindsight:8888").rstrip("/")
HINDSIGHT_KEY = os.environ.get("HINDSIGHT_API_KEY", "")
BANK = os.environ.get("HINDSIGHT_BANK_ID", "hermes-course")
HERMES_URL = os.environ.get("WEBHOOK_HERMES_URL", "http://hermes:8642").rstrip("/")
HERMES_KEY = os.environ.get("API_SERVER_KEY", "")
HERMES_MODEL = os.environ.get("WEBHOOK_HERMES_MODEL", "hermes-agent")
TIMEOUT = float(os.environ.get("WEBHOOK_TIMEOUT", "60"))
KEEP = int(os.environ.get("WEBHOOK_LOG_SIZE", "50"))

LOG = deque(maxlen=KEEP)
LOCK = threading.Lock()


def call(name, url, payload, headers):
    """One downstream leg. Never raises: failure is data in the report."""
    t0 = time.time()
    leg = {"leg": name, "url": url}
    req = request.Request(url, data=json.dumps(payload).encode(), method="POST",
                          headers={"Content-Type": "application/json", **headers})
    try:
        with request.urlopen(req, timeout=TIMEOUT) as r:
            leg["status"], body = r.status, r.read()
    except error.HTTPError as e:
        leg["status"], body = e.code, e.read()
    except Exception as e:  # DNS failure, refused, timeout
        leg["status"], body = None, b""
        leg["error"] = "%s: %s" % (type(e).__name__, e)
    leg["ok"] = leg["status"] is not None and 200 <= leg["status"] < 300
    leg["body_excerpt"] = body.decode("utf-8", "replace")[:300]
    leg["ms"] = int((time.time() - t0) * 1000)
    return leg


def hindsight_leg(delivery):
    h = {"Authorization": "Bearer " + HINDSIGHT_KEY} if HINDSIGHT_KEY else {}
    return call("hindsight", "%s/v1/default/banks/%s/memories/recall" % (HINDSIGHT_URL, BANK),
                {"query": "webhook relay probe", "budget": "low"}, h)


def hermes_leg(delivery):
    h = {"Authorization": "Bearer " + HERMES_KEY} if HERMES_KEY else {}
    return call("hermes", HERMES_URL + "/v1/chat/completions",
                {"model": HERMES_MODEL, "max_tokens": 32,
                 "messages": [{"role": "user", "content": "Reply with the single word: pong"}]}, h)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        data = json.dumps(obj, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"status": "ok"})
        elif self.path.split("?")[0] == "/log":
            with LOCK:
                self._send(200, {"count": len(LOG), "deliveries": list(LOG)[::-1]})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path.split("?")[0] != "/hook":
            return self._send(404, {"error": "not found"})
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try:
            body = json.loads(raw) if raw else None
        except ValueError:
            body = raw.decode("utf-8", "replace")
        delivery = {"received_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "method": "POST", "path": self.path,
                    "headers": dict(self.headers), "body": body}
        print("DELIVERY " + json.dumps(delivery), flush=True)

        legs = {}
        threads = [threading.Thread(target=lambda n=n, f=f: legs.__setitem__(n, f(delivery)))
                   for n, f in (("hindsight", hindsight_leg), ("hermes", hermes_leg))]
        [t.start() for t in threads]
        [t.join() for t in threads]

        report = {"delivery": delivery, "hindsight": legs["hindsight"], "hermes": legs["hermes"],
                  "round_trip_ok": legs["hindsight"]["ok"] and legs["hermes"]["ok"]}
        print("REPORT hindsight=%s hermes=%s" % (legs["hindsight"]["status"], legs["hermes"]["status"]),
              flush=True)
        with LOCK:
            LOG.append(report)
        self._send(200, report)

    def log_message(self, fmt, *args):  # per-request access lines are noise
        pass


if __name__ == "__main__":
    print("webhook-test listening on :%d  hindsight=%s hermes=%s" % (PORT, HINDSIGHT_URL, HERMES_URL), flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
