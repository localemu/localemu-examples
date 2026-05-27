"""Notification service: polls its SQS queue, records notifications sent."""
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


QUEUE_URL = os.environ.get(
    "NOTIFICATION_QUEUE_URL",
    "http://sqs.us-east-1.localhost:4566/000000000000/notification-queue",
)
TABLE_NAME = os.environ.get("NOTIFICATION_TABLE", "notifications")


def send_notifications(*, max_messages: int = 10, wait_seconds: int = 0) -> int:
    sqs = get_client("sqs")
    ddb = get_client("dynamodb")

    resp = sqs.receive_message(
        QueueUrl=QUEUE_URL,
        MaxNumberOfMessages=max_messages,
        WaitTimeSeconds=wait_seconds,
    )
    sent = 0
    for msg in resp.get("Messages", []):
        envelope = json.loads(msg["Body"])
        order = json.loads(envelope.get("Message", "{}"))

        ddb.put_item(
            TableName=TABLE_NAME,
            Item={
                "order_id": {"S": order["order_id"]},
                "customer": {"S": order["customer"]},
                "type": {"S": "order_confirmation"},
                "status": {"S": "sent"},
            },
        )
        sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=msg["ReceiptHandle"])
        sent += 1
    return sent
