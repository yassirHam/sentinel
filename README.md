# Sentinel

Cloud-native platform that runs and supervises AI workloads (ORION) on AWS.

| sprint / month | scope | docs |
|---|---|---|
| Sprint 1 | local service + Prometheus + Grafana, fault experiment | [docs/sprint1_report.md](docs/sprint1_report.md) |
| Month 1 (Yassir, Cloud/K8s) | Terraform AWS foundations (VPC, EKS, ECR, S3, RDS, GitHub OIDC), Helm chart, local Kubernetes 1.36 | [docs/infrastructure.md](docs/infrastructure.md), [docs/kubernetes.md](docs/kubernetes.md) |
| Month 2 (Yassir, CI/CD + DevSecOps) | GitHub Actions, GitOps with Argo CD, image hardening, SBOM, Cosign keyless, Kyverno, policy-as-code on Terraform plans | [docs/cicd-gitops.md](docs/cicd-gitops.md), [docs/security.md](docs/security.md) |

## Layout

```
sentinel/
├── app/                    FastAPI service (health, readiness, metrics, fault injection)
├── tests/                  pytest: service behaviour, promotion helper
├── scripts/                smoke/fault tests, k8s_local.py, gitops_local.py, policy_tests.py, set_image.py
├── tools/                  tools.py + tools.lock.json (pinned, SHA-256 verified toolchain)
├── infra/terraform/        modules/, stacks/{bootstrap,platform}, envs/
├── infra/policies/         Kyverno JSON guardrails on Terraform plans (+ tests)
├── deploy/helm/            sentinel-service chart (values-dev / values-prod / schema)
├── deploy/policies/        Kyverno admission policies + offline/online/chart test suites
├── deploy/argocd/          AppProjects, app-of-apps, Applications
├── deploy/platform/        Kyverno and Argo CD Helm values
├── deploy/kind/            local cluster definition, Gitea fixture
├── prometheus/, grafana/   Sprint-1 local observability stack
└── Dockerfile, docker-compose.yml, requirements*.{in,txt}
```

CI lives at the repository root: `.github/workflows/sentinel-ci.yml`,
`sentinel-terraform.yml`, `terraform-apply.yml`, and `.github/dependabot.yml`.

## Quick start

```bash
# 0. tools (terraform, helm, kind, trivy, cosign, kyverno, ...) into ../.tools/bin
python tools/tools.py install

# 1. service tests (hash-locked deps)
python -m venv .venv && .venv/bin/pip install --require-hashes -r requirements.txt -r requirements-dev.txt
pytest -q && ruff check .

# 2. local stack (Sprint 1 path still works)
docker compose up -d --build && python scripts/smoke_test.py && python scripts/fault_test.py

# 3. Kubernetes 1.36 on kind, hardened deploy, policies, GitOps
python scripts/k8s_local.py up
python scripts/k8s_local.py deploy && python scripts/k8s_local.py verify
python scripts/k8s_local.py platform && python scripts/k8s_local.py policies
python scripts/gitops_local.py

# 4. infrastructure checks (no AWS account needed)
cd infra/terraform && terraform fmt -recursive -check
for d in modules/* stacks/*; do terraform -chdir=$d init -backend=false && terraform -chdir=$d test; done
python scripts/policy_tests.py --signatures
```

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/healthz` | liveness |
| GET | `/readyz` | readiness (503 during warm-up or forced fault) |
| GET | `/metrics` | Prometheus; labels use route templates, unknown paths -> `<unmatched>` |
| GET | `/`, `/work?ms=N` | work (N capped to 0-5000 ms, non-blocking) |
| POST | `/fault?rate=R`, `/fault?unready=true`, `/recover` | **only when `ENABLE_FAULT_INJECTION=true`** (compose, dev); 404 otherwise |

## Verified status (2026-10-30)

| area | result |
|---|---|
| service tests | 13 passed; ruff clean |
| Terraform | 8/8 validate, 26/26 `terraform test`, tflint 0, Trivy IaC 0 MEDIUM+ |
| plan guardrails | 9/9 |
| image | hadolint 0, Trivy fixable HIGH/CRITICAL 0, SBOM 114 packages |
| Kyverno | offline 21/21, chart 56/56, keyless online 2/2, live admission 13/13 |
| kind | `verify` 16/16 checks, smoke + fault experiment through Kubernetes |
| GitOps | 9/9 checks (sync, self-heal, Git-driven rollout, manual prod) |
| workflows | actionlint 0 |
| **not yet run** | anything needing the AWS account: `terraform apply`, ECR push, Cosign signing with the GitHub identity, EKS deployment |
