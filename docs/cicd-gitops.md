# Sentinel — CI/CD and GitOps (Month 2)

## Flow

```
PR ──▶ sentinel-ci: test ─┬─ policy (actionlint, helm lint, kubeconform 1.36,
                          │          Kyverno tests, Cosign keyless suite, plan guardrails)
                          ├─ scan   (hadolint, Trivy fs: deps + secrets + misconfig -> SARIF)
                          └─▶ build (buildx) -> Trivy image gate -> Syft SBOM (SPDX)
merge to master:
   build ──▶ OIDC -> ECR push (immutable tag = SHA) -> digest
         ──▶ cosign sign (keyless, Fulcio + Rekor) + cosign attest SBOM
         ──▶ GitHub SLSA build provenance
   promote-dev ──▶ commit digest to values-dev.yaml  ─────────────┐
                                                                  ▼
Argo CD (in cluster, pulls Git) ── sync dev automatically ── Kyverno admits only
                                                             signed + attested digests
prod: PR copying a dev-proven digest into values-prod.yaml -> manual sync in the window
```

The cluster pulls; CI never holds a kubeconfig. CI holds no AWS key either
(OIDC roles from `modules/github-oidc`).

## Workflows (`.github/workflows`)

| file | trigger | jobs |
|---|---|---|
| `sentinel-ci.yml` | PR / push on `sentinel/**` | test, policy, scan, build (+push/sign/attest on master), promote-dev |
| `sentinel-terraform.yml` | PR / push on `sentinel/infra/**` | static (fmt, validate, `terraform test`, tflint, Trivy IaC -> SARIF), plan per env + Kyverno plan guardrails, apply dev -> prod |
| `terraform-apply.yml` | reusable | plan -> guardrails -> apply *that* plan, inside the GitHub environment |
| `orion-ci.yml` | PR / push on `orion/**` | ruff + pytest (CPU torch) |
| `dependabot.yml` | weekly | action SHAs, pip, base-image digest, Terraform providers |

Hardening of the pipelines themselves:

* `permissions: {}` at workflow level; each job opts into the minimum
  (`id-token: write` only where OIDC is used, `contents: write` only in
  promote-dev, `security-events: write` only for SARIF upload).
* Every action pinned to a commit SHA (comment = version). Scanners/signers
  are not actions: `tools/tools.py` installs vendor binaries verified against
  SHA-256 digests committed in `tools/tools.lock.json`. This is the direct
  lesson of the March 2026 `trivy-action` tag hijack (GHSA-69fq-xp46-6x23).
* `persist-credentials: false` on checkout except in the one job that pushes.
* Plan/apply jobs are skipped until the repository variables exist, so the
  pipeline is green before an AWS account is wired.
* `actionlint` runs on every workflow change (0 findings locally).

## Promotion helper

`scripts/set_image.py` rewrites only `image.repository/tag/digest` of a values
file (validated digest/tag/repository formats, comments preserved). Tested in
`tests/test_set_image.py`. Pushes made with `GITHUB_TOKEN` do not trigger new
workflow runs, so promotion cannot loop.

## Argo CD (`deploy/argocd`, chart 10.11.6 / Argo CD v3.5.6)

| object | purpose |
|---|---|
| `projects/bootstrap.yaml` | project of the root app only: may create `Application` objects in `argocd`, nothing else |
| `projects/sentinel.yaml` | trusted sources (this repo, Kyverno chart repo), destinations (`sentinel-dev`, `sentinel-prod`, `kyverno`), whitelisted cluster kinds, `ResourceQuota`/`LimitRange` blacklisted, prod sync window Mon-Fri 08:00-18:00 Africa/Casablanca, read-only CI role |
| `root-app.yaml` | app-of-apps over `deploy/argocd/apps` |
| `apps/kyverno.yaml` | wave -2, upstream chart 3.9.2 + values from Git (multi-source), server-side apply, no auto-prune |
| `apps/kyverno-policies.yaml` | wave -1, policies with self-heal |
| `apps/sentinel-dev.yaml` | auto-sync, prune, self-heal, namespace labels (PSA restricted, `sentinel.io/env=dev`), HPA-owned replicas ignored |
| `apps/sentinel-prod.yaml` | **manual** sync, `sentinel.io/env=prod` (digest-only admission) |

Server settings (`deploy/platform/argocd-values.yaml`): default RBAC
`role:readonly`, web terminal off, Dex off (SSO on EKS), Argo CD
NetworkPolicies on, Kyverno report kinds excluded from tracking.

## GitOps verification on kind (no push to GitHub)

`scripts/gitops_local.py` snapshots the working tree into an in-cluster Gitea,
points the Applications at it and asserts the whole loop:

```
PASS app-of-apps created all child Applications (1s)
PASS kyverno-policies Synced + Healthy (1s)
PASS sentinel-dev Synced + Healthy (32s)
PASS kyverno (upstream chart) Synced (1s)
PASS sentinel-root (app-of-apps) Synced + Healthy, no flapping (1s)
PASS sentinel-prod not auto-synced (sync=OutOfSync): promotion to prod is manual
PASS self-heal reverted manual drift (LOG_LEVEL back to DEBUG) (6s)
PASS Git commit rolled out by Argo CD (LOG_LEVEL=INFO) (6s)
PASS sentinel-dev Synced + Healthy after the change (50s)
ALL GITOPS CHECKS PASSED
```

Issues found and fixed during this test:

1. The root app was in the `sentinel` project, whose destinations exclude
   `argocd` -> `InvalidSpecError`. Fix: dedicated `sentinel-bootstrap` project
   allowed to create `Application` objects only.
2. `sentinel-dev` Degraded: HPA had no metrics on kind. Fix: metrics-server in
   `k8s_local.py platform` (on EKS it is the EKS add-on).
3. Root app flapping OutOfSync: Argo CD adds `pre-delete-finalizer.*` to the
   Kyverno Application (its chart has PreDelete hooks). Fix: a jq
   `ignoreDifferences` limited to exactly those finalizers +
   `RespectIgnoreDifferences=true`.

## Not verified yet (needs the AWS account + pushing this branch)

* The publish half of `sentinel-ci.yml` (ECR push, Cosign signing with the
  GitHub identity, SLSA attestation) and `sentinel-terraform.yml` plan/apply
  only run on GitHub with the bootstrap roles. Everything they call was run
  locally (build, Trivy gate, Syft, Kyverno, Terraform tests), and the Cosign
  keyless verification path was tested online with a public keyless-signed
  image (security.md).
