#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:-local}"
STACK="${STACK_NAME:-le-events}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "$TARGET" == "local" ]]; then
  ENDPOINT=(--endpoint-url http://localhost:4566)
  export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY AWS_DEFAULT_REGION=us-east-1
else
  ENDPOINT=()
fi

echo "→ deploying CloudFormation stack '$STACK' to $TARGET"

# create-stack if absent, else update-stack (ignoring no-change errors)
if aws cloudformation describe-stacks --stack-name "$STACK" "${ENDPOINT[@]}" >/dev/null 2>&1; then
  ACTION=update-stack
else
  ACTION=create-stack
fi

set +e
aws cloudformation "$ACTION" \
  --stack-name "$STACK" \
  --template-body "file://$HERE/cfn/stack.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  "${ENDPOINT[@]}" 2>&1 | tee /tmp/cfn-deploy-$$.log
STATUS=$?
set -e
if grep -q "No updates are to be performed" /tmp/cfn-deploy-$$.log; then
  echo "  no changes"
  STATUS=0
fi
rm -f /tmp/cfn-deploy-$$.log
[[ $STATUS -eq 0 ]] || exit $STATUS

WAIT_CMD=stack-create-complete
[[ "$ACTION" == "update-stack" ]] && WAIT_CMD=stack-update-complete
echo "  waiting for $WAIT_CMD..."
aws cloudformation wait $WAIT_CMD --stack-name "$STACK" "${ENDPOINT[@]}" || true

echo
echo "→ deployed to $TARGET. outputs:"
aws cloudformation describe-stacks --stack-name "$STACK" "${ENDPOINT[@]}" \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' --output table
