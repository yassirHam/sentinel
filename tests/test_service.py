"""In-process tests for the Sentinel service (no container required).

Run:  pytest -q   (from the sentinel/ directory)
"""
from __future__ import annotations

import time

from fastapi.testclient import TestClient

from app.main import app, state


def _requests_total(metrics_text: str) -> float:
    total = 0.0
    for line in metrics_text.splitlines():
        if line.startswith("sentinel_requests_total{"):
            total += float(line.rsplit(" ", 1)[1])
    return total


def _errors_total(metrics_text: str) -> float:
    total = 0.0
    for line in metrics_text.splitlines():
        if line.startswith("sentinel_errors_total{"):
            total += float(line.rsplit(" ", 1)[1])
    return total


def test_healthz():
    with TestClient(app) as client:
        r = client.get("/healthz")
        assert r.status_code == 200
        assert r.json()["status"] == "ok"


def test_readyz_after_warmup():
    # Force warmup to zero so the service is immediately ready.
    state.warmup_seconds = 0.0
    state.started_at = time.time() - 1
    state.forced_unready = False
    with TestClient(app) as client:
        r = client.get("/readyz")
        assert r.status_code == 200
        assert r.json()["ready"] is True


def test_metrics_increment_on_traffic():
    with TestClient(app) as client:
        before = _requests_total(client.get("/metrics").text)
        for _ in range(5):
            client.get("/work?ms=1")
        after = _requests_total(client.get("/metrics").text)
        assert after >= before + 5


def test_fault_injection_and_recovery():
    with TestClient(app, raise_server_exceptions=False) as client:
        # Baseline errors
        base_err = _errors_total(client.get("/metrics").text)

        # Inject a guaranteed fault (rate=1.0) and send traffic.
        client.post("/fault?rate=1.0")
        for _ in range(10):
            client.get("/work")
        faulted_err = _errors_total(client.get("/metrics").text)
        assert faulted_err > base_err, "errors should rise under injected fault"

        # Recover and confirm new traffic no longer errors.
        client.post("/recover")
        after_recover = _errors_total(client.get("/metrics").text)
        for _ in range(10):
            r = client.get("/work")
            assert r.status_code == 200
        final_err = _errors_total(client.get("/metrics").text)
        assert final_err == after_recover, "no new errors after recovery"
