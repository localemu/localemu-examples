"""Order service: publishes order events to SNS.

Knows nothing about downstream consumers (payment, notification, etc.).
"""
from __future__ import annotations

import json
import os

import boto3


def get_client(service: str):
    kwargs = {"region_name": "us-east-1"}
    endpoint = os.environ.get("AWS_ENDPOINT_URL")
    if endpoint:
        kwargs["endpoint_url"] = endpoint
    return boto3.client(service, **kwargs)


TOPIC_ARN = os.environ.get(
    "ORDER_EVENTS_TOPIC_ARN",
    "arn:aws:sns:us-east-1:000000000000:order-events",
)


def place_order(order_id: str, customer: str, items: list[str], total: float) -> dict:
    sns = get_client("sns")
    message = json.dumps(
        {
            "order_id": order_id,
            "customer": customer,
            "items": items,
            "total": total,
        }
    )
    sns.publish(TopicArn=TOPIC_ARN, Message=message, Subject="new-order")
    return {"order_id": order_id, "status": "published"}
