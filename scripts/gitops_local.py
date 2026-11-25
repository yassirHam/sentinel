#!/usr/bin/env python3
"""End-to-end GitOps test on kind, without pushing anything to GitHub.

Prerequisites: ``k8s_local.py up`` + ``k8s_local.py platform`` (Kyverno,
policies, Argo CD) and the Gitea fixture (deploy/kind/gitea.yaml).

Steps (each asserted):
  1. snapshot the *working tree* (tracked + untracked, minus .gitignore) into
     a throw-away repo, point every Argo CD repoURL at the in-cluster Gitea,
     push it there;
  2. apply the AppProject + the root app-of-apps;
  3. wait until every child Application is Synced + Healthy (dev), and
     sentinel-prod stays un-synced (manual promotion only);
  4. DRIFT: change the live Deployment by hand -> Argo CD self-heals it;
  5. CHANGE: commit a values change to Git -> Argo CD rolls it out.
"""
from __future__ import annotations

import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SENTINEL = HERE.parent
REPO = SENTINEL.parent
os.environ["PATH"] = f"{REPO / '.tools' / 'bin'}{os.pathsep}{os.environ.get('PATH', '')}"
CTX = "kind-sentinel"
GITHUB_URL = "https://github.com/yassirHam/sentinel-orion.git"
GITEA_URL = "http://git.gitops.svc.cluster.local:3000/sentinel/sentinel-orion.git"
GIT_USER = "sentinel"


def sh(cmd: list[str], check: bool = True, cwd: Path | None = None, input_text: str | None = None,
       quiet: bool = False) -> subprocess.CompletedProcess:
    if not quiet:
        print("$ " + " ".join(c if "@127.0.0.1" not in c else "<git remote>" for c in cmd), flush=True)
    res = subprocess.run(cmd, text=True, capture_output=True, cwd=cwd, input=input_text, check=False)
    if check and res.returncode != 0:
        sys.stderr.write(res.stdout + res.stderr)
        raise SystemExit(f"failed: {cmd[0]} ({res.returncode})")
    return res


def kubectl(*args: str, **kw) -> subprocess.CompletedProcess:
    return sh(["kubectl", "--context", CTX, *args], **kw)


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def gitea_admin(password: str) -> None:
    pod = kubectl("get", "pod", "-n", "gitops", "-l", "app.kubernetes.io/name=gitea", "-o",
                  "jsonpath={.items[0].metadata.name}").stdout
    base = ["exec", "-n", "gitops", pod, "--", "gitea", "admin", "user"]
    res = kubectl(*base, "create", "--admin", "--username", GIT_USER, "--password", password,
                  "--email", "sentinel@example.invalid", "--must-change-password=false", check=False, quiet=True)
    if res.returncode != 0:
        kubectl(*base, "change-password", "--username", GIT_USER, "--password", password,
                "--must-change-password=false", quiet=True)


def snapshot(dest: Path) -> None:
    files = sh(["git", "-C", str(REPO), "ls-files", "-co", "--exclude-standard", "-z"], quiet=True).stdout
    for rel in filter(None, files.split("\0")):
        src = REPO / rel
        if src.is_file():
            target = dest / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, target)
    for manifest in (dest / "sentinel/deploy/argocd").rglob("*.yaml"):
        manifest.write_text(manifest.read_text(encoding="utf-8").replace(GITHUB_URL, GITEA_URL), encoding="utf-8")


def git(repo: Path, *args: str) -> None:
    sh(["git", "-c", "user.name=sentinel-ci", "-c", "user.email=ci@example.invalid", *args], cwd=repo, quiet=True)


def apps() -> dict[str, dict]:
    out = kubectl("get", "applications.argoproj.io", "-n", "argocd", "-o", "json", quiet=True).stdout
    return {a["metadata"]["name"]: a for a in json.loads(out)["items"]}


def wait_for(pred, what: str, timeout: int = 300, interval: int = 5) -> bool:
    t0 = time.time()
    while time.time() - t0 < timeout:
        if pred():
            print(f"  PASS {what} ({time.time() - t0:.0f}s)", flush=True)
            return True
        time.sleep(interval)
    print(f"  FAIL {what} (timeout {timeout}s)", flush=True)
    for name, a in apps().items():
        for cond in a.get("status", {}).get("conditions", []):
            print(f"       {name}: {cond.get('type')}: {cond.get('message', '')[:200]}", flush=True)
    return False


def status(name: str) -> tuple[str, str]:
    a = apps().get(name, {})
    st = a.get("status", {})
    return st.get("sync", {}).get("status", "?"), st.get("health", {}).get("status", "?")


def main() -> int:
    failures = 0
    password = secrets.token_urlsafe(18)
    gitea_admin(password)
    port = free_port()
    pf = subprocess.Popen(["kubectl", "--context", CTX, "port-forward", "-n", "gitops", "svc/git", f"{port}:3000"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    work = Path(tempfile.mkdtemp(prefix="sentinel-gitops-"))
    try:
        time.sleep(3)
        remote = f"http://{GIT_USER}:{password}@127.0.0.1:{port}/{GIT_USER}/sentinel-orion.git"
        snapshot(work)
        git(work, "init", "-q", "-b", "master")
        git(work, "add", "-A")
        git(work, "commit", "-q", "-m", "snapshot of working tree for local GitOps test")
        git(work, "push", "-q", "--force", remote, "master")
        print(f"pushed working-tree snapshot to in-cluster Gitea ({GITEA_URL})")

        # The chart's dev values reference the locally built image tag.
        sh(["docker", "tag", "sentinel-sample-service:dev", "sentinel-sample-service:0.2.0"])
        sh(["kind", "load", "docker-image", "sentinel-sample-service:0.2.0", "--name", "sentinel"], check=False)
        # Argo CD becomes the single owner of the dev release.
        sh(["helm", "uninstall", "sentinel", "-n", "sentinel-dev", "--kube-context", CTX, "--wait"], check=False)

        kubectl("apply", "-f", str(SENTINEL / "deploy/argocd/projects"))
        root = (SENTINEL / "deploy/argocd/root-app.yaml").read_text(encoding="utf-8").replace(GITHUB_URL, GITEA_URL)
        kubectl("apply", "-f", "-", input_text=root)

        expected = {"sentinel-root", "kyverno", "kyverno-policies", "sentinel-dev", "sentinel-prod"}
        failures += not wait_for(lambda: expected <= set(apps()), "app-of-apps created all child Applications")
        for name in ("kyverno-policies", "sentinel-dev"):
            failures += not wait_for(lambda n=name: status(n) == ("Synced", "Healthy"), f"{name} Synced + Healthy")
        failures += not wait_for(lambda: status("kyverno")[0] == "Synced", "kyverno (upstream chart) Synced",
                                 timeout=600)
        failures += not wait_for(lambda: status("sentinel-root") == ("Synced", "Healthy"),
                                 "sentinel-root (app-of-apps) Synced + Healthy, no flapping")
        sync, _ = status("sentinel-prod")
        print(f"  {'PASS' if sync != 'Synced' else 'FAIL'} sentinel-prod not auto-synced (sync={sync}): "
              "promotion to prod is manual")
        failures += sync == "Synced"

        dep = "sentinel-sentinel-service"
        # --- drift: tamper with the live object, Argo CD must revert it ------
        kubectl("set", "env", "-n", "sentinel-dev", f"deploy/{dep}", "LOG_LEVEL=ERROR")

        def log_level() -> str:
            return kubectl("get", "deploy", dep, "-n", "sentinel-dev", "-o",
                           "jsonpath={.spec.template.spec.containers[0].env[?(@.name=='LOG_LEVEL')].value}",
                           quiet=True).stdout

        failures += not wait_for(lambda: log_level() == "DEBUG", "self-heal reverted manual drift (LOG_LEVEL back to DEBUG)",
                                 timeout=240)

        # --- change through Git: values-dev.yaml logLevel DEBUG -> INFO -----
        values = work / "sentinel/deploy/helm/sentinel-service/values-dev.yaml"
        values.write_text(values.read_text(encoding="utf-8").replace("logLevel: DEBUG", "logLevel: INFO"),
                          encoding="utf-8")
        git(work, "commit", "-q", "-am", "dev: lower log verbosity")
        git(work, "push", "-q", remote, "master")
        kubectl("annotate", "applications.argoproj.io", "sentinel-dev", "-n", "argocd",
                "argocd.argoproj.io/refresh=normal", "--overwrite", quiet=True)
        failures += not wait_for(lambda: log_level() == "INFO", "Git commit rolled out by Argo CD (LOG_LEVEL=INFO)",
                                 timeout=300)
        failures += not wait_for(lambda: status("sentinel-dev") == ("Synced", "Healthy"),
                                 "sentinel-dev Synced + Healthy after the change")
    finally:
        pf.terminate()
        shutil.rmtree(work, ignore_errors=True)

    print("\nApplications:")
    for name, a in sorted(apps().items()):
        st = a.get("status", {})
        print(f"  {name:18s} sync={st.get('sync', {}).get('status', '?'):10s} "
              f"health={st.get('health', {}).get('status', '?'):12s} rev={st.get('sync', {}).get('revision', '')[:10]}")
    if failures:
        print(f"\n{failures} GitOps check(s) failed")
        return 1
    print("\nALL GITOPS CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
