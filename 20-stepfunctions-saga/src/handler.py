"""
A single handler deployed seven times, each instance is wired to one
step of an order-processing saga by its STEP_NAME env var:

    Forward:        reserve -> charge -> ship -> notify
    Compensations:  comp_ship -> comp_charge -> comp_reserve

The state-machine ASL catches any forward-step failure and jumps to
the compensation for the *previous* successful step, cascading down
to release every side-effect that was applied. Inject a failure with
event["fail_at"] = "<step>".

The handler is intentionally tiny: each step writes one DDB item or
publishes one SNS message. Compensations delete the corresponding
DDB item; the notification step has no compensation because it is
the last forward step.
"""

import json
import os

import boto3
from botocore.exceptions import ClientError


STEP = os.environ["STEP_NAME"]

INVENTORY_TABLE = os.environ.get("INVENTORY_TABLE", "")
PAYMENTS_TABLE = os.environ.get("PAYMENTS_TABLE", "")
SHIPMENTS_TABLE = os.environ.get("SHIPMENTS_TABLE", "")
NOTIFICATIONS_TOPIC = os.environ.get("NOTIFICATIONS_TOPIC", "")


def _ddb():
    return boto3.client("dynamodb")


def _sns():
    return boto3.client("sns")


def handler(event, _ctx):
    order_id = event["order_id"]
    fail_at = event.get("fail_at")

    if fail_at == STEP:
        raise RuntimeError(f"injected failure at '{STEP}'")

    if STEP == "reserve":
        _ddb().put_item(
            TableName=INVENTORY_TABLE,
            Item={"order_id": {"S": order_id}, "qty": {"N": str(event.get("qty", 1))}},
        )
        return {**event, "inventory_reserved": True}

    if STEP == "charge":
        _ddb().put_item(
            TableName=PAYMENTS_TABLE,
            Item={"order_id": {"S": order_id}, "amount": {"N": str(event.get("amount", 100))}},
        )
        return {**event, "payment_charged": True}

    if STEP == "ship":
        _ddb().put_item(
            TableName=SHIPMENTS_TABLE,
            Item={"order_id": {"S": order_id}, "status": {"S": "created"}},
        )
        return {**event, "shipment_created": True}

    if STEP == "notify":
        _sns().publish(
            TopicArn=NOTIFICATIONS_TOPIC,
            Message=json.dumps({"order_id": order_id, "status": "complete"}),
        )
        return {**event, "notification_sent": True}

    if STEP == "comp_ship":
        try:
            _ddb().delete_item(TableName=SHIPMENTS_TABLE, Key={"order_id": {"S": order_id}})
        except ClientError:
            pass
        return {**event, "shipment_cancelled": True}

    if STEP == "comp_charge":
        try:
            _ddb().delete_item(TableName=PAYMENTS_TABLE, Key={"order_id": {"S": order_id}})
        except ClientError:
            pass
        return {**event, "payment_refunded": True}

    if STEP == "comp_reserve":
        try:
            _ddb().delete_item(TableName=INVENTORY_TABLE, Key={"order_id": {"S": order_id}})
        except ClientError:
            pass
        return {**event, "inventory_released": True}

    raise ValueError(f"unknown STEP_NAME: {STEP}")
