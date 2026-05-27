"""Load-row Lambda: invoked once per CSV row by the Map state.

Raises RowRejected for invalid rows (missing order_id, bad/negative amount).
The Map state's Catch captures the error and routes to a Pass state that
returns {"status": "rejected"}, so a bad row does not abort the batch.
"""
from __future__ import annotations

import os
from decimal import Decimal

import boto3

_table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])


class RowRejected(Exception):
    pass


def handle(event, _ctx):
    row = dict(event)
    order_id = (row.get("order_id") or "").strip()
    if not order_id:
        raise RowRejected(f"missing order_id: {event!r}")

    try:
        amount = Decimal(row.get("amount") or "0")
    except Exception as exc:
        raise RowRejected(f"bad amount for {order_id}: {row.get('amount')!r}") from exc
    if amount < 0:
        raise RowRejected(f"negative amount for {order_id}: {amount}")

    _table.put_item(
        Item={
            "order_id": order_id,
            "amount": amount,
            "customer": row.get("customer", ""),
        }
    )
    return {"order_id": order_id, "status": "loaded"}
