"""
Sentinel sample service — Sprint 1.

A small HTTP service that demonstrates the health-monitoring foundation:
  * /healthz   liveness   (is the process up?)
  * /readyz    readiness  (is it ready to serve traffic?)
  * /metrics   Prometheus metrics (request count, error count, latency)
  * /          a trivial work endpoint
  * /work      simulated unit of work (optional ?ms= to add latency)
  * /fault     controlled fault injection (S1.5)

Design notes
------------
Telemetry is exposed with prometheus_client. A middleware records, for every
request: the total count, the error count (HTTP 5xx or raised exception) and
the request latency as a histogram. Logs are emitted as single-line JSON so a
log collector can parse them without a regex.
"""
from __future__ import annotations

import logging
import os
import random
import sys
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse, PlainTextResponse
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

from .logging_config import configure_logging, request_logger

SERVICE_NAME = os.getenv("SERVICE_NAME", "sentinel-sample-service")
VERSION = os.getenv("SERVICE_VERSION", "0.1.0")

# --------------------------------------------------------------------------- #
#  Prometheus metrics (S1.4)                                                  #
# --------------------------------------------------------------------------- #
REQUESTS = Counter(
    "sentinel_requests_total",
    "Total HTTP requests processed.",
    ["method", "path", "status"],
)
ERRORS = Counter(
    "sentinel_errors_total",
    "Total HTTP requests that resulted in an error (status >= 500).",
    ["method", "path"],
)
LATENCY = Histogram(
    "sentinel_request_latency_seconds",
    "Request latency in seconds.",
    ["method", "path"],
    # Buckets tuned for a fast local service (1ms .. 2.5s).
    buckets=(0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5),
)
IN_PROGRESS = Gauge(
    "sentinel_requests_in_progress",
    "Number of requests currently being processed.",
)
READY = Gauge(
    "sentinel_ready",
    "Whether the service reports itself ready (1) or not (0).",
)

log = logging.getLogger("sentinel.app")


class ServiceState:
    """Mutable runtime state used to drive readiness and fault injection."""

    def __init__(self) -> None:
        # Service starts "warming up": not ready for a short grace period so
        # readiness is observably distinct from liveness.
        self.started_at = time.time()
        self.warmup_seconds = float(os.getenv("WARMUP_SECONDS", "2"))
        # Fault injection (S1.5). fault_rate in [0,1]; when >0 a fraction of
        # /work (and /) requests fail with HTTP 500.
        self.fault_rate = 0.0
        self.forced_unready = False

    @property
    def ready(self) -> bool:
        if self.forced_unready:
            return False
        return (time.time() - self.started_at) >= self.warmup_seconds


state = ServiceState()


@asynccontextmanager
async def lifespan(app: FastAPI):
    configure_logging()
    log.info(
        "service_starting",
        extra={"service": SERVICE_NAME, "version": VERSION, "pid": os.getpid()},
    )
    READY.set(0)
    yield
    log.info("service_stopping", extra={"service": SERVICE_NAME})


app = FastAPI(title=SERVICE_NAME, version=VERSION, lifespan=lifespan)


# --------------------------------------------------------------------------- #
#  Telemetry middleware (S1.4)                                                #
# --------------------------------------------------------------------------- #
@app.middleware("http")
async def telemetry_middleware(request: Request, call_next):
    # /metrics is excluded from its own accounting to avoid feedback noise.
    path = request.url.path
    method = request.method
    if path == "/metrics":
        return await call_next(request)

    IN_PROGRESS.inc()
    start = time.perf_counter()
    status_code = 500
    try:
        response = await call_next(request)
        status_code = response.status_code
        return response
    except Exception:  # noqa: BLE001 — convert unexpected errors to 500 + metric
        ERRORS.labels(method=method, path=path).inc()
        log.exception("unhandled_exception", extra={"path": path, "method": method})
        return JSONResponse(status_code=500, content={"error": "internal_error"})
    finally:
        elapsed = time.perf_counter() - start
        LATENCY.labels(method=method, path=path).observe(elapsed)
        REQUESTS.labels(method=method, path=path, status=str(status_code)).inc()
        if status_code >= 500:
            ERRORS.labels(method=method, path=path).inc()
        IN_PROGRESS.dec()
        request_logger().info(
            "request",
            extra={
                "method": method,
                "path": path,
                "status": status_code,
                "latency_ms": round(elapsed * 1000, 2),
            },
        )


# --------------------------------------------------------------------------- #
#  Health & readiness (S1.3)                                                  #
# --------------------------------------------------------------------------- #
@app.get("/healthz")
async def healthz() -> JSONResponse:
    """Liveness: the process is running and can serve this handler."""
    return JSONResponse({"status": "ok", "service": SERVICE_NAME, "version": VERSION})


@app.get("/readyz")
async def readyz() -> JSONResponse:
    """Readiness: the service is ready to accept traffic."""
    ready = state.ready
    READY.set(1 if ready else 0)
    code = 200 if ready else 503
    return JSONResponse(
        status_code=code,
        content={
            "ready": ready,
            "warmup_seconds": state.warmup_seconds,
            "forced_unready": state.forced_unready,
        },
    )


@app.get("/metrics")
async def metrics() -> Response:
    """Prometheus scrape endpoint (S1.4)."""
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


# --------------------------------------------------------------------------- #
#  Work endpoints                                                             #
# --------------------------------------------------------------------------- #
@app.get("/")
async def root() -> dict:
    _maybe_fail()
    return {"message": "hello from sentinel", "service": SERVICE_NAME}


@app.get("/work")
async def work(ms: int = 0) -> dict:
    """Simulate a unit of work. ?ms=N adds N milliseconds of latency."""
    if ms > 0:
        time.sleep(min(ms, 5000) / 1000.0)
    _maybe_fail()
    return {"did_work": True, "slept_ms": ms}


def _maybe_fail() -> None:
    """Raise a 500-equivalent error according to the configured fault rate."""
    if state.fault_rate > 0 and random.random() < state.fault_rate:
        raise RuntimeError("injected fault (S1.5)")


# --------------------------------------------------------------------------- #
#  Controlled fault experiment (S1.5)                                         #
# --------------------------------------------------------------------------- #
@app.post("/fault")
async def set_fault(rate: float = 1.0, unready: bool = False) -> dict:
    """
    Enable a controlled fault.
      rate     : fraction of /work and / requests that fail (0..1).
      unready  : if true, force /readyz to report not-ready.
    """
    state.fault_rate = max(0.0, min(1.0, rate))
    state.forced_unready = unready
    log.warning(
        "fault_enabled",
        extra={"fault_rate": state.fault_rate, "forced_unready": unready},
    )
    return {"fault_rate": state.fault_rate, "forced_unready": unready}


@app.post("/recover")
async def recover() -> dict:
    """Clear any injected fault and restore normal operation."""
    state.fault_rate = 0.0
    state.forced_unready = False
    log.info("fault_cleared")
    return {"fault_rate": 0.0, "forced_unready": False}


if __name__ == "__main__":  # pragma: no cover - manual local run
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8000")),
        reload=False,
    )
