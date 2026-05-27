#!/usr/bin/env bash
# Step 03: fault injection. Run three failure scenarios and assert
# that the saga's compensations leave the system in a clean state
# (the items written by the steps that succeeded BEFORE the failure
# must be deleted by the corresponding Compensate* state).
#
#   fail_at=charge  -> Reserve OK, Charge fails
#                       -> CompensateReserve fires
#                       -> inventory empty
#   fail_at=ship    -> Reserve+Charge OK, Ship fails
#                       -> CompensateCharge -> CompensateReserve
#                       -> inventory empty, payments empty
#   fail_at=notify  -> Reserve+Charge+Ship OK, Notify fails
#                       -> CompensateShip -> CompensateCharge -> CompensateReserve
#                       -> all three tables empty

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

need_healthy_localemu
state_load
: "${SM_ARN:?run infra/01_setup.sh first}"

bold "6. Fault injection: three failure scenarios, all must compensate cleanly"

run_failure() {
  local fail_at="$1"; shift
  local empty_tables=("$@")
  local order_id="fail-${fail_at}-$(date +%s)"

  log "Scenario: fail_at=${fail_at}  order_id=${order_id}"
  local status
  status=$(start_and_wait "${SM_ARN}" \
    "{\"order_id\":\"${order_id}\",\"qty\":1,\"amount\":99,\"fail_at\":\"${fail_at}\"}")
  if [[ "${status}" != "FAILED" ]]; then
    fail "expected FAILED (saga should reach FailHandler), got ${status}"
  fi
  ok "  execution status = FAILED (FailHandler reached)"

  for t in "${empty_tables[@]}"; do
    if ddb_has "${t}" "${order_id}"; then
      fail "  ${t} still has ${order_id}: compensation did not fire"
    fi
    ok "  ${t} is clean for ${order_id}"
  done
}

run_failure charge "${INV}"
run_failure ship   "${INV}" "${PAY}"
run_failure notify "${INV}" "${PAY}" "${SHIP}"

ok "All three failure scenarios compensated cleanly."
