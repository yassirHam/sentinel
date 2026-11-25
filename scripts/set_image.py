#!/usr/bin/env python3
"""Rewrite the image reference of a Helm values file (GitOps promotion step).

Only the three scalar keys under the top-level ``image:`` block are touched
(repository, tag, digest); comments and every other line are preserved, so
the resulting Git diff is exactly the promotion and nothing else.

    python scripts/set_image.py deploy/helm/sentinel-service/values-dev.yaml \
        --repository 123456789012.dkr.ecr.eu-west-3.amazonaws.com/sentinel/sample-service \
        --tag 3f2a1b9c0d1e --digest sha256:<64 hex>
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

DIGEST_RE = re.compile(r"^sha256:[a-f0-9]{64}$")
TAG_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")
REPO_RE = re.compile(r"^[a-z0-9]+([._-][a-z0-9]+)*(:[0-9]+)?(/[a-z0-9]+([._-][a-z0-9]+)*)*$")


def set_image(text: str, repository: str | None, tag: str | None, digest: str | None) -> str:
    lines = text.splitlines(keepends=True)
    try:
        start = next(i for i, line in enumerate(lines) if re.match(r"^image:\s*(#.*)?$", line))
    except StopIteration:
        raise SystemExit("no top-level 'image:' block found") from None
    wanted = {"repository": repository, "tag": tag, "digest": digest}
    seen: set[str] = set()
    for i in range(start + 1, len(lines)):
        line = lines[i]
        if line.strip() and not line.startswith((" ", "\t")):
            break  # next top-level key: end of the image block
        m = re.match(r"^(\s+)(repository|tag|digest):\s*[^#\n]*?(\s*#.*)?(\r?\n)?$", line)
        if m and wanted[m.group(2)] is not None:
            indent, key, comment, eol = m.group(1), m.group(2), m.group(3) or "", m.group(4) or ""
            lines[i] = f'{indent}{key}: "{wanted[key]}"{comment}{eol}'
            seen.add(key)
    missing = {k for k, v in wanted.items() if v is not None} - seen
    if missing:
        raise SystemExit(f"keys not found under image: {sorted(missing)}")
    return "".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("values_file")
    ap.add_argument("--repository")
    ap.add_argument("--tag")
    ap.add_argument("--digest")
    args = ap.parse_args()
    if args.digest and not DIGEST_RE.match(args.digest):
        sys.exit(f"invalid digest {args.digest!r}")
    if args.tag and not TAG_RE.match(args.tag):
        sys.exit(f"invalid tag {args.tag!r}")
    if args.repository and not REPO_RE.match(args.repository):
        sys.exit(f"invalid repository {args.repository!r}")
    path = Path(args.values_file)
    before = path.read_text(encoding="utf-8")
    after = set_image(before, args.repository, args.tag, args.digest)
    path.write_text(after, encoding="utf-8", newline="")
    print("unchanged" if before == after else f"updated {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
