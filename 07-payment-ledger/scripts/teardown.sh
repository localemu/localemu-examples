#!/usr/bin/env bash
set -euo pipefail
TARGET="${1:-local}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE/terraform"

terraform destroy -auto-approve -input=false -var "target=$TARGET"

echo
echo "→ verifying teardown for prefix 'le-pay' on $TARGET"

if [[ "$TARGET" == "local" ]]; then
  ENDPOINT_FLAG="--endpoint-url http://localhost:4566"
else
  ENDPOINT_FLAG=""
fi

leaks=0
for t in le-pay-accounts le-pay-ledger le-pay-idempotency; do
  if aws dynamodb describe-table --table-name "$t" $ENDPOINT_FLAG --region us-east-1 2>/dev/null; then
    echo "  LEAK: dynamodb table $t still exists"
    leaks=$((leaks+1))
  fi
done
if aws lambda get-function --function-name "le-pay-api" $ENDPOINT_FLAG --region us-east-1 2>/dev/null; then
  echo "  LEAK: lambda le-pay-api still exists"
  leaks=$((leaks+1))
fi
if aws events describe-event-bus --name "le-pay-bus" $ENDPOINT_FLAG --region us-east-1 2>/dev/null; then
  echo "  LEAK: event bus le-pay-bus still exists"
  leaks=$((leaks+1))
fi

if [[ $leaks -eq 0 ]]; then
  echo "  clean: nothing left behind"
fi
exit $leaks
