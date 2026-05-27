#!/usr/bin/env bash
# Step 01: create the DynamoDB table, IAM role with PutItem on the
# table + CloudWatch Logs, and the resilient writer Lambda.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

need_healthy_localemu
rm -f "${STATE_DIR}/ids.env"

PFX=chaos
TABLE="${PFX}-writes"
ROLE="${PFX}-lambda-role"
FN="${PFX}-resilient-writer"

# ---- Best-effort cleanup so the script is re-runnable ---------------------
_cleanup_silent() {
  awsx lambda delete-function --function-name "${FN}" >/dev/null 2>&1 || true
  for p in $(awsx iam list-role-policies --role-name "${ROLE}" \
               --query 'PolicyNames' --output text 2>/dev/null); do
    awsx iam delete-role-policy --role-name "${ROLE}" --policy-name "$p" >/dev/null 2>&1 || true
  done
  awsx iam delete-role --role-name "${ROLE}" >/dev/null 2>&1 || true
  awsx dynamodb delete-table --table-name "${TABLE}" >/dev/null 2>&1 || true
}
log "Clearing any previous run state (best effort)"
_cleanup_silent
ok "Clean slate"

bold "1. Create DynamoDB table"

log "Creating table ${TABLE}"
awsx dynamodb create-table \
  --table-name "${TABLE}" \
  --attribute-definitions AttributeName=request_id,AttributeType=S \
  --key-schema AttributeName=request_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST >/dev/null
awsx dynamodb wait table-exists --table-name "${TABLE}"
ok "Table ${TABLE} ACTIVE"

bold "2. Create Lambda role"

TRUST=$(cat <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
)
log "Creating role ${ROLE}"
ROLE_ARN=$(awsx iam create-role --role-name "${ROLE}" \
  --assume-role-policy-document "${TRUST}" \
  --query 'Role.Arn' --output text)

POLICY=$(cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],"Resource":"*"},
 {"Effect":"Allow","Action":["dynamodb:PutItem"],"Resource":"arn:aws:dynamodb:${AWS_REGION}:000000000000:table/${TABLE}"}
]}
JSON
)
awsx iam put-role-policy --role-name "${ROLE}" \
  --policy-name chaos-writer --policy-document "${POLICY}" >/dev/null
ok "Role ${ROLE_ARN}"

bold "3. Package + create the resilient writer Lambda"

BUILD="${TUTORIAL_ROOT}/build"
mkdir -p "${BUILD}"
cp "${TUTORIAL_ROOT}/src/handler.py" "${BUILD}/handler.py"
(cd "${BUILD}" && zip -q -FS handler.zip handler.py)
log "Zip built"

for attempt in 1 2 3 4 5; do
  if awsx lambda create-function \
      --function-name "${FN}" \
      --runtime python3.11 \
      --handler handler.handler \
      --role "${ROLE_ARN}" \
      --zip-file fileb://"${BUILD}/handler.zip" \
      --timeout 60 \
      --environment "Variables={TABLE_NAME=${TABLE},MAX_ATTEMPTS=5}" \
      --query 'FunctionArn' --output text >/dev/null 2>&1; then
    break
  fi
  [[ ${attempt} -eq 5 ]] && fail "create-function failed after 5 attempts"
  sleep 2
done
awsx lambda wait function-active --function-name "${FN}"
ok "Lambda ${FN} Active"

state_set TABLE "${TABLE}"
state_set ROLE  "${ROLE}"
state_set FN    "${FN}"

ok "Setup complete. Ids in ${STATE_DIR}/ids.env"
