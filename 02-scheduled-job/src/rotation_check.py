"""Scheduled rotation-check Lambda.

On every fire, list secrets tagged Managed=true, classify each one as
'ok' or 'needs_rotation' based on LastRotatedDate, and write an audit row
to DynamoDB per (secret_name, run_id).
"""
from __future__ import annotations

import datetime as dt
import logging
import os
import time

import boto3

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

TABLE_NAME = os.environ["TABLE_NAME"]
MAX_AGE_DAYS = int(os.environ.get("MAX_AGE_DAYS", "30"))

_sm = boto3.client("secretsmanager")
_tbl = boto3.resource("dynamodb").Table(TABLE_NAME)


def handle(event, _ctx):
    now = dt.datetime.now(dt.timezone.utc)
    cutoff = now - dt.timedelta(days=MAX_AGE_DAYS)
    run_id = f"run-{int(time.time() * 1000)}"

    checked = 0
    flagged = 0
    for page in _sm.get_paginator("list_secrets").paginate(
        Filters=[{"Key": "tag-key", "Values": ["Managed"]}]
    ):
        for secret in page.get("SecretList", []):
            tags = {t["Key"]: t["Value"] for t in secret.get("Tags", [])}
            if tags.get("Managed") != "true":
                continue
            checked += 1
            last = secret.get("LastRotatedDate") or secret.get("LastChangedDate")
            status = "needs_rotation" if (last is None or last < cutoff) else "ok"
            if status == "needs_rotation":
                flagged += 1
            _tbl.put_item(
                Item={
                    "secret_name": secret["Name"],
                    "run_id": run_id,
                    "status": status,
                    "checked_at": now.isoformat(),
                }
            )
    return {"run_id": run_id, "checked": checked, "flagged": flagged}
