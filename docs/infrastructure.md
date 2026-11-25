# Sentinel — Cloud foundations (Month 1, axis: Cloud / IaC / Kubernetes)

Owner: Yassir Hamri (pilot). Reviewer: another axis (Jalal or Amine), per the
"every PR reviewed by another speciality" rule.

Everything AWS is Terraform (`sentinel/infra/terraform`). Nothing in this
document has been applied to a real AWS account yet: no account/credentials
were available. What *is* verified is listed under "Verification" with the
exact commands; the first real `apply` is the next step (see "Bootstrap").

## Layout

```
infra/terraform/
├── modules/                 reusable, unit-tested building blocks
│   ├── network/             VPC, 3-tier subnets, NAT, S3 endpoint, flow logs
│   ├── eks/                 EKS control plane, node groups, add-ons, access entries
│   ├── ecr/                 immutable, scanned, KMS-encrypted repositories
│   ├── s3-bucket/           hardened bucket (state, MLflow, DVC)
│   ├── rds-postgres/        private PostgreSQL with PITR (MLflow backend)
│   └── github-oidc/         GitHub Actions -> AWS federation, 3 CI roles
├── stacks/
│   ├── bootstrap/           once per account, applied by a human
│   └── platform/            one state per environment (dev, prod)
├── envs/                    dev.tfvars, prod.tfvars, *.s3.tfbackend
└── .tflint.hcl
infra/policies/terraform-plan.yaml   Kyverno JSON guardrails on the plan
```

Two stacks on purpose: `bootstrap` creates what CI depends on (state bucket,
ECR, the CI roles themselves), so the CI apply role can never modify its own
permissions. `platform` is applied by CI from protected GitHub environments.

## Network (modules/network)

Address plan for a /16 (dev `10.40.0.0/16`, prod `10.41.0.0/16`, never
overlapping so they can be peered later):

| tier | size | CIDRs (dev) | routes |
|---|---|---|---|
| private (nodes + pods) | /19 per AZ | 10.40.0.0/19, .32.0/19, .64.0/19 | 0.0.0.0/0 -> NAT |
| public (LBs, NAT) | /24 per AZ | 10.40.128.0/24 .. 130 | 0.0.0.0/0 -> IGW |
| database | /24 per AZ | 10.40.144.0/24 .. 146 | VPC-local only |

Private subnets are /19 because the VPC CNI gives every pod a VPC IP.
Subnets carry the `kubernetes.io/role/(internal-)elb` and
`karpenter.sh/discovery` tags. Hardening: the default security group is
emptied (CIS 5.4), no subnet auto-assigns public IPs, VPC flow logs (ALL
traffic) go to a KMS-encrypted log group with 90-day retention, and a free S3
gateway endpoint keeps image-layer and artefact traffic off the NAT gateway.
dev uses one NAT gateway; prod one per AZ plus interface endpoints
(ecr.api, ecr.dkr, sts, logs) so nodes can still pull images if NAT fails.

## EKS (modules/eks)

| control | setting |
|---|---|
| API endpoint | private always; public optional, **refused** without an explicit CIDR list and refused for 0.0.0.0/0 (validation + precondition) |
| authentication | access entries only (`authentication_mode = API`), cluster creator is not implicitly admin |
| secrets | envelope encryption with a dedicated, rotated KMS key |
| audit | all 5 control-plane log types, 90-day retention |
| version / support | 1.36, `upgrade_policy = STANDARD` (no silent extended-support billing) |
| nodes | private subnets, AL2023, IMDSv2 required with hop limit 1, encrypted gp3, no SSH key (SSM only) |
| workload IAM | EKS Pod Identity (EBS CSI driver uses it); CNI policy stays on the node role on purpose (bootstrap loop otherwise) |
| add-ons | vpc-cni, kube-proxy, eks-pod-identity-agent (before nodes), coredns, aws-ebs-csi-driver, metrics-server (after nodes) |
| node pools | dev: `system` 2x t3.large + `workloads` spot 0-4; prod: `system` 3x m6i.large, `workloads` 2-10 m6i.xlarge, `gpu` g5.xlarge **0-2, tainted** `nvidia.com/gpu` for ORION / vLLM |

## Data plane for MLOps (Jalal's axis consumes it)

* `mlflow-artifacts` and `dvc-remote` buckets: block-public-access x4,
  ACLs disabled, versioning, SSE-KMS with a stack CMK and bucket keys, policy
  denying non-TLS, TLS < 1.2 and PUTs encrypted with another key, lifecycle
  for non-current versions and stale multipart uploads.
* PostgreSQL 17 (`rds-postgres`): isolated subnets, ingress only from the EKS
  cluster security group, `rds.force_ssl=1`, storage + secret + Performance
  Insights encrypted with the CMK, **master password managed by RDS in Secrets
  Manager** (never in Terraform state), backups 7 days dev / 14 days prod
  (point-in-time recovery), deletion protection on by default.

## CI identities (modules/github-oidc)

| role | assumable from (OIDC `sub`) | rights |
|---|---|---|
| `sentinel-image-publisher` | `repo:yassirHam/sentinel-orion:ref:refs/heads/master` | push to the listed ECR repos only |
| `sentinel-terraform-plan` | pull requests + master | ReadOnlyAccess + state read + `*.tflock` write |
| `sentinel-terraform-apply` | `environment:dev`, `environment:prod` (protected environments) | PowerUserAccess + IAM limited to `/sentinel/` path, explicit deny on `/sentinel-ci/` |

All sessions last 1 h; every trust policy checks `aud = sts.amazonaws.com`.
No AWS access key exists anywhere.

## Bootstrap (first apply, done once by an administrator)

```bash
cd sentinel/infra/terraform/stacks/bootstrap
terraform init && terraform apply                     # local state, creates the state bucket
cp backend.tf.example backend.tf
terraform init -migrate-state \
  -backend-config=../../envs/bootstrap.s3.tfbackend \
  -backend-config="bucket=$(terraform output -raw state_bucket)"
terraform output github_actions_variables            # -> GitHub repository variables
```

Then create the GitHub environments `dev` and `prod` (required reviewers on
`prod`), set the printed values as repository *variables*, and the
`sentinel-terraform` workflow starts planning and applying `stacks/platform`.

## Cost estimate (dev, eu-west-3, on-demand list prices, approximate)

| item | ~USD/month |
|---|---:|
| EKS control plane (0.10 USD/h) | 73 |
| 2x t3.large system nodes | ~140 |
| 1x m6i.large spot workload node | ~30 |
| 1 NAT gateway + light traffic | ~40 |
| RDS db.t4g.micro + 20 GiB gp3 | ~17 |
| KMS keys (5), flow logs, CloudWatch | ~15 |
| **total** | **~315** |

Check against the AWS Pricing Calculator before applying; FinOps tracking is
Jalal's axis (Month 3). Cheapest lever: destroy dev outside lab hours
(`db_deletion_protection = false` in dev exists for that).

## Verification (all run on 2026-10-30)

| check | command | result |
|---|---|---|
| format | `terraform fmt -recursive -check` | clean |
| validate | `terraform validate` in 6 modules + 2 stacks | 8/8 valid |
| unit tests (mocked AWS provider) | `terraform test` per module + platform | **26/26 pass** (network 8, eks 6, ecr 1, s3 3, rds 2, github-oidc 3, platform 3) |
| lint | `tflint --recursive` (AWS ruleset 0.50.0) | 0 issues |
| misconfiguration scan | `trivy config --severity MEDIUM,HIGH,CRITICAL` | 0 findings |
| plan guardrails | `pytest sentinel/infra/policies/tests` | **9/9 pass** (good plan passes; each of 8 violations is caught) |

Bugs the tests caught before any apply: the RDS ingress `for_each` over
security-group IDs that are only known after apply (would have failed the
first real plan; now a static-keyed map), and EKS defaulting a public endpoint
to 0.0.0.0/0 when the CIDR list is empty (now a precondition).
