"""Three tests: schedule config, handler behaviour, audit row shape.

No clock-watching: we assert the schedule via GetSchedule, and invoke the
Lambda directly the same way the scheduler target would.
"""
from __future__ import annotations

import json

from boto3.dynamodb.conditions import Key


def test_schedule_is_configured(tf, scheduler):
    got = scheduler.get_schedule(Name=tf["schedule_name"])
    assert got["ScheduleExpression"] == tf["schedule_expression"]
    assert got["State"] == "ENABLED"
    assert got["Target"]["Arn"].endswith(f"function:{tf['function_name']}")


def test_lambda_flags_managed_secrets(tf, lambda_client, dynamodb):
    resp = lambda_client.invoke(
        FunctionName=tf["function_name"],
        InvocationType="RequestResponse",
        Payload=b"{}",
    )
    body = json.loads(resp["Payload"].read())
    assert body["checked"] == 2  # fresh + stale are Managed=true

    # Un-managed secret was skipped: no audit rows at all.
    ignored_rows = dynamodb.Table(tf["table_name"]).query(
        KeyConditionExpression=Key("secret_name").eq(tf["ignored_secret_name"]),
    ).get("Items", [])
    assert ignored_rows == []


def test_audit_row_carries_status_and_timestamp(tf, lambda_client, dynamodb):
    resp = lambda_client.invoke(
        FunctionName=tf["function_name"],
        InvocationType="RequestResponse",
        Payload=b"{}",
    )
    body = json.loads(resp["Payload"].read())
    run_id = body["run_id"]

    # Fetch the row for the fresh secret from this run using a composite-key query.
    rows = dynamodb.Table(tf["table_name"]).query(
        KeyConditionExpression=(
            Key("secret_name").eq(tf["fresh_secret_name"]) & Key("run_id").eq(run_id)
        ),
    ).get("Items", [])
    assert len(rows) == 1
    row = rows[0]
    assert row["status"] in ("ok", "needs_rotation")
    assert row["checked_at"].endswith("+00:00")  # ISO-8601 with tz offset
