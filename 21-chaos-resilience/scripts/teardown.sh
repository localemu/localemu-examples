#!/usr/bin/env bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

need_healthy_localemu
state_load

log "== Cleanup =="
try() { "$@" 2>/dev/null || true; }

try awsx lambda delete-function --function-name "${FN:-chaos-resilient-writer}"
for p in $(awsx iam list-role-policies --role-name "${ROLE:-chaos-lambda-role}" \
             --query 'PolicyNames' --output text 2>/dev/null); do
  try awsx iam delete-role-policy --role-name "${ROLE:-chaos-lambda-role}" --policy-name "$p"
done
try awsx iam delete-role --role-name "${ROLE:-chaos-lambda-role}"
try awsx dynamodb delete-table --table-name "${TABLE:-chaos-writes}"

rm -rf "${STATE_DIR}" "${TUTORIAL_ROOT}/build"
ok "Cleanup complete."
