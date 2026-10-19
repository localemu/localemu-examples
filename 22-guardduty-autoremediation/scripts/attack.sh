#!/usr/bin/env bash
# Live-demo script: play both sides, red then blue, against a deployed stack.
# Not part of the automated test suite (see tests/test_guardduty_response.py) —
# this is the narrated version for presenting on stage.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE/terraform"

export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
export AWS_DEFAULT_REGION=us-east-1
export AWS_ENDPOINT_URL=http://localhost:4566

ROLE_ARN=$(terraform output -raw victim_role_arn)
ROLE_NAME=$(terraform output -raw victim_role_name)
RULE_NAME=$(terraform output -raw rule_name)
DETECTOR_ID=$(aws guardduty list-detectors --query 'DetectorIds[0]' --output text)

# Make this script safely re-runnable without a full teardown/redeploy
# cycle: clear any quarantine left over from a previous run of this demo.
aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name le-gd-quarantine 2>/dev/null || true

echo "=================================================================="
echo " BONUS: CreateSampleFindings now works for real (previously a"
echo " LocalEmu gap this workshop's upstream fix closed)."
echo "=================================================================="
aws guardduty create-sample-findings --detector-id "$DETECTOR_ID" \
  --finding-types "UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS"
echo "-> real finding generated and auto-forwarded to EventBridge (matching"
echo "   real AWS behavior). Note: AWS's sample findings always name a"
echo "   generic placeholder identity (not a real resource in your"
echo "   account, on LocalEmu OR on real AWS) — fine for proving your"
echo "   EventBridge/Lambda wiring, but it can't demonstrate containing"
echo "   an identity that actually exists. That's what the rest of this"
echo "   demo does, with a real victim role."
sleep 2

echo
echo "=================================================================="
echo " RED TEAM: attacker already phished this EC2 instance role's creds"
echo " (e.g. via the SSRF -> IMDS chain from the security lab)."
echo "=================================================================="
echo "role: $ROLE_NAME"

CREDS=$(aws sts assume-role --role-arn "$ROLE_ARN" --role-session-name hacker-session --output json)
AK=$(echo "$CREDS" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Credentials"]["AccessKeyId"])')
SK=$(echo "$CREDS" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Credentials"]["SecretAccessKey"])')
ST=$(echo "$CREDS" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Credentials"]["SessionToken"])')

echo
echo "-> attacker recon with the stolen session:"
AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK AWS_SESSION_TOKEN=$ST \
  aws sts get-caller-identity
AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK AWS_SESSION_TOKEN=$ST \
  aws s3 ls

# A beat of real time between the stolen session being minted and
# containment being applied, so aws:TokenIssueTime (now populated by
# LocalEmu) strictly precedes the Deny's DateLessThan boundary — on real
# AWS this gap is however long detection actually takes, never sub-second.
sleep 2

echo
echo "=================================================================="
echo " DETECTION: GuardDuty flags this as InstanceCredentialExfiltration,"
echo " naming the real victim role. Sample findings can't do that (see"
echo " above), so this is a schema-accurate finding shaped exactly like"
echo " what GuardDuty's real detection would emit, published straight to"
echo " EventBridge, matching rule: $RULE_NAME"
echo "=================================================================="

FINDING_ID=$(python3 -c 'import uuid;print(uuid.uuid4().hex)')
DETAIL=$(python3 - "$ROLE_NAME" "$FINDING_ID" <<'PY'
import json, sys, time, uuid
role_name, finding_id = sys.argv[1], sys.argv[2]
print(json.dumps({
    "schemaVersion": "2.0",
    "accountId": "000000000000",
    "region": "us-east-1",
    "id": finding_id,
    "type": "UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration.OutsideAWS",
    "severity": 8.5,
    "title": "InstanceCredentialExfiltration.OutsideAWS",
    "resource": {
        "resourceType": "AccessKey",
        "accessKeyDetails": {
            "accessKeyId": "ASIAEXAMPLE" + uuid.uuid4().hex[:9].upper(),
            "principalId": uuid.uuid4().hex,
            "userType": "AssumedRole",
            "userName": role_name,
        },
    },
    "service": {"action": {"actionType": "AWS_API_CALL", "awsApiCallAction": {
        "api": "GetCallerIdentity", "serviceName": "sts.amazonaws.com",
        "callerType": "Remote IP",
        "remoteIpDetails": {"ipAddressV4": "203.0.113.42", "country": {"countryName": "Unknown"}},
    }}},
}))
PY
)

aws events put-events --entries "[{\"Source\":\"aws.guardduty\",\"DetailType\":\"GuardDuty Finding\",\"Detail\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$DETAIL")}]"

echo "waiting for the responder Lambda to react..."
sleep 3

echo
echo "=================================================================="
echo " BLUE TEAM: the stolen session should be denied now — but only"
echo " that session. A FRESH session minted after this point would NOT"
echo " be blocked (aws:TokenIssueTime-gated Deny, not a blanket lockout)."
echo "=================================================================="
echo "(sts:GetCallerIdentity is exempt from IAM policy evaluation on AWS"
echo " by design, so it will still succeed -- that's expected, not a miss:"
echo " it proves nothing about containment, which is why we check s3:ls too.)"
AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK AWS_SESSION_TOKEN=$ST \
  aws sts get-caller-identity
set +e
AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK AWS_SESSION_TOKEN=$ST \
  aws s3 ls
echo "(exit code: $?) -- a non-zero/AccessDenied here means containment worked."
set -e

echo
echo "-> proving the surgical scope: a session minted AFTER containment works fine"
sleep 1
FRESH_CREDS=$(aws sts assume-role --role-arn "$ROLE_ARN" --role-session-name legit-after-fix --output json)
FAK=$(echo "$FRESH_CREDS" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Credentials"]["AccessKeyId"])')
FSK=$(echo "$FRESH_CREDS" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Credentials"]["SecretAccessKey"])')
FST=$(echo "$FRESH_CREDS" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Credentials"]["SessionToken"])')
AWS_ACCESS_KEY_ID=$FAK AWS_SECRET_ACCESS_KEY=$FSK AWS_SESSION_TOKEN=$FST \
  aws s3 ls
echo "(a 200/empty-list here, not AccessDenied, is the point: the role itself"
echo " isn't locked out, only the pre-containment session was.)"

echo
echo "-> incident row:"
aws dynamodb get-item --table-name "$(terraform output -raw incidents_table)" \
  --key "{\"finding_id\":{\"S\":\"$FINDING_ID\"}}"

echo
echo "Done. Run scripts/teardown.sh when you're finished presenting."
