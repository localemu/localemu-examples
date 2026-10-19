"""GuardDuty finding responder Lambda — a minimal Cloud Detection & Response (CDR) loop.

Triggered by an EventBridge rule matching `source: aws.guardduty`. Looks at
the compromised identity named in the finding, quarantines it, deactivates
any leaked access key, logs an incident (deduped on the finding id), and
publishes an SNS alert.

Quarantine technique: a `TokenIssueTime`-gated Deny for assumed-role
sessions (AWS's own surgical IR pattern — only already-issued sessions
are cut off), or an unconditional Deny-all for IAM users (no session to
gate on). See `_quarantine_role`'s docstring.
"""
from __future__ import annotations

import json
import logging
import os
import time
from decimal import Decimal

import boto3
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

INCIDENTS_TABLE = os.environ["INCIDENTS_TABLE"]
ALERTS_TOPIC_ARN = os.environ["ALERTS_TOPIC_ARN"]

# Finding types this responder knows how to act on. Anything else is logged
# as a no-op rather than silently ignored, same spirit as 06-s3-guardrail's
# "rule-pattern shape" case.
ACTIONABLE_TYPES = {
    "UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS",
    "UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.InsideAWS",
    "Recon:IAMUser/MaliciousIPCaller",
    "UnauthorizedAccess:IAMUser/UnusualASNCaller",
}

_iam = boto3.client("iam")
_ddb = boto3.resource("dynamodb")
_sns = boto3.client("sns")
_incidents = _ddb.Table(INCIDENTS_TABLE)

QUARANTINE_POLICY_NAME = "le-gd-quarantine"


def handle(event, _ctx):
    detail = event.get("detail") or {}
    finding_id = detail.get("id") or ""
    finding_type = detail.get("type") or ""
    severity = detail.get("severity")

    if not finding_id:
        return {"contained": False, "reason": "no_finding_id"}

    if finding_type not in ACTIONABLE_TYPES:
        return {"contained": False, "reason": "finding_type_not_actionable", "finding_id": finding_id, "type": finding_type}

    access_key_details = (detail.get("resource") or {}).get("accessKeyDetails") or {}
    principal_name = access_key_details.get("userName")
    user_type = access_key_details.get("userType")  # "AssumedRole" | "IAMUser"
    access_key_id = access_key_details.get("accessKeyId")

    if not principal_name:
        return {"contained": False, "reason": "no_principal_name", "finding_id": finding_id}

    # Dedup first: claim the finding id before taking any action, so a
    # replayed event (or a retried EventBridge delivery) is a no-op.
    if not _claim_finding(finding_id, principal=principal_name, finding_type=finding_type, severity=severity):
        return {"contained": False, "reason": "already_processed", "finding_id": finding_id}

    actions_taken = []
    now = int(time.time())

    if user_type == "AssumedRole":
        try:
            _quarantine_role(principal_name, as_of_epoch=now)
            actions_taken.append(f"quarantined_role:{principal_name}")
        except ClientError as e:
            actions_taken.append(f"quarantine_failed:{e.response['Error']['Code']}")
    elif user_type == "IAMUser":
        try:
            _quarantine_role(principal_name, as_of_epoch=now, is_user=True)
            actions_taken.append(f"quarantined_user:{principal_name}")
        except ClientError as e:
            actions_taken.append(f"quarantine_failed:{e.response['Error']['Code']}")
        if access_key_id:
            try:
                _iam.update_access_key(UserName=principal_name, AccessKeyId=access_key_id, Status="Inactive")
                actions_taken.append(f"deactivated_key:{access_key_id}")
            except ClientError as e:
                actions_taken.append(f"deactivate_key_failed:{e.response['Error']['Code']}")

    _publish_alert(
        finding_id=finding_id,
        finding_type=finding_type,
        severity=severity,
        principal=principal_name,
        actions_taken=actions_taken,
    )

    return {
        "contained": True,
        "finding_id": finding_id,
        "principal": principal_name,
        "actions_taken": actions_taken,
    }


def _claim_finding(finding_id: str, *, principal: str, finding_type: str, severity) -> bool:
    try:
        _incidents.put_item(
            Item={
                "finding_id": finding_id,
                "principal": principal,
                "finding_type": finding_type,
                "severity": Decimal(str(severity)) if severity is not None else None,
                "processed_at": int(time.time()),
            },
            ConditionExpression="attribute_not_exists(finding_id)",
        )
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def _quarantine_role(name: str, *, as_of_epoch: int, is_user: bool = False) -> None:
    """Quarantine the compromised identity, pending investigation.

    AssumedRole: the surgical AWS IR technique — Deny every action for any
    session token issued before containment, via
    `Condition: {"DateLessThan": {"aws:TokenIssueTime": "<now>"}}`. Only
    sessions already in the attacker's hands are cut off; a session minted
    *after* remediation (e.g. once the role's trust/perms are fixed) is
    unaffected, so the role doesn't need to stay locked out of legitimate
    use while the incident is being investigated. (LocalEmu didn't
    populate `aws:TokenIssueTime` as a condition key until this workshop's
    accompanying upstream fix — see the README.)

    IAMUser: there's no session/token to gate on issue time (no AssumeRole
    involved), so an unconditional inline Deny-all is the direct
    equivalent of pulling the user's access immediately.
    """
    if is_user:
        policy = {
            "Version": "2012-10-17",
            "Statement": [{
                "Sid": "DenyAllPendingInvestigation",
                "Effect": "Deny", "Action": "*", "Resource": "*",
            }],
        }
        _iam.put_user_policy(UserName=name, PolicyName=QUARANTINE_POLICY_NAME, PolicyDocument=json.dumps(policy))
        return

    as_of = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(as_of_epoch))
    policy = {
        "Version": "2012-10-17",
        "Statement": [{
            "Sid": "DenySessionsIssuedBeforeContainment",
            "Effect": "Deny", "Action": "*", "Resource": "*",
            "Condition": {"DateLessThan": {"aws:TokenIssueTime": as_of}},
        }],
    }
    _iam.put_role_policy(RoleName=name, PolicyName=QUARANTINE_POLICY_NAME, PolicyDocument=json.dumps(policy))


def _publish_alert(*, finding_id: str, finding_type: str, severity, principal: str, actions_taken: list[str]) -> None:
    _sns.publish(
        TopicArn=ALERTS_TOPIC_ARN,
        Subject=f"[GuardDuty] {finding_type}",
        Message=json.dumps(
            {
                "finding_id": finding_id,
                "finding_type": finding_type,
                "severity": severity,
                "principal": principal,
                "actions_taken": actions_taken,
            }
        ),
    )
