"""Test fixtures shared by all tests."""
from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

import boto3
import pytest
import requests

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
    """Read Terraform outputs once per session."""
    raw = subprocess.check_output(
        ["terraform", "output", "-json"],
        cwd=str(TERRAFORM_DIR),
    )
    parsed = json.loads(raw)
    return {k: v["value"] for k, v in parsed.items()}


@pytest.fixture(scope="session")
def dynamodb():
    return boto3.resource("dynamodb", **_aws_kwargs())


@pytest.fixture(scope="session")
def sqs_client():
    return boto3.client("sqs", **_aws_kwargs())


@pytest.fixture
def clean_cache(dynamodb, tf):
    """Truncate the three tables before each test; return the cache Table."""
    for name_key in ("cache_table", "incidents_table", "scores_table"):
        table = dynamodb.Table(tf[name_key])
        keys = [k["AttributeName"] for k in table.key_schema]
        for item in table.scan().get("Items", []):
            table.delete_item(Key={k: item[k] for k in keys})
    return dynamodb.Table(tf["cache_table"])


@pytest.fixture(scope="session")
def ask(tf):
    """HTTP POST to /ask; returns a requests.Response."""
    target = os.environ.get("TARGET", "local")
    if target == "local":
        base = f"http://localhost:4566/_aws/execute-api-v2/{tf['api_id']}/$default"
    else:
        base = tf["api_endpoint"]

    def _ask(question: str) -> requests.Response:
        return requests.post(
            f"{base}/ask",
            json={"question": question},
            timeout=30,
        )

    return _ask


def wait_for(fn, *, timeout: float = 30.0, interval: float = 0.5):
    """Poll fn() until it returns a truthy value or timeout."""
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = fn()
        if last:
            return last
        time.sleep(interval)
    raise AssertionError(f"wait_for timeout after {timeout}s, last result={last!r}")
