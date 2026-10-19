"""Test fixtures: clients, ephemeral victim-user factory, helpers."""
from __future__ import annotations

import json
import os
import subprocess
import time
import uuid
from pathlib import Path

import boto3
import pytest

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
    raw = subprocess.check_output(["terraform", "output", "-json"], cwd=str(TERRAFORM_DIR))
    parsed = json.loads(raw)
    return {k: v["value"] for k, v in parsed.items()}


@pytest.fixture(scope="session")
def account_id() -> str:
    if os.environ.get("TARGET", "local") == "local":
        return "000000000000"
    return boto3.client("sts", **_aws_kwargs()).get_caller_identity()["Account"]


@pytest.fixture(scope="session")
def lambda_client():
    return boto3.client("lambda", **_aws_kwargs())


@pytest.fixture(scope="session")
def dynamodb():
    return boto3.resource("dynamodb", **_aws_kwargs())


@pytest.fixture(scope="session")
def iam():
    return boto3.client("iam", **_aws_kwargs())


@pytest.fixture(scope="session")
def sns():
    return boto3.client("sns", **_aws_kwargs())


@pytest.fixture(scope="session")
def sqs():
    return boto3.client("sqs", **_aws_kwargs())


@pytest.fixture(scope="session")
def events_client():
    return boto3.client("events", **_aws_kwargs())


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
def victim_user_factory(iam):
    """Create disposable le-gd-victim-* IAM users (with an access key),
    matching the responder's scoped quarantine permissions. Cleaned up
    after the test."""
    created: list[str] = []

    def _make() -> dict:
        name = f"le-gd-victim-user-{uuid.uuid4().hex[:10]}"
        iam.create_user(UserName=name)
        key = iam.create_access_key(UserName=name)["AccessKey"]
        created.append(name)
        return {"name": name, "access_key_id": key["AccessKeyId"]}

    yield _make

    for name in created:
        try:
            for k in iam.list_access_keys(UserName=name)["AccessKeyMetadata"]:
                iam.delete_access_key(UserName=name, AccessKeyId=k["AccessKeyId"])
        except Exception:
            pass
        try:
            iam.delete_user_policy(UserName=name, PolicyName="le-gd-quarantine")
        except Exception:
            pass
        try:
            iam.delete_user(UserName=name)
        except Exception:
            pass


@pytest.fixture
def drain_alerts(sns, sqs, tf):
    """Create an ephemeral SQS queue subscribed to the alerts topic, return its URL."""
    qname = f"le-gd-alerts-{uuid.uuid4().hex[:8]}"
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


def make_finding_event(
    *,
    finding_type: str,
    principal_name: str,
    user_type: str,
    account: str,
    access_key_id: str | None = None,
    finding_id: str | None = None,
    severity: float = 8.5,
) -> dict:
    """Shape a schema-accurate GuardDuty Finding event.

    LocalEmu's GuardDuty does not yet implement CreateSampleFindings /
    ListFindings (see README), so this is how the lab's demo and tests
    inject a finding: publish the exact event shape GuardDuty would emit,
    straight to EventBridge. The rule and responder are 100% production
    shape either way — only the finding's origin differs.
    """
    return {
        "version": "0",
        "id": uuid.uuid4().hex,
        "detail-type": "GuardDuty Finding",
        "source": "aws.guardduty",
        "account": account,
        "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "region": os.environ.get("AWS_REGION", "us-east-1"),
        "resources": [],
        "detail": {
            "schemaVersion": "2.0",
            "accountId": account,
            "region": "us-east-1",
            "id": finding_id or uuid.uuid4().hex,
            "type": finding_type,
            "severity": severity,
            "title": finding_type,
            "resource": {
                "resourceType": "AccessKey",
                "accessKeyDetails": {
                    "accessKeyId": access_key_id or f"ASIAEXAMPLE{uuid.uuid4().hex[:9].upper()}",
                    "principalId": uuid.uuid4().hex,
                    "userType": user_type,
                    "userName": principal_name,
                },
            },
            "service": {
                "action": {
                    "actionType": "AWS_API_CALL",
                    "awsApiCallAction": {
                        "api": "GetCallerIdentity",
                        "serviceName": "sts.amazonaws.com",
                        "callerType": "Remote IP",
                        "remoteIpDetails": {"ipAddressV4": "203.0.113.42", "country": {"countryName": "Unknown"}},
                    },
                }
            },
        },
    }
