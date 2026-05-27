#!/usr/bin/env bash
# Step 02: happy path. Start an execution with no fault, expect
# SUCCEEDED, and verify all three tables hold the order's row.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

need_healthy_localemu
state_load
: "${SM_ARN:?run infra/01_setup.sh first}"

bold "5. Happy path: invoke saga, expect SUCCEEDED + all 3 tables populated"

ORDER_ID="happy-$(date +%s)"
log "Starting execution for order_id=${ORDER_ID}"

STATUS=$(start_and_wait "${SM_ARN}" "{\"order_id\":\"${ORDER_ID}\",\"qty\":2,\"amount\":199}")

if [[ "${STATUS}" != "SUCCEEDED" ]]; then
  fail "expected SUCCEEDED, got ${STATUS}"
fi
ok "Execution status = SUCCEEDED"

log "Asserting DDB state"
ddb_has "${INV}"  "${ORDER_ID}" && ok "  inventory has ${ORDER_ID}"  || fail "inventory missing ${ORDER_ID}"
ddb_has "${PAY}"  "${ORDER_ID}" && ok "  payments has ${ORDER_ID}"   || fail "payments missing ${ORDER_ID}"
ddb_has "${SHIP}" "${ORDER_ID}" && ok "  shipments has ${ORDER_ID}"  || fail "shipments missing ${ORDER_ID}"

state_set HAPPY_ORDER_ID "${ORDER_ID}"
ok "Happy path verified: all forward steps committed their side effects."
