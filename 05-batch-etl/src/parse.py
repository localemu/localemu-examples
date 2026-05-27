"""Parse Lambda: read a CSV from S3, return the rows as JSON.

Called once per Step Functions execution. The Map state iterates over the
returned `rows` array, invoking load_row once per row.
"""
from __future__ import annotations

import csv
import io
import os

import boto3

_s3 = boto3.client("s3")


def handle(event, _ctx):
    bucket = event["bucket"]
    key = event["key"]
    obj = _s3.get_object(Bucket=bucket, Key=key)
    text = obj["Body"].read().decode("utf-8")
    reader = csv.DictReader(io.StringIO(text))
    rows = [dict(r) for r in reader]
    return {
        "rows": rows,
        "count": len(rows),
        "source": f"s3://{bucket}/{key}",
    }
