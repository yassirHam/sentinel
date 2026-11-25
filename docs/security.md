# Sentinel — DevSecOps (Month 2, axis: DevSecOps)

Defence in layers, each verified by an automated test. "Verified" below means
the command was run on 2026-10-30 and the result is copied, not assumed.

## 1. Toolchain supply chain

`tools/tools.py` installs terraform 1.17.1, tflint 0.65.0, trivy 0.76.1,
helm 4.3.1, kind 0.33.0, kubeconform 0.8.0, kyverno 1.19.2, actionlint 1.7.12,
hadolint 2.15.1, cosign 3.1.4, syft 1.55.0 for Windows and Linux from the
vendors' release pages and **refuses any binary whose SHA-256 differs from
`tools/tools.lock.json`** (digests resolved from the vendors' checksum files
by `tools.py lock`, reviewed like any dependency bump). Trivy is pinned to the
post-incident 0.76.x line; 0.69.4 was the malicious build of March 2026.

## 2. Image

| control | evidence |
|---|---|
| base pinned by digest `python:3.13-slim-trixie@sha256:2d44…86bb` | Dockerfile |
| dependencies hash-locked (`pip --require-hashes`), compiled inside the target image so Linux wheels/markers match | `requirements.txt` |
| no `uvicorn[standard]` extras (watchfiles, websockets, dotenv, PyYAML removed from the runtime) | `requirements.in` |
| multi-stage; pip, setuptools, wheel **and ensurepip** removed from runtime | pip vendored urllib3 2.7.0 / msgpack 1.1.2 with fixable HIGH CVEs; removing it took the image from 5 fixable HIGH to **0** |
| `apt-get upgrade` at build | picks up Debian fixes published after the base digest |
| non-root UID 10001, works read-only, `--no-server-header` | kind `verify` |
| hadolint | 0 findings |
| Trivy gate: fixable HIGH/CRITICAL + secrets | **0** (exit 0). Unfixed findings: 44 HIGH / 58 MEDIUM / 61 LOW, all Debian base packages (util-linux family, ncurses, perl-base, systemd libs) with no fix released; tracked, re-evaluated weekly via Dependabot base-image bumps |
| SBOM | Syft SPDX 2.3: 114 packages (92 deb, 17 PyPI, 4 generic, 1 OCI) |
| size | 225 MB |

Moving to a distroless Python base would remove most unfixed OS findings; it
is the documented next step (Month 3, "durcissement supply chain").

## 3. Admission control (Kyverno 1.19, CEL policy types)

The legacy `ClusterPolicy` kind is deprecated in 1.19 and removed in 1.20, so
all policies use `policies.kyverno.io/v1` `ValidatingPolicy` /
`ImageValidatingPolicy`, with pod-controller autogen.

| policy | rule |
|---|---|
| `sentinel-pod-hardening` | non-root, no privilege escalation, not privileged, drop ALL, read-only root FS, seccomp RuntimeDefault/Localhost, no host namespaces, no hostPath |
| `sentinel-require-resources` | cpu + memory requests and a memory limit |
| `sentinel-require-probes` | liveness + readiness on Deployments/StatefulSets |
| `sentinel-image-references` | no `:latest`/untagged; registry allow-list (Sentinel ECR, local `sentinel-*` on kind); **digest mandatory** in namespaces labelled `sentinel.io/env=prod` |
| `sentinel-verify-signed-images` | ECR images must carry a Cosign **keyless** signature whose Fulcio identity is `…/sentinel-orion/.github/workflows/sentinel-ci.yml@refs/heads/master` (issuer GitHub OIDC, Rekor-logged) **and** a signed SPDX SBOM attestation; tags mutated to digests |

Exceptions use the CEL `PolicyException` (only allowed in the `kyverno`
namespace), e.g. `deploy/kind/gitea.yaml` exempts only the Gitea fixture from
the registry rule; the exception appears as `skip` in PolicyReports.

### Tests

| suite | what | result |
|---|---|---|
| `deploy/policies/tests/pods` (offline) | 1 good pod + 1 ECR digest pod + 10 single-violation cases | **21/21** |
| `deploy/policies/tests/chart` (offline) | the Helm chart rendered for dev **and** prod (prod with an ECR digest) against every policy | **56/56**; mutating the chart to a Docker Hub image makes it fail (checked) |
| `deploy/policies/tests/signatures` (online) | the keyless mechanism on a real public keyless-signed image (Google distroless): correct identity accepted, Sentinel CI identity on the same image **rejected** | **2/2** |
| `k8s_local.py policies` (live cluster, server-side dry-run through the real webhooks) | 12 admissions: only `good-pod` admitted; the unsigned ECR pod is refused **by the signature policy specifically**; PSA and Kyverno both observed denying | **13/13** |

## 4. Infrastructure policy-as-code

* `trivy config` on all Terraform: 0 MEDIUM+ findings (the one finding,
  RDS deletion protection off in dev, was fixed by making protection the
  default and opting dev out explicitly in `dev.tfvars`).
* `infra/policies/terraform-plan.yaml`: Kyverno JSON policies on the resolved
  plan (public EKS API to 0.0.0.0/0, missing secrets encryption, public S3,
  public/unencrypted RDS, mutable ECR tags, SSH/RDP/PostgreSQL open to the
  internet, IMDSv1, and any delete/replace of RDS/S3/KMS/EKS/ECR). Run in
  `sentinel-terraform.yml` between plan and apply. Tests: 9/9 (one per rule).

## 5. Runtime network and identity

* NetworkPolicy: ingress same-namespace + monitoring, egress DNS only (live
  test: a pod in another namespace times out).
* No service-account token mounted; Pod Security Admission `restricted` on
  workload namespaces.
* AWS: IMDSv2 hop limit 1 (pods cannot use node credentials), Pod Identity
  for workloads, OIDC-only CI roles with 1 h sessions.

## Residual risks (accepted, tracked)

| risk | mitigation / plan |
|---|---|
| unfixed Debian CVEs in the base | distroless migration (Month 3); weekly digest bumps |
| Rekor/Fulcio availability on admission | `failurePolicy: Fail` (secure); Kyverno caches verification results |
| dev RDS without deletion protection | explicit, dev only, nightly teardown |
| Grafana `admin/admin` in docker-compose | local only; EKS uses SSO (Amine's observability axis) |
