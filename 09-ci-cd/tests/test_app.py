"""Integration tests for the file processor."""
from __future__ import annotations

import json
import os
import sys

import pytest

# Make src/ importable
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from app import process_file  # noqa: E402

# Make sure the app picks up the LocalEmu endpoint the tests use.
os.environ.setdefault("AWS_ENDPOINT_URL", "http://localhost:4566")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "AKIAIOSFODNN7EXAMPLE")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")


@pytest.fixture(autouse=True)
def setup_resources(s3_client, dynamodb_client):
    """Create the S3 bucket and DynamoDB table before each test; clean rows after."""
    try:
        s3_client.create_bucket(Bucket="uploads")
    except s3_client.exceptions.BucketAlreadyOwnedByYou:
        pass
    except s3_client.exceptions.BucketAlreadyExists:
        pass

    try:
        dynamodb_client.create_table(
            TableName="processed-records",
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        dynamodb_client.get_waiter("table_exists").wait(TableName="processed-records")
    except dynamodb_client.exceptions.ResourceInUseException:
        pass

    yield

    # Clean up rows so tests don't see each other's data.
    try:
        scan = dynamodb_client.scan(TableName="processed-records")
        for item in scan.get("Items", []):
            dynamodb_client.delete_item(
                TableName="processed-records",
                Key={"id": item["id"]},
            )
    except Exception:
        pass


def test_process_file_writes_all_records(s3_client, dynamodb_client):
    """Upload a JSON file with 3 records, verify all 3 land in DynamoDB."""
    test_data = json.dumps({"records": [
        {"id": "r1", "name": "Alice"},
        {"id": "r2", "name": "Bob"},
        {"id": "r3", "name": "Charlie"},
    ]})
    s3_client.put_object(Bucket="uploads", Key="batch-001.json", Body=test_data)

    result = process_file("uploads", "batch-001.json")
    assert result["processed"] == 3
    assert result["source"] == "s3://uploads/batch-001.json"

    for rid, name in [("r1", "Alice"), ("r2", "Bob"), ("r3", "Charlie")]:
        item = dynamodb_client.get_item(
            TableName="processed-records",
            Key={"id": {"S": rid}},
        )["Item"]
        assert item["name"]["S"] == name
        assert item["status"]["S"] == "processed"
        assert item["source_file"]["S"] == "batch-001.json"


def test_process_file_handles_empty_records(s3_client):
    """An empty records array should process zero items without errors."""
    s3_client.put_object(
        Bucket="uploads",
        Key="empty.json",
        Body=json.dumps({"records": []}),
    )
    result = process_file("uploads", "empty.json")
    assert result["processed"] == 0


def test_process_file_sets_source_file(s3_client, dynamodb_client):
    """The source_file field should match the S3 key of the input file."""
    test_data = json.dumps({"records": [
        {"id": "src-1", "name": "Diana"},
    ]})
    s3_client.put_object(Bucket="uploads", Key="report-42.json", Body=test_data)

    process_file("uploads", "report-42.json")

    item = dynamodb_client.get_item(
        TableName="processed-records",
        Key={"id": {"S": "src-1"}},
    )["Item"]
    assert item["source_file"]["S"] == "report-42.json"
