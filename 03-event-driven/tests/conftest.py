"""Test fixtures: stack outputs + boto3 clients."""
from __future__ import annotations

import os
import time

import boto3
import pytest

STACK_NAME = os.environ.get("STACK_NAME", "le-events")


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
def cfn():
    return boto3.client("cloudformation", **_aws_kwargs())


@pytest.fixture(scope="session")
def stack(cfn) -> dict[str, str]:
    """Fetch the stack outputs once per session."""
    resp = cfn.describe_stacks(StackName=STACK_NAME)
    outputs = resp["Stacks"][0]["Outputs"]
    return {o["OutputKey"]: o["OutputValue"] for o in outputs}


@pytest.fixture(scope="session")
def sns():
    return boto3.client("sns", **_aws_kwargs())


@pytest.fixture(scope="session")
def sqs():
    return boto3.client("sqs", **_aws_kwargs())


@pytest.fixture(scope="session")
def dynamodb():
    return boto3.resource("dynamodb", **_aws_kwargs())


def wait_for(fn, *, timeout: float = 45.0, interval: float = 0.5):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = fn()
        if last:
            return last
        time.sleep(interval)
    raise AssertionError(f"wait_for timeout after {timeout}s, last={last!r}")
