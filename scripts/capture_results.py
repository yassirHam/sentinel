"""Capture real smoke + fault numbers in-process (no server, no Docker).

Used to produce the figures in docs/sprint1_report.md. Run:
    python scripts/capture_results.py
"""
from __future__ import annotations

import logging

from fastapi.testclient import TestClient
from app.main import app, state

# Keep the capture output clean: silence per-request + httpx chatter.
for noisy in ("sentinel.request", "sentinel.app", "httpx", "httpcore"):
    logging.getLogger(noisy).setLevel(logging.WARNING)


def total(metrics: str, name: str) -> float:
    s = 0.0
    for line in metrics.splitlines():
        if line.startswith(name + "{"):
            s += float(line.rsplit(" ", 1)[1])
    return s


def main() -> None:
    state.warmup_seconds = 0.0  # immediate readiness for the capture
    with TestClient(app, raise_server_exceptions=False) as c:
        print("== SMOKE ==")
        print("healthz:", c.get("/healthz").status_code)
        print("readyz :", c.get("/readyz").status_code)
        before = total(c.get("/metrics").text, "sentinel_requests_total")
        for _ in range(20):
            c.get("/work?ms=2")
        after = total(c.get("/metrics").text, "sentinel_requests_total")
        print(f"requests_total: {before:.0f} -> {after:.0f} (+{after-before:.0f})")

        print("\n== FAULT EXPERIMENT ==")

        def phase(label):
            e0 = total(c.get("/metrics").text, "sentinel_errors_total")
            codes = {}
            for _ in range(40):
                r = c.get("/work?ms=1")
                codes[r.status_code] = codes.get(r.status_code, 0) + 1
            e1 = total(c.get("/metrics").text, "sentinel_errors_total")
            ok = codes.get(200, 0)
            err = sum(v for k, v in codes.items() if k >= 500)
            print(f"{label:10s} 200={ok:3d} 5xx={err:3d} errors_total+={e1-e0:.0f}")
            return e1 - e0

        base = phase("baseline")
        c.post("/fault?rate=0.5")
        faulted = phase("faulted")
        c.post("/recover")
        recovered = phase("recovered")
        print("readyz after recovery:", c.get("/readyz").status_code)
        print(f"\nsummary: baseline_err={base:.0f} faulted_err={faulted:.0f} "
              f"recovered_err={recovered:.0f}")
        print("result:", "PASS" if faulted > base and recovered <= 1 else "CHECK")


if __name__ == "__main__":
    main()
