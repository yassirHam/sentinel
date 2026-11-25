#!/usr/bin/env python3
"""Policy-as-code test runner (Month 2, DevSecOps).

1. Renders the Helm chart for dev and prod (prod with a sample ECR digest,
   exactly what GitOps would deploy) into deploy/policies/tests/chart/.
2. Runs ``kyverno test`` on every test suite under deploy/policies/tests.
3. Optionally (``--signatures``) runs the online Cosign keyless suite, which
   needs network access to a registry and the Sigstore public-good instance.

Exit code is non-zero on any failure (used by CI).
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

SENTINEL = Path(__file__).resolve().parents[1]
REPO = SENTINEL.parent
CHART = SENTINEL / "deploy/helm/sentinel-service"
TESTS = SENTINEL / "deploy/policies/tests"
os.environ["PATH"] = f"{REPO / '.tools' / 'bin'}{os.pathsep}{os.environ.get('PATH', '')}"

PROD_IMAGE = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/sentinel/sample-service"
PROD_DIGEST = "sha256:" + "0" * 64


def render(env: str, extra: list[str]) -> None:
    out = subprocess.run(
        ["helm", "template", "sentinel", str(CHART), "-n", f"sentinel-{env}",
         "-f", str(CHART / f"values-{env}.yaml"), *extra],
        check=True, capture_output=True, text=True,
    ).stdout
    # helm template omits metadata.namespace; kyverno needs it to resolve namespaceObject.
    out = out.replace("\nmetadata:\n", f"\nmetadata:\n  namespace: sentinel-{env}\n")
    (TESTS / "chart" / f"rendered-{env}.yaml").write_text(out, encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--signatures", action="store_true", help="also run the online keyless-signature suite")
    args = ap.parse_args()
    render("dev", [])
    render("prod", ["--set", f"image.repository={PROD_IMAGE}", "--set", f"image.digest={PROD_DIGEST}"])
    suites = [TESTS / "pods", TESTS / "chart"]
    if args.signatures:
        suites.append(TESTS / "signatures")
    rc = 0
    for suite in suites:
        print(f"== kyverno test {suite.relative_to(SENTINEL)}", flush=True)
        res = subprocess.run(["kyverno", "test", str(suite), "--remove-color"], text=True)
        rc |= res.returncode
    return rc


if __name__ == "__main__":
    sys.exit(main())
