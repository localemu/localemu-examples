"""Test fixtures: bucket factory (with per-test cleanup), clients, helpers."""
from __future__ import annotations

import json
import os
import subprocess
import time
import uuid
from pathlib import Path

import boto3
import pytest
from botocore.config import Config

TERRAFORM_DIR = Path(__file__).resolve().parent.parent / "terraform"


def _aws_kwargs() -> dict:
    target = os.environ.get("TARGET", "local")
    if target == "local":
        return {
            "region_name": "us-east-1",
            "aws_access_key_id": "AKIAIOSFODNN7EXAMPLE",
            "aws_secret_access_key": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "endpoint_url": "http://localhost:4566",
        }
    return {"region_name": os.environ.get("AWS_REGION", "us-east-1")}


@pytest.fixture(scope="session")
def tf() -> dict[str, str]:
    raw = subprocess.check_output(
        ["terraform", "output", "-json"],
        cwd=str(TERRAFORM_DIR),
    )
    parsed = json.loads(raw)
    return {k: v["value"] for k, v in parsed.items()}


@pytest.fixture(scope="session")
def account_id() -> str:
    if os.environ.get("TARGET", "local") == "local":
        return "000000000000"
    return boto3.client("sts", **_aws_kwargs()).get_caller_identity()["Account"]


@pytest.fixture(scope="session")
def s3():
    return boto3.client("s3", **_aws_kwargs(), config=Config(s3={"addressing_style": "path"}))


@pytest.fixture(scope="session")
def lambda_client():
    return boto3.client("lambda", **_aws_kwargs())


@pytest.fixture(scope="session")
def dynamodb():
    return boto3.resource("dynamodb", **_aws_kwargs())


@pytest.fixture(scope="session")
def sns():
    return boto3.client("sns", **_aws_kwargs())


@pytest.fixture(scope="session")
def sqs():
    return boto3.client("sqs", **_aws_kwargs())


@pytest.fixture(scope="session")
def events_client():
    return boto3.client("events", **_aws_kwargs())


@pytest.fixture(scope="session")
def cloudtrail():
    return boto3.client("cloudtrail", **_aws_kwargs())


@pytest.fixture(scope="session", autouse=True)
def suspend_cloudtrail_for_direct_tests(tf, cloudtrail):
    """Stop CloudTrail logging by default so direct-invoke tests don't race
    with the real pipeline. The hero test explicitly re-enables it."""
    try:
        cloudtrail.stop_logging(Name=tf["trail_name"])
    except Exception:
        pass
    yield
    try:
        cloudtrail.stop_logging(Name=tf["trail_name"])
    except Exception:
        pass


@pytest.fixture
def trail_logging_on(tf, cloudtrail):
    """Enable CloudTrail logging for tests that need the full pipeline."""
    cloudtrail.start_logging(Name=tf["trail_name"])
    yield
    cloudtrail.stop_logging(Name=tf["trail_name"])


def wait_for(fn, *, timeout: float = 30.0, interval: float = 0.5):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = fn()
        if last:
            return last
        time.sleep(interval)
    raise AssertionError(f"wait_for timeout after {timeout}s, last={last!r}")


@pytest.fixture
def bucket_factory(s3):
    """Create buckets with a given ACL; clean them up after the test."""
    created: list[str] = []

    def _make(acl: str = "private") -> str:
        name = f"le-guard-test-{uuid.uuid4().hex[:10]}"
        kwargs = {"Bucket": name}
        # Disable BlockPublicAcls ownership so a public ACL actually sticks.
        s3.create_bucket(**kwargs)
        s3.put_bucket_ownership_controls(
            Bucket=name,
            OwnershipControls={"Rules": [{"ObjectOwnership": "BucketOwnerPreferred"}]},
        )
        s3.put_public_access_block(
            Bucket=name,
            PublicAccessBlockConfiguration={
                "BlockPublicAcls": False,
                "IgnorePublicAcls": False,
                "BlockPublicPolicy": False,
                "RestrictPublicBuckets": False,
            },
        )
        if acl != "private":
            s3.put_bucket_acl(Bucket=name, ACL=acl)
        created.append(name)
        return name

    yield _make

    for name in created:
        try:
            for obj in s3.list_objects_v2(Bucket=name).get("Contents", []) or []:
                s3.delete_object(Bucket=name, Key=obj["Key"])
            s3.delete_bucket(Bucket=name)
        except Exception:
            pass


@pytest.fixture
def drain_alerts(sns, sqs, tf):
    """Create an ephemeral SQS queue subscribed to the alerts topic, return its URL."""
    qname = f"le-guard-alerts-{uuid.uuid4().hex[:8]}"
    q_url = sqs.create_queue(QueueName=qname)["QueueUrl"]
    q_arn = sqs.get_queue_attributes(QueueUrl=q_url, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
    sqs.set_queue_attributes(
        QueueUrl=q_url,
        Attributes={
            "Policy": json.dumps(
                {
                    "Version": "2012-10-17",
                    "Statement": [
                        {
                            "Effect": "Allow",
                            "Principal": {"Service": "sns.amazonaws.com"},
                            "Action": "sqs:SendMessage",
                            "Resource": q_arn,
                            "Condition": {"ArnEquals": {"aws:SourceArn": tf["alerts_topic_arn"]}},
                        }
                    ],
                }
            )
        },
    )
    sub = sns.subscribe(TopicArn=tf["alerts_topic_arn"], Protocol="sqs", Endpoint=q_arn)

    yield q_url

    try:
        sns.unsubscribe(SubscriptionArn=sub["SubscriptionArn"])
    except Exception:
        pass
    try:
        sqs.delete_queue(QueueUrl=q_url)
    except Exception:
        pass


def make_cloudtrail_event(*, event_name: str, bucket: str, account: str, event_id: str | None = None) -> dict:
    """Shape a synthetic EventBridge-wrapped CloudTrail event for direct Lambda invoke."""
    return {
        "version": "0",
        "id": uuid.uuid4().hex,
        "detail-type": "AWS API Call via CloudTrail",
        "source": "aws.s3",
        "account": account,
        "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "region": os.environ.get("AWS_REGION", "us-east-1"),
        "resources": [],
        "detail": {
            "eventID": event_id or uuid.uuid4().hex,
            "eventSource": "s3.amazonaws.com",
            "eventName": event_name,
            "requestParameters": {"bucketName": bucket},
        },
    }
