#!/usr/bin/env python3
"""Pinned, checksum-verified installer for the Sentinel platform toolchain.

Why this exists
---------------
In March 2026 the Trivy release pipeline and the ``trivy-action`` /
``setup-trivy`` tags were hijacked (GHSA-69fq-xp46-6x23): anyone who
downloaded "latest" or followed a mutable tag executed attacker code. The fix
is boring and effective: pin exact versions *and* their SHA-256 digests in the
repository, and refuse to run anything that does not match.

Two sub-commands:

* ``lock``    — resolve the versions in ``TOOLS`` against the vendors' official
  checksum files and write ``tools.lock.json`` (run by a human, reviewed in a
  PR like any other dependency bump).
* ``install`` — download every tool for the current OS/arch, verify it against
  the *committed* lock file, extract it into ``<repo>/.tools/bin``.

Usage::

    python sentinel/tools/tools.py install            # dev laptop / CI
    python sentinel/tools/tools.py install --only terraform helm
    python sentinel/tools/tools.py lock               # maintainers only

Then put ``<repo>/.tools/bin`` on PATH (the script prints the exact command).
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import platform
import stat
import sys
import tarfile
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
LOCK_FILE = HERE / "tools.lock.json"
BIN_DIR = REPO_ROOT / ".tools" / "bin"

GH = "https://github.com"

# name -> version + per-platform asset + where the vendor publishes checksums.
# {v} = version without leading "v", {V} = version as tagged.
TOOLS: dict[str, dict] = {
    "terraform": {
        "version": "1.17.1",
        "assets": {
            "windows-amd64": "https://releases.hashicorp.com/terraform/{v}/terraform_{v}_windows_amd64.zip",
            "linux-amd64": "https://releases.hashicorp.com/terraform/{v}/terraform_{v}_linux_amd64.zip",
        },
        "checksums": "https://releases.hashicorp.com/terraform/{v}/terraform_{v}_SHA256SUMS",
        "binary": "terraform",
    },
    "tflint": {
        "version": "v0.65.0",
        "assets": {
            "windows-amd64": GH + "/terraform-linters/tflint/releases/download/{V}/tflint_windows_amd64.zip",
            "linux-amd64": GH + "/terraform-linters/tflint/releases/download/{V}/tflint_linux_amd64.zip",
        },
        "checksums": GH + "/terraform-linters/tflint/releases/download/{V}/checksums.txt",
        "binary": "tflint",
    },
    "trivy": {
        # Post-incident release line; v0.69.4 was the malicious build.
        "version": "v0.76.1",
        "assets": {
            "windows-amd64": GH + "/aquasecurity/trivy/releases/download/{V}/trivy_{v}_windows-64bit.zip",
            "linux-amd64": GH + "/aquasecurity/trivy/releases/download/{V}/trivy_{v}_Linux-64bit.tar.gz",
        },
        "checksums": GH + "/aquasecurity/trivy/releases/download/{V}/trivy_{v}_checksums.txt",
        "binary": "trivy",
    },
    "helm": {
        "version": "v4.3.1",
        "assets": {
            "windows-amd64": "https://get.helm.sh/helm-{V}-windows-amd64.zip",
            "linux-amd64": "https://get.helm.sh/helm-{V}-linux-amd64.tar.gz",
        },
        # Helm publishes one <asset>.sha256sum file per asset.
        "checksums": "per-asset:.sha256sum",
        "binary": "helm",
    },
    "kind": {
        "version": "v0.33.0",
        "assets": {
            "windows-amd64": GH + "/kubernetes-sigs/kind/releases/download/{V}/kind-windows-amd64",
            "linux-amd64": GH + "/kubernetes-sigs/kind/releases/download/{V}/kind-linux-amd64",
        },
        "checksums": "per-asset:.sha256sum",
        "binary": "kind",
    },
    "kubeconform": {
        "version": "v0.8.0",
        "assets": {
            "windows-amd64": GH + "/yannh/kubeconform/releases/download/{V}/kubeconform-windows-amd64.zip",
            "linux-amd64": GH + "/yannh/kubeconform/releases/download/{V}/kubeconform-linux-amd64.tar.gz",
        },
        "checksums": GH + "/yannh/kubeconform/releases/download/{V}/CHECKSUMS",
        "binary": "kubeconform",
    },
    "kyverno": {
        "version": "v1.19.2",
        "assets": {
            "windows-amd64": GH + "/kyverno/kyverno/releases/download/{V}/kyverno-cli_{V}_windows_x86_64.zip",
            "linux-amd64": GH + "/kyverno/kyverno/releases/download/{V}/kyverno-cli_{V}_linux_x86_64.tar.gz",
        },
        "checksums": GH + "/kyverno/kyverno/releases/download/{V}/checksums.txt",
        "binary": "kyverno",
    },
    "actionlint": {
        "version": "v1.7.12",
        "assets": {
            "windows-amd64": GH + "/rhysd/actionlint/releases/download/{V}/actionlint_{v}_windows_amd64.zip",
            "linux-amd64": GH + "/rhysd/actionlint/releases/download/{V}/actionlint_{v}_linux_amd64.tar.gz",
        },
        "checksums": GH + "/rhysd/actionlint/releases/download/{V}/actionlint_{v}_checksums.txt",
        "binary": "actionlint",
    },
    "hadolint": {
        "version": "v2.15.1",
        "assets": {
            "windows-amd64": GH + "/hadolint/hadolint/releases/download/{V}/hadolint-windows-x86_64.exe",
            "linux-amd64": GH + "/hadolint/hadolint/releases/download/{V}/hadolint-linux-x86_64",
        },
        "checksums": GH + "/hadolint/hadolint/releases/download/{V}/checksums.sha256",
        "binary": "hadolint",
    },
    "cosign": {
        "version": "v3.1.4",
        "assets": {
            "windows-amd64": GH + "/sigstore/cosign/releases/download/{V}/cosign-windows-amd64.exe",
            "linux-amd64": GH + "/sigstore/cosign/releases/download/{V}/cosign-linux-amd64",
        },
        "checksums": GH + "/sigstore/cosign/releases/download/{V}/cosign_checksums.txt",
        "binary": "cosign",
    },
    "syft": {
        "version": "v1.55.0",
        "assets": {
            "windows-amd64": GH + "/anchore/syft/releases/download/{V}/syft_{v}_windows_amd64.zip",
            "linux-amd64": GH + "/anchore/syft/releases/download/{V}/syft_{v}_linux_amd64.tar.gz",
        },
        "checksums": GH + "/anchore/syft/releases/download/{V}/syft_{v}_checksums.txt",
        "binary": "syft",
    },
}


def _fmt(template: str, version: str) -> str:
    return template.format(v=version.lstrip("v"), V=version)


def _fetch(url: str, timeout: int = 120) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "sentinel-tools/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 - pinned https URLs
        return resp.read()


def current_platform() -> str:
    system = platform.system().lower()
    machine = platform.machine().lower()
    arch = {"x86_64": "amd64", "amd64": "amd64"}.get(machine)
    if system not in ("windows", "linux") or arch is None:
        sys.exit(f"unsupported platform {system}/{machine}; extend TOOLS in {__file__}")
    return f"{system}-{arch}"


def _parse_checksum_file(text: str, filename: str) -> str:
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[-1].lstrip("*").split("/")[-1] == filename:
            return parts[0].lower()
        if len(parts) == 1 and len(parts[0]) == 64:  # bare digest (per-asset files)
            return parts[0].lower()
    raise KeyError(f"{filename} not found in checksum file")


def cmd_lock(_: argparse.Namespace) -> int:
    lock: dict[str, dict] = {}
    for name, spec in TOOLS.items():
        version = spec["version"]
        entry = {"version": version, "binary": spec["binary"], "assets": {}}
        shared = None
        if not spec["checksums"].startswith("per-asset:"):
            shared = _fetch(_fmt(spec["checksums"], version)).decode()
        for plat, template in spec["assets"].items():
            url = _fmt(template, version)
            filename = url.rsplit("/", 1)[1]
            if shared is not None:
                digest = _parse_checksum_file(shared, filename)
            else:
                suffix = spec["checksums"].split(":", 1)[1]
                digest = _parse_checksum_file(_fetch(url + suffix).decode(), filename)
            entry["assets"][plat] = {"url": url, "sha256": digest}
            print(f"[lock] {name:12s} {version:9s} {plat:14s} {digest}")
        lock[name] = entry
    LOCK_FILE.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")
    print(f"[lock] wrote {LOCK_FILE}")
    return 0


def _extract_binary(blob: bytes, filename: str, binary: str, dest: Path) -> None:
    exe = binary + (".exe" if dest.suffix == ".exe" else "")
    if filename.endswith(".zip"):
        with zipfile.ZipFile(io.BytesIO(blob)) as zf:
            member = next(m for m in zf.namelist() if m.split("/")[-1] == exe)
            dest.write_bytes(zf.read(member))
    elif filename.endswith(".tar.gz"):
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tf:
            member = next(m for m in tf.getmembers() if m.name.split("/")[-1] == exe and m.isfile())
            extracted = tf.extractfile(member)
            if extracted is None:
                raise RuntimeError(f"{member.name} is not a regular file")
            dest.write_bytes(extracted.read())
    else:  # raw binary
        dest.write_bytes(blob)
    dest.chmod(dest.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def cmd_install(args: argparse.Namespace) -> int:
    if not LOCK_FILE.exists():
        sys.exit(f"missing {LOCK_FILE}; run `tools.py lock` first")
    lock = json.loads(LOCK_FILE.read_text())
    plat = current_platform()
    BIN_DIR.mkdir(parents=True, exist_ok=True)
    names = args.only or sorted(lock)
    for name in names:
        entry = lock[name]
        asset = entry["assets"][plat]
        suffix = ".exe" if plat.startswith("windows") else ""
        dest = BIN_DIR / (entry["binary"] + suffix)
        stamp = BIN_DIR / f".{name}.sha256"
        if dest.exists() and stamp.exists() and stamp.read_text().strip() == asset["sha256"]:
            print(f"[install] {name:12s} {entry['version']:9s} already installed")
            continue
        blob = _fetch(asset["url"], timeout=600)
        digest = hashlib.sha256(blob).hexdigest()
        if digest != asset["sha256"]:
            print(f"[install] {name}: CHECKSUM MISMATCH\n  expected {asset['sha256']}\n  got      {digest}",
                  file=sys.stderr)
            return 3
        filename = asset["url"].rsplit("/", 1)[1]
        _extract_binary(blob, filename, entry["binary"], dest)
        stamp.write_text(asset["sha256"])
        print(f"[install] {name:12s} {entry['version']:9s} verified sha256={digest[:16]}... -> {dest}")
    sep = ";" if os.name == "nt" else ":"
    if str(BIN_DIR) not in os.environ.get("PATH", "").split(sep):
        if os.name == "nt":
            print(f'\nAdd to PATH for this shell:  $env:PATH = "{BIN_DIR};$env:PATH"')
        else:
            print(f'\nAdd to PATH for this shell:  export PATH="{BIN_DIR}:$PATH"')
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Pinned toolchain installer")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("lock", help="resolve vendor checksums into tools.lock.json").set_defaults(func=cmd_lock)
    p_inst = sub.add_parser("install", help="download + verify + extract into .tools/bin")
    p_inst.add_argument("--only", nargs="*", help="subset of tools to install")
    p_inst.set_defaults(func=cmd_install)
    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
