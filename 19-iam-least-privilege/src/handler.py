"""
Lambda that touches 6 AWS services in a fixed order. The handler is
structured so a mutation test can pinpoint which permission is missing:

  - If every step succeeds, return {"status": "ok", "trace": [...]}.
  - If any step fails with AccessDenied, stop and return
    {"status": "forbidden", "denied_action": "<service:Action>", ...}.

The handler reads its resource handles from environment variables, which
Terraform writes when it creates the function. AWS_ENDPOINT_URL is
injected automatically by LocalEmu's Lambda runtime.
"""

import base64
import json
import os

import boto3
from botocore.exceptions import ClientError


BUCKET = os.environ["CONFIG_BUCKET"]
TABLE = os.environ["EVENT_TABLE"]
TOPIC_ARN = os.environ["NOTIFY_TOPIC"]
KMS_KEY_ID = os.environ["KMS_KEY_ID"]
SSM_PARAM = os.environ["SSM_PARAM_NAME"]
SECRET_ID = os.environ["SECRET_ID"]
CIPHERTEXT_B64 = os.environ["KMS_CIPHERTEXT_B64"]


DENIED_CODES = {
    "AccessDenied",
    "AccessDeniedException",
    "UnauthorizedOperation",
    "403",
}


def _step(action, fn, trace):
    try:
        fn()
        trace.append({"action": action, "result": "ok"})
        return None
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        if code in DENIED_CODES:
            trace.append({"action": action, "result": "denied", "error_code": code})
            return {"status": "forbidden", "denied_action": action, "trace": trace}
        trace.append({"action": action, "result": "error", "error_code": code})
        raise


def handler(event, context):
    s3 = boto3.client("s3")
    kms = boto3.client("kms")
    ssm = boto3.client("ssm")
    sm = boto3.client("secretsmanager")
    ddb = boto3.client("dynamodb")
    sns = boto3.client("sns")

    request_id = (event or {}).get("request_id", context.aws_request_id)
    trace = []

    steps = (
        ("s3:GetObject",
            lambda: s3.get_object(Bucket=BUCKET, Key="config.json")["Body"].read()),
        ("kms:Decrypt",
            lambda: kms.decrypt(
                CiphertextBlob=base64.b64decode(CIPHERTEXT_B64),
                KeyId=KMS_KEY_ID,  # pass explicitly so IAM can scope to this key
            )),
        ("ssm:GetParameter",
            lambda: ssm.get_parameter(Name=SSM_PARAM)),
        ("secretsmanager:GetSecretValue",
            lambda: sm.get_secret_value(SecretId=SECRET_ID)),
        ("dynamodb:PutItem",
            lambda: ddb.put_item(
                TableName=TABLE,
                Item={"pk": {"S": request_id}, "at": {"S": "now"}},
            )),
        ("sns:Publish",
            lambda: sns.publish(TopicArn=TOPIC_ARN, Message=json.dumps({"id": request_id}))),
    )

    for action, fn in steps:
        denied = _step(action, fn, trace)
        if denied is not None:
            return denied

    return {"status": "ok", "trace": trace}
