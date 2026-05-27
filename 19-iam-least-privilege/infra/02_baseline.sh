#!/usr/bin/env bash
# Step 02: baseline. Attach the "golden" minimum-viable policy to the
# Lambda's role, invoke the Lambda, expect status == "ok" and all six
# steps green. This is the control run. If the baseline fails, the
# whole mutation harness is meaningless.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

need_healthy_localemu
state_load
: "${ROLE:?run infra/01_setup.sh first}"

bold "4. Attach the golden policy (6 Sids, one per action)"

# Assemble the golden policy. Each Sid grants exactly one business
# action, scoped to exactly one resource. This is the minimum the
# handler needs to succeed on all six steps.
GOLDEN=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {"Sid":"GetConfig","Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::${BUCKET}/*"},
    {"Sid":"DecryptKms","Effect":"Allow","Action":"kms:Decrypt","Resource":"${KEY_ARN}"},
    {"Sid":"ReadParam","Effect":"Allow","Action":"ssm:GetParameter","Resource":"${PARAM_ARN}"},
    {"Sid":"ReadSecret","Effect":"Allow","Action":"secretsmanager:GetSecretValue","Resource":"${SECRET_ARN}"},
    {"Sid":"WriteEvent","Effect":"Allow","Action":"dynamodb:PutItem","Resource":"arn:aws:dynamodb:${AWS_REGION}:000000000000:table/${TABLE}"},
    {"Sid":"Notify","Effect":"Allow","Action":"sns:Publish","Resource":"${TOPIC_ARN}"}
  ]
}
JSON
)

awsx iam put-role-policy --role-name "${ROLE}" \
  --policy-name mutation-test-policy \
  --policy-document "${GOLDEN}" >/dev/null
ok "Golden policy attached to ${ROLE}"

# Persist so the mutation script can read + edit it.
printf '%s' "${GOLDEN}" > "${STATE_DIR}/golden.json"

bold "5. Invoke the Lambda under the golden policy: expect status=ok"

log "Invoking ${FN}"
RESPONSE=$(invoke_lambda "${FN}" '{"request_id":"baseline"}')
printf '      %s\n' "${RESPONSE}"

STATUS=$(printf '%s' "${RESPONSE}" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status",""))')
if [[ "${STATUS}" != "ok" ]]; then
  fail "baseline should return status=ok, got: ${RESPONSE}"
fi
ok "Baseline green: golden policy lets all 6 steps through"
