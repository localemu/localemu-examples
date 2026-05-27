"""Seven tests: 6 direct-invoke of the Lambda, 1 real end-to-end via CloudTrail."""
from __future__ import annotations

import json
import os

from boto3.dynamodb.conditions import Key

from conftest import make_cloudtrail_event, wait_for


def _invoke(lambda_client, fn_name: str, event: dict) -> dict:
    resp = lambda_client.invoke(
        FunctionName=fn_name,
        InvocationType="RequestResponse",
        Payload=json.dumps(event).encode(),
    )
    return json.loads(resp["Payload"].read())


def test_public_bucket_is_remediated(lambda_client, s3, bucket_factory, tf, dynamodb, sqs, drain_alerts, account_id):
    bucket = bucket_factory(acl="public-read")
    event = make_cloudtrail_event(event_name="PutBucketAcl", bucket=bucket, account=account_id)

    result = _invoke(lambda_client, tf["function_name"], event)
    assert result["remediated"] is True, result

    pab = s3.get_public_access_block(Bucket=bucket)["PublicAccessBlockConfiguration"]
    assert pab == {
        "BlockPublicAcls": True,
        "IgnorePublicAcls": True,
        "BlockPublicPolicy": True,
        "RestrictPublicBuckets": True,
    }

    tags = {t["Key"]: t["Value"] for t in s3.get_bucket_tagging(Bucket=bucket).get("TagSet", [])}
    assert tags.get("le-guardrail-source") == "automated"

    rows = dynamodb.Table(tf["incidents_table"]).query(
        KeyConditionExpression=Key("event_id").eq(event["detail"]["eventID"])
    ).get("Items", [])
    assert len(rows) == 1
    assert rows[0]["bucket"] == bucket

    msgs = wait_for(
        lambda: sqs.receive_message(QueueUrl=drain_alerts, MaxNumberOfMessages=5, WaitTimeSeconds=1).get("Messages"),
        timeout=15,
    )
    alert = json.loads(json.loads(msgs[0]["Body"])["Message"])
    assert alert["bucket"] == bucket
    assert alert["action"].startswith("PutPublicAccessBlock")


def test_private_bucket_is_no_op(lambda_client, s3, bucket_factory, tf, account_id):
    bucket = bucket_factory(acl="private")
    # Turn PAB fully on so the guardrail sees the bucket as locked.
    s3.put_public_access_block(
        Bucket=bucket,
        PublicAccessBlockConfiguration={
            "BlockPublicAcls": True,
            "IgnorePublicAcls": True,
            "BlockPublicPolicy": True,
            "RestrictPublicBuckets": True,
        },
    )
    event = make_cloudtrail_event(event_name="PutBucketAcl", bucket=bucket, account=account_id)
    result = _invoke(lambda_client, tf["function_name"], event)
    assert result["remediated"] is False
    assert result["reason"] == "pab_fully_on"


def test_duplicate_event_is_deduped(lambda_client, s3, bucket_factory, tf, dynamodb, account_id):
    bucket = bucket_factory(acl="public-read")
    event = make_cloudtrail_event(event_name="PutBucketAcl", bucket=bucket, account=account_id)

    first = _invoke(lambda_client, tf["function_name"], event)
    assert first["remediated"] is True

    second = _invoke(lambda_client, tf["function_name"], event)
    assert second["remediated"] is False
    assert second["reason"] == "already_processed"

    rows = dynamodb.Table(tf["incidents_table"]).query(
        KeyConditionExpression=Key("event_id").eq(event["detail"]["eventID"])
    ).get("Items", [])
    assert len(rows) == 1  # only one incident row despite two firings


def test_missing_bucket_is_ignored(lambda_client, tf, account_id):
    event = make_cloudtrail_event(
        event_name="PutBucketAcl",
        bucket="le-guard-does-not-exist-zzz999",
        account=account_id,
    )
    result = _invoke(lambda_client, tf["function_name"], event)
    assert result["remediated"] is False
    assert result["reason"] == "bucket_missing"


def test_event_without_bucket_name_is_handled(lambda_client, tf, account_id):
    event = make_cloudtrail_event(event_name="PutBucketAcl", bucket="__placeholder__", account=account_id)
    del event["detail"]["requestParameters"]["bucketName"]
    result = _invoke(lambda_client, tf["function_name"], event)
    assert result["remediated"] is False
    assert result["reason"] == "no_bucket"


def test_eventbridge_rule_matches_the_right_apis(events_client, tf):
    resp = events_client.describe_rule(Name=tf["rule_name"])
    pattern = json.loads(resp["EventPattern"])
    assert pattern["source"] == ["aws.s3"]
    expected = {
        "CreateBucket", "PutBucketAcl", "PutBucketPolicy",
        "PutBucketPublicAccessBlock", "DeletePublicAccessBlock",
        "DeleteBucketPublicAccessBlock", "PutBucketWebsite",
    }
    assert set(pattern["detail"]["eventName"]) == expected


def test_real_cloudtrail_eventbridge_flow_remediates_public_bucket(
    s3, bucket_factory, tf, dynamodb, account_id, trail_logging_on
):
    """Hero test: create a public bucket; the full pipeline (CloudTrail ->
    EventBridge -> Lambda) must detect and remediate without any direct invoke."""
    bucket = bucket_factory(acl="public-read")

    timeout = 60.0 if os.environ.get("TARGET", "local") == "local" else 1200.0

    def _is_locked():
        pab = s3.get_public_access_block(Bucket=bucket)["PublicAccessBlockConfiguration"]
        return all([
            pab["BlockPublicAcls"],
            pab["IgnorePublicAcls"],
            pab["BlockPublicPolicy"],
            pab["RestrictPublicBuckets"],
        ]) or None

    wait_for(_is_locked, timeout=timeout, interval=1.0)

    # An incident row was created for this bucket.
    items = dynamodb.Table(tf["incidents_table"]).scan().get("Items", [])
    matching = [i for i in items if i.get("bucket") == bucket]
    assert matching, "expected at least one incident row for the public bucket"
    assert matching[0]["event_name"] in (
        "CreateBucket", "PutBucketAcl", "PutBucketPolicy",
        "PutBucketPublicAccessBlock", "DeletePublicAccessBlock",
    )
