"""Test fixtures shared across tests."""
from __future__ import annotations

import os

import boto3
import pytest

ENDPOINT = os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566")
CLIENT_KWARGS = dict(
    endpoint_url=ENDPOINT,
    aws_access_key_id="AKIAIOSFODNN7EXAMPLE",
    aws_secret_access_key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    region_name="us-east-1",
)


@pytest.fixture(scope="session")
def s3_client():
    return boto3.client("s3", **CLIENT_KWARGS)


@pytest.fixture(scope="session")
def dynamodb_client():
    return boto3.client("dynamodb", **CLIENT_KWARGS)
