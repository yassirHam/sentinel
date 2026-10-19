# Sentinel — Sprint 1 (Infrastructure)

A reproducible **local observability platform**: a small HTTP service that
exposes health, readiness and Prometheus metrics, wired to Prometheus and
Grafana via Docker Compose, with a controlled fault experiment and scripts to
reproduce it.

> **Sprint 1 completion criterion:** *another developer can start the service,
> observe its metrics, reproduce the fault and verify recovery.* This README is
> that path.

## Components (S1.1)

| Component    | Role                                              | Port |
|--------------|---------------------------------------------------|------|
| `service`    | FastAPI app: health/readiness/metrics + work/fault | 8000 |
| `prometheus` | scrapes `/metrics` every 5s, stores time series    | 9090 |
| `grafana`    | RED dashboard (rate / errors / latency)            | 3000 |

See [`docs/architecture.txt`](docs/architecture.txt) for the diagram and the
full boundary/data-flow description.

```
sentinel/
├── app/                  # the service (main.py, logging_config.py)
├── prometheus/           # scrape config
├── grafana/              # datasource + dashboard provisioning
├── scripts/              # smoke_test.py, fault_test.py
├── tests/                # pytest (in-process, no container needed)
├── docs/                 # architecture + Sprint 1 report
├── Dockerfile
└── docker-compose.yml
```

## Quick start (S1.2)

**Requirements:** Docker + Docker Compose.

```bash
# from sentinel/
docker compose up -d --build      # start the whole stack
docker compose ps                 # confirm 3 services are up/healthy
docker compose logs -f service    # follow structured JSON logs
docker compose down               # stop (add -v to drop volumes)
```

Once up:

* Service:    <http://localhost:8000>  (`/healthz`, `/readyz`, `/metrics`)
* Prometheus: <http://localhost:9090>  (try `sentinel_requests_total`)
* Grafana:    <http://localhost:3000>  → dashboard **Sentinel — Service Health (RED)**

## Endpoints

| Method | Path            | Purpose                                             |
|--------|-----------------|-----------------------------------------------------|
| GET    | `/healthz`      | liveness — process is up (always 200 if alive)      |
| GET    | `/readyz`       | readiness — 200 when ready, 503 during warmup/fault |
| GET    | `/metrics`      | Prometheus exposition                               |
| GET    | `/`             | trivial work                                        |
| GET    | `/work?ms=N`    | work with N ms of added latency                     |
| POST   | `/fault?rate=R` | inject fault: fraction R of work requests → 500     |
| POST   | `/fault?unready=true` | force `/readyz` to report not-ready           |
| POST   | `/recover`      | clear the fault, restore health                     |

## Telemetry (S1.4)

Exposed on `/metrics`:

* `sentinel_requests_total{method,path,status}` — request count
* `sentinel_errors_total{method,path}` — error count (status ≥ 500)
* `sentinel_request_latency_seconds{method,path}` — latency histogram
* `sentinel_requests_in_progress` — gauge
* `sentinel_ready` — gauge (1 ready / 0 not)

Confirm metrics change under load:

```bash
python scripts/smoke_test.py          # sends traffic, asserts counters move
```

## Controlled fault experiment (S1.5)

```bash
python scripts/fault_test.py --rate 0.5 -n 40
```

The script sends a baseline load, injects a 50% failure rate, sends load again
(errors rise), calls `/recover`, and confirms errors stop rising and `/readyz`
is 200. See [`docs/sprint1_report.md`](docs/sprint1_report.md) for recorded
results.

## Tests

```bash
pip install -r requirements.txt
pytest -q            # in-process tests (health, metrics increment, fault/recovery)
```

## Reproducibility (S1.6)

1. `docker compose up -d --build`
2. `python scripts/smoke_test.py` → expect `ALL CHECKS PASSED`
3. `python scripts/fault_test.py` → expect `EXPERIMENT PASSED`
4. Observe the same signals in Grafana (RED dashboard) and Prometheus.
5. `docker compose down`
