"""Two integration tests: happy path (data plane) + output shape (control plane)."""
from __future__ import annotations

import json
import uuid
from decimal import Decimal

from conftest import SAMPLE_CSV, wait_for_execution


def _run_and_wait(sfn, tf, s3) -> dict:
    key = f"orders-{uuid.uuid4().hex[:8]}.csv"
    s3.put_object(Bucket=tf["input_bucket"], Key=key, Body=SAMPLE_CSV.read_bytes())
    start = sfn.start_execution(
        stateMachineArn=tf["state_machine_arn"],
        input=json.dumps({"bucket": tf["input_bucket"], "key": key}),
    )
    return wait_for_execution(sfn, start["executionArn"], timeout=120)


def test_etl_happy_path(tf, s3, sfn, dynamodb):
    """Data plane: the four valid rows land, the two bad rows are skipped."""
    result = _run_and_wait(sfn, tf, s3)
    assert result["status"] == "SUCCEEDED", result.get("cause") or result

    table = dynamodb.Table(tf["table_name"])
    for order_id in {"ord-001", "ord-002", "ord-003", "ord-004"}:
        got = table.get_item(Key={"order_id": order_id})
        assert "Item" in got, f"expected {order_id} to be loaded"
        assert isinstance(got["Item"]["amount"], Decimal)

    # The negative-amount row was caught and never written.
    assert "Item" not in table.get_item(Key={"order_id": "ord-006"})


def test_run_output_shape(tf, s3, sfn):
    """Control plane: Map's aggregated output has 4 loaded + 2 rejected."""
    result = _run_and_wait(sfn, tf, s3)
    assert result["status"] == "SUCCEEDED"

    output = json.loads(result["output"])
    items = output["results"]
    assert len(items) == 6

    statuses = []
    for item in items:
        if "result" in item:
            statuses.append(item["result"]["status"])
        elif "status" in item:
            statuses.append(item["status"])
        else:
            raise AssertionError(f"unexpected item shape: {item!r}")

    assert statuses.count("loaded") == 4
    assert statuses.count("rejected") == 2
