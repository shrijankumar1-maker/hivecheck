"""Checks a deployed hive check service from the outside, the way a client would.

    python smoke_test.py URL GIT_SHA

1. /health must report status ok and this commit. Right after a deploy the old
   task can still be answering, so it asks again for up to five minutes and
   passes once three answers in a row come from the new version.
2. A failing hive must be flagged for inspection, and a healthy one must not.

Exits 1 with the reason on the first check that fails. Only the standard
library, so it runs on any machine with Python.
"""
import json
import sys
import time
import urllib.request

HEALTHY = {"brood_temp_c": 35.0, "weight_change_kg": 0.8, "humidity_pct": 58,
           "buzz_hz": 245, "mite_load": 1.0}
FAILING = {"brood_temp_c": 33.4, "weight_change_kg": -1.6, "humidity_pct": 68,
           "buzz_hz": 285, "mite_load": 4.5}
WAIT_SECONDS = 300


def call(url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def fail(message):
    print(f"FAIL {message}")
    sys.exit(1)


def main(url, sha):
    url = url.rstrip("/")
    start, in_a_row, seen = time.time(), 0, "nothing"
    while in_a_row < 3:
        if time.time() - start > WAIT_SECONDS:
            fail(f"{url} still answers with {seen} after {WAIT_SECONDS} s, not {sha[:7]}")
        try:
            health = call(f"{url}/health")
            seen = health["git_sha"][:7]
            in_a_row = in_a_row + 1 if health["git_sha"] == sha else 0
        except OSError as e:
            seen, in_a_row = f"an error ({e})", 0
        if in_a_row < 3:
            time.sleep(5)
    print(f"ok   {url} answers with {sha[:7]} after {time.time() - start:.0f} s")
    if health["status"] != "ok":
        fail(f"/health says {health['status']}")
    print(f"ok   status ok, model {health['model_version']}")

    failing, healthy = call(f"{url}/predict", FAILING), call(f"{url}/predict", HEALTHY)
    if not failing["inspect"]:
        fail(f"a failing hive was not flagged: {failing}")
    if healthy["inspect"]:
        fail(f"a healthy hive was flagged: {healthy}")
    print(f"ok   failing hive flagged ({failing['collapse_risk']}), "
          f"healthy hive not ({healthy['collapse_risk']})")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: python smoke_test.py URL GIT_SHA")
    main(*sys.argv[1:])
