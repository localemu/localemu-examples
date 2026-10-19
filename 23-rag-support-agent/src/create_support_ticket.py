"""Tool Lambda: file a support ticket. Invoked by agent.py via a real
lambda:Invoke call when a structured lookup (e.g. order status) comes up
empty and a human needs to take over."""
from __future__ import annotations

import os
import time
import uuid

import boto3

TICKETS_TABLE = os.environ["TICKETS_TABLE"]

_ddb = boto3.resource("dynamodb")
_tickets = _ddb.Table(TICKETS_TABLE)


def handle(event, _ctx):
    ticket_id = f"TKT-{uuid.uuid4().hex[:8].upper()}"
    _tickets.put_item(Item={
        "ticket_id": ticket_id,
        "subject": event.get("subject") or "",
        "body": event.get("body") or "",
        "status": "OPEN",
        "created_at": int(time.time()),
    })
    return {"ticket_id": ticket_id}
