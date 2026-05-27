"""Payment service: polls its SQS queue, records payments in DynamoDB."""
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
    "PAYMENT_QUEUE_URL",
    "http://sqs.us-east-1.localhost:4566/000000000000/payment-queue",
)
TABLE_NAME = os.environ.get("PAYMENT_TABLE", "payments")


def process_payments(*, max_messages: int = 10, wait_seconds: int = 0) -> int:
    """Drain the queue once; return number of payments processed."""
    sqs = get_client("sqs")
    ddb = get_client("dynamodb")

    resp = sqs.receive_message(
        QueueUrl=QUEUE_URL,
        MaxNumberOfMessages=max_messages,
        WaitTimeSeconds=wait_seconds,
    )
    processed = 0
    for msg in resp.get("Messages", []):
        envelope = json.loads(msg["Body"])
        order = json.loads(envelope.get("Message", "{}"))

        ddb.put_item(
            TableName=TABLE_NAME,
            Item={
                "order_id": {"S": order["order_id"]},
                "amount": {"N": str(order["total"])},
                "status": {"S": "charged"},
            },
        )
        sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=msg["ReceiptHandle"])
        processed += 1
    return processed
