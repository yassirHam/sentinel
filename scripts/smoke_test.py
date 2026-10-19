#!/usr/bin/env python3
"""Smoke test for the Sentinel service (S1.6).

Verifies the service is up and that telemetry responds to traffic:
  1. /healthz returns 200
  2. /readyz eventually returns 200 (after warmup)
  3. /metrics is scrapeable
  4. the request counter increases after we send traffic

Usage:
    python scripts/smoke_test.py [--base-url http://localhost:8000]
Exit code 0 on success, non-zero on failure.
"""
from __future__ import annotations

import argparse
import re
import sys
import time
import urllib.request


def get(url: str, timeout: float = 5.0):
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read().decode()


def post(url: str, timeout: float = 5.0):
    req = urllib.request.Request(url, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read().decode()


def metric_value(metrics_text: str, name: str) -> float:
    """Sum all samples of a counter family (ignoring labels)."""
    total = 0.0
    for line in metrics_text.splitlines():
        if line.startswith(name + "{") or line.startswith(name + " "):
            try:
                total += float(line.rsplit(" ", 1)[1])
            except (ValueError, IndexError):
                pass
    return total


def wait_ready(base: str, attempts: int = 30) -> None:
    for _ in range(attempts):
        try:
            status, _ = get(f"{base}/readyz")
            if status == 200:
                return
        except Exception:
            pass
        time.sleep(1)
    raise SystemExit("FAIL: service never became ready")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default="http://localhost:8000")
    args = ap.parse_args()
    base = args.base_url.rstrip("/")

    print(f"[smoke] target = {base}")

    # 1. liveness
    status, _ = get(f"{base}/healthz")
    assert status == 200, f"healthz returned {status}"
    print("[smoke] /healthz 200 OK")

    # 2. readiness (after warmup)
    wait_ready(base)
    print("[smoke] /readyz 200 OK")

    # 3. metrics scrapeable + capture baseline
    status, before = get(f"{base}/metrics")
    assert status == 200, f"metrics returned {status}"
    before_count = metric_value(before, "sentinel_requests_total")
    print(f"[smoke] /metrics OK (requests_total={before_count:.0f})")

    # 4. send traffic, confirm the counter moved
    for i in range(10):
        get(f"{base}/work?ms=5")
    time.sleep(0.5)
    _, after = get(f"{base}/metrics")
    after_count = metric_value(after, "sentinel_requests_total")
    print(f"[smoke] after traffic requests_total={after_count:.0f}")
    assert after_count >= before_count + 10, "request counter did not increase"
    print("[smoke] telemetry increments on traffic — PASS")

    print("[smoke] ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except AssertionError as exc:
        print(f"[smoke] FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:  # noqa: BLE001
        print(f"[smoke] ERROR: {exc}", file=sys.stderr)
        sys.exit(2)
