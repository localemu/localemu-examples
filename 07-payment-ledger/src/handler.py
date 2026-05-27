"""Payment API: POST /payments with Idempotency-Key header.

One DynamoDB TransactWriteItems call atomically:
  1) reserves the idempotency key
  2) debits the payer (active + sufficient funds)
  3) credits the payee (active)
  4) writes a DEBIT ledger row
  5) writes a CREDIT ledger row

On ConditionalCheckFailed[0] (duplicate key), returns the stored response
byte-identical. On [1] or [2] (business rule), returns 422 with no side
effects. On success, publishes a payment.settled event to EventBridge.
"""
from __future__ import annotations

import json
import logging
import os
import time
import uuid

import boto3
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

ACCOUNTS_TABLE = os.environ["ACCOUNTS_TABLE"]
LEDGER_TABLE = os.environ["LEDGER_TABLE"]
IDEMPOTENCY_TABLE = os.environ["IDEMPOTENCY_TABLE"]
EVENT_BUS_NAME = os.environ["EVENT_BUS_NAME"]
IDEMPOTENCY_TTL = int(os.environ.get("IDEMPOTENCY_TTL_SECONDS", "86400"))

_ddb = boto3.client("dynamodb")
_events = boto3.client("events")


def _resp(status: int, body) -> dict:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }


def handle(event, _ctx):
    if event.get("routeKey") != "POST /payments":
        return _resp(404, {"error": "route not found"})

    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    idem_key = headers.get("idempotency-key")
    if not idem_key:
        return _resp(400, {"error": "Idempotency-Key header is required"})

    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _resp(400, {"error": "invalid JSON body"})

    from_acc = (body.get("from") or "").strip()
    to_acc = (body.get("to") or "").strip()
    amount = body.get("amount")
    currency = (body.get("currency") or "USD").strip()

    if not from_acc or not to_acc:
        return _resp(400, {"error": "'from' and 'to' are required"})
    if from_acc == to_acc:
        return _resp(400, {"error": "'from' and 'to' must differ"})
    if not isinstance(amount, int) or amount <= 0:
        return _resp(400, {"error": "'amount' must be a positive integer (minor units)"})

    tx_id = uuid.uuid4().hex
    now = int(time.time())
    response_body = json.dumps({
        "tx_id": tx_id,
        "from": from_acc,
        "to": to_acc,
        "amount": amount,
        "currency": currency,
        "created_at": now,
        "status": "settled",
    })

    try:
        _ddb.transact_write_items(
            TransactItems=[
                {
                    "Put": {
                        "TableName": IDEMPOTENCY_TABLE,
                        "Item": {
                            "key": {"S": idem_key},
                            "response_body": {"S": response_body},
                            "status_code": {"N": "201"},
                            "tx_id": {"S": tx_id},
                            "created_at": {"N": str(now)},
                            "ttl": {"N": str(now + IDEMPOTENCY_TTL)},
                        },
                        "ConditionExpression": "attribute_not_exists(#k)",
                        "ExpressionAttributeNames": {"#k": "key"},
                    }
                },
                {
                    "Update": {
                        "TableName": ACCOUNTS_TABLE,
                        "Key": {"account_id": {"S": from_acc}},
                        "UpdateExpression": "SET balance = balance - :amt",
                        "ConditionExpression": (
                            "attribute_exists(account_id) AND balance >= :amt AND #s = :active"
                        ),
                        "ExpressionAttributeNames": {"#s": "status"},
                        "ExpressionAttributeValues": {
                            ":amt": {"N": str(amount)},
                            ":active": {"S": "active"},
                        },
                    }
                },
                {
                    "Update": {
                        "TableName": ACCOUNTS_TABLE,
                        "Key": {"account_id": {"S": to_acc}},
                        "UpdateExpression": "SET balance = balance + :amt",
                        "ConditionExpression": "attribute_exists(account_id) AND #s = :active",
                        "ExpressionAttributeNames": {"#s": "status"},
                        "ExpressionAttributeValues": {
                            ":amt": {"N": str(amount)},
                            ":active": {"S": "active"},
                        },
                    }
                },
                {
                    "Put": {
                        "TableName": LEDGER_TABLE,
                        "Item": {
                            "tx_id": {"S": tx_id},
                            "leg": {"S": "DEBIT"},
                            "account_id": {"S": from_acc},
                            "amount": {"N": str(amount)},
                            "currency": {"S": currency},
                            "created_at": {"N": str(now)},
                        },
                    }
                },
                {
                    "Put": {
                        "TableName": LEDGER_TABLE,
                        "Item": {
                            "tx_id": {"S": tx_id},
                            "leg": {"S": "CREDIT"},
                            "account_id": {"S": to_acc},
                            "amount": {"N": str(amount)},
                            "currency": {"S": currency},
                            "created_at": {"N": str(now)},
                        },
                    }
                },
            ]
        )
    except ClientError as e:
        if e.response["Error"]["Code"] != "TransactionCanceledException":
            LOG.exception("transact_write_items unexpected error")
            raise
        reasons = e.response.get("CancellationReasons", [])

        # [0] idempotency-key collision => replay stored response.
        if reasons and reasons[0].get("Code") == "ConditionalCheckFailed":
            stored = _ddb.get_item(
                TableName=IDEMPOTENCY_TABLE,
                Key={"key": {"S": idem_key}},
                ConsistentRead=True,
            ).get("Item")
            if stored:
                return _resp(
                    int(stored["status_code"]["N"]),
                    json.loads(stored["response_body"]["S"]),
                )
            return _resp(500, {"error": "idempotency collision but no stored response"})

        # [1] payer update failed (insufficient funds or inactive).
        if len(reasons) > 1 and reasons[1].get("Code") == "ConditionalCheckFailed":
            return _resp(
                422,
                {
                    "error": "payer check failed",
                    "detail": "insufficient funds or inactive",
                    "account": from_acc,
                },
            )
        # [2] payee update failed.
        if len(reasons) > 2 and reasons[2].get("Code") == "ConditionalCheckFailed":
            return _resp(422, {"error": "payee check failed", "account": to_acc})

        LOG.error("TransactionCanceledException with unexpected reasons: %s", reasons)
        return _resp(500, {"error": "transaction cancelled", "reasons": reasons})

    # Success: publish the settled event. Best-effort: if EventBridge is down,
    # the transaction is already durable; a reconciliation job can backfill.
    try:
        _events.put_events(
            Entries=[
                {
                    "Source": "pay.ledger",
                    "DetailType": "payment.settled",
                    "Detail": response_body,
                    "EventBusName": EVENT_BUS_NAME,
                }
            ]
        )
    except Exception:
        LOG.exception("PutEvents failed, transaction is still durable")

    return _resp(201, json.loads(response_body))
