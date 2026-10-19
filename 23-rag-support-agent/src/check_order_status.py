"""Tool Lambda: look up an order's status. Invoked by agent.py via a real
lambda:Invoke call, not an in-process function call."""
from __future__ import annotations

import os

import boto3

ORDERS_TABLE = os.environ["ORDERS_TABLE"]

_ddb = boto3.resource("dynamodb")
_orders = _ddb.Table(ORDERS_TABLE)


def handle(event, _ctx):
    order_id = event.get("order_id") or ""
    item = _orders.get_item(Key={"order_id": order_id}).get("Item")
    if item is None:
        return {"found": False, "order_id": order_id}
    return {"found": True, "order_id": order_id, "status": item["status"]}
