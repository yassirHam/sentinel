"""Each Terraform-plan guardrail must fail on exactly the violation it targets.

Builds single-violation variants of plan-good.json and evaluates them with
the Kyverno CLI (needs `kyverno` on PATH: python sentinel/tools/tools.py install).
Run: pytest -q sentinel/infra/policies/tests
"""
from __future__ import annotations

import copy
import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
POLICY = HERE.parent / "terraform-plan.yaml"
REPO = HERE.parents[3]
os.environ["PATH"] = f"{REPO / '.tools' / 'bin'}{os.pathsep}{os.environ.get('PATH', '')}"
GOOD = json.loads((HERE / "plan-good.json").read_text(encoding="utf-8"))

pytestmark = pytest.mark.skipif(shutil.which("kyverno") is None, reason="kyverno CLI not installed")


def evaluate(plan: dict, tmp_path: Path) -> subprocess.CompletedProcess:
    f = tmp_path / "plan.json"
    f.write_text(json.dumps(plan), encoding="utf-8")
    return subprocess.run(["kyverno", "apply", str(POLICY), "--json", str(f), "--remove-color"],
                          capture_output=True, text=True, check=False)


def mutate(fn) -> dict:
    plan = copy.deepcopy(GOOD)
    fn({r["type"]: r for r in plan["resource_changes"]}, plan)
    return plan


CASES = {
    "EKS public API endpoint must not be open": lambda r, p: r["aws_eks_cluster"]["change"]["after"]["vpc_config"][0].update(
        endpoint_public_access=True, public_access_cidrs=["0.0.0.0/0"]),
    "EKS secrets must be envelope-encrypted": lambda r, p: r["aws_eks_cluster"]["change"]["after"].update(
        encryption_config=[]),
    "S3 buckets must block all public access": lambda r, p: r["aws_s3_bucket_public_access_block"]["change"]["after"].update(
        restrict_public_buckets=False),
    "RDS instances must be private and encrypted": lambda r, p: r["aws_db_instance"]["change"]["after"].update(
        publicly_accessible=True),
    "ECR repositories must use immutable tags": lambda r, p: r["aws_ecr_repository"]["change"]["after"].update(
        image_tag_mutability="MUTABLE"),
    "no security-group rule may open": lambda r, p: r["aws_vpc_security_group_ingress_rule"]["change"]["after"].update(
        cidr_ipv4="0.0.0.0/0"),
    "launch templates must require IMDSv2": lambda r, p: r["aws_launch_template"]["change"]["after"]["metadata_options"][0].update(
        http_tokens="optional"),
    "plan destroys stateful resources": lambda r, p: r["aws_db_instance"]["change"].update(
        actions=["delete", "create"]),
}


def test_good_plan_passes(tmp_path):
    res = evaluate(GOOD, tmp_path)
    assert res.returncode == 0, res.stdout + res.stderr
    assert "fail: 0" in res.stdout and "error: 0" in res.stdout


@pytest.mark.parametrize("message", list(CASES))
def test_each_guardrail_catches_its_violation(message, tmp_path):
    res = evaluate(mutate(CASES[message]), tmp_path)
    assert res.returncode != 0
    assert message in res.stdout, res.stdout
    assert "error: 0" in res.stdout, "policy must fail cleanly, not error"
