#!/usr/bin/env bash
# Best-effort teardown: swallows per-resource errors so a partial
# state from a failed run still gets cleaned up.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

need_healthy_localemu
state_load

log "== Cleanup =="
try() { "$@" 2>/dev/null || true; }

if [[ -n "${SM_ARN:-}" ]]; then
  try awsx stepfunctions delete-state-machine --state-machine-arn "${SM_ARN}"
fi

for step in reserve charge ship notify comp_ship comp_charge comp_reserve; do
  try awsx lambda delete-function --function-name "saga-${step}"
done

for r in "${LAMBDA_ROLE:-saga-lambda-role}" "${SFN_ROLE:-saga-sfn-role}"; do
  for p in $(awsx iam list-role-policies --role-name "${r}" \
               --query 'PolicyNames' --output text 2>/dev/null); do
    try awsx iam delete-role-policy --role-name "${r}" --policy-name "$p"
  done
  try awsx iam delete-role --role-name "${r}"
done

try awsx sns delete-topic --topic-arn "${TOPIC_ARN:-arn:aws:sns:us-east-1:000000000000:saga-notifications}"

for t in "${INV:-saga-inventory}" "${PAY:-saga-payments}" "${SHIP:-saga-shipments}"; do
  try awsx dynamodb delete-table --table-name "${t}"
done

rm -rf "${STATE_DIR}" "${TUTORIAL_ROOT}/build"
ok "Cleanup complete."
