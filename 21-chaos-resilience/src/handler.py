"""
Resilient writer Lambda. Idempotent put_item with exponential backoff
retry on throttle (ProvisionedThroughputExceededException), bounded
attempts, jitter. Returns a structured envelope the load driver can
roll up into success / retry / failure counts.

The handler is intentionally honest about what it survived: it does
NOT swallow throttles silently. Every throttle that triggers a retry
is counted; a request that exhausts its retries returns ok=false so
the driver can report it as a real failure.
"""

import os
import random
import time

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError


TABLE = os.environ["TABLE_NAME"]
MAX_ATTEMPTS = int(os.environ.get("MAX_ATTEMPTS", "5"))

# Disable boto3's own retry layer so OUR retry loop is the only one;
# otherwise we'd double-count and the timing data would be misleading.
_ddb = boto3.client("dynamodb", config=Config(retries={"max_attempts": 0}))

_THROTTLE_CODES = {
    "ProvisionedThroughputExceededException",
    "ThrottlingException",
    "Throttling",
    "RequestLimitExceeded",
    "TooManyRequestsException",
    "SlowDown",
    "OverLimit",
    "LimitExceededException",
}


def _sleep_with_jitter(attempt: int) -> float:
    """Exponential backoff 100ms -> 200ms -> 400ms -> 800ms -> 1600ms,
    plus 0-50% additive jitter. Returns the actual seconds slept."""
    base = 0.1 * (2 ** attempt)
    jitter = base * random.random() * 0.5
    delay = base + jitter
    time.sleep(delay)
    return delay


def handler(event, _ctx):
    req_id = event["request_id"]
    payload = event.get("payload", "default")

    attempts = 0
    throttled = 0
    total_backoff_s = 0.0
    start = time.monotonic()
    last_error = None

    while attempts < MAX_ATTEMPTS:
        attempts += 1
        try:
            _ddb.put_item(
                TableName=TABLE,
                Item={
                    "request_id": {"S": req_id},
                    "payload": {"S": payload},
                    "attempts_to_land": {"N": str(attempts)},
                },
            )
            return {
                "ok": True,
                "request_id": req_id,
                "attempts": attempts,
                "throttled": throttled,
                "elapsed_ms": round((time.monotonic() - start) * 1000, 1),
                "total_backoff_ms": round(total_backoff_s * 1000, 1),
            }
        except ClientError as e:
            code = e.response.get("Error", {}).get("Code", "")
            last_error = code
            if code not in _THROTTLE_CODES:
                # Non-throttle error: surface it, don't retry blindly.
                return {
                    "ok": False,
                    "request_id": req_id,
                    "attempts": attempts,
                    "throttled": throttled,
                    "elapsed_ms": round((time.monotonic() - start) * 1000, 1),
                    "error": code,
                }
            throttled += 1
            if attempts >= MAX_ATTEMPTS:
                break
            total_backoff_s += _sleep_with_jitter(attempts - 1)

    return {
        "ok": False,
        "request_id": req_id,
        "attempts": attempts,
        "throttled": throttled,
        "elapsed_ms": round((time.monotonic() - start) * 1000, 1),
        "total_backoff_ms": round(total_backoff_s * 1000, 1),
        "error": last_error or "retries_exhausted",
    }
