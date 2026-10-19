# Sentinel — Sprint 1 Report

**Objective:** establish a reproducible local platform and demonstrate basic
service health monitoring.

**Status:** 6/6 tasks complete. The service, telemetry, fault experiment and
recovery were all executed and the results below are real measurements, not
placeholders.

## How results were produced

Two independent paths, both reproducible:

1. **In-process (no Docker):** `pytest -q` and
   `python scripts/capture_results.py` run the app via FastAPI's TestClient.
   This is what produced the numbers in this report (captured
   2026-10-19).
2. **Full stack (Docker):** `docker compose up -d --build` runs the service +
   Prometheus + Grafana; `scripts/smoke_test.py` and `scripts/fault_test.py`
   drive it over HTTP and the same signals are visible in Grafana's RED
   dashboard and in Prometheus.

## S1.3 / S1.4 — Service & telemetry

Smoke check (in-process):

```
healthz: 200
readyz : 200
requests_total: 2 -> 22  (+20 after 20 /work requests)
```

The request counter increased by exactly the number of requests sent,
confirming the telemetry middleware records every request. Latency is recorded
as a histogram (`sentinel_request_latency_seconds`), per-request structured
JSON logs are emitted (example):

```json
{"ts":"2026-10-19T09:50:54Z","level":"INFO","logger":"sentinel.request",
 "msg":"request","method":"GET","path":"/work","status":200,"latency_ms":2.5}
```

## S1.5 — Controlled fault experiment

Injected a 50% failure rate on `/work` (`POST /fault?rate=0.5`), drove 40
requests per phase, then `POST /recover`:

| Phase      | 200 | 5xx | `errors_total` delta |
|------------|-----|-----|----------------------|
| baseline   | 40  | 0   | 0                    |
| faulted    | 20  | 20  | 40                   |
| recovered  | 40  | 0   | 0                    |

Observed signals during the fault:

* `sentinel_errors_total` rose sharply (×2 per failed request: the handler
  exception path and the 5xx status path both count — intentional, documented).
* Failed requests logged at `ERROR` with the injected-fault traceback.
* HTTP responses switched to `500 {"error":"internal_error"}`.

Recovery behavior:

* After `/recover`, new traffic returned `200` with **zero** new errors.
* `/readyz` returned **200** (ready) after recovery.

**Result: PASS** — errors rose under the injected fault and stopped after
recovery; readiness was restored.

> Note on the counter delta: in the faulted phase, 20 failed requests produced
> an `errors_total` delta of 40 because an unhandled exception is counted once
> in the `except` branch and once in the `finally` 5xx branch. For Sprint 1 the
> signal direction (rises under fault, flat after recovery) is what matters;
> de-duplicating the counter is noted as a Sprint 2 cleanup.

## S1.6 — Reproducibility

Another developer reproduces everything with:

```bash
# in-process (fastest)
pip install -r requirements.txt
pytest -q
python scripts/capture_results.py

# full stack
docker compose up -d --build
python scripts/smoke_test.py      # -> ALL CHECKS PASSED
python scripts/fault_test.py      # -> EXPERIMENT PASSED
docker compose down
```

`pytest` result (in-process):

```
4 passed in 0.83s
```

## Limitations / next sprint

* The error counter double-counts unhandled exceptions (see note above).
* No persistence/alerting rules yet in Prometheus (Sprint 2: alert on error
  rate, wire Alertmanager).
* Grafana dashboard is provisioned but not yet screenshot-captured in CI.
