"""S3 public-access guardrail Lambda.

Triggered by an EventBridge rule matching S3 API calls that can widen
public access. Inspects the bucket, remediates (PutPublicAccessBlock
+ tag), logs an incident (deduped on CloudTrail eventID), and publishes
an alert to SNS.
"""
from __future__ import annotations

import json
import logging
import os
import time

import boto3
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

INCIDENTS_TABLE = os.environ["INCIDENTS_TABLE"]
ALERTS_TOPIC_ARN = os.environ["ALERTS_TOPIC_ARN"]

_s3 = boto3.client("s3")
_ddb = boto3.resource("dynamodb")
_sns = boto3.client("sns")
_incidents = _ddb.Table(INCIDENTS_TABLE)


def handle(event, _ctx):
    detail = event.get("detail") or {}
    event_id = detail.get("eventID") or ""
    event_name = detail.get("eventName") or ""
    req = detail.get("requestParameters") or {}
    bucket = req.get("bucketName")

    if not bucket:
        return {"remediated": False, "reason": "no_bucket", "event_id": event_id}

    # Dedup: claim the CloudTrail eventID first, before any inspection. A replay
    # of the same event is a no-op even if the bucket state changed in the
    # meantime (e.g., because we already remediated it).
    dedup_id = event_id or f"{event_name}:{bucket}:{int(time.time())}"
    if not _claim_event(dedup_id, bucket=bucket, event_name=event_name):
        return {"remediated": False, "reason": "already_processed", "bucket": bucket}

    # Race: bucket might have been deleted between the CloudTrail event and us.
    try:
        _s3.head_bucket(Bucket=bucket)
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code in ("404", "NoSuchBucket", "NotFound"):
            return {"remediated": False, "reason": "bucket_missing", "bucket": bucket}
        raise

    is_public, why = _bucket_is_public(bucket)
    if not is_public:
        return {"remediated": False, "reason": why, "bucket": bucket}

    _remediate(bucket)
    _alert(bucket=bucket, reason=why, event_id=event_id, event_name=event_name)

    return {
        "remediated": True,
        "bucket": bucket,
        "reason": why,
        "event_id": event_id,
        "event_name": event_name,
    }


def _bucket_is_public(bucket: str) -> tuple[bool, str]:
    # 1) Fully-on PublicAccessBlock wins: bucket is definitively private.
    try:
        cfg = _s3.get_public_access_block(Bucket=bucket)["PublicAccessBlockConfiguration"]
        if all([
            cfg["BlockPublicAcls"],
            cfg["IgnorePublicAcls"],
            cfg["BlockPublicPolicy"],
            cfg["RestrictPublicBuckets"],
        ]):
            return False, "pab_fully_on"
    except ClientError as e:
        if e.response["Error"]["Code"] != "NoSuchPublicAccessBlockConfiguration":
            raise
        # No PAB at all, suspicious: treat as public unless ACL/policy say otherwise.

    # 2) Any ACL grant to AllUsers / AuthenticatedUsers => public.
    try:
        grants = _s3.get_bucket_acl(Bucket=bucket).get("Grants", [])
    except ClientError:
        grants = []
    for g in grants:
        uri = (g.get("Grantee") or {}).get("URI", "")
        if uri.endswith("/AllUsers") or uri.endswith("/AuthenticatedUsers"):
            return True, f"acl_grants_{g['Grantee'].get('Type', 'Group')}"

    # 3) Bucket-policy status IsPublic.
    try:
        ps = _s3.get_bucket_policy_status(Bucket=bucket).get("PolicyStatus", {})
    except ClientError:
        ps = {}
    if ps.get("IsPublic"):
        return True, "bucket_policy_is_public"

    return False, "ok"


def _claim_event(event_id: str, *, bucket: str, event_name: str) -> bool:
    """Try to claim the eventID in DynamoDB. True = first time, False = already processed."""
    try:
        _incidents.put_item(
            Item={
                "event_id": event_id,
                "bucket": bucket,
                "event_name": event_name,
                "recorded_at": int(time.time()),
            },
            ConditionExpression="attribute_not_exists(event_id)",
        )
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def _remediate(bucket: str) -> None:
    _s3.put_public_access_block(
        Bucket=bucket,
        PublicAccessBlockConfiguration={
            "BlockPublicAcls": True,
            "IgnorePublicAcls": True,
            "BlockPublicPolicy": True,
            "RestrictPublicBuckets": True,
        },
    )
    _s3.put_bucket_tagging(
        Bucket=bucket,
        Tagging={"TagSet": [{"Key": "le-guardrail-source", "Value": "automated"}]},
    )


def _alert(*, bucket: str, reason: str, event_id: str, event_name: str) -> None:
    payload = {
        "bucket": bucket,
        "reason": reason,
        "event_id": event_id,
        "event_name": event_name,
        "action": "PutPublicAccessBlock(BlockPublicAcls=true, ...)",
    }
    _sns.publish(TopicArn=ALERTS_TOPIC_ARN, Message=json.dumps(payload))
