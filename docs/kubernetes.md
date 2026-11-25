# Sentinel — Kubernetes packaging and local cluster (Month 1)

## Helm chart `deploy/helm/sentinel-service`

| object | why |
|---|---|
| Deployment | rolling update with `maxUnavailable: 0`; startup / liveness (`/healthz`) / readiness (`/readyz`) probes; native `preStop.sleep` 5 s so endpoints drain before SIGTERM |
| Service (ClusterIP) | port 80 -> container 8000 |
| ServiceAccount | `automountServiceAccountToken: false` (the app never calls the API) |
| HorizontalPodAutoscaler | CPU 70 %, 2-6 replicas (dev 2-3, prod 3-10), 5 min scale-down stabilisation |
| PodDisruptionBudget | `minAvailable` 1 (prod 2), `unhealthyPodEvictionPolicy: AlwaysAllow` |
| NetworkPolicy | ingress only from the same namespace and the `monitoring` namespace; **egress only DNS** |
| ServiceMonitor | rendered only if the Prometheus Operator CRD exists (prod) |
| helm test pod | in-namespace call of `/healthz`, `/readyz`, `/metrics` |

Pod security defaults: UID/GID 10001, `runAsNonRoot`, `readOnlyRootFilesystem`
(+ 64 Mi `emptyDir` on `/tmp`), all capabilities dropped,
`allowPrivilegeEscalation: false`, seccomp `RuntimeDefault`, topology spread
across zones and nodes, memory limit without CPU limit (avoids CFS throttling).
`values.schema.json` refuses `image.tag: latest`, a malformed digest, a
writable root filesystem or `runAsNonRoot: false` at `helm template` time.

`image.digest` (written by CI) wins over `image.tag`: what runs is exactly the
digest that was scanned and signed.

## Service changes made while hardening (Sprint-2 backlog + review findings)

| change | reason |
|---|---|
| `errors_total` counted once per failed request | Sprint-1 known issue (exception counted twice) — verified: 20 failures -> +20 |
| metrics labelled by route template, unknown paths -> `<unmatched>` | raw URLs as labels = unbounded cardinality; 25 random probes now create 0 new series |
| `asyncio.sleep` instead of `time.sleep` in `/work` | a blocking sleep froze the event loop (incl. `/healthz`); test proves `/healthz` answers in < 0.2 s during a 400 ms request |
| `/fault` and `/recover` disabled unless `ENABLE_FAULT_INJECTION=true` | unauthenticated endpoints that break the service must not exist in prod (404); on in compose and dev |
| image: digest-pinned base, hash-locked deps, multi-stage, pip and ensurepip removed, UID 10001 | supply chain; 0 fixable HIGH/CRITICAL (see security.md) |

## Local cluster = EKS shape (kind)

`deploy/kind/kind-config.yaml`: Kubernetes **1.36.4** (same minor as EKS),
1 control-plane + 2 workers labelled with zones `local-a/b/c`, kindnet
NetworkPolicy enforcement. The node image is pinned by digest.

```bash
python tools/tools.py install                 # pinned, checksum-verified tools -> .tools/bin
python scripts/k8s_local.py up                # cluster
python scripts/k8s_local.py deploy            # build image, kind load, helm upgrade --install (dev values)
python scripts/k8s_local.py verify            # 16 assertions, below
python scripts/k8s_local.py platform          # metrics-server, Kyverno + policies, Argo CD, Gitea fixture
python scripts/k8s_local.py policies          # live admission e2e (security.md)
python scripts/gitops_local.py                # GitOps loop e2e (cicd-gitops.md)
python scripts/k8s_local.py down
```

The namespace is labelled `pod-security.kubernetes.io/enforce=restricted`
(Pod Security Admission) in addition to Kyverno: two independent layers.

### `verify` result (2026-10-30, with Kyverno enforcing)

```
PASS 2 replicas running (>= 2)
PASS replicas spread over 2 nodes
PASS <pod>: runs as non-root UID 10001          (x2 pods)
PASS <pod>: read-only root filesystem           (x2)
PASS <pod>: all capabilities dropped            (x2)
PASS <pod>: no API token mounted                (x2)
PASS process UID inside container = 10001
PASS writing to the image filesystem is refused
PASS helm test (in-namespace connectivity)
PASS NetworkPolicy blocks other namespaces
PASS smoke test (port-forward to one replica)
PASS fault experiment on one replica   baseline 40/0 -> faulted 20x200/20x5xx, errors_total +20 -> recovered 40/0, /readyz 200
ALL KUBERNETES CHECKS PASSED
```

Two bugs found by this harness and fixed: the helm-test pod carried the
Service selector labels (it became a Service endpoint and inherited the
egress-deny policy, so it timed out), and the fault experiment originally went
through the Service, mixing per-replica counters (now pinned to one pod).
