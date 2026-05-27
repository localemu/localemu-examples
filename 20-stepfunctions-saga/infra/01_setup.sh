#!/usr/bin/env bash
# Step 01: create the saga's resources:
#   * 3 DynamoDB tables (inventory, payments, shipments)
#   * 1 SNS topic (notifications)
#   * 1 Lambda role with PutItem/DeleteItem on the tables and Publish
#   * 1 Step Functions role with lambda:InvokeFunction
#   * 7 Lambda functions (4 forward + 3 compensations), all from the
#     same handler.py, with STEP_NAME env var picking the branch at runtime
#   * 1 Step Functions state machine wiring the saga

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

need_healthy_localemu
rm -f "${STATE_DIR}/ids.env"

PFX=saga
INV="${PFX}-inventory"
PAY="${PFX}-payments"
SHIP="${PFX}-shipments"
TOPIC_NAME="${PFX}-notifications"
LAMBDA_ROLE="${PFX}-lambda-role"
SFN_ROLE="${PFX}-sfn-role"
SM_NAME="${PFX}-order-saga"

# ---- Best-effort cleanup (re-runnable) -------------------------------------
_cleanup_silent() {
  local sm_arn
  sm_arn=$(awsx stepfunctions list-state-machines \
    --query "stateMachines[?name=='${SM_NAME}'].stateMachineArn | [0]" \
    --output text 2>/dev/null || echo "None")
  [[ "${sm_arn}" != "None" && -n "${sm_arn}" ]] && \
    awsx stepfunctions delete-state-machine --state-machine-arn "${sm_arn}" >/dev/null 2>&1 || true
  for step in reserve charge ship notify comp_ship comp_charge comp_reserve; do
    awsx lambda delete-function --function-name "${PFX}-${step}" >/dev/null 2>&1 || true
  done
  for r in "${LAMBDA_ROLE}" "${SFN_ROLE}"; do
    for p in $(awsx iam list-role-policies --role-name "${r}" \
                 --query 'PolicyNames' --output text 2>/dev/null); do
      awsx iam delete-role-policy --role-name "${r}" --policy-name "$p" >/dev/null 2>&1 || true
    done
    awsx iam delete-role --role-name "${r}" >/dev/null 2>&1 || true
  done
  awsx sns delete-topic --topic-arn "arn:aws:sns:${AWS_REGION}:000000000000:${TOPIC_NAME}" >/dev/null 2>&1 || true
  for t in "${INV}" "${PAY}" "${SHIP}"; do
    awsx dynamodb delete-table --table-name "${t}" >/dev/null 2>&1 || true
  done
}

log "Clearing any previous run state (best effort)"
_cleanup_silent
ok "Clean slate"

bold "1. Create DynamoDB tables + SNS topic"

for t in "${INV}" "${PAY}" "${SHIP}"; do
  log "Creating table ${t}"
  awsx dynamodb create-table \
    --table-name "${t}" \
    --attribute-definitions AttributeName=order_id,AttributeType=S \
    --key-schema AttributeName=order_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
done
for t in "${INV}" "${PAY}" "${SHIP}"; do
  awsx dynamodb wait table-exists --table-name "${t}"
  ok "Table ${t} ACTIVE"
done

log "Creating SNS topic ${TOPIC_NAME}"
TOPIC_ARN=$(awsx sns create-topic --name "${TOPIC_NAME}" \
  --query 'TopicArn' --output text)
ok "Topic ${TOPIC_ARN}"

bold "2. Create IAM roles"

LAMBDA_TRUST=$(cat <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
)
log "Creating Lambda role ${LAMBDA_ROLE}"
LAMBDA_ROLE_ARN=$(awsx iam create-role --role-name "${LAMBDA_ROLE}" \
  --assume-role-policy-document "${LAMBDA_TRUST}" \
  --query 'Role.Arn' --output text)

LAMBDA_POLICY=$(cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],"Resource":"*"},
 {"Effect":"Allow","Action":["dynamodb:PutItem","dynamodb:DeleteItem"],"Resource":"arn:aws:dynamodb:${AWS_REGION}:000000000000:table/${PFX}-*"},
 {"Effect":"Allow","Action":["sns:Publish"],"Resource":"${TOPIC_ARN}"}
]}
JSON
)
awsx iam put-role-policy --role-name "${LAMBDA_ROLE}" \
  --policy-name saga-lambda --policy-document "${LAMBDA_POLICY}" >/dev/null
ok "Lambda role ${LAMBDA_ROLE_ARN}"

SFN_TRUST=$(cat <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"states.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
)
log "Creating Step Functions role ${SFN_ROLE}"
SFN_ROLE_ARN=$(awsx iam create-role --role-name "${SFN_ROLE}" \
  --assume-role-policy-document "${SFN_TRUST}" \
  --query 'Role.Arn' --output text)

SFN_POLICY=$(cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["lambda:InvokeFunction"],"Resource":"arn:aws:lambda:${AWS_REGION}:000000000000:function:${PFX}-*"}
]}
JSON
)
awsx iam put-role-policy --role-name "${SFN_ROLE}" \
  --policy-name saga-sfn --policy-document "${SFN_POLICY}" >/dev/null
ok "Step Functions role ${SFN_ROLE_ARN}"

bold "3. Package + create the seven Lambda functions"

BUILD="${TUTORIAL_ROOT}/build"
mkdir -p "${BUILD}"
cp "${TUTORIAL_ROOT}/src/handler.py" "${BUILD}/handler.py"
(cd "${BUILD}" && zip -q -FS handler.zip handler.py)
ok "Zip built"

declare -a STEPS=(reserve charge ship notify comp_ship comp_charge comp_reserve)
declare -A ARN

for step in "${STEPS[@]}"; do
  fn="${PFX}-${step}"
  log "Creating Lambda ${fn}"
  for attempt in 1 2 3 4 5; do
    if arn=$(awsx lambda create-function \
        --function-name "${fn}" \
        --runtime python3.11 \
        --handler handler.handler \
        --role "${LAMBDA_ROLE_ARN}" \
        --zip-file fileb://"${BUILD}/handler.zip" \
        --timeout 30 \
        --environment "Variables={STEP_NAME=${step},INVENTORY_TABLE=${INV},PAYMENTS_TABLE=${PAY},SHIPMENTS_TABLE=${SHIP},NOTIFICATIONS_TOPIC=${TOPIC_ARN}}" \
        --query 'FunctionArn' --output text 2>/dev/null); then
      break
    fi
    [[ ${attempt} -eq 5 ]] && fail "create-function ${fn} failed after 5 attempts"
    sleep 2
  done
  awsx lambda wait function-active --function-name "${fn}"
  ARN[$step]="${arn}"
  ok "  ${fn} ${arn}"
done

bold "4. Create the state machine"

ASL=$(cat <<JSON
{
  "Comment": "Order saga: reserve -> charge -> ship -> notify with cascading compensations",
  "StartAt": "ReserveInventory",
  "States": {
    "ReserveInventory": {
      "Type": "Task",
      "Resource": "${ARN[reserve]}",
      "Next": "ChargePayment",
      "Catch": [{"ErrorEquals":["States.ALL"],"Next":"FailHandler","ResultPath":"$.error"}]
    },
    "ChargePayment": {
      "Type": "Task",
      "Resource": "${ARN[charge]}",
      "Next": "CreateShipment",
      "Catch": [{"ErrorEquals":["States.ALL"],"Next":"CompensateReserve","ResultPath":"$.error"}]
    },
    "CreateShipment": {
      "Type": "Task",
      "Resource": "${ARN[ship]}",
      "Next": "SendNotification",
      "Catch": [{"ErrorEquals":["States.ALL"],"Next":"CompensateCharge","ResultPath":"$.error"}]
    },
    "SendNotification": {
      "Type": "Task",
      "Resource": "${ARN[notify]}",
      "End": true,
      "Catch": [{"ErrorEquals":["States.ALL"],"Next":"CompensateShip","ResultPath":"$.error"}]
    },
    "CompensateShip": {
      "Type": "Task",
      "Resource": "${ARN[comp_ship]}",
      "Next": "CompensateCharge"
    },
    "CompensateCharge": {
      "Type": "Task",
      "Resource": "${ARN[comp_charge]}",
      "Next": "CompensateReserve"
    },
    "CompensateReserve": {
      "Type": "Task",
      "Resource": "${ARN[comp_reserve]}",
      "Next": "FailHandler"
    },
    "FailHandler": {
      "Type": "Fail",
      "Cause": "saga compensated"
    }
  }
}
JSON
)

# Retry to absorb IAM propagation
for attempt in 1 2 3 4 5; do
  if SM_ARN=$(awsx stepfunctions create-state-machine \
      --name "${SM_NAME}" \
      --definition "${ASL}" \
      --role-arn "${SFN_ROLE_ARN}" \
      --query 'stateMachineArn' --output text 2>/dev/null); then
    break
  fi
  [[ ${attempt} -eq 5 ]] && fail "create-state-machine failed after 5 attempts"
  sleep 2
done
ok "State machine ${SM_ARN}"

# ---- Persist ids -----------------------------------------------------------
state_set INV         "${INV}"
state_set PAY         "${PAY}"
state_set SHIP        "${SHIP}"
state_set TOPIC_ARN   "${TOPIC_ARN}"
state_set LAMBDA_ROLE "${LAMBDA_ROLE}"
state_set SFN_ROLE    "${SFN_ROLE}"
state_set SM_ARN      "${SM_ARN}"
state_set SM_NAME     "${SM_NAME}"

ok "Setup complete. Ids in ${STATE_DIR}/ids.env"
