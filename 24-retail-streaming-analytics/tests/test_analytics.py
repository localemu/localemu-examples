"""6 integration tests against a real streaming pipeline: Firehose
(DirectPut) -> S3 -> Glue -> Athena. A fixed, known batch of events is
produced once per session; tests assert against values computed by hand
from that exact batch, so a wrong aggregation is a genuine bug, not
sampling noise."""
from __future__ import annotations

import time

import pytest

from conftest import put_event, query

DB = "retail_analytics_db.events"

# order_id prefixed so a re-run doesn't collide with a previous run's data
# still sitting in S3 (teardown removes the bucket, but a test run against
# an already-seeded bucket from a previous interrupted session shouldn't
# silently inflate counts).
_RUN_TAG = str(int(time.time()))

FIXED_BATCH = [
    {"order_id": f"T{_RUN_TAG}-1", "event": "order_placed", "amount": 100.0, "customer": "alice"},
    {"order_id": f"T{_RUN_TAG}-2", "event": "order_placed", "amount": 50.0, "customer": "alice"},
    {"order_id": f"T{_RUN_TAG}-3", "event": "order_placed", "amount": 30.0, "customer": "bob"},
    {"order_id": f"T{_RUN_TAG}-4", "event": "order_shipped", "amount": 100.0, "customer": "alice"},
    {"order_id": f"T{_RUN_TAG}-5", "event": "order_shipped", "amount": 50.0, "customer": "alice"},
    {"order_id": f"T{_RUN_TAG}-6", "event": "order_cancelled", "amount": 30.0, "customer": "bob"},
]


@pytest.fixture(scope="session", autouse=True)
def seeded(firehose, tf):
    for record in FIXED_BATCH:
        put_event(firehose, tf, record)
    # buffering_interval=10s in terraform/main.tf, plus delivery lag.
    time.sleep(15)


def test_total_event_count_includes_this_runs_batch(athena, tf):
    rows = query(athena, tf, f"SELECT COUNT(*) FROM {DB} WHERE order_id LIKE 'T{_RUN_TAG}-%'")
    assert rows[1][0] == "6"


def test_group_by_event_type(athena, tf):
    rows = query(
        athena, tf,
        f"SELECT event, COUNT(*), SUM(amount) FROM {DB} "
        f"WHERE order_id LIKE 'T{_RUN_TAG}-%' GROUP BY event ORDER BY event",
    )
    by_event = {r[0]: (r[1], float(r[2])) for r in rows[1:]}
    assert by_event["order_placed"] == ("3", 180.0)
    assert by_event["order_shipped"] == ("2", 150.0)
    assert by_event["order_cancelled"] == ("1", 30.0)


def test_filter_by_customer(athena, tf):
    rows = query(
        athena, tf,
        f"SELECT SUM(amount) FROM {DB} WHERE order_id LIKE 'T{_RUN_TAG}-%' "
        f"AND customer = 'alice' AND event = 'order_placed'",
    )
    assert float(rows[1][0]) == 150.0


def test_cancellation_rate(athena, tf):
    rows = query(
        athena, tf,
        f"SELECT "
        f"  SUM(CASE WHEN event = 'order_cancelled' THEN 1 ELSE 0 END) * 1.0 / "
        f"  SUM(CASE WHEN event = 'order_placed' THEN 1 ELSE 0 END) "
        f"FROM {DB} WHERE order_id LIKE 'T{_RUN_TAG}-%'",
    )
    # 1 cancelled / 3 placed
    assert abs(float(rows[1][0]) - (1 / 3)) < 0.01


def test_delivered_files_are_newline_delimited_json(s3, tf):
    """The exact gotcha this lab is built around: Firehose does not
    insert delimiters between records on its own."""
    objs = s3.list_objects_v2(Bucket=tf["raw_bucket"], Prefix="events/")["Contents"]
    assert len(objs) > 0
    body = s3.get_object(Bucket=tf["raw_bucket"], Key=objs[0]["Key"])["Body"].read()
    assert body.endswith(b"\n")


def test_unknown_order_prefix_returns_zero_not_an_error(athena, tf):
    rows = query(athena, tf, f"SELECT COUNT(*) FROM {DB} WHERE order_id = 'does-not-exist'")
    assert rows[1][0] == "0"
