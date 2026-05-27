#!/usr/bin/env bash
# Step 01: create the six AWS resources the Lambda touches, plus the
# Lambda itself and its execution role. The role's baseline policy
# grants CloudWatch Logs only; the mutable policy that governs the six
# business actions is managed by steps 02/03 via iam:PutRolePolicy.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

need_healthy_localemu
rm -f "${STATE_DIR}/ids.env"

PFX=iam-mvp
BUCKET="${PFX}-config"
TABLE="${PFX}-events"
TOPIC_NAME="${PFX}-notify"
PARAM="/${PFX}/runtime-config"
SECRET="${PFX}/api-key"
ROLE="${PFX}-lambda-role"
FN="${PFX}-target"

# ---- Best-effort cleanup so the script is re-runnable ----------------------
_cleanup_silent() {
  awsx lambda delete-function --function-name "${FN}" >/dev/null 2>&1 || true
  for p in $(awsx iam list-role-policies --role-name "${ROLE}" \
               --query 'PolicyNames' --output text 2>/dev/null); do
    awsx iam delete-role-policy --role-name "${ROLE}" --policy-name "$p" >/dev/null 2>&1 || true
  done
  awsx iam delete-role --role-name "${ROLE}" >/dev/null 2>&1 || true
  awsx sns delete-topic --topic-arn "arn:aws:sns:${AWS_REGION}:000000000000:${TOPIC_NAME}" >/dev/null 2>&1 || true
  awsx secretsmanager delete-secret --secret-id "${SECRET}" --force-delete-without-recovery >/dev/null 2>&1 || true
  awsx ssm delete-parameter --name "${PARAM}" >/dev/null 2>&1 || true
  awsx dynamodb delete-table --table-name "${TABLE}" >/dev/null 2>&1 || true
  awsx s3 rm "s3://${BUCKET}" --recursive >/dev/null 2>&1 || true
  awsx s3api delete-bucket --bucket "${BUCKET}" >/dev/null 2>&1 || true
}
log "Clearing any previous run state (best effort)"
_cleanup_silent
ok "Clean slate"

bold "1. Setup: create the six AWS resources"

log "Creating S3 bucket ${BUCKET}"
awsx s3api create-bucket --bucket "${BUCKET}" >/dev/null
printf '{"feature_flags":{"enable_new_flow":true}}' > "${STATE_DIR}/config.json"
awsx s3api put-object --bucket "${BUCKET}" --key config.json \
  --body "${STATE_DIR}/config.json" >/dev/null
ok "Bucket ${BUCKET} created + config.json uploaded"

log "Creating DynamoDB table ${TABLE}"
awsx dynamodb create-table \
  --table-name "${TABLE}" \
  --attribute-definitions AttributeName=pk,AttributeType=S \
  --key-schema AttributeName=pk,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST >/dev/null
awsx dynamodb wait table-exists --table-name "${TABLE}"
ok "Table ${TABLE} ACTIVE"

log "Creating KMS key"
KEY_ID=$(awsx kms create-key --description "IAM mvp test key" \
  --query 'KeyMetadata.KeyId' --output text)
KEY_ARN=$(awsx kms describe-key --key-id "${KEY_ID}" \
  --query 'KeyMetadata.Arn' --output text)
ok "KMS key ${KEY_ID}"

log "Encrypting a bootstrap secret with the key (will be decrypted at invoke)"
printf 'bootstrap-secret' > "${STATE_DIR}/plaintext.bin"
CIPHERTEXT_B64=$(awsx kms encrypt --key-id "${KEY_ID}" \
  --plaintext fileb://"${STATE_DIR}/plaintext.bin" \
  --query CiphertextBlob --output text)
ok "Ciphertext captured (${#CIPHERTEXT_B64} chars base64)"

log "Creating SSM parameter ${PARAM}"
awsx ssm put-parameter --name "${PARAM}" --type String \
  --value "runtime-mode=prod" >/dev/null
PARAM_ARN="arn:aws:ssm:${AWS_REGION}:000000000000:parameter${PARAM}"
ok "Parameter ${PARAM}"

log "Creating Secrets Manager secret ${SECRET}"
SECRET_ARN=$(awsx secretsmanager create-secret --name "${SECRET}" \
  --secret-string "sk_test_localemu_deadbeef" \
  --query 'ARN' --output text)
ok "Secret ${SECRET_ARN}"

log "Creating SNS topic ${TOPIC_NAME}"
TOPIC_ARN=$(awsx sns create-topic --name "${TOPIC_NAME}" \
  --query 'TopicArn' --output text)
ok "Topic ${TOPIC_ARN}"

# ---- IAM role for the Lambda -----------------------------------------------
bold "2. Create the Lambda execution role (CloudWatch Logs only)"

TRUST=$(cat <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
)
log "Creating role ${ROLE}"
ROLE_ARN=$(awsx iam create-role --role-name "${ROLE}" \
  --assume-role-policy-document "${TRUST}" \
  --query 'Role.Arn' --output text)

LOGS=$(cat <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],"Resource":"*"}]}
JSON
)
awsx iam put-role-policy --role-name "${ROLE}" \
  --policy-name baseline-logs --policy-document "${LOGS}" >/dev/null
ok "Role ${ROLE_ARN} (logs-only baseline)"

# ---- Package and create the Lambda -----------------------------------------
bold "3. Package + create the Lambda function"

BUILD="${TUTORIAL_ROOT}/build"
mkdir -p "${BUILD}"
cp "${TUTORIAL_ROOT}/src/handler.py" "${BUILD}/handler.py"
(cd "${BUILD}" && zip -q -FS handler.zip handler.py)
log "Zip built (${BUILD}/handler.zip)"

log "Creating Lambda function ${FN}"
# Retry once in case IAM propagation lags the Lambda service's assume-role check.
for attempt in 1 2 3 4 5; do
  if awsx lambda create-function \
      --function-name "${FN}" \
      --runtime python3.11 \
      --handler handler.handler \
      --role "${ROLE_ARN}" \
      --zip-file fileb://"${BUILD}/handler.zip" \
      --timeout 30 \
      --environment "Variables={CONFIG_BUCKET=${BUCKET},EVENT_TABLE=${TABLE},NOTIFY_TOPIC=${TOPIC_ARN},KMS_KEY_ID=${KEY_ID},SSM_PARAM_NAME=${PARAM},SECRET_ID=${SECRET_ARN},KMS_CIPHERTEXT_B64=${CIPHERTEXT_B64}}" \
      --query 'FunctionArn' --output text >/dev/null 2>&1; then
    break
  fi
  [[ ${attempt} -eq 5 ]] && fail "create-function failed after 5 attempts"
  sleep 2
done
awsx lambda wait function-active --function-name "${FN}"
ok "Lambda ${FN} Active"

# ---- Persist ids for later steps -------------------------------------------
state_set BUCKET     "${BUCKET}"
state_set TABLE      "${TABLE}"
state_set KEY_ID     "${KEY_ID}"
state_set KEY_ARN    "${KEY_ARN}"
state_set PARAM      "${PARAM}"
state_set PARAM_ARN  "${PARAM_ARN}"
state_set SECRET     "${SECRET}"
state_set SECRET_ARN "${SECRET_ARN}"
state_set TOPIC_ARN  "${TOPIC_ARN}"
state_set ROLE       "${ROLE}"
state_set ROLE_ARN   "${ROLE_ARN}"
state_set FN         "${FN}"

ok "Setup complete. Ids in ${STATE_DIR}/ids.env"
