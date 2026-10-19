#!/usr/bin/env python3
"""Simulate a retail order clickstream, writing straight to Firehose.

Firehose concatenates record payloads back-to-back in the delivered file
with no delimiter of its own (real AWS behavior, not a LocalEmu quirk) -
each record MUST end with its own newline, or Athena's JSON reader sees
one malformed blob instead of N newline-delimited records.
"""
from __future__ import annotations

import json
import os
import random
import subprocess
import sys
from pathlib import Path

import boto3

HERE = Path(__file__).resolve().parent

EVENTS = ["order_placed", "order_shipped", "order_cancelled"]
CUSTOMERS = ["alice", "bob", "carol", "dave"]


def _tf_output(name: str) -> str:
    out = subprocess.check_output(["terraform", "output", "-raw", name], cwd=str(HERE.parent / "terraform"))
    return out.decode().strip()


def main() -> None:
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 20

    firehose = boto3.client(
        "firehose",
        endpoint_url=os.environ.get("AWS_ENDPOINT_URL", "http://localhost:4566"),
        region_name="us-east-1",
        aws_access_key_id="AKIAIOSFODNN7EXAMPLE",
        aws_secret_access_key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    )
    stream_name = _tf_output("delivery_stream_name")

    for i in range(count):
        record = {
            "order_id": f"O-{3000 + i}",
            "event": random.choice(EVENTS),
            "amount": round(random.uniform(10, 200), 2),
            "customer": random.choice(CUSTOMERS),
        }
        firehose.put_record(
            DeliveryStreamName=stream_name,
            Record={"Data": (json.dumps(record) + "\n").encode()},
        )

    print(f"put {count} records to {stream_name}")


if __name__ == "__main__":
    main()
