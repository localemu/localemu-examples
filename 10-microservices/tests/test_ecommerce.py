"""End-to-end integration test for the mini e-commerce system.

Flow:
  1. order_service.place_order() publishes to SNS
  2. SNS fans out to payment-queue and notification-queue
  3. payment_service.process_payments() drains the payment queue, writes DDB
  4. notification_service.send_notifications() drains the notification queue, writes DDB
  5. Assert both DynamoDB tables have the expected rows.
"""
from __future__ import annotations

import os
import sys
import uuid

import boto3
import pytest

# Make src/ importable
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

os.environ.setdefault("AWS_ENDPOINT_URL", "http://localhost:4566")
os.environ.setdefault("AWS_ACCESS_KEY_ID", "AKIAIOSFODNN7EXAMPLE")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

from order_service import place_order  # noqa: E402
from payment_service import process_payments  # noqa: E402
from notification_service import send_notifications  # noqa: E402

KWARGS = {
    "endpoint_url": "http://localhost:4566",
    "aws_access_key_id": "AKIAIOSFODNN7EXAMPLE",
    "aws_secret_access_key": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    "region_name": "us-east-1",
}


@pytest.fixture(scope="session")
def ddb():
    return boto3.client("dynamodb", **KWARGS)


def test_order_flows_through_all_services(ddb):
    order_id = f"ORD-{uuid.uuid4().hex[:8]}"

    # Place an order; the publish happens inside place_order().
    result = place_order(
        order_id=order_id,
        customer=f"{uuid.uuid4().hex[:6]}@example.com",
        items=["widget-a", "widget-b"],
        total=59.99,
    )
    assert result == {"order_id": order_id, "status": "published"}

    # Drain both queues end-to-end. Long-poll briefly to absorb SNS fan-out latency.
    payments = process_payments(wait_seconds=2)
    notifications = send_notifications(wait_seconds=2)
    assert payments >= 1, f"payment service drained {payments} messages, expected >= 1"
    assert notifications >= 1, f"notification service drained {notifications} messages, expected >= 1"

    # Verify DynamoDB rows.
    p = ddb.get_item(TableName="payments", Key={"order_id": {"S": order_id}}).get("Item")
    assert p is not None
    assert p["status"]["S"] == "charged"
    assert float(p["amount"]["N"]) == 59.99

    n = ddb.get_item(TableName="notifications", Key={"order_id": {"S": order_id}}).get("Item")
    assert n is not None
    assert n["type"]["S"] == "order_confirmation"
    assert n["status"]["S"] == "sent"
