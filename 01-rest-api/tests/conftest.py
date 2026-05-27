"""Test fixtures shared by all tests."""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

TERRAFORM_DIR = Path(__file__).resolve().parent.parent / "terraform"


@pytest.fixture(scope="session")
def tf() -> dict[str, str]:
    raw = subprocess.check_output(
        ["terraform", "output", "-json"],
        cwd=str(TERRAFORM_DIR),
    )
    parsed = json.loads(raw)
    return {k: v["value"] for k, v in parsed.items()}


@pytest.fixture(scope="session")
def api_base(tf) -> str:
    """Base URL for the API. On LocalEmu, use the bridge path; on AWS, use the host."""
    target = os.environ.get("TARGET", "local")
    if target == "aws":
        return tf["api_endpoint"]
    return f"http://localhost:4566/_aws/execute-api-v2/{tf['api_id']}/$default"
