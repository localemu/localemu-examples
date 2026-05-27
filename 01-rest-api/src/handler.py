"""Notes REST API: one file, five routes, no framework.

API Gateway HTTP API v2 sends a Lambda proxy v2.0 payload. We route on
event["routeKey"] to one of five handlers. boto3 reads AWS_ENDPOINT_URL
from the environment automatically, so this code is byte-identical on
LocalEmu and on real AWS.
"""
from __future__ import annotations

import json
import logging
import os
import time
import uuid
from decimal import Decimal

import boto3
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

TABLE_NAME = os.environ["TABLE_NAME"]
_table = boto3.resource("dynamodb").Table(TABLE_NAME)


def _json_default(v):
    """DynamoDB resource API returns Decimals; coerce at the edge."""
    if isinstance(v, Decimal):
        return int(v) if v == v.to_integral_value() else float(v)
    return str(v)


def _resp(status: int, body) -> dict:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body, default=_json_default),
    }


def handle(event, _ctx):
    route = event.get("routeKey", "")
    LOG.info("handling %s", route)
    try:
        if route == "POST /notes":
            return _create_note(event)
        if route == "GET /notes":
            return _list_notes()
        if route == "GET /notes/{id}":
            return _get_note(event)
        if route == "PATCH /notes/{id}":
            return _update_note(event)
        if route == "DELETE /notes/{id}":
            return _delete_note(event)
        return _resp(404, {"error": "route not found", "route": route})
    except ClientError as e:
        LOG.exception("DynamoDB error")
        return _resp(500, {"error": str(e)})


def _create_note(event):
    body = json.loads(event.get("body") or "{}")
    title = (body.get("title") or "").strip()
    if not title:
        return _resp(400, {"error": "title is required"})
    note_id = uuid.uuid4().hex[:10]
    item = {
        "note_id": note_id,
        "title": title,
        "content": body.get("content", ""),
        "created_at": int(time.time()),
    }
    _table.put_item(Item=item)
    return _resp(201, item)


def _list_notes():
    page = _table.scan()
    return _resp(200, {"items": page.get("Items", [])})


def _get_note(event):
    note_id = event["pathParameters"]["id"]
    resp = _table.get_item(Key={"note_id": note_id})
    if "Item" not in resp:
        return _resp(404, {"error": "not found"})
    return _resp(200, resp["Item"])


def _update_note(event):
    note_id = event["pathParameters"]["id"]
    body = json.loads(event.get("body") or "{}")
    updates = {k: v for k, v in body.items() if k in ("title", "content")}
    if not updates:
        return _resp(400, {"error": "nothing to update"})
    expr_parts = ["#u = :ts"]
    values = {":ts": int(time.time())}
    names = {"#u": "updated_at"}
    for k, v in updates.items():
        expr_parts.append(f"#{k} = :{k}")
        values[f":{k}"] = v
        names[f"#{k}"] = k
    try:
        resp = _table.update_item(
            Key={"note_id": note_id},
            UpdateExpression="SET " + ", ".join(expr_parts),
            ExpressionAttributeValues=values,
            ExpressionAttributeNames=names,
            ConditionExpression="attribute_exists(note_id)",
            ReturnValues="ALL_NEW",
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return _resp(404, {"error": "not found"})
        raise
    return _resp(200, resp.get("Attributes", {}))


def _delete_note(event):
    note_id = event["pathParameters"]["id"]
    try:
        _table.delete_item(
            Key={"note_id": note_id},
            ConditionExpression="attribute_exists(note_id)",
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return _resp(404, {"error": "not found"})
        raise
    return _resp(204, {})
