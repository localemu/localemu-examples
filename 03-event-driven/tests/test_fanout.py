"""Two tests: FilterPolicy fan-out, and payload preservation."""
from __future__ import annotations

import json
import uuid

from boto3.dynamodb.conditions import Key

from conftest import wait_for


def _publish(sns, topic_arn: str, *, event_id: str, amount: float, customer: str = "demo") -> None:
    payload = {"event_id": event_id, "amount": amount, "customer": customer}
    sns.publish(
        TopicArn=topic_arn,
        Message=json.dumps(payload),
        MessageAttributes={
            "amount": {"DataType": "Number", "StringValue": str(amount)},
        },
    )


def _rows_for(dynamodb, table_name: str, event_id: str) -> list[dict]:
    return dynamodb.Table(table_name).query(
        KeyConditionExpression=Key("event_id").eq(event_id),
    ).get("Items", [])


def test_fanout_filter_policy(stack, sns, dynamodb):
    topic_arn = stack["TopicArn"]
    table_name = stack["TableName"]

    small_id = f"small-{uuid.uuid4().hex[:8]}"
    big_id = f"big-{uuid.uuid4().hex[:8]}"

    _publish(sns, topic_arn, event_id=small_id, amount=10)    # below threshold
    _publish(sns, topic_arn, event_id=big_id, amount=500)      # above threshold

    # emails-consumer has no filter: both events land with service="emails".
    small_rows = wait_for(lambda: _rows_for(dynamodb, table_name, small_id))
    assert {r["service"] for r in small_rows} == {"emails"}

    # alerts-consumer only sees the big one: 2 rows total for big_id.
    big_rows = wait_for(
        lambda: _rows_for(dynamodb, table_name, big_id)
        if len(_rows_for(dynamodb, table_name, big_id)) == 2
        else None
    )
    assert {r["service"] for r in big_rows} == {"emails", "alerts"}


def test_payload_is_preserved(stack, sns, dynamodb):
    topic_arn = stack["TopicArn"]
    table_name = stack["TableName"]

    event_id = f"preserve-{uuid.uuid4().hex[:8]}"
    _publish(sns, topic_arn, event_id=event_id, amount=500, customer="acme-corp")

    rows = wait_for(
        lambda: _rows_for(dynamodb, table_name, event_id)
        if len(_rows_for(dynamodb, table_name, event_id)) == 2
        else None
    )
    for row in rows:
        payload = json.loads(row["payload"])
        assert payload["event_id"] == event_id
        assert payload["amount"] == 500
        assert payload["customer"] == "acme-corp"
