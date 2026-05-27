"""Test fixtures: boto3 clients, account seeding, api_base, queue drain."""
from __future__ import annotations

import json
import os
import subprocess
import time
import uuid
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
def api_base(tf) -> str:
    if os.environ.get("TARGET", "local") == "aws":
        return tf["api_endpoint"]
    return f"http://localhost:4566/_aws/execute-api-v2/{tf['api_id']}/$default"


@pytest.fixture(scope="session")
def dynamodb():
    return boto3.resource("dynamodb", **_aws_kwargs())


@pytest.fixture(scope="session")
def sqs():
    return boto3.client("sqs", **_aws_kwargs())


@pytest.fixture
def fresh_accounts(dynamodb, tf) -> tuple[str, str]:
    """Create two active accounts: alice with 10000 minor units, bob with 0."""
    alice = f"alice-{uuid.uuid4().hex[:8]}"
    bob = f"bob-{uuid.uuid4().hex[:8]}"
    t = dynamodb.Table(tf["accounts_table"])
    t.put_item(Item={"account_id": alice, "balance": 10000, "status": "active"})
    t.put_item(Item={"account_id": bob, "balance": 0, "status": "active"})
    return alice, bob


@pytest.fixture
def balance_of(dynamodb, tf):
    t = dynamodb.Table(tf["accounts_table"])

    def _balance(account_id: str) -> int:
        return int(t.get_item(Key={"account_id": account_id}).get("Item", {}).get("balance", 0))

    return _balance


def drain_queue(sqs_client, queue_url: str) -> list[dict]:
    """Receive-and-delete everything on a queue, return the messages."""
    out = []
    while True:
        resp = sqs_client.receive_message(
            QueueUrl=queue_url, MaxNumberOfMessages=10, WaitTimeSeconds=0
        )
        msgs = resp.get("Messages", [])
        if not msgs:
            break
        for m in msgs:
            out.append(m)
            sqs_client.delete_message(QueueUrl=queue_url, ReceiptHandle=m["ReceiptHandle"])
    return out


def collect_messages(sqs_client, queue_url: str, *, expected: int, timeout: float = 10.0) -> list[dict]:
    """Poll for expected messages; return as soon as we have them or timeout expires."""
    out = []
    deadline = time.monotonic() + timeout
    while len(out) < expected and time.monotonic() < deadline:
        resp = sqs_client.receive_message(
            QueueUrl=queue_url, MaxNumberOfMessages=10, WaitTimeSeconds=1
        )
        for m in resp.get("Messages", []):
            out.append(m)
            sqs_client.delete_message(QueueUrl=queue_url, ReceiptHandle=m["ReceiptHandle"])
    return out
