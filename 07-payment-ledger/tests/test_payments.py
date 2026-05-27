"""Nine integration tests for the payments API."""
from __future__ import annotations

import concurrent.futures
import json
import uuid

import pytest
import requests

from conftest import collect_messages, drain_queue


def _post(api_base: str, body: dict, *, idem_key: str | None = None, headers: dict | None = None) -> requests.Response:
    h = {"content-type": "application/json"}
    if idem_key is not None:
        h["Idempotency-Key"] = idem_key
    if headers:
        h.update(headers)
    return requests.post(f"{api_base}/payments", json=body, headers=h, timeout=15)


def test_happy_path(api_base, fresh_accounts, balance_of, sqs, tf, dynamodb):
    alice, bob = fresh_accounts
    drain_queue(sqs, tf["settled_queue_url"])

    r = _post(api_base, {"from": alice, "to": bob, "amount": 3000}, idem_key=uuid.uuid4().hex)
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["status"] == "settled"
    tx_id = body["tx_id"]

    assert balance_of(alice) == 7000
    assert balance_of(bob) == 3000

    # Ledger: one DEBIT leg for alice, one CREDIT leg for bob.
    ledger = dynamodb.Table(tf["ledger_table"])
    legs = ledger.query(
        KeyConditionExpression="tx_id = :tx",
        ExpressionAttributeValues={":tx": tx_id},
    ).get("Items", [])
    assert {l["leg"] for l in legs} == {"DEBIT", "CREDIT"}

    # Exactly one settled event on the EventBridge to SQS wire.
    msgs = collect_messages(sqs, tf["settled_queue_url"], expected=1, timeout=15)
    assert len(msgs) == 1
    envelope = json.loads(msgs[0]["Body"])
    detail = envelope["detail"]
    # detail is a JSON string on real AWS, may be a dict on LocalEmu; handle both.
    settled = json.loads(detail) if isinstance(detail, str) else detail
    assert settled["tx_id"] == tx_id


def test_idempotent_replay(api_base, fresh_accounts, balance_of, sqs, tf):
    alice, bob = fresh_accounts
    drain_queue(sqs, tf["settled_queue_url"])
    key = uuid.uuid4().hex

    r1 = _post(api_base, {"from": alice, "to": bob, "amount": 3000}, idem_key=key)
    assert r1.status_code == 201
    first = r1.json()

    # Replay with SAME key, DIFFERENT body: stored response wins.
    r2 = _post(api_base, {"from": alice, "to": bob, "amount": 9999999}, idem_key=key)
    assert r2.status_code == 201
    assert r2.json() == first, "replay must return byte-identical stored response"

    # Balances moved exactly once.
    assert balance_of(alice) == 7000
    assert balance_of(bob) == 3000

    # Exactly one settled event (the replay did not emit).
    msgs = collect_messages(sqs, tf["settled_queue_url"], expected=1, timeout=10)
    assert len(msgs) == 1


def test_insufficient_funds_is_atomic(api_base, fresh_accounts, balance_of, dynamodb, tf):
    alice, bob = fresh_accounts  # alice has 10000
    key = uuid.uuid4().hex

    r = _post(api_base, {"from": alice, "to": bob, "amount": 99999}, idem_key=key)
    assert r.status_code == 422
    assert "payer" in r.json()["error"].lower()

    # Nothing moved.
    assert balance_of(alice) == 10000
    assert balance_of(bob) == 0

    # No ledger row for these accounts.
    ledger = dynamodb.Table(tf["ledger_table"]).scan().get("Items", [])
    assert not any(l["account_id"] in (alice, bob) for l in ledger)

    # Idempotency key was NOT persisted (whole TX rolled back),
    # so the client can retry the same key with a valid amount.
    got = dynamodb.Table(tf["idempotency_table"]).get_item(
        Key={"key": key}, ConsistentRead=True
    )
    assert "Item" not in got

    r2 = _post(api_base, {"from": alice, "to": bob, "amount": 500}, idem_key=key)
    assert r2.status_code == 201
    assert balance_of(alice) == 9500
    assert balance_of(bob) == 500


def test_concurrent_debits_never_overdraw(api_base, fresh_accounts, balance_of):
    alice, bob = fresh_accounts  # alice=10000, bob=0

    def _attempt(i: int) -> int:
        r = _post(
            api_base,
            {"from": alice, "to": bob, "amount": 8000},
            idem_key=f"race-{uuid.uuid4().hex}",
        )
        return r.status_code

    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as ex:
        codes = list(ex.map(_attempt, range(5)))

    # Five concurrent attempts to debit 8000 from an account with 10000.
    # DynamoDB's conditional expression serializes: exactly one wins.
    assert codes.count(201) == 1, codes
    assert codes.count(422) == 4, codes

    # Balance never went negative; would have been -30000 without transactions.
    assert balance_of(alice) == 2000
    assert balance_of(bob) == 8000


@pytest.mark.parametrize(
    "body,substr",
    [
        ({"from": "a", "to": "a", "amount": 100}, "differ"),
        ({"from": "a", "to": "b", "amount": 0}, "positive"),
        ({"from": "a", "to": "b", "amount": -5}, "positive"),
        ({"from": "", "to": "b", "amount": 100}, "required"),
    ],
    ids=["body0-differ", "body1-positive", "body2-positive", "body3-required"],
)
def test_input_validation(api_base, body, substr):
    r = _post(api_base, body, idem_key=uuid.uuid4().hex)
    assert r.status_code == 400, r.text
    assert substr in r.json()["error"].lower()


def test_missing_idempotency_key(api_base, fresh_accounts):
    alice, bob = fresh_accounts
    r = _post(api_base, {"from": alice, "to": bob, "amount": 100}, idem_key=None)
    assert r.status_code == 400
    assert "idempotency" in r.json()["error"].lower()
