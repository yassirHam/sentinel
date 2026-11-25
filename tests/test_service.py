"""In-process tests for the Sentinel service (no container required).

Run:  pytest -q   (from the sentinel/ directory)
"""
from __future__ import annotations

import asyncio
import time

import httpx
import pytest
from fastapi.testclient import TestClient

from app.main import app, state


def _sum(metrics_text: str, family: str, **labels: str) -> float:
    total = 0.0
    for line in metrics_text.splitlines():
        if not line.startswith(family + "{"):
            continue
        if all(f'{k}="{v}"' in line for k, v in labels.items()):
            total += float(line.rsplit(" ", 1)[1])
    return total


@pytest.fixture(autouse=True)
def _reset_state():
    state.warmup_seconds = 0.0
    state.started_at = time.time() - 1
    state.forced_unready = False
    state.fault_rate = 0.0
    state.fault_injection_enabled = True
    yield
    state.fault_rate = 0.0
    state.forced_unready = False


def test_healthz():
    with TestClient(app) as client:
        r = client.get("/healthz")
        assert r.status_code == 200
        assert r.json()["status"] == "ok"


def test_readyz_after_warmup():
    with TestClient(app) as client:
        r = client.get("/readyz")
        assert r.status_code == 200
        assert r.json()["ready"] is True


def test_readyz_during_warmup_is_503_while_liveness_is_200():
    state.warmup_seconds = 60.0
    state.started_at = time.time()
    with TestClient(app) as client:
        assert client.get("/healthz").status_code == 200
        assert client.get("/readyz").status_code == 503


def test_metrics_increment_on_traffic():
    with TestClient(app) as client:
        before = _sum(client.get("/metrics").text, "sentinel_requests_total")
        for _ in range(5):
            client.get("/work?ms=1")
        after = _sum(client.get("/metrics").text, "sentinel_requests_total")
        assert after == before + 5


def test_fault_injection_and_recovery():
    with TestClient(app, raise_server_exceptions=False) as client:
        base_err = _sum(client.get("/metrics").text, "sentinel_errors_total")

        client.post("/fault?rate=1.0")
        for _ in range(10):
            assert client.get("/work").status_code == 500
        faulted_err = _sum(client.get("/metrics").text, "sentinel_errors_total")
        # Sprint-2 fix: exactly one error per failed request (was 2).
        assert faulted_err - base_err == 10

        client.post("/recover")
        after_recover = _sum(client.get("/metrics").text, "sentinel_errors_total")
        for _ in range(10):
            assert client.get("/work").status_code == 200
        final_err = _sum(client.get("/metrics").text, "sentinel_errors_total")
        assert final_err == after_recover, "no new errors after recovery"


def test_fault_endpoints_disabled_by_default():
    state.fault_injection_enabled = False
    with TestClient(app) as client:
        assert client.post("/fault?rate=1.0").status_code == 404
        assert client.post("/recover").status_code == 404
        assert state.fault_rate == 0.0
        assert client.get("/work").status_code == 200


def test_unknown_paths_do_not_explode_label_cardinality():
    with TestClient(app) as client:
        for i in range(25):
            assert client.get(f"/probe-{i}").status_code == 404
        text = client.get("/metrics").text
        assert "/probe-" not in text
        assert _sum(text, "sentinel_requests_total", path="<unmatched>", status="404") >= 25


def test_metrics_use_route_templates():
    with TestClient(app) as client:
        client.get("/work?ms=0")
        text = client.get("/metrics").text
        assert _sum(text, "sentinel_requests_total", path="/work", status="200") >= 1


def test_slow_request_does_not_block_event_loop():
    """A 400 ms /work must not delay /healthz (Sprint-1 used time.sleep)."""

    async def scenario() -> float:
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://t") as client:
            slow = asyncio.create_task(client.get("/work?ms=400"))
            await asyncio.sleep(0.05)
            t0 = time.perf_counter()
            r = await client.get("/healthz")
            elapsed = time.perf_counter() - t0
            assert r.status_code == 200
            assert (await slow).status_code == 200
            return elapsed

    assert asyncio.run(scenario()) < 0.2


def test_work_latency_is_capped():
    with TestClient(app) as client:
        assert client.get("/work?ms=-5").json()["slept_ms"] == 0
