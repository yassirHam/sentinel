"""GitOps promotion helper: only the image keys change, comments survive."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from set_image import set_image  # noqa: E402

VALUES = """# dev overlay
image:
  repository: sentinel-sample-service   # local
  tag: "0.2.0"
  digest: ""
app:
  tag: keep-me
"""


def test_rewrites_only_image_block():
    ecr = "123456789012.dkr.ecr.eu-west-3.amazonaws.com/sentinel/sample-service"
    out = set_image(VALUES, ecr, "abc123", "sha256:" + "a" * 64)
    assert f'repository: "{ecr}"   # local' in out
    assert 'tag: "abc123"' in out
    assert f'digest: "sha256:{"a" * 64}"' in out
    assert "  tag: keep-me" in out          # same key name outside the block untouched
    assert out.startswith("# dev overlay")


def test_missing_block_fails():
    with pytest.raises(SystemExit):
        set_image("app:\n  x: 1\n", None, "t", None)


def test_real_values_files_are_editable():
    root = Path(__file__).resolve().parents[1] / "deploy/helm/sentinel-service"
    for name in ("values-dev.yaml", "values-prod.yaml"):
        out = set_image((root / name).read_text(encoding="utf-8"), None, "deadbeef", "sha256:" + "b" * 64)
        assert 'tag: "deadbeef"' in out
