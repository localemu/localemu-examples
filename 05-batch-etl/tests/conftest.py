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
SAMPLE_CSV = Path(__file__).resolve().parent.parent / "sample" / "orders.csv"


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
    kwargs = _aws_kwargs()
    if "endpoint_url" in kwargs:
        from botocore.config import Config
        return boto3.client("s3", **kwargs, config=Config(s3={"addressing_style": "path"}))
    return boto3.client("s3", **kwargs)


@pytest.fixture(scope="session")
def dynamodb():
    return boto3.resource("dynamodb", **_aws_kwargs())


@pytest.fixture(scope="session")
def sfn():
    return boto3.client("stepfunctions", **_aws_kwargs())


def wait_for_execution(sfn_client, execution_arn: str, *, timeout: float = 90.0) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        desc = sfn_client.describe_execution(executionArn=execution_arn)
        if desc["status"] != "RUNNING":
            return desc
        time.sleep(0.5)
    raise AssertionError(f"Execution {execution_arn} still RUNNING after {timeout}s")
