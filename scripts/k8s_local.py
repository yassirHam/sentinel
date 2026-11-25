#!/usr/bin/env python3
"""Local Kubernetes workflow for Sentinel (kind) — Month 1 / Month 2.

Sub-commands (run from ``sentinel/``):

    up        create the 3-node kind cluster (Kubernetes 1.36, = EKS version)
    deploy    build the image, load it into kind, helm upgrade --install (dev values)
    verify    end-to-end checks against the running release:
                * rollout complete, pods spread over nodes, run as UID 10001,
                  read-only root FS, no service-account token mounted
                * helm test (in-namespace connectivity)
                * smoke test + controlled fault experiment through port-forward
                * NetworkPolicy: a pod in another namespace is refused
    platform  install Kyverno + the Sentinel policies and Argo CD (GitOps)
    down      delete the cluster

Every command exits non-zero on failure so it can run in CI.
Tools come from ``python tools/tools.py install`` (.tools/bin is added to PATH).
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SENTINEL = HERE.parent
REPO = SENTINEL.parent
TOOLS_BIN = REPO / ".tools" / "bin"
CLUSTER = "sentinel"
NAMESPACE = "sentinel-dev"
RELEASE = "sentinel"
CHART = SENTINEL / "deploy" / "helm" / "sentinel-service"
IMAGE_REPO = "sentinel-sample-service"

os.environ["PATH"] = f"{TOOLS_BIN}{os.pathsep}{os.environ.get('PATH', '')}"


def run(cmd: list[str], check: bool = True, capture: bool = False, timeout: int = 900,
        input_text: str | None = None) -> subprocess.CompletedProcess:
    print("$ " + " ".join(cmd), flush=True)
    res = subprocess.run(cmd, check=False, text=True, capture_output=capture, timeout=timeout,
                         input=input_text)
    if check and res.returncode != 0:
        if capture:
            sys.stderr.write(res.stdout + res.stderr)
        raise SystemExit(f"command failed ({res.returncode}): {' '.join(cmd)}")
    return res


def kubectl(*args: str, capture: bool = True, check: bool = True, input_text: str | None = None):
    return run(["kubectl", "--context", f"kind-{CLUSTER}", *args], capture=capture, check=check,
               input_text=input_text)


def git_sha() -> str:
    res = run(["git", "-C", str(REPO), "rev-parse", "--short=12", "HEAD"], capture=True, check=False)
    sha = res.stdout.strip() or "local"
    dirty = run(["git", "-C", str(REPO), "status", "--porcelain", "--", "sentinel/app"],
                capture=True, check=False).stdout.strip()
    return f"{sha}-dirty" if dirty else sha


# --------------------------------------------------------------------------- up / down
def cmd_up(_: argparse.Namespace) -> None:
    existing = run(["kind", "get", "clusters"], capture=True).stdout.split()
    if CLUSTER in existing:
        print(f"cluster {CLUSTER} already exists")
        return
    run(["kind", "create", "cluster", "--config", str(SENTINEL / "deploy/kind/kind-config.yaml"),
         "--wait", "180s"])


def cmd_down(_: argparse.Namespace) -> None:
    run(["kind", "delete", "cluster", "--name", CLUSTER])


# --------------------------------------------------------------------------- deploy
def cmd_deploy(args: argparse.Namespace) -> None:
    tag = args.tag or git_sha()
    image = f"{IMAGE_REPO}:{tag}"
    run(["docker", "build", "-t", image, "--build-arg", f"REVISION={tag}", str(SENTINEL)])
    run(["kind", "load", "docker-image", image, "--name", CLUSTER])
    kubectl("create", "namespace", NAMESPACE, check=False)
    # Pod Security Admission: the namespace only admits "restricted" pods.
    kubectl("label", "--overwrite", "namespace", NAMESPACE,
            "pod-security.kubernetes.io/enforce=restricted",
            "pod-security.kubernetes.io/enforce-version=latest",
            "pod-security.kubernetes.io/warn=restricted")
    run(["helm", "upgrade", "--install", RELEASE, str(CHART), "--kube-context", f"kind-{CLUSTER}",
         "-n", NAMESPACE, "-f", str(CHART / "values-dev.yaml"),
         "--set", f"image.repository={IMAGE_REPO}", "--set", f"image.tag={tag}",
         "--set", "image.pullPolicy=Never", "--wait", "--timeout", "180s"])
    print(f"deployed {image} to {NAMESPACE}")


# --------------------------------------------------------------------------- verify
def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _check(cond: bool, msg: str, failures: list[str]) -> None:
    print(("  PASS " if cond else "  FAIL ") + msg, flush=True)
    if not cond:
        failures.append(msg)


def cmd_verify(_: argparse.Namespace) -> None:
    failures: list[str] = []
    fullname = f"{RELEASE}-sentinel-service"
    kubectl("rollout", "status", f"deploy/{fullname}", "-n", NAMESPACE, "--timeout=120s", capture=False)

    pods = json.loads(kubectl("get", "pods", "-n", NAMESPACE, "-l",
                              "app.kubernetes.io/name=sentinel-service", "-o", "json").stdout)["items"]
    _check(len(pods) >= 2, f"{len(pods)} replicas running (>= 2)", failures)
    nodes = {p["spec"].get("nodeName") for p in pods}
    _check(len(nodes) >= 2, f"replicas spread over {len(nodes)} nodes", failures)
    for p in pods:
        spec = p["spec"]
        c = spec["containers"][0]
        sc = c.get("securityContext", {})
        name = p["metadata"]["name"]
        _check(spec["securityContext"].get("runAsUser") == 10001 and spec["securityContext"].get("runAsNonRoot"),
               f"{name}: runs as non-root UID 10001", failures)
        _check(sc.get("readOnlyRootFilesystem") is True, f"{name}: read-only root filesystem", failures)
        _check(sc.get("capabilities", {}).get("drop") == ["ALL"], f"{name}: all capabilities dropped", failures)
        _check(spec.get("automountServiceAccountToken") is False, f"{name}: no API token mounted", failures)
    uid = kubectl("exec", "-n", NAMESPACE, pods[0]["metadata"]["name"], "--", "id", "-u").stdout.strip()
    _check(uid == "10001", f"process UID inside container = {uid}", failures)
    write = kubectl("exec", "-n", NAMESPACE, pods[0]["metadata"]["name"], "--", "sh", "-c",
                    "touch /srv/x 2>&1 || echo READONLY", check=False).stdout
    _check("READONLY" in write or "Read-only" in write, "writing to the image filesystem is refused", failures)

    res = run(["helm", "test", RELEASE, "-n", NAMESPACE, "--kube-context", f"kind-{CLUSTER}", "--logs"],
              check=False, capture=True)
    _check(res.returncode == 0 and "helm test OK" in res.stdout, "helm test (in-namespace connectivity)", failures)

    # NetworkPolicy: a client in another namespace must time out.
    kubectl("create", "namespace", "np-probe", check=False)
    kubectl("label", "--overwrite", "namespace", "np-probe", "pod-security.kubernetes.io/enforce=restricted")
    probe = kubectl(
        "run", "np-probe", "-n", "np-probe", "--rm", "-i", "--restart=Never", "--quiet",
        "--image=busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec",
        "--overrides", json.dumps({"spec": {"securityContext": {"runAsNonRoot": True, "runAsUser": 65534,
                                                                 "seccompProfile": {"type": "RuntimeDefault"}},
                                            "containers": [{"name": "np-probe",
                                                            "image": "busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec",
                                                            "command": ["sh", "-c", f"wget -T 5 -q -O- http://{fullname}.{NAMESPACE}/healthz && echo REACHED || echo BLOCKED"],
                                                            "securityContext": {"allowPrivilegeEscalation": False,
                                                                                "readOnlyRootFilesystem": True,
                                                                                "capabilities": {"drop": ["ALL"]}},
                                                            "resources": {"requests": {"cpu": "10m", "memory": "16Mi"},
                                                                          "limits": {"memory": "32Mi"}}}]}}),
        check=False)
    _check("BLOCKED" in probe.stdout, "NetworkPolicy blocks other namespaces", failures)
    if "BLOCKED" not in probe.stdout:
        print(probe.stdout[-500:], probe.stderr[-500:])
    kubectl("delete", "namespace", "np-probe", "--wait=false", check=False)

    port = _free_port()
    # Forward to ONE pod explicitly: fault state and counters are per process,
    # so every request of an experiment must hit the same replica.
    target_pod = pods[0]["metadata"]["name"]
    pf = subprocess.Popen(["kubectl", "--context", f"kind-{CLUSTER}", "port-forward", "-n", NAMESPACE,
                           f"pod/{target_pod}", f"{port}:8000"], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL)
    try:
        time.sleep(3)
        base = f"http://127.0.0.1:{port}"
        smoke = run([sys.executable, str(HERE / "smoke_test.py"), "--base-url", base], check=False, capture=True)
        print(smoke.stdout)
        _check(smoke.returncode == 0, "smoke test (port-forward to one replica)", failures)
        fault = run([sys.executable, str(HERE / "fault_test.py"), "--base-url", base, "-n", "40", "--rate", "0.5"],
                    check=False, capture=True)
        print(fault.stdout)
        _check(fault.returncode == 0, "fault experiment on one replica (dev has fault injection on)", failures)
    finally:
        pf.terminate()

    if failures:
        raise SystemExit(f"{len(failures)} check(s) failed: {failures}")
    print("ALL KUBERNETES CHECKS PASSED")


# --------------------------------------------------------------------------- platform
KYVERNO_CHART_VERSION = "3.9.2"   # Kyverno v1.19.2
ARGOCD_CHART_VERSION = "10.11.6"  # Argo CD v3.5.6
METRICS_SERVER_CHART_VERSION = "3.14.0"  # metrics-server v0.9.0


def cmd_platform(_: argparse.Namespace) -> None:
    ctx = ["--kube-context", f"kind-{CLUSTER}"]
    # metrics-server: on EKS it is an EKS add-on (modules/eks); on kind the
    # kubelets use self-signed serving certs, hence --kubelet-insecure-tls.
    run(["helm", "repo", "add", "metrics-server", "https://kubernetes-sigs.github.io/metrics-server/",
         "--force-update"])
    run(["helm", "upgrade", "--install", "metrics-server", "metrics-server/metrics-server", *ctx,
         "-n", "kube-system", "--version", METRICS_SERVER_CHART_VERSION,
         "--set", "args={--kubelet-insecure-tls}", "--wait", "--timeout", "300s"])
    run(["helm", "repo", "add", "kyverno", "https://kyverno.github.io/kyverno/", "--force-update"])
    run(["helm", "repo", "add", "argo", "https://argoproj.github.io/argo-helm", "--force-update"])
    run(["helm", "repo", "update", "kyverno", "argo"])
    run(["helm", "upgrade", "--install", "kyverno", "kyverno/kyverno", *ctx, "-n", "kyverno",
         "--create-namespace", "--version", KYVERNO_CHART_VERSION,
         "-f", str(SENTINEL / "deploy/platform/kyverno-values.yaml"), "--wait", "--timeout", "300s"])
    kubectl("apply", "-f", str(SENTINEL / "deploy/policies/kyverno"), capture=False)
    run(["helm", "upgrade", "--install", "argocd", "argo/argo-cd", *ctx, "-n", "argocd",
         "--create-namespace", "--version", ARGOCD_CHART_VERSION,
         "-f", str(SENTINEL / "deploy/platform/argocd-values.yaml"), "--wait", "--timeout", "600s"])
    kubectl("apply", "-f", str(SENTINEL / "deploy/argocd/projects"), capture=False)
    # Local Git server for the GitOps loop (scripts/gitops_local.py). The
    # PolicyException must be live before the Deployment is admitted, so retry.
    for _attempt in range(6):
        res = kubectl("apply", "-f", str(SENTINEL / "deploy/kind/gitea.yaml"), check=False)
        if res.returncode == 0:
            break
        time.sleep(5)
    else:
        raise SystemExit("could not deploy the Gitea fixture: " + res.stderr)
    kubectl("rollout", "status", "deploy/git", "-n", "gitops", "--timeout=300s", capture=False)


def cmd_policies(_: argparse.Namespace) -> None:
    """Admission e2e: every bad case is denied by the live webhook, good ones admitted.

    Uses server-side dry-run, so the request goes through the real API server
    and Kyverno admission webhooks but nothing is persisted.
    """
    import yaml

    failures: list[str] = []
    docs = list(yaml.safe_load_all((SENTINEL / "deploy/policies/tests/pods/resources.yaml").read_text()))
    kubectl("create", "namespace", "sentinel-prod", check=False)
    kubectl("label", "--overwrite", "namespace", "sentinel-prod", "sentinel.io/env=prod")
    kubectl("label", "--overwrite", "namespace", NAMESPACE, "sentinel.io/env=dev")
    for doc in docs:
        name = doc["metadata"]["name"]
        # good-ecr-digest satisfies every *validating* rule (that is what the
        # offline suite checks) but it was never signed by Sentinel CI, so the
        # live ImageValidatingPolicy must refuse it.
        expect_allowed = name == "good-pod"
        res = kubectl("apply", "--dry-run=server", "-f", "-", input_text=yaml.safe_dump(doc), check=False)
        allowed = res.returncode == 0
        reason = (res.stderr or res.stdout).strip().splitlines()[-1][:160] if not allowed else "admitted"
        _check(allowed == expect_allowed,
               f"{doc['kind']}/{name}: {'admitted' if allowed else 'denied'} (expected "
               f"{'admit' if expect_allowed else 'deny'}) - {reason}", failures)
        if name == "good-ecr-digest":
            _check("sentinel-verify-signed-images" in (res.stderr or ""),
                   "unsigned ECR image refused by the signature policy (not by another rule)", failures)
    if failures:
        raise SystemExit(f"{len(failures)} admission check(s) failed")
    print("ALL ADMISSION CHECKS PASSED")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("up").set_defaults(func=cmd_up)
    sub.add_parser("down").set_defaults(func=cmd_down)
    p = sub.add_parser("deploy")
    p.add_argument("--tag", help="image tag (default: git sha)")
    p.set_defaults(func=cmd_deploy)
    sub.add_parser("verify").set_defaults(func=cmd_verify)
    sub.add_parser("platform").set_defaults(func=cmd_platform)
    sub.add_parser("policies").set_defaults(func=cmd_policies)
    args = ap.parse_args()
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
