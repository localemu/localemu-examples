"""Test fixtures: clients, terraform outputs."""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import boto3
import pytest
from botocore.config import Config

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
    raw = subprocess.check_output(["terraform", "output", "-json"], cwd=str(TERRAFORM_DIR))
    parsed = json.loads(raw)
    return {k: v["value"] for k, v in parsed.items()}


@pytest.fixture(scope="session")
def lambda_client():
    # Real local inference (BEDROCK_BACKEND=ollama) can take over a minute when
    # a model has to be loaded, and a retry would only start a second load.
    return boto3.client(
        "lambda", config=Config(read_timeout=300, retries={"max_attempts": 1}), **_aws_kwargs()
    )


@pytest.fixture(scope="session")
def dynamodb():
    return boto3.resource("dynamodb", **_aws_kwargs())


def ask(lambda_client, function_name: str, question: str) -> dict:
    resp = lambda_client.invoke(
        FunctionName=function_name,
        InvocationType="RequestResponse",
        Payload=json.dumps({"question": question}).encode(),
    )
    return json.loads(resp["Payload"].read())
