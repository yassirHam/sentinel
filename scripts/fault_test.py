#!/usr/bin/env python3
"""Controlled fault experiment for the Sentinel service (S1.5 + S1.6).

Procedure:
  1. Baseline: send N requests, record error count (should be ~0).
  2. Inject fault: POST /fault?rate=0.5  -> ~50% of /work requests fail.
  3. Load:     send N requests, record error count (should rise sharply).
  4. Recover:  POST /recover -> fault cleared.
  5. Verify:   send N requests, error count should stop rising; /readyz 200.

Prints a small before/during/after table and exits 0 if the experiment
behaved as expected (errors rose under fault and stopped after recovery).

Usage:
    python scripts/fault_test.py [--base-url http://localhost:8000] [-n 40] [--rate 0.5]
"""
from __future__ import annotations

import argparse
import sys
import time
import urllib.request


def get_status(url: str, timeout: float = 5.0) -> int:
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return 0


def post(url: str, timeout: float = 5.0) -> int:
    req = urllib.request.Request(url, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status


def read_metrics(base: str) -> str:
    req = urllib.request.Request(f"{base}/metrics", method="GET")
    with urllib.request.urlopen(req, timeout=5) as resp:
        return resp.read().decode()


def errors_total(metrics_text: str) -> float:
    total = 0.0
    for line in metrics_text.splitlines():
        if line.startswith("sentinel_errors_total{"):
            try:
                total += float(line.rsplit(" ", 1)[1])
            except (ValueError, IndexError):
                pass
    return total


def send_load(base: str, n: int) -> dict[int, int]:
    counts: dict[int, int] = {}
    for _ in range(n):
        code = get_status(f"{base}/work?ms=2")
        counts[code] = counts.get(code, 0) + 1
    return counts


def phase(base: str, label: str, n: int) -> tuple[dict[int, int], float]:
    before = errors_total(read_metrics(base))
    counts = send_load(base, n)
    after = errors_total(read_metrics(base))
    delta = after - before
    ok = counts.get(200, 0)
    err = sum(v for k, v in counts.items() if k >= 500 or k == 0)
    print(f"[fault] {label:9s}  200={ok:3d}  5xx={err:3d}  errors_total+={delta:.0f}")
    return counts, delta


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default="http://localhost:8000")
    ap.add_argument("-n", type=int, default=40)
    ap.add_argument("--rate", type=float, default=0.5)
    args = ap.parse_args()
    base = args.base_url.rstrip("/")
    n = args.n

    print(f"[fault] target = {base}  n={n}  rate={args.rate}")

    # 1. baseline
    _, baseline_delta = phase(base, "baseline", n)

    # 2. inject
    post(f"{base}/fault?rate={args.rate}")
    print(f"[fault] injected fault rate={args.rate}")

    # 3. load under fault
    _, fault_delta = phase(base, "faulted", n)

    # 4. recover
    post(f"{base}/recover")
    print("[fault] recovery requested (/recover)")
    time.sleep(0.5)

    # 5. verify recovery
    _, recovered_delta = phase(base, "recovered", n)
    ready = get_status(f"{base}/readyz")
    print(f"[fault] /readyz after recovery = {ready}")

    # assertions
    ok = True
    if fault_delta <= baseline_delta:
        print("[fault] FAIL: errors did not rise under injected fault", file=sys.stderr)
        ok = False
    if recovered_delta > max(1, fault_delta * 0.5):
        print("[fault] FAIL: errors kept rising after recovery", file=sys.stderr)
        ok = False
    if ready != 200:
        print("[fault] FAIL: service not ready after recovery", file=sys.stderr)
        ok = False

    if ok:
        print("[fault] EXPERIMENT PASSED: fault raised errors, recovery restored health")
        return 0
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"[fault] ERROR: {exc}", file=sys.stderr)
        sys.exit(2)
