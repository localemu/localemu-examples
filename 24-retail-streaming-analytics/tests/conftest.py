"""Test fixtures: clients, terraform outputs, Athena query helper."""
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
    raw = subprocess.check_output(["terraform", "output", "-json"], cwd=str(TERRAFORM_DIR))
    parsed = json.loads(raw)
    return {k: v["value"] for k, v in parsed.items()}


@pytest.fixture(scope="session")
def firehose():
    return boto3.client("firehose", **_aws_kwargs())


@pytest.fixture(scope="session")
def athena():
    return boto3.client("athena", **_aws_kwargs())


@pytest.fixture(scope="session")
def s3():
    return boto3.client("s3", **_aws_kwargs())


def query(athena_client, tf: dict, sql: str, *, timeout: float = 30.0) -> list[list[str | None]]:
    qid = athena_client.start_query_execution(
        QueryString=sql,
        ResultConfiguration={"OutputLocation": f"s3://{tf['athena_results_bucket']}/"},
    )["QueryExecutionId"]

    deadline = time.monotonic() + timeout
    status = {}
    while time.monotonic() < deadline:
        status = athena_client.get_query_execution(QueryExecutionId=qid)["QueryExecution"]["Status"]
        if status["State"] in ("SUCCEEDED", "FAILED", "CANCELLED"):
            break
        time.sleep(1)

    if status.get("State") != "SUCCEEDED":
        raise AssertionError(f"query did not succeed: {status}")

    rows = athena_client.get_query_results(QueryExecutionId=qid)["ResultSet"]["Rows"]
    return [[c.get("VarCharValue") for c in r["Data"]] for r in rows]


def put_event(firehose_client, tf: dict, record: dict) -> None:
    # Firehose concatenates records with no delimiter of its own (real AWS
    # behavior) - the trailing newline is what keeps multiple records in
    # one delivered file individually parseable as NDJSON.
    firehose_client.put_record(
        DeliveryStreamName=tf["delivery_stream_name"],
        Record={"Data": (json.dumps(record) + "\n").encode()},
    )
