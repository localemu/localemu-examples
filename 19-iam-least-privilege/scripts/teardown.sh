#!/usr/bin/env bash
# Teardown. Best-effort: swallows per-resource errors so a partial
# state from a failed run still gets cleaned up.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"

need_healthy_localemu
state_load

log "== Cleanup =="
try() { "$@" 2>/dev/null || true; }

try awsx lambda delete-function --function-name "${FN:-iam-mvp-target}"

# Delete all inline policies before the role can be removed.
ROLE_NAME="${ROLE:-iam-mvp-lambda-role}"
for p in $(awsx iam list-role-policies --role-name "${ROLE_NAME}" \
             --query 'PolicyNames' --output text 2>/dev/null); do
  try awsx iam delete-role-policy --role-name "${ROLE_NAME}" --policy-name "$p"
done
try awsx iam delete-role --role-name "${ROLE_NAME}"

try awsx sns delete-topic --topic-arn "${TOPIC_ARN:-arn:aws:sns:us-east-1:000000000000:iam-mvp-notify}"
try awsx secretsmanager delete-secret --secret-id "${SECRET:-iam-mvp/api-key}" --force-delete-without-recovery
try awsx ssm delete-parameter --name "${PARAM:-/iam-mvp/runtime-config}"
try awsx dynamodb delete-table --table-name "${TABLE:-iam-mvp-events}"
try awsx s3 rm "s3://${BUCKET:-iam-mvp-config}" --recursive
try awsx s3api delete-bucket --bucket "${BUCKET:-iam-mvp-config}"
# KMS keys can only be scheduled for deletion (min 7 days on real AWS;
# LocalEmu accepts the same API).
if [[ -n "${KEY_ID:-}" ]]; then
  try awsx kms schedule-key-deletion --key-id "${KEY_ID}" --pending-window-in-days 7
fi

rm -rf "${STATE_DIR}" "${TUTORIAL_ROOT}/build"
ok "Cleanup complete."
