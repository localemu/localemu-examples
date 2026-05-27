"""Test fixtures."""
from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

import boto3
import pytest

TERRAFORM_DIR = Path(__file__).resolve().parent.parent / "terraform"


def _aws_kwargs() -> dict:
    target = os.environ.get("TARGET", "local")
    if target == "local":
        return {
            "region_name": "us-east-1",
            "aws_access_key_id": "AKIAIOSFODNN7EXAMPLE",
            "aws_secret_access_key": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "endpoint_url": "http://localhost:4566",
        }
    return {"region_name": os.environ.get("AWS_REGION", "us-east-1")}


@pytest.fixture(scope="session")
def tf() -> dict[str, str]:
    raw = subprocess.check_output(
        ["terraform", "output", "-json"],
        cwd=str(TERRAFORM_DIR),
    )
    parsed = json.loads(raw)
    return {k: v["value"] for k, v in parsed.items()}


@pytest.fixture(scope="session")
def s3():
    # S3 on LocalEmu requires path-style addressing to resolve correctly.
    kwargs = _aws_kwargs()
    if "endpoint_url" in kwargs:
        from botocore.config import Config
        return boto3.client("s3", **kwargs, config=Config(s3={"addressing_style": "path"}))
    return boto3.client("s3", **kwargs)


@pytest.fixture(scope="session")
def sns():
    return boto3.client("sns", **_aws_kwargs())


@pytest.fixture(scope="session")
def sqs():
    return boto3.client("sqs", **_aws_kwargs())


@pytest.fixture(scope="session")
def cloudwatch():
    return boto3.client("cloudwatch", **_aws_kwargs())


def wait_for(fn, *, timeout: float = 60.0, interval: float = 0.5):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = fn()
        if last:
            return last
        time.sleep(interval)
    raise AssertionError(f"wait_for timeout after {timeout}s, last={last!r}")
