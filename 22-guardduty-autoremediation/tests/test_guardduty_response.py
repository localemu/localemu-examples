"""6 direct-invoke tests + 1 real end-to-end via EventBridge."""
from __future__ import annotations

import json

from conftest import make_finding_event, wait_for


def _invoke(lambda_client, fn_name: str, event: dict) -> dict:
    resp = lambda_client.invoke(
        FunctionName=fn_name,
        InvocationType="RequestResponse",
        Payload=json.dumps(event).encode(),
    )
    return json.loads(resp["Payload"].read())


def test_assumed_role_is_quarantined(lambda_client, iam, tf, dynamodb, account_id):
    event = make_finding_event(
        finding_type="UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS",
        principal_name=tf["victim_role_name"],
        user_type="AssumedRole",
        account=account_id,
    )

    result = _invoke(lambda_client, tf["function_name"], event)
    assert result["contained"] is True, result
    assert any(a.startswith("quarantined_role:") for a in result["actions_taken"])

    policy = iam.get_role_policy(RoleName=tf["victim_role_name"], PolicyName="le-gd-quarantine")
    doc = policy["PolicyDocument"]
    assert doc["Statement"][0]["Effect"] == "Deny"
    assert doc["Statement"][0]["Action"] == "*"
    assert "aws:TokenIssueTime" in doc["Statement"][0]["Condition"]["DateLessThan"]

    row = dynamodb.Table(tf["incidents_table"]).get_item(Key={"finding_id": event["detail"]["id"]}).get("Item")
    assert row is not None
    assert row["principal"] == tf["victim_role_name"]

    # cleanup so later tests in this module see a clean role
    iam.delete_role_policy(RoleName=tf["victim_role_name"], PolicyName="le-gd-quarantine")


def test_iam_user_is_quarantined_and_key_deactivated(lambda_client, iam, tf, victim_user_factory, account_id):
    victim = victim_user_factory()
    event = make_finding_event(
        finding_type="UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS",
        principal_name=victim["name"],
        user_type="IAMUser",
        access_key_id=victim["access_key_id"],
        account=account_id,
    )

    result = _invoke(lambda_client, tf["function_name"], event)
    assert result["contained"] is True, result
    assert f"quarantined_user:{victim['name']}" in result["actions_taken"]
    assert f"deactivated_key:{victim['access_key_id']}" in result["actions_taken"]

    keys = iam.list_access_keys(UserName=victim["name"])["AccessKeyMetadata"]
    assert keys[0]["Status"] == "Inactive"


def test_duplicate_finding_is_deduped(lambda_client, tf, account_id):
    event = make_finding_event(
        finding_type="UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS",
        principal_name=tf["victim_role_name"],
        user_type="AssumedRole",
        account=account_id,
    )

    first = _invoke(lambda_client, tf["function_name"], event)
    assert first["contained"] is True

    second = _invoke(lambda_client, tf["function_name"], event)
    assert second["contained"] is False
    assert second["reason"] == "already_processed"


def test_non_actionable_finding_type_is_ignored(lambda_client, tf, account_id):
    event = make_finding_event(
        finding_type="Impact:S3Object/MaliciousFile.Benign",  # not in ACTIONABLE_TYPES
        principal_name=tf["victim_role_name"],
        user_type="AssumedRole",
        account=account_id,
    )
    result = _invoke(lambda_client, tf["function_name"], event)
    assert result["contained"] is False
    assert result["reason"] == "finding_type_not_actionable"


def test_missing_principal_name_is_ignored(lambda_client, tf, account_id):
    event = make_finding_event(
        finding_type="UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS",
        principal_name="",
        user_type="AssumedRole",
        account=account_id,
    )
    event["detail"]["resource"]["accessKeyDetails"]["userName"] = None
    result = _invoke(lambda_client, tf["function_name"], event)
    assert result["contained"] is False
    assert result["reason"] == "no_principal_name"


def test_missing_finding_id_is_ignored(lambda_client, tf, account_id):
    event = make_finding_event(
        finding_type="UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS",
        principal_name=tf["victim_role_name"],
        user_type="AssumedRole",
        account=account_id,
    )
    event["detail"]["id"] = ""
    result = _invoke(lambda_client, tf["function_name"], event)
    assert result["contained"] is False
    assert result["reason"] == "no_finding_id"


def test_end_to_end_via_eventbridge(events_client, iam, dynamodb, sqs, tf, victim_user_factory, drain_alerts, account_id):
    """The hero test: inject the finding via EventBridge (not a direct Lambda
    invoke), and watch the whole rule -> Lambda -> IAM/DynamoDB/SNS pipeline
    fire on its own."""
    victim = victim_user_factory()
    event = make_finding_event(
        finding_type="UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS",
        principal_name=victim["name"],
        user_type="IAMUser",
        access_key_id=victim["access_key_id"],
        account=account_id,
    )

    events_client.put_events(
        Entries=[
            {
                "Source": event["source"],
                "DetailType": event["detail-type"],
                "Detail": json.dumps(event["detail"]),
            }
        ]
    )

    def _quarantined():
        try:
            return iam.get_user_policy(UserName=victim["name"], PolicyName="le-gd-quarantine")
        except iam.exceptions.NoSuchEntityException:
            return None

    wait_for(_quarantined, timeout=20)

    keys = iam.list_access_keys(UserName=victim["name"])["AccessKeyMetadata"]
    assert keys[0]["Status"] == "Inactive"

    row = dynamodb.Table(tf["incidents_table"]).get_item(Key={"finding_id": event["detail"]["id"]}).get("Item")
    assert row is not None

    msgs = wait_for(
        lambda: sqs.receive_message(QueueUrl=drain_alerts, MaxNumberOfMessages=5, WaitTimeSeconds=1).get("Messages"),
        timeout=15,
    )
    alert = json.loads(json.loads(msgs[0]["Body"])["Message"])
    assert alert["principal"] == victim["name"]
