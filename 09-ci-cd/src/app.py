"""File Processing Service: read a JSON file from S3, write each record to DynamoDB.

Works with both LocalEmu (dev, CI) and real AWS (prod) without a code change:
boto3 picks up AWS_ENDPOINT_URL from the environment when set, otherwise
talks to real AWS.
"""
from __future__ import annotations

import json
import os

import boto3


def get_client(service: str):
    """Create a boto3 client. Uses AWS_ENDPOINT_URL for LocalEmu when set."""
    kwargs = {"region_name": "us-east-1"}
    endpoint = os.environ.get("AWS_ENDPOINT_URL")
    if endpoint:
        kwargs["endpoint_url"] = endpoint
    return boto3.client(service, **kwargs)


def process_file(bucket: str, key: str) -> dict:
    """Read a JSON file from S3, extract records, write each to DynamoDB."""
    s3 = get_client("s3")
    dynamodb = get_client("dynamodb")

    response = s3.get_object(Bucket=bucket, Key=key)
    data = json.loads(response["Body"].read())

    written = 0
    for record in data.get("records", []):
        dynamodb.put_item(
            TableName="processed-records",
            Item={
                "id": {"S": record["id"]},
                "name": {"S": record["name"]},
                "status": {"S": "processed"},
                "source_file": {"S": key},
            },
        )
        written += 1

    return {"processed": written, "source": f"s3://{bucket}/{key}"}
