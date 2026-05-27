"""Kinesis producer + consumer in one script.

Creates a stream, writes 3 events, reads them back with a shard iterator,
asserts the payloads decode correctly, and deletes the stream.
"""
from __future__ import annotations

import json
import sys
import time

import boto3


def main() -> int:
    kinesis = boto3.client(
        "kinesis",
        endpoint_url="http://localhost:4566",
        region_name="us-east-1",
        aws_access_key_id="AKIAIOSFODNN7EXAMPLE",
        aws_secret_access_key="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    )
    stream_name = "events"

    # Fresh stream
    try:
        kinesis.delete_stream(StreamName=stream_name)
        kinesis.get_waiter("stream_not_exists").wait(StreamName=stream_name)
    except kinesis.exceptions.ResourceNotFoundException:
        pass

    kinesis.create_stream(StreamName=stream_name, ShardCount=1)
    kinesis.get_waiter("stream_exists").wait(StreamName=stream_name)
    print(f"→ stream '{stream_name}' is ACTIVE")

    # Producer
    events = [
        {"event": "login", "user": "tarek"},
        {"event": "purchase", "user": "alice", "amount": 99.99},
        {"event": "logout", "user": "tarek"},
    ]
    print("\n→ producer: writing 3 events")
    for evt in events:
        resp = kinesis.put_record(
            StreamName=stream_name,
            Data=json.dumps(evt).encode("utf-8"),
            PartitionKey=f"user-{evt['user']}",
        )
        print(f"   seq={resp['SequenceNumber']} shard={resp['ShardId']} payload={evt}")

    # Consumer: read all records from TRIM_HORIZON
    desc = kinesis.describe_stream(StreamName=stream_name)
    shard_id = desc["StreamDescription"]["Shards"][0]["ShardId"]
    iterator = kinesis.get_shard_iterator(
        StreamName=stream_name,
        ShardId=shard_id,
        ShardIteratorType="TRIM_HORIZON",
    )["ShardIterator"]

    # Poll until we see all 3 records (shard read is eventually-consistent but fast)
    seen: list[dict] = []
    deadline = time.monotonic() + 10
    while len(seen) < len(events) and time.monotonic() < deadline:
        response = kinesis.get_records(ShardIterator=iterator, Limit=100)
        for r in response["Records"]:
            seen.append(
                {
                    "seq": r["SequenceNumber"],
                    "partition_key": r["PartitionKey"],
                    "payload": json.loads(r["Data"]),
                }
            )
        iterator = response["NextShardIterator"]
        if len(seen) < len(events):
            time.sleep(0.2)

    print(f"\n→ consumer: read {len(seen)} records")
    for rec in seen:
        print(f"   seq={rec['seq']} pk={rec['partition_key']} payload={rec['payload']}")

    # Verify payloads round-tripped intact
    assert len(seen) == len(events), f"expected {len(events)} records, got {len(seen)}"
    for expected, got in zip(events, [r["payload"] for r in seen]):
        assert got == expected, f"payload mismatch: {got} != {expected}"
    print("\n→ all 3 payloads round-tripped intact")

    kinesis.delete_stream(StreamName=stream_name)
    print(f"→ stream '{stream_name}' deleted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
